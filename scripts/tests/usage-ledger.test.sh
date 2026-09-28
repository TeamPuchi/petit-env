#!/usr/bin/env bash
# autonomous-action.sh が、自律行動の1回ごとに家 API の record_usage.py（コスト台帳）と
# archive_stream.py（全文ログ・petit-api#38）を呼ぶかを確かめる。
# claude と家 API の python は偽物を置く。claude・AWS には触らない。
#
# Usage: bash scripts/tests/usage-ledger.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
APP="$PETIT_REPOS_DIR/m5-petit-app"
mkdir -p "$PETIT_DATA_DIR/characters/mio/config" "$PETIT_DATA_DIR/characters/mio/state" \
         "$APP/scripts" "$APP/.venv/bin" "$PETIT_MCP_DIR" "$WORK/bin"
echo '# placeholder' > "$APP/scripts/record_usage.py"
echo '# placeholder' > "$APP/scripts/archive_stream.py"
# 偽の python: 引数と、渡された stream ファイルの中身を書き残す
cat > "$APP/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
prev=""
for a in "$@"; do
  if [ "$prev" = "--file" ]; then cat "$a" >> "$FAKE_STREAMS"; fi
  if [ "$prev" = "--prompt-file" ]; then cat "$a" >> "$FAKE_PROMPTS"; echo >> "$FAKE_PROMPTS"; fi
  prev="$a"
done
PY
chmod +x "$APP/.venv/bin/python"
# 偽の claude: --resume で FAKE_RESUME_FAIL なら失敗、ほかは result 行を出す
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
if [[ " $* " == *" --resume "* ]] && [ -n "${FAKE_RESUME_FAIL:-}" ]; then
  echo "No conversation found with session ID: old"
  exit 1
fi
echo '{"type":"system","subtype":"init","model":"claude-sonnet-5"}'
echo '{"type":"result","subtype":"success","session_id":"s-new","num_turns":2,"total_cost_usd":0.03}'
SH
chmod +x "$WORK/bin/claude"
export FAKE_CALLS="$WORK/calls" FAKE_STREAMS="$WORK/streams" FAKE_PROMPTS="$WORK/prompts"

fails=0
check() {  # 名前 条件(0=ok)
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
run() {
  : > "$FAKE_CALLS"; : > "$FAKE_STREAMS"; : > "$FAKE_PROMPTS"
  env PETIT_HOUSE_TABLE= PATH="$WORK/bin:$PATH" "$@" bash "$SCRIPT" mio -p "おさんぽしよう" > /dev/null 2>&1
}

rm -f "$PETIT_DATA_DIR/characters/mio/state/.heartbeat-session-id"
run
[ "$(grep -c record_usage.py "$FAKE_CALLS")" -eq 1 ]; check "新しいセッション: 1 回だけ台帳に足す" $?
[ "$(grep -c archive_stream.py "$FAKE_CALLS")" -eq 1 ]; check "新しいセッション: 全文ログを 1 本置く" $?
grep -q -- "archive_stream.py --petit mio --source autonomous --file .* --prompt-file .* --attempt 1$" "$FAKE_CALLS"; check "全文ログにプロンプトも渡す" $?
grep -qx "おさんぽしよう" "$FAKE_PROMPTS"; check "プロンプトの中身" $?
! ls "${TMPDIR:-/tmp}"/petit-prompt.* >/dev/null 2>&1; check "プロンプトの一時ファイルは消える" $?
grep -q "m5-petit-app/scripts/record_usage.py --petit mio --source autonomous --file " "$FAKE_CALLS"; check "ぷち・用途・stream を渡す" $?
grep -q -- "--input-chars 7 --attempt 1 --data-dir $PETIT_DATA_DIR" "$FAKE_CALLS"; check "プロンプトの文字数・台帳の置き場" $?
grep -q '"total_cost_usd":0.03' "$FAKE_STREAMS"; check "stream を消す前に渡す" $?
! grep -q -- "--resumed" "$FAKE_CALLS"; check "新しいセッションは resumed でない" $?

echo old > "$PETIT_DATA_DIR/characters/mio/state/.heartbeat-session-id"
date "+%Y-%m-%d" > "$PETIT_DATA_DIR/characters/mio/state/.heartbeat-session-date"
run
grep -q -- "--attempt 1 --data-dir $PETIT_DATA_DIR --resumed$" "$FAKE_CALLS"; check "resume した回は --resumed" $?
grep -q -- "archive_stream.py .* --attempt 1 --resumed$" "$FAKE_CALLS"; check "全文ログも --resumed" $?

echo old > "$PETIT_DATA_DIR/characters/mio/state/.heartbeat-session-id"
run FAKE_RESUME_FAIL=1
[ "$(grep -c record_usage.py "$FAKE_CALLS")" -eq 2 ]; check "resume に失敗して作り直した回は 2 行" $?
[ "$(grep -c archive_stream.py "$FAKE_CALLS")" -eq 2 ]; check "全文ログも 2 本" $?
grep -q -- "--attempt 1 .* --resumed --fail-reason resume_failed" "$FAKE_CALLS"; check "失敗した resume も残す" $?
grep -q -- "--attempt 2 --data-dir" "$FAKE_CALLS"; check "作り直した回は attempt 2" $?

rm "$APP/scripts/record_usage.py" "$APP/scripts/archive_stream.py"
run
[ ! -s "$FAKE_CALLS" ]; check "record_usage.py・archive_stream.py の無い古い家 API では呼ばない" $?

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
