# Phase 2 (v2) — UI 재구축

## 목적

- Barik의 패널 구조를 그대로 가져와서 화면을 띄운다.
- Phase 1의 `SpaceEngine` 연결은 이후에 한다. 먼저 **하드코딩된 더미 데이터로 화면이 정상 표시되는지 검증**한다.

## Barik 패널 구조 (그대로 차용)

Barik은 작은 패널이 아니라 **전체 화면 크기의 투명 NSPanel**을 만들고, SwiftUI가 내부에서 콘텐츠를 배치한다.

```text
NSPanel (full screen frame)
├── level: .backstopMenu (메뉴바 아래, 일반 윈도우 아래)
├── styleMask: [.nonactivatingPanel]
├── backgroundColor: .clear
├── hasShadow: false
├── collectionBehavior: [.canJoinAllSpaces]
├── contentView: NSHostingView
│   └── SpaceBarView (SwiftUI)
│       └── 좌하단에 고정된 bar pill
```

### 핵심 차이점 (기존 vs Barik 방식)

| 항목 | 기존 방식 | Barik 방식 (채택) |
|------|----------|------------------|
| 패널 크기 | 콘텐츠 크기에 맞춤 | **전체 화면** |
| 패널 위치 | frame 좌표 계산 | **SwiftUI가 내부 배치** |
| 크기 변경 | panel.setFrame 호출 | **SwiftUI 자동 레이아웃** |
| 공간 전환 글리치 | frame 조작으로 발생 | **frame 불변, 글리치 없음** |

## 위치

- Dock과 같은 Y레벨, 좌측 (Barik은 우측)
- SwiftUI에서 `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)` + padding

## UI 레이아웃

```text
┌─────────────────────────────────────────────┐
│ [숫자]  [컨텍스트 라벨]  │  [앱아이콘] [앱아이콘] ... │
└─────────────────────────────────────────────┘
```

- 숫자: 현재 스페이스 번호 (예: "1")
- 컨텍스트: 스페이스 라벨 (예: "Work")
- 구분자: Barik 스타일 세로 Capsule
- 앱 아이콘: 현재 스페이스의 앱 아이콘 목록

## 스타일

- Barik 참고: 테두리 없음, 반투명 검정 배경 (0.55), 라운드 코너 9pt
- 텍스트: 흰색 (0.9 opacity), 라벨은 (0.55 opacity)
- 구분자: Capsule, 흰색 0.2 opacity, 높이 12pt
- 블러 효과 사용하지 않음 (캡처 프로그램 충돌 이슈)

## 구현 파일

| 파일 | 역할 |
|------|------|
| `Panel/SpacePanel.swift` | NSPanel 서브클래스 (Barik의 패널 설정 그대로) |
| `Panel/SpacePanelController.swift` | 패널 생성/관리, 화면 변경 대응 |
| `Views/SpaceBarView.swift` | SwiftUI 메인 뷰 (좌하단 pill bar) |

## Step 1: 더미 데이터로 화면 띄우기

1. `SpacePanel` 생성 — 전체 화면 투명 패널
2. `SpaceBarView` 생성 — 하드코딩 데이터로 렌더링
   - 숫자: "1"
   - 라벨: "Work"  
   - 아이콘: NSWorkspace.shared.icon (Finder, Safari, Terminal 등 3-4개)
3. `SpacePanelController` 생성 — 패널에 SwiftUI 뷰 연결
4. `AppDelegate`에서 `SpacePanelController` 생성
5. 빌드 → 실행 → 스크린샷으로 위치/디자인 검증

### 검증 기준

- [ ] 앱 실행 시 좌하단에 bar pill이 보인다
- [ ] Dock과 같은 Y레벨에 위치한다
- [ ] 숫자, 라벨, 구분자, 아이콘이 모두 표시된다
- [ ] 패널이 다른 윈도우 뒤에 있다 (backstopMenu 레벨)
- [ ] 스페이스 전환 시 패널 크기/위치 글리치 없다
- [ ] 캡처 프로그램 실행 시 시각적 문제 없다

## Step 2: SpaceEngine 연결

- `SpacePanelController`가 `SpaceEngine.$snapshot`을 구독
- `DockSnapshot` → `SpaceBarView` 데이터 매핑
- 더미 데이터 제거

## Step 3: 전환 검증

- 스페이스 전환 시 번호/라벨/아이콘 갱신 확인
- 크기 변경 글리치 없음 확인 (패널 frame이 불변이므로)
- 앱 실행/종료 시 아이콘 목록 갱신 확인
