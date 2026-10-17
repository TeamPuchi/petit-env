#!/usr/bin/env bash
# autonomous-action.sh が、自律行動の前に家 API の /internal/petits/<id>/snacks/consume へ reserve、
# 動いたら confirm、claude が動かなかったら cancel を頼むか。口が呼べなくても自律行動を止めないか。
# 予約で 402 なら動かずに眠るか（⑨。家 API が 402 を返すのは PETIT_SNACK_ENFORCE=1 のときだけ）。
# （設計書 §5 ⑤・家 API 契約 §⑧ 8-5）。
# 家 API の代わりに 127.0.0.1 の小さな HTTP サーバーを立て、本物の curl で呼ばせる。claude は偽物。AWS には触らない。
#
# Usage: bash scripts/tests/snack-consume.test.sh
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

# 偽の家 API: 受けた要求（道・秘密・本文）を1行ずつ書き、FAKE_STATUS_<op> の数で応える
cat > "$WORK/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

log, portfile = sys.argv[1], sys.argv[2]

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0)).decode()
        try:
            op = json.loads(body).get("op")
        except ValueError:
            op = None
        status = int(open(os.path.join(os.path.dirname(log), f"status-{op}")).read()) \
            if os.path.exists(os.path.join(os.path.dirname(log), f"status-{op}")) else 200
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "secret": self.headers.get("x-petit-internal-secret"),
                                "ctype": self.headers.get("content-type"), "body": json.loads(body)}) + "\n")
        out = {"error": "no_snacks", "available": 0, "need": 1} if status == 402 else \
            {"kind": op, "reserved": 1, "short": False, "balance": 3, "replayed": False, "enforce": False}
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

# 偽の claude: 呼ばれたことを書き、FAKE_CLAUDE_BROKEN なら result 行を出さずに落ちる
cat > "$WORK/bin/claude" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
echo called >> "$FAKE_CLAUDE_CALLS"
if [ -n "${FAKE_CLAUDE_BROKEN:-}" ]; then
  echo "Invalid API key"
  exit 1
fi
echo '{"type":"system","subtype":"init","model":"fake-model"}'
echo '{"type":"result","subtype":"success","session_id":"s-new","num_turns":2,"total_cost_usd":0.03,"usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":3000,"output_tokens":45}}'
SH
chmod +x "$WORK/bin/claude"
export FAKE_CLAUDE_CALLS="$WORK/claude-calls"

fails=0
check() {  # 名前 条件(0=ok)
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
run() {  # run [env...] [-- 追加の引数...]  — 既定の時間帯(18-24)の中の 19:00 に、cron と同じ形で1回動かす
  : > "$WORK/requests"; : > "$WORK/curl-args"; : > "$FAKE_CLAUDE_CALLS"
  rm -f "$WORK"/status-* "$CHAR/state/.heartbeat-session-id"
  rm -rf "$PETIT_DATA_DIR/logs"
  local envs=() extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift && extra=("$@")
  for e in ${envs[@]+"${envs[@]}"}; do
    case "$e" in STATUS_*=*) k="${e%%=*}"; echo "${e#*=}" > "$WORK/status-${k#STATUS_}" ;; esac
  done
  env PATH="$WORK/bin:$PATH" PETIT_HOUSE_TABLE=t PORT="$PORT_OK" PETIT_INTERNAL_SECRET='s3cr"et' \
    PETIT_HOUSE_API_URL= PETIT_SETTINGS_GATE=0 ${envs[@]+"${envs[@]}"} \
    bash "$SCRIPT" mio --date "2026-10-16 19:00" ${extra[@]+"${extra[@]}"} > /dev/null 2>&1
  RC=$?
  LOG="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
}
ops() { jq -r '.body.op' "$WORK/requests" | tr '\n' ' ' | sed 's/ $//'; }

# 1. いつもの回: 予約 → 動く → 確定（usage つき）
run
[ "$RC" -eq 0 ]; check "いつもの回: 正常に終わる" $?
[ "$(ops)" = "reserve confirm" ]; check "いつもの回: reserve のあと confirm" $?
[ "$(wc -l < "$FAKE_CLAUDE_CALLS")" -eq 1 ]; check "いつもの回: claude を呼ぶ" $?
[ "$(jq -r '.path' "$WORK/requests" | sort -u)" = "/internal/petits/mio/snacks/consume" ]; check "口の道" $?
[ "$(jq -r '.secret' "$WORK/requests" | sort -u)" = 's3cr"et' ]; check "秘密を x-petit-internal-secret で渡す" $?
[ "$(jq -r '.ctype' "$WORK/requests" | sort -u)" = "application/json" ]; check "JSON で送る" $?
! grep -q 's3cr' "$WORK/curl-args"; check "秘密は curl の引数に出さない" $?
[ "$(jq -r '.body.run_id' "$WORK/requests" | sort -u | wc -l)" -eq 1 ]; check "予約と確定で同じ run_id" $?
jq -r '.body.run_id' "$WORK/requests" | head -n1 | grep -Eq '^[A-Za-z0-9_-]{1,64}$'; check "run_id は家 API の形（英数字と - _・64 文字まで）" $?
[ "$(jq -c 'select(.body.op == "reserve") | .body | {action, snacks, usage}' "$WORK/requests")" = '{"action":"autonomous","snacks":null,"usage":null}' ]
check "予約: action=autonomous・snacks=null・usage=null" $?
[ "$(jq -c 'select(.body.op == "confirm") | .body.usage' "$WORK/requests")" = '{"tokens_in":120,"tokens_out":45,"cache_read":3000,"model":"fake-model","usd_estimate":0.03}' ]
check "確定: result 行の usage・モデル・1回ぶんの額を添える" $?
echo "$LOG" | grep -q '^\[snack\] reserve run=auto-.* {"kind":"reserve"'; check "ログに予約の結果を1行" $?

# 2. 予約で 402（家 API が PETIT_SNACK_ENFORCE=1 のときだけ返す）なら、動かずに眠る（⑨）
run STATUS_reserve=402
[ "$RC" -eq 0 ]; check "402: 正常に終わる" $?
[ ! -s "$FAKE_CLAUDE_CALLS" ]; check "402: claude を呼ばない" $?
[ "$(ops)" = "reserve" ]; check "402: 予約のあと確定も取り消しも頼まない" $?
echo "$LOG" | grep -q '\[snack\] reserve .* 402 .*眠る'; check "402 はログに1行" $?
echo "$LOG" | grep -q '^\[skip\] おやつ切れ'; check "402: 眠ったことをログに1行" $?

# 2b. 確定で 402 でも（もう動いたあと）そのまま終わる
run STATUS_confirm=402
[ "$RC" -eq 0 ] && [ "$(wc -l < "$FAKE_CLAUDE_CALLS")" -eq 1 ]; check "確定の 402: 動いたまま正常に終わる" $?
[ "$(ops)" = "reserve confirm" ]; check "確定の 402: 取り消しは頼まない" $?

# 3. 家 API がエラー（503）でも止めない
run STATUS_reserve=503 STATUS_confirm=503
[ "$(wc -l < "$FAKE_CLAUDE_CALLS")" -eq 1 ] && [ "$RC" -eq 0 ]; check "503 でも動く" $?
echo "$LOG" | grep -q '\[snack\] confirm .* 呼べなかった（http=503'; check "503 はログに1行" $?

# 4. 口につながらない（閉じたポート）でも止めない・待ちすぎない
start=$(date +%s)
run PORT=1
[ "$(wc -l < "$FAKE_CLAUDE_CALLS")" -eq 1 ] && [ "$RC" -eq 0 ]; check "つながらなくても動く" $?
[ $(( $(date +%s) - start )) -lt 20 ]; check "つながらないときに長く待たない" $?
echo "$LOG" | grep -q '\[snack\] reserve .* 呼べなかった（http=000'; check "つながらないことはログに1行" $?

# 5. claude が動かなかった（result 行が無い）なら取り消す
run FAKE_CLAUDE_BROKEN=1
[ "$(ops)" = "reserve cancel" ]; check "claude が動かなければ reserve のあと cancel" $?

# 6. 呼ばない場合
run -- -p "おさんぽしよう"
[ ! -s "$WORK/requests" ] && [ "$(wc -l < "$FAKE_CLAUDE_CALLS")" -eq 1 ]; check "手で渡すプロンプト（-p）では食べない" $?
run PETIT_SNACK_CONSUME=0
[ ! -s "$WORK/requests" ] && [ "$(wc -l < "$FAKE_CLAUDE_CALLS")" -eq 1 ]; check "PETIT_SNACK_CONSUME=0 で外す" $?
run PETIT_HOUSE_TABLE=
[ ! -s "$WORK/requests" ] && [ "$(wc -l < "$FAKE_CLAUDE_CALLS")" -eq 1 ]; check "家の表が無い環境では呼ばない" $?
run -- --dry-run
[ ! -s "$WORK/requests" ] && [ ! -s "$FAKE_CLAUDE_CALLS" ]; check "dry-run では呼ばない" $?

# 7. PETIT_HOUSE_API_URL があればそちらへ（末尾の / は無視）
run PORT=1 PETIT_HOUSE_API_URL="http://127.0.0.1:$PORT_OK/"
[ "$(ops)" = "reserve confirm" ]; check "PETIT_HOUSE_API_URL を使う" $?

echo
if [ "$fails" -eq 0 ]; then echo "all ok"; else echo "$fails failed"; exit 1; fi
