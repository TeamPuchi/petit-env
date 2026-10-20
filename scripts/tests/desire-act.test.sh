#!/usr/bin/env bash
# 行動で欲求を満たす(澪のリクエスト 2026-10-20「72 時間ずっと 1.00 のものがあった」)を確かめる。
# - 自律行動のあと、その回で使った道具の名前を desire-act <id> <道具>... に渡す(入力・本文は渡さない)
# - 欲求 MCP と同じ env(gen-mcp-config.sh の desire-system)で呼ぶ
# - 道具を使わなかった回・dry-run・夜の今日をふり返る回では呼ばない
# claude・家 API の python・petit-desire は偽物を置く。claude・AWS には触らない。
#
# Usage: bash scripts/tests/desire-act.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
CHAR="$PETIT_DATA_DIR/characters/mio"
API="$PETIT_REPOS_DIR/m5-petit-app"
DESIRE="$PETIT_REPOS_DIR/petit-desire"
mkdir -p "$CHAR/config" "$CHAR/state" "$API/scripts" "$API/.venv/bin" "$DESIRE/.venv/bin" "$PETIT_MCP_DIR" "$WORK/bin"
echo '{"active_hours": [[0, 24]]}' > "$CHAR/config/settings.json"
for f in tutorial_state.py settings_state.py maintenance_state.py record_usage.py archive_stream.py \
         diary_material.py body_news.py read_mailbox.py; do echo '# placeholder' > "$API/scripts/$f"; done
cat > "$API/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
case "$1" in
  *settings_state.py) echo "settings: run camera=on speaker=on sns=on" ;;
  *tutorial_state.py) echo "tutorial: done" ;;
  *maintenance_state.py) echo "maintenance: off" ;;
  *diary_material.py) printf '## 今日の会話（古い順）\n[09:00] なぎ: おはよう\n' ;;
  *read_mailbox.py) echo 0 ;;
esac
exit 0
PY
chmod +x "$API/.venv/bin/python"
echo '[project]' > "$DESIRE/pyproject.toml"
printf '#!/bin/sh\necho "知りたい 1.00"\n' > "$DESIRE/.venv/bin/desire-status"
printf '#!/bin/sh\necho "$CHARACTER_ID|$*" >> "$FAKE_ACT_CALLS"\necho "[desire-act] curiosity=0.800"\n' > "$DESIRE/.venv/bin/desire-act"
printf '#!/bin/sh\n' > "$DESIRE/.venv/bin/desire-system"
chmod +x "$DESIRE/.venv/bin/"*
# 偽の claude: FAKE_TOOLS の道具を使った行を出してから result 行を出す
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
for t in ${FAKE_TOOLS:-}; do
  echo "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"$t\",\"input\":{\"query\":\"ひみつ\"}}],\"usage\":{\"input_tokens\":10}}}"
done
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"s1","total_cost_usd":0.01,"num_turns":2}'
SH
chmod +x "$WORK/bin/claude"
export FAKE_ACT_CALLS="$WORK/act-calls"
DATE="2026-10-20 14:00"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
reset() { rm -rf "$PETIT_DATA_DIR/logs" "$CHAR/state/.heartbeat-session-"*; : > "$FAKE_ACT_CALLS"; }
log() { cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null; }
run() { env PATH="$WORK/bin:$PATH" "$@" > /dev/null 2>&1; }

# 1. 使った道具の名前を渡す（欲求 MCP と同じ env で）
reset
run PETIT_HOUSE_TABLE=t FAKE_TOOLS="WebSearch mcp__house__book_read" "$BASH" "$SCRIPT" mio --date "$DATE"
grep -qx "mio|mio WebSearch mcp__house__book_read" "$FAKE_ACT_CALLS"; check "使った道具の名前を desire-act <id> に渡す(CHARACTER_ID も)" $?
grep -q "\[desire-act\] curiosity=0.800" <<< "$(log)"; check "desire-act の結果をログに残す" $?
! grep -q "ひみつ" "$FAKE_ACT_CALLS" && ! grep -q "ひみつ" <<< "$(log)"; check "道具の入力は渡さない・残さない" $?

# 2. 道具を使わなかった回・dry-run・夜の回では呼ばない
reset
run PETIT_HOUSE_TABLE=t "$BASH" "$SCRIPT" mio --date "$DATE"
[ ! -s "$FAKE_ACT_CALLS" ]; check "道具を使わなかった回は呼ばない" $?
reset
run PETIT_HOUSE_TABLE=t FAKE_TOOLS="WebSearch" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE"
[ ! -s "$FAKE_ACT_CALLS" ]; check "dry-run では呼ばない" $?
reset
run PETIT_HOUSE_TABLE=t FAKE_TOOLS="WebSearch" "$BASH" "$SCRIPT" mio --date "2026-10-20 20:30" --diary
[ ! -s "$FAKE_ACT_CALLS" ]; check "今日をふり返る回では呼ばない" $?

if [ "$fails" -gt 0 ]; then echo "$fails 件失敗"; exit 1; fi
echo "すべて通った"
