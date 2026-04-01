# SpaceWidget — 구현 계획

## 배경

`space-dock-widget`의 구조적 문제를 해결하기 위한 재구축:
- DockProcessController와 DockViewModel이 동일한 역할을 이중으로 수행
- SpaceMonitor가 3개의 중복 @Published 프로퍼티 발행
- background thread에서 @Published 프로퍼티 읽기 (data race)
- StateWriter/ConfigManager의 이중 atomic write
- 모든 의존성이 내부 생성 (테스트 불가, 교체 불가)

## 핵심 설계: 단일 데이터 파이프라인

```
SpaceMonitor + WindowListProvider + ConfigManager
                    ↓
              SpaceEngine           ← 유일한 데이터 소유자
              publishes DockSnapshot
                    ↓
         ┌──────────┼───────────┐
         ↓          ↓           ↓
   StateWriter    Log      DockUIModel (optional)
   (subscribe)              (subscribe → UI state)
                                 ↓
                            Views/Panel
```

**SpaceEngine**: SpaceMonitor + WindowListProvider를 소유. `@Published snapshot: DockSnapshot` 하나만 발행.
**DockUIModel**: SpaceEngine의 snapshot을 구독. UI 전용 상태(loading, locked width, display phase)만 관리.
**StateWriter**: SpaceEngine의 snapshot을 독립적으로 구독하여 state.json 기록.

## 폴더 구조

```
space-widget/
├── Package.swift
├── Makefile
├── PLAN.md
├── scripts/
│   ├── ignore-apps
│   ├── app-actions
│   └── reload
└── Sources/SpaceWidget/
    ├── App/
    │   ├── SpaceWidgetApp.swift           # @main, CLI args, AppDelegate
    │   ├── MenuBarController.swift        # NSStatusItem 메뉴바
    │   └── AccessibilityChecker.swift     # AX 권한 체크
    ├── Engine/
    │   ├── SpaceEngine.swift              # 단일 데이터 파이프라인 (NEW)
    │   ├── SpaceMonitor.swift             # Space 변경 감지 (정리됨)
    │   ├── WindowListProvider.swift       # 윈도우 목록 수집
    │   └── CGSPrivate.swift               # SkyLight private API
    ├── Models/
    │   ├── ActiveSpace.swift              # Space ID + ordinal
    │   ├── DockItem.swift                 # 앱 모델
    │   ├── DockSnapshot.swift             # 스냅샷 모델 (개선됨)
    │   └── SpaceInfo.swift                # UI용 Space 모델
    ├── Config/
    │   ├── ConfigManager.swift            # 설정 읽기/쓰기 (atomicWrite 단순화)
    │   ├── FileWatcher.swift              # 파일 변경 감시
    │   ├── StateWriter.swift              # state.json (단순화 + subscribe)
    │   ├── DockMetrics.swift              # Dock 크기 계산
    │   ├── Theme.swift                    # 색상 상수
    │   └── Migrator.swift                 # Lua→JSON 마이그레이션
    ├── ViewModels/
    │   └── DockUIModel.swift              # UI 전용 ViewModel (NEW)
    ├── Panel/
    │   ├── DockPanel.swift                # NSPanel 서브클래스
    │   ├── DockPanelController.swift      # 패널 위치/크기 (DockUIModel 사용)
    │   └── DockBarLayout.swift            # 폭 계산
    ├── Views/
    │   ├── DockBarView.swift              # 루트 SwiftUI (DockUIModel 사용)
    │   ├── SpaceBadgeView.swift           # Space 배지 (DockUIModel 사용)
    │   └── AppIconView.swift              # 앱 아이콘 + 인터랙션
    └── Actions/
        ├── AppActivator.swift             # 앱 활성화/숨기기/종료
        └── AppleScriptBridge.swift        # 앱별 새 윈도우 전략
```

## 파일별 명세

### Models

**ActiveSpace.swift** — SpaceMonitor에서 분리
```swift
struct ActiveSpace: Equatable {
    let id: UInt64
    let ordinal: Int
}
```

**DockSnapshot.swift** — 기존 대비 개선: items를 [DockItem]으로 직접 포함
```swift
struct DockSnapshot: Equatable {
    let space: ActiveSpace
    let spaceLabel: String
    let items: [DockItem]           // 이름/ID 배열 대신 전체 DockItem
    let focusedBundleID: String?
    let capturedAt: Date

    var spaceNumber: Int { space.ordinal }
    var spaceID: UInt64 { space.id }
    var appBundleIDs: [String] { items.map(\.id) }
    var appNames: [String] { items.map(\.name) }
}
```

**DockItem.swift** — 기존과 동일
**SpaceInfo.swift** — 기존과 동일

### Engine

**SpaceMonitor.swift** — 정리됨
- `@Published currentSpaceID`, `@Published currentSpaceNumber` 제거
- `@Published currentSpace: ActiveSpace` 하나만 유지
- 나머지 로직(debounce, computeOrdinal, fallback) 동일

**SpaceEngine.swift** — NEW. 핵심 변경점
```swift
final class SpaceEngine: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot

    let configManager: ConfigManager
    private let spaceMonitor: SpaceMonitor
    private let windowListProvider: WindowListProvider
    private var cancellables = Set<AnyCancellable>()
    private var refreshWorkItem: DispatchWorkItem?

    init(configManager: ConfigManager,
         spaceMonitor: SpaceMonitor = SpaceMonitor(),
         windowListProvider: WindowListProvider = WindowListProvider())
}
```

주요 메서드:
- `observeSpaceChanges()` — spaceMonitor.$currentSpace 구독
- `observeConfigChanges()` — configManager.$spaceLabels, $ignoredApps 구독
- `observeWorkspaceNotifications()` — didActivate, didLaunch, didTerminate
- `captureSnapshot(reason:activeSpace:)` — **main thread에서 ignoredApps 캡처 후** background fetch
- `scheduleRefresh(reason:delay:)` — debounce 패턴
- `refresh()` — 외부 호출용

로그 태그: `[SPACE]`, `[FETCH]`, `[SNAPSHOT]` — 기존과 동일

**WindowListProvider.swift** — 기존과 동일
**CGSPrivate.swift** — 기존과 동일

### Config

**ConfigManager.swift** — atomicWrite 단순화
```swift
// 기존: Data.write(.atomic) → tmp 생성 → replaceItemAt (이중 atomic)
// 변경: Data.write(to: url, options: .atomic) 한 번만
```
나머지 로직(load, reload, save*, FileWatcher self-write suppression) 동일

**StateWriter.swift** — 단순화 + Combine 구독
```swift
final class StateWriter {
    init(stateURL: URL? = nil)              // URL 주입 가능
    func subscribe(to: Published<DockSnapshot>.Publisher)  // Combine 연결
    func write(currentSpace: Int, apps: [String])          // 수동 호출도 가능
}
```
- atomicWrite → `Data.write(to:options:.atomic)` 단순화
- debounce 1초 유지

**FileWatcher.swift** — 기존과 동일
**DockMetrics.swift** — 기존과 동일
**Theme.swift** — 기존과 동일
**Migrator.swift** — 기존과 동일

### ViewModels

**DockUIModel.swift** — NEW. DockViewModel의 UI 절반만 담당
```swift
final class DockUIModel: ObservableObject {
    @Published private(set) var currentSpace: SpaceInfo
    @Published var apps: [DockItem] = []
    @Published var isLoading: Bool = false
    @Published var displayPhase: DockDisplayPhase = .loading(width: 300)
    @Published var lastKnownPanelWidth: CGFloat = 300
    @Published var lockedPanelWidth: CGFloat?

    let engine: SpaceEngine
    var configManager: ConfigManager { engine.configManager }

    init(engine: SpaceEngine)
}
```

핵심 메서드:
- `handleSnapshot(_:)` — space 변경 시 loading 트랜지션, 같은 space면 직접 적용
- `moveApp(from:to:)`, `cacheWidth(_:for:)`, `updateSpaceLabel(ordinal:label:)` — 기존 동일
- `stableSort(items:order:)` — 기존 동일
- `scheduleWidthUnlock(for:)` — 기존 동일

**제거된 것**: SpaceMonitor 소유, WindowListProvider 소유, StateWriter 소유, FileWatcher 소유, NSWorkspace 알림 직접 구독, fetchAppsForGeneration의 validation double-fetch

### Panel / Views / Actions

기존 코드와 동일. 변경점:
- `DockPanelController`: `DockViewModel` → `DockUIModel` (init 주입)
- `DockBarView`, `SpaceBadgeView`: `viewModel: DockViewModel` → `uiModel: DockUIModel`
- `AppIconView`: 변경 없음
- `DockPanel`, `DockBarLayout`: 변경 없음
- `AppActivator`, `AppleScriptBridge`: 변경 없음

### App

**SpaceWidgetApp.swift** — 조립 구조 변경
```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    let configManager = ConfigManager()

    // 파일 감시
    let watcher = FileWatcher(url: ConfigManager.configDir, configManager: configManager)
    DispatchQueue.global(qos: .utility).async { watcher.start() }

    // 단일 엔진
    let engine = SpaceEngine(configManager: configManager)

    // 상태 기록 (엔진 구독)
    let writer = StateWriter()
    writer.subscribe(to: engine.$snapshot)

    // UI (선택적)
    let uiModel = DockUIModel(engine: engine)
    panelController = DockPanelController(uiModel: uiModel)

    // 메뉴바
    menuBarController = MenuBarController(configManager: configManager)
}
```

## Combine 데이터 흐름

```
SpaceMonitor.$currentSpace
    │
    └─→ SpaceEngine.observeSpaceChanges()
          │
          ▼
        captureSnapshot() → global queue → fetchItems()
          │   (ignoredApps는 main에서 캡처 후 전달 — data race 해결)
          │   (spaceLabels는 main에서 읽음)
          │
          ▼
        SpaceEngine.$snapshot (main thread)
          │
          ├─→ StateWriter.subscribe() → debounced write → state.json
          │
          └─→ DockUIModel.handleSnapshot()
                │
                ├─ space 변경 → loading transition → delayed apply
                └─ 같은 space → stableSort → 직접 적용
                │
                ▼
              DockUIModel.$apps, $currentSpace, $displayPhase
                │
                └─→ DockBarView → SpaceBadgeView + AppIconView[]

NSWorkspace 알림 (activate, launch, terminate)
    │
    └─→ SpaceEngine.scheduleRefresh() → captureSnapshot() → 같은 파이프라인
```

## 구현 단계

### Phase 1: Headless (엔진 + 로그 + state.json)

**목표**: 현재 DockProcessController와 동일한 동작. UI 없음.

**생성 파일** (15개):
1. `Package.swift`
2. `Makefile`
3. `Sources/SpaceWidget/Models/ActiveSpace.swift`
4. `Sources/SpaceWidget/Models/DockItem.swift`
5. `Sources/SpaceWidget/Models/DockSnapshot.swift`
6. `Sources/SpaceWidget/Models/SpaceInfo.swift`
7. `Sources/SpaceWidget/Engine/CGSPrivate.swift`
8. `Sources/SpaceWidget/Engine/SpaceMonitor.swift`
9. `Sources/SpaceWidget/Engine/WindowListProvider.swift`
10. `Sources/SpaceWidget/Engine/SpaceEngine.swift`
11. `Sources/SpaceWidget/Config/ConfigManager.swift`
12. `Sources/SpaceWidget/Config/FileWatcher.swift`
13. `Sources/SpaceWidget/Config/StateWriter.swift`
14. `Sources/SpaceWidget/Config/Migrator.swift`
15. `Sources/SpaceWidget/App/SpaceWidgetApp.swift`

**검증**:
- `swift build` 성공
- Space 전환 시 `[SPACE]`, `[FETCH]`, `[SNAPSHOT]` 로그 출력
- `~/.config/space-dock/state.json` 정상 갱신
- `--version`, `--help`, `--migrate`, `--config-dir` 동작
- `pkill -USR1 SpaceWidget` → config reload
- `ignored_apps.json` 외부 편집 → FileWatcher 감지 → 갱신

**완료 기준**:
- 앱 실행 후 최초 snapshot 1회만 안정적으로 생성
- Space 전환마다 snapshot 정확히 1회 생성
- app activate / launch / terminate 시에만 refresh
- config file watching 없이 정상 동작 (SIGUSR1 수동 reload)
- state.json에 current_space, space_id, space_label, apps 기록
- UI 관련 코드 없음

### Phase 2: Panel + Views (UI 레이어)

**목표**: 플로팅 패널에 SwiftUI 뷰 표시. 기존 시각적 동작 동일.

**생성 파일** (10개):
16. `Sources/SpaceWidget/Config/DockMetrics.swift`
17. `Sources/SpaceWidget/Config/Theme.swift`
18. `Sources/SpaceWidget/Panel/DockBarLayout.swift`
19. `Sources/SpaceWidget/Panel/DockPanel.swift`
20. `Sources/SpaceWidget/ViewModels/DockUIModel.swift`
21. `Sources/SpaceWidget/Panel/DockPanelController.swift`
22. `Sources/SpaceWidget/Views/DockBarView.swift`
23. `Sources/SpaceWidget/Views/SpaceBadgeView.swift`
24. `Sources/SpaceWidget/Views/AppIconView.swift`

**수정**: `SpaceWidgetApp.swift` — DockUIModel + DockPanelController 연결

**검증**:
- 하단 좌측 패널 표시
- Space 전환 시 loading bar → 앱 아이콘 전환
- 패널이 모든 Space에 표시
- 포커스 안 뺏김, Cmd+Tab에 안 나옴
- 호버 애니메이션, 툴팁
- 패널 폭이 앱 수에 따라 조절
- 커스텀 위치 저장

### Phase 3: Interactions + Menu

**목표**: 클릭 액션, 컨텍스트 메뉴, 메뉴바, 접근성 체크.

**생성 파일** (4개):
25. `Sources/SpaceWidget/Actions/AppActivator.swift`
26. `Sources/SpaceWidget/Actions/AppleScriptBridge.swift`
27. `Sources/SpaceWidget/App/MenuBarController.swift`
28. `Sources/SpaceWidget/App/AccessibilityChecker.swift`

**수정**: `SpaceWidgetApp.swift` — MenuBarController + AccessibilityChecker 연결

**검증**:
- 아이콘 클릭 → 앱 활성화 (frontmost면 toggle hide)
- 우클릭 → Hide/Quit/New Window
- Space 배지 클릭 → 라벨 편집
- 드래그 리오더
- 메뉴바 Reload/Quit
- 접근성 권한 프롬프트

### Phase 4: Scripts + Build + Polish

**생성 파일** (3개):
29. `scripts/ignore-apps`
30. `scripts/app-actions`
31. `scripts/reload`

**검증**:
- `make build`, `make install` 성공
- 스크립트 동작 확인
- Dock 크기 변경 시 패널 메트릭 갱신
- 전체 기능 E2E 테스트

## 해결된 문제 요약

| 문제 | 해결 | 위치 |
|------|------|------|
| Controller/ViewModel 이중화 | SpaceEngine 하나로 통합 | `Engine/SpaceEngine.swift` |
| SpaceMonitor 중복 @Published 3개 | `currentSpace` 하나만 유지 | `Engine/SpaceMonitor.swift` |
| background thread data race | main에서 ignoredApps 캡처 후 전달 | `SpaceEngine.captureSnapshot()` |
| 이중 atomic write | `Data.write(to:options:.atomic)` 한 번 | `StateWriter`, `ConfigManager` |
| 의존성 내부 생성 | init 파라미터 주입 + 기본값 | 모든 생성자 |
