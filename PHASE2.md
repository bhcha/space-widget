# Phase 2

## 목적

- Phase 1의 `SpaceEngine -> DockSnapshot` 파이프라인 위에 최소한의 패널 UI를 다시 올린다.
- 기존 look & feel의 방향은 유지하되, UI 상태 관리가 프로세스 코어를 오염시키지 않도록 범위를 제한한다.
- 먼저 "보인다"와 "붙는다"를 복구하고, 이후 인터랙션과 정교한 상태머신은 별도 단계로 분리한다.

## 현재 구현 범위

- 앱 실행 시 `DockPanelController`를 생성해 플로팅 패널을 띄운다.
- 패널 콘텐츠는 `DockBarView` 하나로 렌더링된다.
- UI는 현재 `SpaceEngine.$snapshot`을 직접 구독한다.
- 패널은 현재 스페이스 번호, 라벨, 앱 개수만 표시한다.
- Space 변경과 앱 개수 변경 시 `hostingView.rootView`를 교체하고, `fittingSize` 기반으로 패널 폭을 다시 맞춘다.
- 패널 위치는 기본적으로 현재 마우스가 있는 화면의 좌하단 Dock 위에 잡힌다.
- 화면 구성 변경과 Dock preference 변경 시 패널을 다시 배치한다.
- 비활성 패널에서도 hover tooltip이 보이도록 별도 tooltip panel을 사용한다.

## 현재 구현 파일

- `Sources/SpaceWidget/App/SpaceWidgetApp.swift`
- `Sources/SpaceWidget/Panel/DockPanel.swift`
- `Sources/SpaceWidget/Panel/DockPanelController.swift`
- `Sources/SpaceWidget/Panel/DockBarLayout.swift`
- `Sources/SpaceWidget/Views/DockBarView.swift`

## 현재 UI 구조

```text
SpaceEngine.$snapshot
  -> DockPanelController.observeEngine()
  -> DockBarView(spaceNumber, spaceLabel, appCount, metrics)
  -> NSHostingView
  -> DockPanel
```

즉, 현재 Phase 2는 아직 `DockUIModel` 계층 없이 `snapshot -> panel view`로 바로 연결된 최소 버전이다.

## 확인된 동작

- 패널 생성 및 표시
- `spaceNumber`, `spaceLabel`, `appCount` 표시
- snapshot 갱신 시 UI 갱신
- `hosting.fittingSize`를 이용한 폭 재계산
- `DockMetrics.current()` 기준 높이 유지
- tooltip 표시
- `swift build` 통과

## 아직 구현되지 않은 것

- `DockUIModel`
- loading/display phase 상태머신
- locked width / stable width 정책
- 앱 아이콘 렌더링
- 앱 재정렬
- 메뉴바 컨트롤러
- 클릭 액션/앱 활성화/앱별 동작
- look & feel의 세부 복원
  - 현재는 chip + label + app count만 있는 단순 바 형태

## 현재 설계와 계획서의 차이

- 계획서에는 `DockUIModel`이 UI 전용 상태를 담당하는 구조가 정의되어 있다.
- 실제 현재 구현은 그 단계 전의 최소 버전이며, `DockPanelController`가 `SpaceEngine`을 직접 구독한다.
- 즉, 현재 Phase 2는 "UI 재도입 1차"이며 "UI 상태 분리 완료" 단계는 아직 아니다.

## transient space 대응 메모

- Flameshot 캡처 시 생성되는 임시 active space는 `SpaceMonitor`에서 metadata 기준으로 차단한다.
- 현재 기준:
  - `type == 0`
  - `listed == true`
  인 경우만 user desktop으로 취급한다.
- 따라서 transient candidate는 UI snapshot으로 반영되지 않는다.

## 검증 포인트

- 앱 실행 시 패널이 생성된다.
- 일반 desktop 전환 시 `spaceNumber`, `spaceLabel`, `appCount`가 반영된다.
- Flameshot 같은 캡처 overlay는 잘못된 `space_changed` UI 갱신을 만들지 않는다.
- 패널이 화면/Dock 변경 시 적절히 재배치된다.

## 현재 한계

- `DockPanelController`가 레이아웃, 위치, 엔진 구독을 모두 담당하고 있어 책임이 아직 크다.
- `hosting.fittingSize` 기반 폭 재계산은 이후 다시 흔들림 이슈를 만들 가능성이 있다.
- UI 전환 정책이 아직 별도 모델로 분리되지 않았다.

## 다음 단계

1. `DockUIModel` 도입
2. `SpaceEngine.$snapshot -> DockUIModel` 어댑터 작성
3. `DockPanelController`는 `DockUIModel`만 구독하도록 축소
4. 앱 아이콘 렌더링 복원
5. loading/display phase와 폭 정책을 UI 계층으로 한정
6. 기존 look & feel 복원
