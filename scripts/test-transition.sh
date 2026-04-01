#!/bin/bash
set -e

PROJECT_DIR="/Users/chabh/workspace/space-widget"
LOG_FILE="$HOME/.config/space-dock/spacewidget.log"
CAPTURE_DIR="$HOME/.config/space-dock/test-captures"

cd "$PROJECT_DIR"

rm -rf "$CAPTURE_DIR"
mkdir -p "$CAPTURE_DIR"
pkill -f SpaceWidget 2>/dev/null || true
sleep 0.5

echo "=== Building ==="
swift build 2>&1 | tail -3

echo "=== Starting SpaceWidget ==="
> "$LOG_FILE"
.build/debug/SpaceWidget &>/dev/null &
sleep 2

wait_for_transition() {
    local count_before
    count_before=$(grep -c 'space transition finalize ordinal' "$LOG_FILE" 2>/dev/null || echo 0)
    echo "  → 스페이스를 전환하세요..."
    while true; do
        local count_now
        count_now=$(grep -c 'space transition finalize ordinal' "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$count_now" -gt "$count_before" ]; then
            sleep 0.5
            break
        fi
        sleep 0.1
    done
}

# Steps
STEPS=("1_space1_start" "2_space2" "3_space3" "4_space2_return" "5_space1_return")
LABELS=("Space1 시작" "1→2" "2→3" "3→2" "2→1")

echo ""
echo "=== 전환 테스트: 1→2→3→2→1 ==="
echo ""

# First capture (no transition needed)
echo "[${LABELS[0]}]"
sleep 0.5
screencapture -x "$CAPTURE_DIR/${STEPS[0]}.png"
echo "  captured."

# Remaining transitions
for i in 1 2 3 4; do
    echo ""
    echo "[${LABELS[$i]}]"
    wait_for_transition
    screencapture -x "$CAPTURE_DIR/${STEPS[$i]}.png"
    echo "  captured."
done

echo ""
echo "=== 분석 ==="

echo ""
echo "--- FRAME 모니터 (외부 프레임 변경) ---"
grep '\[FRAME\] CHANGED' "$LOG_FILE" || echo "  (없음)"

echo ""
echo "--- SIZE-JUMP ---"
grep 'SIZE-JUMP' "$LOG_FILE" || echo "  (없음)"

echo ""
echo "--- 전환별 패널 폭 ---"
grep 'update_apply' "$LOG_FILE" | sed -n 's/.*reason=\([^ ]*\).*space(ordinal=\([0-9]*\).*appliedWidth=\([^ ]*\).*/  ordinal=\2 \1 → width=\3/p'

echo ""
echo "--- 캡처 비교 ---"
if [ -f "$CAPTURE_DIR/2_space2.png" ] && [ -f "$CAPTURE_DIR/4_space2_return.png" ]; then
    diff <(md5 -q "$CAPTURE_DIR/2_space2.png") <(md5 -q "$CAPTURE_DIR/4_space2_return.png") >/dev/null 2>&1 \
        && echo "  space2 vs space2_return: IDENTICAL ✓" \
        || echo "  space2 vs space2_return: DIFFERENT ✗"
fi
if [ -f "$CAPTURE_DIR/1_space1_start.png" ] && [ -f "$CAPTURE_DIR/5_space1_return.png" ]; then
    diff <(md5 -q "$CAPTURE_DIR/1_space1_start.png") <(md5 -q "$CAPTURE_DIR/5_space1_return.png") >/dev/null 2>&1 \
        && echo "  space1 vs space1_return: IDENTICAL ✓" \
        || echo "  space1 vs space1_return: DIFFERENT ✗"
fi

echo ""
echo "캡처: $CAPTURE_DIR"
echo "로그: $LOG_FILE"
open "$CAPTURE_DIR"
