#!/usr/bin/env bash
# 体のパネルの「ぷちに おねがい」で家 API がすぐに起こす回（autonomous-action.sh --ask・2026-10-11）を確かめる。
# - 設定の関所に --reason ask を渡す（ON/OFF だけを見る）。cron の回には渡さない
# - 活動時間の外でも動く（関所が読めない・家の表が無いときの settings.json の判定でも）。深夜は声を出さずに応える
# - プロンプトに「## お願い」とお願いの言葉。ルーチン回にはならない
# - 台帳（record_usage.py）・全文ログ（archive_stream.py）の source は ask。cron の回は autonomous のまま
# - 重ならないように: 前の回が動いていれば、cron の回は抜け、お願いの回は終わるまで待つ（待ちきれなければ抜ける）
# claude と家 API の python は偽物を置く。claude・AWS には触らない。flock が要る（Linux / WSL で動かす）。
#
# Usage: bash scripts/tests/ask-wake.test.sh
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
mkdir -p "$CHAR/config" "$CHAR/state" "$API/scripts" "$API/.venv/bin" "$PETIT_MCP_DIR" "$WORK/bin"
echo '{"active_hours": [[0, 24]]}' > "$CHAR/config/settings.json"
for f in tutorial_state.py settings_state.py record_usage.py archive_stream.py; do echo '# placeholder' > "$API/scripts/$f"; done
# 偽の家 API の python: 呼ばれた引数を残す。関所は通す
cat > "$API/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_PY_CALLS"
case "$1" in
  *settings_state.py) echo "settings: run (fake) camera=on speaker=on" ;;
  *tutorial_state.py) echo "tutorial: done" ;;
esac
exit 0
PY
chmod +x "$API/.venv/bin/python"
# 偽の claude: 呼ばれたら印を残し、プロンプトを写して result 行を出す
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
cat > "$FAKE_CLAUDE_PROMPT"
echo called >> "$FAKE_CLAUDE_CALLS"
echo '{"type":"result","subtype":"success","is_error":false,"session_id":"s1","total_cost_usd":0.01,"num_turns":1}'
SH
chmod +x "$WORK/bin/claude"
export FAKE_PY_CALLS="$WORK/py-calls" FAKE_CLAUDE_CALLS="$WORK/claude-calls" FAKE_CLAUDE_PROMPT="$WORK/prompt"
DATE="2026-10-11 19:20"
ASK="さっきなぎが体のパネルで『みてみて』とお願いした（写真を撮って見てほしい）"
LOCK="$CHAR/state/.autonomous.lock"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
reset() { rm -rf "$PETIT_DATA_DIR/logs" "$CHAR/state/.heartbeat-session-"*; : > "$FAKE_PY_CALLS"; : > "$FAKE_CLAUDE_CALLS"; : > "$FAKE_CLAUDE_PROMPT"; }
log() { cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null; }
run() { env PATH="$WORK/bin:$PATH" "$@" > /dev/null 2>&1; }

# 1. dry-run: 関所の引数とプロンプト
reset
OUT=$(env PETIT_HOUSE_TABLE=t PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" --ask "$ASK" 2>/dev/null)
grep -q "settings_state.py mio gate .*--reason ask" "$FAKE_PY_CALLS"; check "お願いの回は関所に --reason ask を渡す" $?
grep -q "## お願い" <<< "$OUT" && grep -qF "$ASK。それで目が覚めた。" <<< "$OUT"
check "プロンプトに「## お願い」とお願いの言葉" $?
grep -q "body_glance" <<< "$OUT" && grep -q "body_now を fresh" <<< "$OUT"
check "見る（目）か感じる（body_now fresh）かを選べると書く" $?
grep -q "お願いされて目が覚めた回" <<< "$OUT" && ! grep -q "ルーチン回。" <<< "$OUT"
check "ルーチン回にならない" $?
grep -q "\[SOURCE=ask\]" <<< "$OUT"; check "dry-run に SOURCE=ask を出す" $?
reset
OUT=$(env PETIT_HOUSE_TABLE=t PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" 2>/dev/null)
! grep -q -- "--reason" "$FAKE_PY_CALLS" && ! grep -q "## お願い" <<< "$OUT" && grep -q "\[SOURCE=autonomous\]" <<< "$OUT"
check "cron の回は --reason を渡さず、お願いも出さない" $?

# 1b. 活動時間の外（settings.json は 10〜11 時だけ・関所が無い／読めない）でも、お願いの回は動く
echo '{"active_hours": [[10, 11]]}' > "$CHAR/config/settings.json"
reset
OUT=$(env PETIT_HOUSE_TABLE= PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "2026-10-11 03:20" --ask "$ASK" 2>/dev/null)
grep -q "## お願い" <<< "$OUT" && grep -q "お願いに応えるなら、顔(body_face)" <<< "$OUT"
check "活動時間の外・深夜でもお願いの回は動く（声は出さずに応える）" $?
reset
OUT=$(env PETIT_HOUSE_TABLE= PATH="$WORK/bin:$PATH" "$BASH" "$SCRIPT" mio --dry-run --date "2026-10-11 03:20" 2>/dev/null)
! grep -q "DRY RUN" <<< "$OUT" && grep -q "非アクティブ時間帯" <<< "$(log)"
check "cron の回は活動時間の外では動かないまま" $?
echo '{"active_hours": [[0, 24]]}' > "$CHAR/config/settings.json"

# 2. 台帳・全文ログの source（家の表が無くても record_usage.py・archive_stream.py は呼ばれる）
reset
run PETIT_HOUSE_TABLE= "$BASH" "$SCRIPT" mio --date "$DATE" --ask "$ASK"
grep -q "record_usage.py --petit mio --source ask" "$FAKE_PY_CALLS" && grep -q "archive_stream.py --petit mio --source ask" "$FAKE_PY_CALLS"
check "お願いの回は台帳・全文ログの source が ask" $?
grep -qF "$ASK" "$FAKE_CLAUDE_PROMPT"; check "claude にお願いの言葉が渡る" $?
! grep -qF "みてみて" <<< "$(log)"; check "ログにはお願いの中身を残さない" $?
reset
run PETIT_HOUSE_TABLE= "$BASH" "$SCRIPT" mio --date "$DATE"
grep -q "record_usage.py --petit mio --source autonomous" "$FAKE_PY_CALLS"; check "cron の回の source は autonomous のまま" $?

# 3. 重ならないように（flock）
if command -v flock > /dev/null 2>&1; then
  reset
  flock "$LOCK" sleep 3 & HOLDER=$!; sleep 0.5
  run PETIT_HOUSE_TABLE= "$BASH" "$SCRIPT" mio --date "$DATE"
  [ ! -s "$FAKE_CLAUDE_CALLS" ] && grep -q "まだ動いているので今回は抜ける" <<< "$(log)"
  check "前の回が動いていれば、cron の回は claude を呼ばずに抜ける" $?
  reset
  run PETIT_HOUSE_TABLE= PETIT_ASK_LOCK_WAIT_S=1 "$BASH" "$SCRIPT" mio --date "$DATE" --ask "$ASK"
  [ ! -s "$FAKE_CLAUDE_CALLS" ] && grep -q "お願いの回は動かない" <<< "$(log)"
  check "待ちきれなければ、お願いの回も抜ける" $?
  wait "$HOLDER"
  reset
  flock "$LOCK" sleep 2 & HOLDER=$!; sleep 0.5
  run PETIT_HOUSE_TABLE= PETIT_ASK_LOCK_WAIT_S=20 "$BASH" "$SCRIPT" mio --date "$DATE" --ask "$ASK"
  [ -s "$FAKE_CLAUDE_CALLS" ]; check "前の回が終われば、お願いの回はそのあと動く" $?
  wait "$HOLDER"
  reset
  run PETIT_HOUSE_TABLE= "$BASH" "$SCRIPT" mio --date "$DATE"
  [ -s "$FAKE_CLAUDE_CALLS" ]; check "誰も動いていなければ cron の回は動く" $?
else
  echo "skip flock が無い（重ならないようにの確かめは Linux / WSL で）"
fi

if [ "$fails" -gt 0 ]; then echo "$fails 件失敗"; exit 1; fi
echo "すべて通った"
