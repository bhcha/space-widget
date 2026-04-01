# Phase 1

## 목적

- UI 없이 프로세스 코어만 남긴다.
- 현재 Space 번호와 실행 중 앱 목록을 안정적으로 수집한다.
- 결과는 로그와 `state.json`으로만 검증한다.

## 현재 구현 범위

- `SpaceMonitor`는 현재 활성 Space를 `ActiveSpace` 하나로 발행한다.
- `WindowListProvider`는 현재 화면의 앱 목록을 수집한다.
- `SpaceEngine`은 단일 데이터 파이프라인으로 `DockSnapshot` 하나만 발행한다.
- `StateWriter`는 `SpaceEngine.$snapshot`을 구독해 `state.json`을 기록한다.
- 앱 시작 시 패널, SwiftUI, NSPanel, 폭/높이 동기화 로직은 사용하지 않는다.
- `SIGUSR1`로 설정 reload는 유지한다.

## 주요 파일

- `Sources/SpaceWidget/Engine/SpaceEngine.swift`
- `Sources/SpaceWidget/Engine/SpaceMonitor.swift`
- `Sources/SpaceWidget/Engine/WindowListProvider.swift`
- `Sources/SpaceWidget/Models/ActiveSpace.swift`
- `Sources/SpaceWidget/Models/DockSnapshot.swift`
- `Sources/SpaceWidget/Config/StateWriter.swift`
- `Sources/SpaceWidget/App/SpaceWidgetApp.swift`

## 검증 결과

- `FileWatcher`는 phase1 실행 경로에서 제거됨
- 앱 시작 시 초기 중복 snapshot 문제 해결
- 시작 시 로그는 `space_changed` 기준 1회만 생성됨
- `SpaceMonitor`는 현재 space를 commit하기 전에 metadata를 기록함
  - `type=0` 이고 `listed=true` 인 경우에만 user desktop으로 취급
  - `type!=0` 또는 `listed=false` 인 candidate는 transient space로 간주하고 무시
- `state.json`에 아래 필드 기록 확인
  - `current_space`
  - `space_id`
  - `space_label`
  - `apps`
- `swift build -c release` 통과

## 로그 기준

정상 흐름:

1. `[SPACE] detected`
2. `[FETCH] started`
3. `[FETCH] result`
4. `[SNAPSHOT] applied`

Transient space 억제 흐름:

1. `[SPACE] metadata ...`
2. `[SPACE] skipping non-desktop current space ...`
   또는
3. `[SPACE] skipping unmanaged current space ...`

## Flameshot 검증 메모

- 증상:
  - Flameshot 캡처 시작 시 임시 space가 생성되면서 desktop ordinal이 증가한 것처럼 보일 수 있었음
- 원인:
  - macOS가 캡처 overlay를 별도 active space로 노출하는 경우가 있음
  - 이 candidate를 일반 user desktop으로 commit하면 잘못된 `space_changed` snapshot이 생성됨
- 현재 해결 방식:
  - 앱명 필터를 두지 않음
  - `SpaceMonitor`에서 `CGSSpaceGetType`와 managed display spaces 포함 여부를 함께 확인
  - `type != 0` 또는 `listed=false` 이면 commit하지 않음
- 검증 로그 예시:

```text
[SPACE] metadata id=1737 type=4 listed=false ordinal=1 userSpaces=3 display=...
[SPACE] skipping non-desktop current space id=1737 type=4
```

- 기대 결과:
  - 위 케이스에서는 이어서 `[SPACE] detected ...`, `[SNAPSHOT] applied reason=space_changed ...` 가 나오면 안 됨
  - 실제 검증에서 Flameshot 실행 중 잘못된 desktop 전환 snapshot은 생성되지 않음

## state.json 예시

```json
{
  "apps": [
    "메모",
    "카카오톡",
    "Google Chrome",
    "iTerm2"
  ],
  "current_space": 1,
  "space_id": 1,
  "space_label": "Work"
}
```

## Phase 1 완료 기준

- 앱 실행 후 초기 snapshot이 1회만 생성된다.
- Space 전환마다 snapshot이 안정적으로 갱신된다.
- 앱 활성화/실행/종료 이벤트에서만 refresh가 발생한다.
- UI 관련 코드 없이도 로그와 state 파일만으로 상태 검증이 가능하다.

## 다음 단계

- `DockUIModel` 추가
- `DockSnapshot -> UI state` 어댑터 작성
- 패널/뷰 계층 재도입
- 기존 look & feel 복원
