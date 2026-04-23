# SpaceWidget Feature List

macOS 환경 변경(버전 업그레이드, 디스플레이 구성 변경 등) 시 동작 검증용 체크리스트.
각 섹션의 ⚠️ 표시는 macOS private API / AX API에 의존하여 OS 버전업에서 깨질 위험이 있는 영역입니다.

## 1. Space-Aware Context Bar ⚠️ (CGS private API)
- [ ] 좌하단 플로팅 바에 현재 Space 번호/라벨 표시
- [ ] Space 전환 시 자동 감지·갱신
- [ ] 라벨 영역 클릭 → 인라인 편집
- [ ] 풀스크린/오버레이/타일드 Space 필터링

## 2. Multi-Monitor Support ⚠️ (CGS private API)
- [ ] 연결된 디스플레이마다 패널 자동 생성
- [ ] 미러링 동작
- [ ] 확장 디스플레이 per-display ordinal
- [ ] 디스플레이 연결/분리 시 패널 추가/제거

## 3. Label Persistence
- [ ] 라벨이 spaceID에 고정 유지 (Space 순서 변경/풀스크린 전환)
- [ ] Dead-display fallback (주 디스플레이 분리 시)

## 4. Running App Snapshot ⚠️ (CGS private API + AX)
- [ ] 현재 Space 실행 중 앱 아이콘 표시
- [ ] 윈도우 수 집계
- [ ] 포커스 앱 하이라이트
- [ ] 숨김/최소화 앱 표시
- [ ] 아이콘 클릭 → 앱 활성화

## 5. Icon Pagination
- [ ] 페이지당 아이콘 수 설정 (5~10)
- [ ] 좌우 스와이프 전환
- [ ] 페이지 인디케이터 도트
- [ ] 포커스 앱 있는 페이지로 자동 이동

## 6. Balloon Context Menu ⚠️ (AX API)
- [ ] 아이콘 우클릭 → 말풍선 메뉴
- [ ] New Window (AX 메뉴 탐색 / Cmd+N 폴백)
- [ ] Close from Space (sticky 제외)
- [ ] Quit

## 7. Window Snapping ⚠️ (AX API + Carbon HotKey)
- [ ] 왼쪽/오른쪽 절반 (`Cmd+Ctrl+←/→`)
- [ ] 최대화 (`Cmd+Ctrl+Enter`), 최소화 (`Cmd+Ctrl+Esc`)
- [ ] 1/3·2/3 분할 (`Cmd+Ctrl+D/F/G/E/V/T`)
- [ ] Preferences에서 단축키 커스터마이즈/녹화
- [ ] Electron 앱(Claude, Obsidian, VSCode)에서도 동작

## 8. Layout Templates ⚠️ (AX API)
- [ ] 템플릿 생성/편집/삭제/복제
- [ ] 존에 앱 bundle ID 할당 후 적용
- [ ] 템플릿별 단축키
- [ ] Space별 Auto-Apply
- [ ] Launch Closed Apps

## 9. Hidden Apps
- [ ] Preferences → Hidden Apps 탭에서 앱 제외 관리
- [ ] Add App으로 앱 추가
- [ ] 스크린 캡처에 위젯 패널 미포함

## 10. Desktop Switcher ⚠️ (CGEvent dock-swipe 합성 — 가장 취약)
- [ ] Space 번호 클릭 → 데스크탑 리스트 팝업
- [ ] 선택 시 즉시 전환
- [ ] Ctrl+N 폴백

## 11. Dock Overlap Detection ⚠️
- [ ] Dock-위젯 겹침 시 아이콘 수 자동 축소
- [ ] Dock 위치/크기 변경 시 재계산

## 12. Auto-Hide
- [ ] 바 자동 숨김 토글
- [ ] 마우스 오버 시 표시, 떠나면 0.3초 후 숨김

## 13. Dock Control ⚠️ (CoreDock private framework)
- [ ] Auto Hide / Always Hide / Always Show 모드
- [ ] 앱 종료 시 원래 설정 복원

## 14. Menu Bar
- [ ] 메뉴바 아이콘 표시
- [ ] Auto Hide/Icons per Page/Dock 모드/Layout/Auto-Apply/Preferences/Quit 메뉴

## 15. State Export
- [ ] `~/.config/space-dock/state.json` 기록
- [ ] `current_space`, `space_id`, `space_label`, `apps` 필드

---

## 테스트 순서 권장

macOS 버전업 직후 회귀 테스트 시, private API 의존도가 높은 순서로 진행:
1. Space-Aware Context Bar (1)
2. Multi-Monitor Support (2)
3. Desktop Switcher (10) — CGEvent 합성
4. Dock Control (13) — CoreDock
5. Window Snapping (7) — Electron 앱 포함
6. 나머지
