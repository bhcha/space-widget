# SpaceWidget Window Management - Implementation Plan

## Overview

Rectangle(MIT)의 윈도우 관리 코어를 추출하여 SpaceWidget에 통합하고,
스페이스 인식 레이아웃 템플릿 시스템을 추가한다.

## Open Source Attribution

Rectangle (https://github.com/rxhanson/Rectangle)
Copyright (c) 2019 Ryan Hanson - MIT License
THIRD_PARTY_NOTICES.md에 라이선스 전문 포함 필수

---

## Phase 1: 기본 화면 분할 + 키 매핑

### 목표
Rectangle에서 윈도우 분할 계산 로직을 추출하여 SpaceWidget에서
키보드 단축키로 윈도우를 분할 배치할 수 있게 한다.

### 추출 대상 (Rectangle 소스)

| 파일 | 역할 | 추출 범위 |
|------|------|----------|
| AccessibilityElement.swift | AXUIElement 래퍼 (위치/크기 get/set) | 핵심 메서드만 |
| WindowAction.swift | 액션 enum 정의 | 필요한 9개 액션만 |
| WindowCalculation.swift | 계산 베이스 + 팩토리 | 프로토콜 + 팩토리 |
| LeftRightHalfCalculation.swift | 좌/우 절반 | 전체 |
| FirstThirdCalculation.swift | 1/3 분할 | 전체 |
| FirstTwoThirdsCalculation.swift | 2/3 분할 | 전체 |
| MaximizeCalculation.swift | 최대화 | 전체 |
| CenterThirdCalculation.swift | 가운데 1/3 | 전체 |
| CenterTwoThirdsCalculation.swift | 가운데 2/3 | 전체 |
| WindowManager.swift | 오케스트레이션 | execute() 메서드 |
| ScreenDetection.swift | 화면 감지 | 핵심 메서드 |
| WindowMover.swift | 윈도우 이동 실행 | StandardWindowMover |

### 구현할 액션 (9개)

| 액션 | 기본 단축키 (Rectangle 호환) |
|------|---------------------------|
| 좌측 절반 | Ctrl+Option+← |
| 우측 절반 | Ctrl+Option+→ |
| 최대화 | Ctrl+Option+Return |
| 처음 1/3 | Ctrl+Option+D |
| 가운데 1/3 | Ctrl+Option+F |
| 마지막 1/3 | Ctrl+Option+G |
| 처음 2/3 | Ctrl+Option+E |
| 가운데 2/3 | (미정) |
| 마지막 2/3 | Ctrl+Option+T |

### 신규 파일 구조

```
Sources/SpaceWidget/
├── WindowManagement/
│   ├── WindowAction.swift          # 액션 enum (9개)
│   ├── WindowElement.swift         # AXUIElement 래퍼 (Rectangle의 AccessibilityElement 경량화)
│   ├── WindowCalculation.swift     # 계산 프로토콜 + 팩토리
│   ├── Calculations/
│   │   ├── HalfCalculation.swift
│   │   ├── ThirdCalculation.swift
│   │   ├── TwoThirdsCalculation.swift
│   │   └── MaximizeCalculation.swift
│   ├── WindowMover.swift           # 윈도우 이동 실행
│   ├── WindowSnapManager.swift     # 오케스트레이션 (Rectangle의 WindowManager 역할)
│   └── ShortcutManager.swift       # 키보드 단축키 바인딩
├── ...
```

### 단축키 바인딩

MASShortcut 라이브러리 대신 Carbon HotKey API 또는
CGEvent tap으로 글로벌 단축키를 직접 구현 (의존성 최소화).

### 설정 저장

ConfigManager에 shortcuts.json 추가:
```json
{
  "left_half": "ctrl+option+left",
  "right_half": "ctrl+option+right",
  "maximize": "ctrl+option+return",
  ...
}
```

### 메뉴바 통합

MenuBarController에 "Window Shortcuts" 서브메뉴 추가 —
현재 매핑 표시 + 활성화/비활성화 토글.

---

## Phase 2: 화면분할 템플릿 + 앱 지정

### 목표
분할 레이아웃을 템플릿으로 저장하고, 각 영역에 앱을 지정하여
원클릭으로 앱들을 자동 배치한다.

### 데이터 모델

```swift
struct LayoutTemplate: Codable, Identifiable {
    let id: UUID
    var name: String
    var shortcut: String?           // 단축키 (선택)
    var zones: [LayoutZone]         // 분할 영역들
}

struct LayoutZone: Codable, Identifiable {
    let id: UUID
    var rect: CGRect                // 화면 비율 (0~1 정규화)
    var assignedAppBundleID: String? // 지정된 앱
}
```

### 설정 저장

`~/.config/space-dock/templates.json`

### 기능

1. 템플릿 생성/편집/삭제 (메뉴바 또는 설정 UI)
2. 각 영역에 앱 지정 (번들 ID)
3. 단축키 매핑
4. 템플릿 실행 → 지정 앱들이 해당 영역으로 자동 이동/리사이즈
5. 컨텍스트 메뉴에서 "Apply Layout" 서브메뉴

### 프리셋 템플릿

| 이름 | 영역 |
|------|------|
| Coding | 좌 2/3 (IDE) + 우 1/3 (터미널) |
| Communication | 좌 1/2 (Slack) + 우 1/2 (브라우저) |
| Research | 좌 1/2 (브라우저) + 우 1/2 (노트) |
| Focus | 최대화 (단일 앱) |

---

## Phase 3: 스페이스 연동 + 고급 기능

### 목표
스페이스별 레이아웃 기억, 자동 적용, Per-App 규칙.

### 기능

1. **스페이스별 레이아웃 스냅샷**: 현재 윈도우 배치를 스페이스에 저장/복원
2. **자동 레이아웃**: 스페이스 전환 시 저장된 레이아웃 자동 적용
3. **Per-App 규칙**: "Slack은 항상 Space 3, 우측 절반" 자동 적용
4. **디스플레이 프로필**: 모니터 변경 감지 → 레이아웃 재배치

---

## Phase 1 상세 작업 계획

### Step 1: THIRD_PARTY_NOTICES.md 생성
- Rectangle MIT 라이선스 전문 포함

### Step 2: WindowElement.swift 생성
- Rectangle의 AccessibilityElement에서 핵심만 추출
- getFrontWindow(), getWindowId(), frame get/set, setFrame(), bringToFront()
- 기존 AppActions.swift의 AX 코드와 통합 검토

### Step 3: WindowAction.swift 생성
- 9개 액션 enum 정의
- 각 액션의 메타데이터 (이름, 기본 단축키)

### Step 4: WindowCalculation 구현
- 계산 프로토콜 정의
- HalfCalculation, ThirdCalculation, TwoThirdsCalculation, MaximizeCalculation
- ScreenDetection 경량화 (단일 모니터 우선)

### Step 5: WindowMover.swift 구현
- WindowElement.setFrame()을 사용한 윈도우 이동
- 좌표 변환 (macOS bottom-left → screen top-left)

### Step 6: WindowSnapManager.swift 구현
- 액션 → 계산 → 이동 오케스트레이션
- Rectangle의 WindowManager.execute() 경량 버전

### Step 7: ShortcutManager.swift 구현
- Carbon HotKey API로 글로벌 단축키 등록
- ConfigManager에서 단축키 설정 로드
- shortcuts.json 기본값 생성

### Step 8: MenuBarController 통합
- "Window Shortcuts" 서브메뉴 추가
- 활성화/비활성화 토글

### Step 9: 빌드 + 테스트 + 코덱스 리뷰
