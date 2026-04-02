# Phase 2 — 앱 아이콘 연결 상세 계획

## 목적

- `SpaceEngine.$snapshot.items`의 실제 앱 아이콘을 SpaceBarView에 표시한다.
- 스페이스 전환 시 아이콘 목록이 바뀔 때 부드러운 애니메이션을 적용한다.
- 패널 frame은 절대 변경하지 않는다 (전체 화면 투명 패널 유지).
- 아이콘이 한 페이지 상한을 초과하면 페이지 전환으로 나머지를 볼 수 있다.

## 현재 상태

- `SpaceBarView`는 더미 아이콘 4개를 하드코딩으로 표시 중
- `SpacePanelController`는 `snapshot.spaceNumber`와 `snapshot.spaceLabel`만 뷰에 전달
- `DockSnapshot.items: [DockItem]`에 실제 앱 정보가 이미 있음 (이름, 아이콘, bundleID, isFocused)

## 설정 상수

```swift
enum SpaceBarConstants {
    /// 한 페이지에 표시할 최대 아이콘 수 (테스트: 5, 프로덕션: 10)
    static let iconsPerPage = 5

    /// 아이콘 크기
    static let iconSize: CGFloat = 39

    /// 아이콘 간격
    static let iconSpacing: CGFloat = 9
}
```

- `iconsPerPage`를 **5**로 시작하여 테스트 후 **10**으로 변경 예정
- 이 상수 하나만 바꾸면 페이지당 아이콘 수, 너비 계산, 페이지 수가 모두 자동 조정됨

## 아이콘 표시 정책

### 페이지네이션

- 전체 아이콘을 `iconsPerPage` 단위로 분할
- 현재 페이지의 아이콘만 표시
- 페이지 인디케이터: 2페이지 이상일 때만 표시 (도트 형태)

| 아이콘 수 | iconsPerPage=5 기준 | 표시 |
|-----------|---------------------|------|
| 0 | 0페이지 | 구분자 없이 번호+라벨만 |
| 1~5 | 1페이지 | 아이콘만 표시, 인디케이터 없음 |
| 6~10 | 2페이지 | 아이콘 + 페이지 인디케이터 |
| 11~15 | 3페이지 | 아이콘 + 페이지 인디케이터 |
| 16~20 | 4페이지 | 아이콘 + 페이지 인디케이터 |

### 페이지 전환 방법

- **좌우 스와이프(트랙패드/마우스 스크롤)로 페이지 전환**
- 스페이스 전환 시 **무조건 1페이지로 리셋**
- 앱 실행/종료로 아이콘 목록이 바뀔 때도 1페이지로 리셋
- 마지막 페이지에서 우측 스와이프 → 무시 (순환 안 함)
- 첫 페이지에서 좌측 스와이프 → 무시

#### 스와이프 구현

- `SpacePanel`의 `ignoresMouseEvents`를 **bar pill 영역에서만 해제**해야 함
- 방법: `ignoresMouseEvents = false` + `NSView.hitTest`를 오버라이드하여 bar pill 영역 밖의 이벤트는 패스스루
- 또는: bar pill 영역에 별도의 투명 이벤트 수신 NSView를 올림
- SwiftUI에서 `.gesture(DragGesture())` 사용하여 스와이프 감지
- 스와이프 방향: 좌→우 (이전 페이지), 우→좌 (다음 페이지)
- 최소 드래그 거리: 30pt

### 페이지 인디케이터

```
[● ○ ○]  ← 1/3 페이지
[○ ● ○]  ← 2/3 페이지
[○ ○ ●]  ← 3/3 페이지
```

- 위치: 아이콘 영역 우측 끝, 세로 중앙
- 크기: 도트 4pt, 간격 3pt
- 색상: 현재 페이지 white 0.8, 나머지 white 0.25

### 너비 계산

현재 bar pill 레이아웃:

```
[숫자 32pt] [간격 15] [라벨 74pt] [간격 15] [구분자 1.5pt] [간격 15] [아이콘 영역] [인디케이터?] [패딩 18*2]
```

고정 영역: 32 + 15 + 74 + 15 + 1.5 + 15 + 36 = **188.5pt**

아이콘 영역 계산 (iconsPerPage 기준):
- 아이콘 크기: 39pt
- 아이콘 간격: 9pt
- n개 너비: `n * 39 + (n-1) * 9`

| iconsPerPage | 아이콘 영역 너비 | 인디케이터 | 전체 bar 너비 |
|--------------|-----------------|-----------|--------------|
| 5 | 231pt | ~25pt | ~445pt |
| 10 | 471pt | ~25pt | ~685pt |

### 아이콘 0개인 경우

- 구분자 숨김, 아이콘 영역 없음
- bar pill 너비: ~189pt (고정 영역만)
- 페이지 인디케이터 없음

## 애니메이션 전략

### 원칙

1. **패널 frame 불변** — 전체 화면 투명 패널이므로 리사이즈 없음
2. **SwiftUI가 너비 자동 조절** — HStack이 아이콘 수에 따라 자연스럽게 변함
3. **아이콘 수 기반 너비는 iconsPerPage로 고정** — 2페이지 이상이면 항상 iconsPerPage만큼 너비 유지

### 너비 고정 정책

- **1페이지 이하**: 실제 아이콘 수에 맞춰 너비 변동 (1~5개)
- **2페이지 이상**: iconsPerPage 너비로 고정 (페이지 전환 시 너비 안 바뀜)

```swift
let displayCount = totalPages > 1 ? iconsPerPage : min(items.count, iconsPerPage)
// 이 displayCount로 아이콘 영역 너비를 결정
```

### SwiftUI 애니메이션

```swift
// 스페이스 전환 시 아이콘 변경 애니메이션
barContent
    .animation(.smooth(duration: 0.3), value: items.count)

// 개별 아이콘 등장/퇴장
ForEach(currentPageItems) { item in
    iconView(item)
        .transition(.scale.combined(with: .opacity))
}

// 페이지 전환 애니메이션
iconsSection
    .animation(.smooth(duration: 0.25), value: currentPage)
```

### 스페이스 전환 시 예상 동작

```
t=0       사용자가 스페이스 전환
t=0       이전 스페이스 아이콘이 그대로 보임
t=~100ms  activeSpaceDidChangeNotification 수신
t=~200ms  SpaceMonitor 디바운스 후 captureSnapshot
t=~250ms  새 DockSnapshot → rootView 교체
          → 항상 1페이지 표시 (페이지 리셋 불필요, 항상 prefix만 표시)
          → SwiftUI 애니메이션으로 아이콘 전환
t=~550ms  애니메이션 완료, 새 스페이스의 아이콘(최대 iconsPerPage개) 안정 표시
```

## 구현 계획

### Step 1: 기본 아이콘 연결 (더미 → 실제 데이터)

**변경 파일**: `SpaceBarView.swift`, `SpacePanelController.swift`

1. `SpaceBarView`에 `items: [DockItem]` 파라미터 추가
2. 더미 아이콘 삭제
3. `items.prefix(iconsPerPage)` 표시
4. 아이콘 0개 시 구분자 숨김
5. `SpacePanelController`에서 `snapshot.items` 전달
6. `.animation(.smooth(duration: 0.3), value: items.count)` 적용
7. `.transition(.scale.combined(with: .opacity))` 적용

**검증**:
- [ ] 실제 앱 아이콘이 표시된다
- [ ] state.json과 아이콘 수가 일치한다 (최대 5개)
- [ ] 스페이스 전환 시 아이콘이 바뀐다
- [ ] 전환 애니메이션이 부드럽다
- [ ] 0개 아이콘 스페이스에서 구분자가 숨겨진다

### Step 2: 페이지네이션 (1페이지 고정 + 인디케이터)

**변경 파일**: `SpaceBarView.swift`

항상 첫 iconsPerPage개만 표시하되, 전체 아이콘이 iconsPerPage를 초과하면
페이지 인디케이터로 추가 아이콘이 있음을 알려준다.

1. 전체 페이지 수 계산: `ceil(items.count / iconsPerPage)`
2. 2페이지 이상일 때 페이지 인디케이터 표시 (현재 페이지는 항상 1)
3. 표시 아이콘은 항상 `items.prefix(iconsPerPage)` (현재 동작 그대로)

**검증**:
- [ ] 6개 이상 앱: 5개 표시 + 인디케이터 (●○ 형태)
- [ ] 5개 이하 앱: 인디케이터 없음
- [ ] 인디케이터가 bar pill 안에 자연스럽게 위치
- [ ] 스페이스 전환 시 정상 동작

### Step 3: iconsPerPage 조정 및 최종 검증

1. `iconsPerPage`를 5 → 10으로 변경
2. 전체 검증 재수행

## 검증 계획 (통합)

### 기본 표시

- [ ] 앱 실행 시 현재 스페이스의 실제 앱 아이콘이 표시된다
- [ ] 아이콘 수가 올바르다 (state.json의 apps 배열과 일치, 최대 iconsPerPage)
- [ ] 포커스된 앱 아이콘이 더 밝게 표시된다 (opacity 1 vs 0.7)

### 스페이스 전환

- [ ] 1→2→3→2→1 전환 시 각 스페이스의 앱 아이콘이 정확히 표시된다
- [ ] 전환 시 bar pill 너비가 부드럽게 변한다
- [ ] 전환 시 아이콘이 fade in/out된다
- [ ] 다른 스페이스의 아이콘이 섞여 나오지 않는다
- [ ] 전환 시 currentPage가 0으로 리셋된다

### 페이지네이션

- [ ] iconsPerPage 초과 앱: iconsPerPage개만 표시 + 인디케이터
- [ ] iconsPerPage 이하 앱: 인디케이터 없음
- [ ] 인디케이터가 bar pill 안에 올바른 위치에 표시된다
- [ ] 스페이스 전환/앱 변경 시 항상 1페이지(첫 iconsPerPage개) 표시

### 엣지 케이스

- [ ] 앱 0개: 구분자 없이 번호+라벨만
- [ ] 앱 1개: 아이콘 1개, 인디케이터 없음
- [ ] 앱 정확히 iconsPerPage개: 1페이지, 인디케이터 없음
- [ ] 앱 iconsPerPage+1개: 2페이지, 인디케이터 표시
- [ ] 앱 실행/종료 시 아이콘 실시간 추가/제거 + 페이지 수 재계산
- [ ] 캡처 프로그램 실행 시 시각적 문제 없음

### 크기 안정성

- [ ] 패널 frame 불변
- [ ] 스페이스 전환 시 bar pill이 순간적으로 줄어들거나 커지지 않는다
- [ ] bar pill 최대 너비가 화면을 넘지 않는다

### 검증 방법

```bash
# 1. 빌드 및 실행
pkill -9 -f SpaceWidget; swift build && .build/debug/SpaceWidget &>/dev/null &

# 2. 스크린샷으로 아이콘 확인
sleep 2 && screencapture -x /tmp/icons-test.png

# 3. state.json과 UI 비교
cat ~/.config/space-dock/state.json

# 4. 스페이스 전환 후 재확인 (수동)
screencapture -x /tmp/icons-space2.png
cat ~/.config/space-dock/state.json

# 5. 페이지네이션 검증 (6개 이상 앱이 있는 스페이스에서)
# 3초 간격으로 스크린샷 3장
for i in 1 2 3; do sleep 3 && screencapture -x /tmp/icons-page$i.png; done
```

## 수정하지 않는 것

- Engine, Model, Config 파일 수정 없음
- `SpacePanel.swift` 수정 없음
- `SpaceWidgetApp.swift` 수정 없음
- 패널 frame 조작 없음
