#!/usr/bin/env bash
# autonomous-action.sh が、自律行動の回の始まりに家 API の POST /internal/body/<id>/wake_for_action を頼むか
# （家の見回りが眠らせた体を起こす。なぎさん 2026-11-18「澪が動いているのに顔が起きた顔にならない」）。
# 口が無い・つながらないときも自律行動を止めないか。夜の今日をふり返る回・手で渡すプロンプト・dry-run・
# 家の表が無い環境・PETIT_WAKE_FOR_ACTION=0 では呼ばないか。
# 家 API の代わりに 127.0.0.1 の小さな HTTP サーバーを立て、本物の curl で呼ばせる。claude は偽物。AWS には触らない。
#
# Usage: bash scripts/tests/wake-for-action.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
WORK="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
export PETIT_GEN_SKILLS="$WORK/no-gen-skills.sh"
CHAR="$PETIT_DATA_DIR/characters/mio"
mkdir -p "$CHAR/config" "$CHAR/state" "$PETIT_REPOS_DIR/m5-petit-app/scripts" "$PETIT_MCP_DIR" "$WORK/bin"
REAL_CURL="$(command -v curl)"

# 偽の家 API: 受けた要求（道・秘密）を1行ずつ書き、status ファイルの数で応える（無ければ 200）
cat > "$WORK/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

log, portfile = sys.argv[1], sys.argv[2]
status_file = os.path.join(os.path.dirname(log), "status")

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        status = int(open(status_file).read()) if os.path.exists(status_file) else 200
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "secret": self.headers.get("x-petit-internal-secret")}) + "\n")
        out = {"woke": True, "why": "woke"} if status == 200 else {"error": "not_found"}
        data = json.dumps(out).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass

s = HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()
PY
python3 "$WORK/server.py" "$WORK/requests" "$WORK/port" &
SERVER_PID=$!
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT_OK="$(cat "$WORK/port")"

# curl の引数を書き残してから本物を呼ぶ（秘密が引数に出ないかを見る）
cat > "$WORK/bin/curl" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$WORK/curl-args"
exec "$REAL_CURL" "\$@"
SH
chmod +x "$WORK/bin/curl"

# 偽の claude: 呼ばれたときに、家 API がもう呼ばれていた数を書く（起こすのが claude より前か）
cat > "$WORK/bin/claude" <<SH
#!/usr/bin/env bash
cat > /dev/null
wc -l < "$WORK/requests" >> "$WORK/claude-calls"
echo '{"type":"system","subtype":"init","model":"fake-model"}'
echo '{"type":"result","subtype":"success","session_id":"s-new","num_turns":2,"total_cost_usd":0.03,"usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":3000,"output_tokens":45}}'
SH
chmod +x "$WORK/bin/claude"
CALLS="$WORK/claude-calls"

fails=0
check() {  # 名前 条件(0=ok)
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
run() {  # run [env...] [-- 追加の引数...]  — 既定の時間帯(18-24)の中の 19:00 に、cron と同じ形で1回動かす
  : > "$WORK/requests"; : > "$WORK/curl-args"; : > "$CALLS"
  rm -f "$WORK/status" "$CHAR/state/.heartbeat-session-id"
  rm -rf "$PETIT_DATA_DIR/logs"
  local envs=() extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift && extra=("$@")
  for e in ${envs[@]+"${envs[@]}"}; do
    case "$e" in STATUS=*) echo "${e#*=}" > "$WORK/status" ;; esac
  done
  env PATH="$WORK/bin:$PATH" PETIT_HOUSE_TABLE=t PORT="$PORT_OK" PETIT_INTERNAL_SECRET='s3cr"et' \
    PETIT_HOUSE_API_URL= PETIT_SETTINGS_GATE=0 PETIT_SNACK_CONSUME=0 ${envs[@]+"${envs[@]}"} \
    bash "$SCRIPT" mio --date "2026-10-16 19:00" ${extra[@]+"${extra[@]}"} > /dev/null 2>&1
  RC=$?
  LOG="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
}

# 1. いつもの回: claude の前に起こす口を1回呼ぶ
run
[ "$RC" -eq 0 ]; check "いつもの回: 正常に終わる" $?
[ "$(wc -l < "$WORK/requests")" -eq 1 ]; check "いつもの回: 口を1回呼ぶ" $?
[ "$(jq -r '.path' "$WORK/requests")" = "/internal/body/mio/wake_for_action" ]; check "口の道" $?
[ "$(jq -r '.secret' "$WORK/requests")" = 's3cr"et' ]; check "秘密を x-petit-internal-secret で渡す" $?
! grep -q 's3cr' "$WORK/curl-args"; check "秘密は curl の引数に出さない" $?
[ "$(tr -d ' ' < "$CALLS")" = "1" ]; check "claude を呼ぶ前に起こしている" $?
echo "$LOG" | grep -q '^\[wake\] {"woke":true,"why":"woke"}$'; check "ログに起こした結果を1行" $?

# 2. 口が無い（古い家 API は 404）・つながらないでも止めない
run STATUS=404
[ "$RC" -eq 0 ] && [ "$(wc -l < "$CALLS")" -eq 1 ]; check "404 でも動く" $?
echo "$LOG" | grep -q '^\[wake\] 体を起こす口を呼べなかった(http=404)'; check "404 はログに1行" $?
start=$(date +%s)
run PORT=1
[ "$RC" -eq 0 ] && [ "$(wc -l < "$CALLS")" -eq 1 ]; check "つながらなくても動く" $?
[ $(( $(date +%s) - start )) -lt 20 ]; check "つながらないときに長く待たない" $?
echo "$LOG" | grep -q '^\[wake\] 体を起こす口を呼べなかった(http=000)'; check "つながらないことはログに1行" $?

# 3. 呼ばない場合
run -- -p "おさんぽしよう"
[ ! -s "$WORK/requests" ] && [ "$(wc -l < "$CALLS")" -eq 1 ]; check "手で渡すプロンプト（-p）では呼ばない" $?
run PETIT_WAKE_FOR_ACTION=0
[ ! -s "$WORK/requests" ] && [ "$(wc -l < "$CALLS")" -eq 1 ]; check "PETIT_WAKE_FOR_ACTION=0 で外す" $?
run PETIT_HOUSE_TABLE=
[ ! -s "$WORK/requests" ] && [ "$(wc -l < "$CALLS")" -eq 1 ]; check "家の表が無い環境では呼ばない" $?
run -- --dry-run
[ ! -s "$WORK/requests" ]; check "dry-run では呼ばない" $?
run -- --diary
[ ! -s "$WORK/requests" ]; check "今日をふり返る回（--diary）では呼ばない" $?

# 4. PETIT_HOUSE_API_URL があればそちらへ（末尾の / は無視）
run PORT=1 PETIT_HOUSE_API_URL="http://127.0.0.1:$PORT_OK/"
[ "$(jq -r '.path' "$WORK/requests")" = "/internal/body/mio/wake_for_action" ]; check "PETIT_HOUSE_API_URL を使う" $?

echo
if [ "$fails" -eq 0 ]; then echo "all ok"; else echo "$fails failed"; exit 1; fi
