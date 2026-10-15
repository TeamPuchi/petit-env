#!/usr/bin/env bash
# run-for-each-character.sh の snack-monthly(月きほんのおやつ・akatsuki-petit#102)の呼び方を確かめる。
# - 家 API の scripts/snack_grant.py monthly <id> --by cron をぷちごとに呼ぶ(偽の python が引数を書き残す)
# - 家の表が無い環境・snack_grant.py の無い古い家 API・PETIT_SNACK_MONTHLY_AUTO=0 では呼ばない
# - cron: 毎日 0:10(冪等キーで月1回しか入らない)
# AWS には触らない。
#
# Usage: bash scripts/tests/snack-monthly.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/run-for-each-character.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_REPOS_DIR="$WORK/repos"
APP="$PETIT_REPOS_DIR/m5-petit-app"
mkdir -p "$APP/scripts" "$APP/.venv/bin"
echo '# placeholder' > "$APP/scripts/snack_grant.py"
cat > "$APP/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
printf '[\n  {\n    "kind": "grant",\n    "amount": 10,\n    "balance": 10,\n    "replayed": false\n  }\n]\n'
PY
chmod +x "$APP/.venv/bin/python"
export FAKE_CALLS="$WORK/calls"

fails=0
check() {  # 名前 条件(0=ok)
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

: > "$FAKE_CALLS"
OUT="$(env CHARACTER_IDS="mio, rin" PETIT_HOUSE_TABLE=t bash "$SCRIPT" snack-monthly 2>&1)"
grep -qx "$APP/scripts/snack_grant.py monthly mio --by cron" "$FAKE_CALLS"; check "ぷちごとに snack_grant.py monthly <id> --by cron(mio)" $?
grep -qx "$APP/scripts/snack_grant.py monthly rin --by cron" "$FAKE_CALLS"; check "ぷちごとに snack_grant.py monthly <id> --by cron(rin)" $?
[ "$(grep -c '^\[snack-monthly\] .* mio rc=0 ' <<<"$OUT")" -eq 1 ]; check "結果をぷちごとに1行で残す" $?
grep -q '"replayed": false' <<<"$OUT"; check "結果の JSON を1行に詰めて残す" $?

: > "$FAKE_CALLS"
OUT="$(env CHARACTER_IDS=mio PETIT_HOUSE_TABLE= bash "$SCRIPT" snack-monthly 2>&1)"
[ ! -s "$FAKE_CALLS" ]; check "家の表が無い環境では呼ばない" $?
grep -q "snack-monthlyスキップ" <<<"$OUT"; check "スキップをログに残す" $?

: > "$FAKE_CALLS"
env CHARACTER_IDS=mio PETIT_HOUSE_TABLE=t PETIT_SNACK_MONTHLY_AUTO=0 bash "$SCRIPT" snack-monthly > /dev/null 2>&1
[ ! -s "$FAKE_CALLS" ]; check "PETIT_SNACK_MONTHLY_AUTO=0 で止める" $?

rm "$APP/scripts/snack_grant.py"
: > "$FAKE_CALLS"
env CHARACTER_IDS=mio PETIT_HOUSE_TABLE=t bash "$SCRIPT" snack-monthly > /dev/null 2>&1
[ ! -s "$FAKE_CALLS" ]; check "snack_grant.py の無い古い家 API では呼ばない" $?

CRON="$HERE/../cron/petit.cron"
grep -q '^10 0 \* \* \* /opt/petit/scripts/run-for-each-character.sh snack-monthly' "$CRON"; check "cron: 毎日 0:10" $?

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
