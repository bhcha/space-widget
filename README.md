# SpaceWidget

macOS Space별 컨텍스트를 관리하기 위한 플로팅 위젯. 여러 프로젝트를 Space별로 나눠 쓰는 흐름에서, 기본 Dock이 현재 Space의 작업 맥락을 충분히 보여주지 못하는 문제를 보완하기 위해 시작한 프로젝트입니다.

현재 Space의 번호와 컨텍스트 라벨, 해당 Space에서 작업 중인 앱 목록을 하단 패널에 표시하고, 상태를 `state.json`으로 기록합니다.

## Why

mac을 쓰면서 요즘 API 기반 프로젝트를 여러 개 병렬로 다루면, 자연스럽게 Space를 프로젝트 단위 작업 컨텍스트로 쓰게 됩니다. 문제는 기본 Dock이 현재 Space 기준의 맥락을 명확히 보여주지 못한다는 점입니다.

SpaceWidget은 이 지점을 보완합니다.

- 지금 내가 어느 Space에서 작업 중인지 바로 보이게 하고
- 그 Space의 컨텍스트 라벨을 직접 붙일 수 있게 하고
- 현재 작업 중인 앱만 빠르게 훑고 다시 전환할 수 있게 합니다

## Preview

### Menu Bar Icon

![SpaceWidget menu bar icon](docs/assets/icon.png)

### Live Screenshots

![Space 1 screenshot](docs/assets/screenshot-space-1.png)

![Space 2 screenshot](docs/assets/screenshot-space-2.png)

## Features

### Space-Aware Context Bar

- 현재 활성 Space 번호와 컨텍스트 라벨을 좌하단 플로팅 바에 표시
- Space 전환 시 자동 감지 및 갱신
- 라벨 영역 클릭으로 인라인 라벨 편집
- non-desktop space (fullscreen, overlay, tiled) 자동 필터링

### Multi-Monitor Support

- 연결된 디스플레이마다 독립 패널 자동 생성
- 미러링: 주 디스플레이와 동일하게 동작
- 확장 디스플레이: 별도 Space로 인식, 독립 라벨 관리
- 확장 디스플레이 Space 번호는 `-`로 표시
- 디스플레이 연결/분리 시 패널 자동 추가/제거
- 라벨은 안정적인 spaceID에 고정 (Space 순서 변경/풀스크린 전환 시에도 라벨 유지)
- Space 순서 변경 시 ordinal 자동 재바인딩

### Running App Snapshot

- 현재 Space에서 실행 중인 앱을 수집해 아이콘 목록으로 렌더링
- 앱별 윈도우 수 집계
- 포커스된 앱 하이라이트 표시
- 숨김/최소화된 앱 감지 및 표시
- 아이콘 클릭으로 앱 활성화 (최소화/숨김 상태 해제 포함)
- 최대 20개 앱 표시

### Icon Pagination

- 페이지당 아이콘 수 설정 가능 (5~10개, 기본 5)
- 좌우 스와이프로 페이지 전환
- 경계에서 러버밴드 효과
- 하단 페이지 인디케이터 도트
- 포커스된 앱이 있는 페이지로 자동 이동

### Balloon Context Menu

- 앱 아이콘 우클릭 시 말풍선 형태의 컨텍스트 메뉴 표시
- New Window: 새 창 열기 (AX API 메뉴 탐색 → CGEvent Cmd+N 폴백)
- Close from Space: 현재 Space의 해당 앱 윈도우만 닫기 (sticky 윈도우 제외)
- Quit: 앱 종료
- 화면 밖 방지 클램핑

### Window Snapping

단축키로 창을 화면의 특정 영역에 배치:

| 동작 | 기본 단축키 |
|------|------------|
| 왼쪽 절반 | `Cmd+Ctrl+←` |
| 오른쪽 절반 | `Cmd+Ctrl+→` |
| 최대화 | `Cmd+Ctrl+Enter` |
| 최소화 | `Cmd+Ctrl+Esc` |
| 첫 번째 1/3 | `Cmd+Ctrl+D` |
| 가운데 1/3 | `Cmd+Ctrl+F` |
| 마지막 1/3 | `Cmd+Ctrl+G` |
| 첫 번째 2/3 | `Cmd+Ctrl+E` |
| 가운데 2/3 | `Cmd+Ctrl+V` |
| 마지막 2/3 | `Cmd+Ctrl+T` |

모든 단축키는 Preferences에서 커스터마이즈 가능합니다.

### Layout Templates

- 윈도우 레이아웃 템플릿 생성/편집/삭제/복제
- 템플릿에 윈도우 배치 존(zone) 정의 (WindowAction 기반)
- 존별 앱 bundle ID 할당
- 템플릿별 키보드 단축키 지정
- Space별 Auto-Apply: Space 전환 시 자동으로 템플릿 적용
- Launch Closed Apps: 템플릿 적용 시 실행되지 않은 앱 자동 실행

### Hidden Apps

- Preferences → Hidden Apps 탭에서 위젯 바에 표시하지 않을 앱 관리
- SpaceWidget은 기본 제외 항목 (삭제 불가)
- Add App 버튼으로 설치된 앱(.app) 선택하여 제외 목록에 추가
- 스크린 캡처 도구(Flameshot 등) 사용 시 위젯 패널이 캡처에 포함되지 않음

### Desktop Switcher

- Space 번호 클릭 시 해당 디스플레이의 전체 데스크탑 목록 팝업 표시
- 목록에서 데스크탑 선택 시 CGEvent dock-swipe 합성으로 즉시 전환
- Ctrl+N 키보드 단축키 폴백 (시스템 설정에서 활성화된 경우)
- 멀티 디스플레이: active display 검증 가드로 잘못된 디스플레이 전환 방지
- 전환 후 실제 Space 변경 검증 (실패 시 자동 폴백)

### Dock Overlap Detection

- Dock과 위젯 바가 겹칠 때 페이지당 아이콘 수를 자동으로 축소
- 설정: `enabled` (활성화), `min_icons` (최소 아이콘 수 2~10), `reduce_step` (축소 단위 1~2)
- Dock 위치/크기 변경 시 실시간 재계산
- 축소해도 겹침이 해소되지 않으면 원래 설정 유지

### Auto-Hide

- 바 자동 숨김 모드 토글
- 마우스를 바 영역에 올리면 표시, 떠나면 0.3초 후 숨김
- Hot Zone 감지 영역으로 마우스 진입/이탈 추적

### Dock Control

macOS Dock 동작 제어 (CoreDock private framework 사용):

| 모드 | 설명 |
|------|------|
| Auto Hide | 기본 macOS 자동 숨김 동작 |
| Always Hide | 영구 숨김 (대기 시간 극대화) |
| Always Show | 항상 표시 |

앱 종료 시 원래 Dock 설정 복원.

### Menu Bar

메뉴바 아이콘으로 빠른 설정 접근:

- Auto Hide 토글
- Icons per Page 설정 (5~10)
- Dock 모드 선택
- Layout 템플릿 목록 및 적용
- Auto-Apply 토글
- Preferences 열기
- Quit SpaceWidget

### Preferences UI

- **Shortcuts 탭**: 윈도우 스냅 단축키 활성화/비활성화, 새 단축키 녹화, 기본값 복원
- **Layouts 탭**: 레이아웃 템플릿 생성/편집/삭제, 앱 할당, Space별 Auto-Apply 설정
- **Hidden Apps 탭**: 위젯 바에서 제외할 앱 관리 (기본 항목 + 사용자 추가)

### State Export

- `~/.config/space-dock/state.json`에 현재 상태 기록
- 내용: `current_space`, `space_id`, `space_label`, `apps` 배열
- 1초 디바운스로 과도한 쓰기 방지
- CLI 스크립트 및 외부 자동화 연동용

## Architecture

```text
space-widget/
├── Sources/SpaceWidget/
│   ├── App/
│   │   ├── SpaceWidgetApp.swift          ← 앱 진입점, 의존성 조립
│   │   └── MenuBarController.swift       ← 메뉴바 아이콘 + 설정 메뉴
│   ├── Config/
│   │   ├── ConfigManager.swift           ← 설정 로드/저장 (labels, ignored apps, shortcuts 등)
│   │   ├── Logger.swift                  ← 파일 + stderr 로그
│   │   ├── Migrator.swift                ← sketchybar → space-dock 마이그레이션
│   │   └── StateWriter.swift             ← state.json 기록
│   ├── Engine/
│   │   ├── SpaceMonitor.swift            ← 전체 디스플레이 Space 감지
│   │   ├── WindowListProvider.swift      ← 앱 목록 수집 (화면별 필터링)
│   │   ├── SpaceEngine.swift             ← 멀티 디스플레이 snapshot 파이프라인
│   │   ├── CGSPrivate.swift              ← CGS private API bridge
│   │   ├── AppActions.swift              ← 앱 액션 (new window, close, activate)
│   │   └── SpaceSwitcher.swift          ← CGEvent dock-swipe 기반 Space 전환
│   ├── Panel/
│   │   ├── SpacePanel.swift              ← 투명 NSPanel (스크린 캡처 제외)
│   │   ├── SpacePanelController.swift    ← 멀티 패널 생성/업데이트/제거
│   │   ├── BalloonMenuPanel.swift        ← 우클릭 말풍선 메뉴
│   │   └── DesktopListMenuContent.swift ← 데스크탑 리스트 팝업 UI
│   ├── Views/
│   │   ├── SpaceBarView.swift            ← SwiftUI 바 UI
│   │   ├── PreferencesView.swift         ← 설정 UI (Shortcuts, Layouts, Hidden Apps 탭)
│   │   ├── ShortcutRecorderView.swift    ← 단축키 녹화 뷰
│   │   ├── LayoutTemplatesView.swift     ← 레이아웃 템플릿 편집 뷰
│   │   └── WindowActionIcon.swift        ← 윈도우 배치 시각화 아이콘
│   ├── Models/
│   │   ├── ActiveSpace.swift
│   │   ├── DockItem.swift
│   │   ├── DockSnapshot.swift
│   │   ├── LayoutTemplate.swift
│   │   ├── ShortcutBinding.swift
│   │   └── WindowAction.swift
│   ├── WindowManagement/
│   │   ├── WindowShortcutController.swift ← 윈도우 스냅 단축키 관리
│   │   ├── WindowSnapManager.swift        ← AX API 기반 윈도우 조작
│   │   ├── WindowElement.swift            ← AX 윈도우 래퍼
│   │   ├── WindowCalculation.swift        ← 좌표 계산 (AX ↔ Cocoa)
│   │   ├── ScreenGeometry.swift           ← 화면 지오메트리 유틸
│   │   ├── LayoutApplier.swift            ← 레이아웃 템플릿 적용
│   │   ├── LayoutTemplateStore.swift      ← 템플릿 저장소
│   │   ├── SpaceLayoutBridge.swift        ← Space 전환 → 레이아웃 자동 적용
│   │   └── HotKeyManager.swift            ← 전역 단축키 등록 (Carbon)
│   └── Resources/
│       └── icon.png                       ← 메뉴바 아이콘
├── RunSpaceWidget.app              ← 터미널 없이 실행되는 Finder 런처
├── RunSpaceWidget.command          ← 터미널 기반 런처
├── Makefile
└── README.md
```

### Data Flow

```text
ConfigManager
    ├─ ignored apps, space labels
    ├─ shortcuts, templates
    └─ settings (icons per page)

SpaceMonitor (per-display)
    └─ displaySpaces: [DisplayID: ActiveSpace]

WindowListProvider
    └─ fetchItems (screen-filtered + space-aware)

SpaceEngine
    ├─ publishes snapshots: [DisplayID: DockSnapshot]
    ├─ reacts to space changes (all displays)
    └─ reacts to app activate / launch / terminate / hide

Subscribers
    ├─ StateWriter              → state.json (main display only)
    ├─ SpacePanelController     → N SpacePanels (1 per display)
    └─ SpaceLayoutBridge        → auto-apply templates on space change
```

### Runtime Responsibilities

| Component | 역할 |
|------|------|
| `ConfigManager` | 설정 디렉터리 관리, 기본 파일 생성, 모든 설정 로드/저장 |
| `SpaceMonitor` | 전체 디스플레이의 활성 Space 감지, per-display ordinal 계산 |
| `WindowListProvider` | 화면상 앱 목록 수집, 화면별 필터링, bundle 단위 dedupe |
| `SpaceEngine` | 디스플레이별 `DockSnapshot` 소유, refresh scheduling, stale drop |
| `StateWriter` | `state.json` debounce 기록 (주 디스플레이) |
| `SpacePanelController` | 디스플레이별 패널 생성/제거/리사이즈, snapshot 기반 UI 갱신 |
| `SpaceSwitcher` | CGEvent dock-swipe 합성으로 Space 전환, Ctrl+N 폴백 |
| `SpaceBarView` | Space 라벨/앱 아이콘 렌더링, 스와이프, 앱 활성화 |
| `MenuBarController` | 메뉴바 아이콘 + 전체 설정 메뉴 |
| `WindowShortcutController` | 윈도우 스냅 전역 단축키 관리 |
| `LayoutApplier` | 레이아웃 템플릿 적용 (앱 런치 + 윈도우 배치) |
| `SpaceLayoutBridge` | Space 전환 시 레이아웃 자동 적용 |
| `AutoHideManager` | 바 자동 숨김 상태 관리 |
| `DockController` | macOS Dock 동작 제어 (CoreDock) |

## Quick Start

```bash
# 디버그 빌드
swift build

# 바로 실행
./.build/debug/SpaceWidget

# 터미널 런처 사용
./RunSpaceWidget.command

# Finder에서 더블클릭 실행
open RunSpaceWidget.app
```

`RunSpaceWidget.app`은 터미널 창 없이 실행되는 Finder용 런처입니다.

## Install

```bash
# 릴리즈 빌드
make build

# /usr/local/bin/SpaceWidget 설치
make install

# 설치 후 실행
/usr/local/bin/SpaceWidget

# 설치 후 Finder 런처 사용
open RunSpaceWidget.app
```

## Configuration

기본 설정 디렉터리: `~/.config/space-dock/`

### Config Files

| 파일 | 설명 |
|------|------|
| `space_labels.json` | Space 라벨 (`{"1": "Work", "2": "Browse", "displayID:1": "Extended"}`) |
| `ignored_apps.json` | 바에서 제외할 앱 목록 |
| `app_actions.json` | 앱별 커스텀 액션 (new window, quit 핸들러) |
| `settings.json` | 일반 설정 (`icons_per_page`) |
| `shortcuts.json` | 윈도우 스냅 단축키 바인딩 |
| `templates.json` | 레이아웃 템플릿 정의 |
| `space_assignments.json` | Space → 템플릿 매핑, auto-apply 설정 |

### State Files

| 파일 | 설명 |
|------|------|
| `state.json` | 현재 Space 상태 (외부 스크립트 연동용) |
| `spacewidget.log` | 앱 로그 (매 실행 시 초기화) |

### CLI Options

```bash
SpaceWidget --version           # 버전 출력 (0.1.0)
SpaceWidget --help              # 도움말
SpaceWidget --migrate           # sketchybar 설정 마이그레이션
SpaceWidget --migrate --force   # 기존 파일 덮어쓰기
SpaceWidget --config-dir PATH   # 설정 디렉터리 지정
```

### Defaults

- Space 라벨 기본값: `"1" → "Work"`, `"2" → "Browse"`
- 페이지당 아이콘 수: 5 (범위: 5~10)
- 최대 렌더링 앱 수: 20
- Fallback 라벨: `"Untitled"`

## Private APIs

SpaceWidget은 macOS의 공개되지 않은 API를 사용합니다:

**CGS (Core Graphics Server):**
- `CGSMainConnectionID()` — CGS 연결 획득
- `CGSCopyManagedDisplaySpaces()` — 디스플레이별 Space 열거
- `CGSManagedDisplayGetCurrentSpace()` — 디스플레이별 현재 Space 조회
- `CGSSpaceGetType()` — Space 타입 판별 (desktop/fullscreen/system/tiled)
- `CGSCopySpacesForWindows()` — 윈도우가 속한 Space 조회
- `CGSCopyActiveMenuBarDisplayIdentifier()` — 활성 메뉴바 디스플레이 식별

**CGEvent Gesture Synthesis:**
- dock-swipe 합성 이벤트로 Space 전환 (CGEventField 55, 110, 119, 123, 124, 129, 130, 132, 135, 139)

**CoreDock:**
- `CoreDockGetAutoHideEnabled` / `CoreDockSetAutoHideEnabled` — Dock 자동 숨김 제어

**Accessibility (AX):**
- 윈도우 열거, 위치/크기 조작, 메뉴 탐색, 상태 조회

## Requirements

- macOS 14.0 (Sonoma) 이상
- Swift 5.9+
- Accessibility 권한 필요 (윈도우 조작, 메뉴 탐색, 단축키 감지)
- 외부 의존성 없음 (Foundation, AppKit, Combine, ApplicationServices만 사용)

## Development

```bash
swift build               # 디버그 빌드
make build                # 릴리즈 빌드
make install              # 설치
make uninstall            # 제거
make migrate              # 설정 마이그레이션
make clean                # 클린
```

## Acknowledgements

다음 오픈소스 프로젝트의 구현을 참고했습니다:

| 프로젝트 | 참고 내용 |
|---------|----------|
| [WhichSpace](https://github.com/gechr/WhichSpace) | CGEvent dock-swipe 합성을 통한 Space 전환 기법. 비공개 CGEventField 인덱스와 gesture phase 시퀀스 참조 |
| [yabai](https://github.com/koekeishiya/yabai) | CGS private API 사용 패턴 (`CGSCopyManagedDisplaySpaces`, `CGSSpaceGetType` 등) |
| [Rectangle](https://github.com/rxhanson/Rectangle) | AX API 기반 윈도우 스냅 및 화면 영역 계산 로직 참조 |

## Notes

- macOS 전용 프로젝트입니다.
- SwiftPM 기반으로 빌드합니다.
- CGS private API를 사용하므로 macOS 내부 동작 변화에 영향을 받을 수 있습니다.
- 앱은 `.accessory` 활성화 정책으로 실행되어 Dock 아이콘 및 Cmd+Tab에 표시되지 않습니다.
