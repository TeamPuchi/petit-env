#!/usr/bin/env bash
# run-for-each-character.sh の diary(夜の今日をふり返る回・T4)と sleep(4:00 に寝る・akatsuki-petit#133)の呼び方を確かめる。
# - diary → autonomous-action.sh <id> --diary(中身で確かめる。run-for-each-character.sh は /opt/petit の絶対パスで呼ぶ)
# - sleep → 家 API の scripts/go_to_sleep.py <id>(偽の python が引数を書き残す)。無い古い家 API では write_diary.py
# - cron: diary は 20:30、sleep は 4:00(memory-sleep 4:05 の前)。entrypoint.sh は PETIT_DIARY_AT で diary の行を書き換える
# claude・AWS には触らない。
#
# Usage: bash scripts/tests/diary-job.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/run-for-each-character.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_REPOS_DIR="$WORK/repos"
APP="$PETIT_REPOS_DIR/m5-petit-app"
mkdir -p "$APP/scripts" "$APP/.venv/bin"
echo '# placeholder' > "$APP/scripts/go_to_sleep.py"
echo '# placeholder' > "$APP/scripts/write_diary.py"
cat > "$APP/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
echo "[call_claude:x] stderr noise"
echo "sleep: 2026-09-26 exists (sessions ended: 1)"
PY
chmod +x "$APP/.venv/bin/python"
export FAKE_CALLS="$WORK/calls"

fails=0
check() {  # 名前 条件(0=ok)
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# --- sleep(4:00) ---
: > "$FAKE_CALLS"
OUT="$(env CHARACTER_IDS="mio, rin" PETIT_HOUSE_TABLE=t bash "$SCRIPT" sleep 2>&1)"
grep -qx "$APP/scripts/go_to_sleep.py mio" "$FAKE_CALLS"; check "sleep はぷちごとに go_to_sleep.py <id> を呼ぶ(mio)" $?
grep -qx "$APP/scripts/go_to_sleep.py rin" "$FAKE_CALLS"; check "sleep はぷちごとに go_to_sleep.py <id> を呼ぶ(rin)" $?
grep -q "mio: sleep: 2026-09-26 exists" <<<"$OUT"; check "結果の1行をログに出す" $?
! grep -q "stderr noise" <<<"$OUT"; check "最後の1行だけを残す" $?

: > "$FAKE_CALLS"
OUT="$(env CHARACTER_IDS=mio PETIT_HOUSE_TABLE= bash "$SCRIPT" sleep 2>&1)"
[ ! -s "$FAKE_CALLS" ]; check "家の表が無い環境では呼ばない" $?
grep -q "sleepスキップ" <<<"$OUT"; check "スキップをログに残す" $?

rm "$APP/scripts/go_to_sleep.py"
: > "$FAKE_CALLS"
env CHARACTER_IDS=mio PETIT_HOUSE_TABLE=t bash "$SCRIPT" sleep > /dev/null 2>&1
grep -qx "$APP/scripts/write_diary.py mio" "$FAKE_CALLS"; check "go_to_sleep.py の無い古い家 API では write_diary.py(その版は日記を書いてセッションも切る)" $?
rm "$APP/scripts/write_diary.py"
: > "$FAKE_CALLS"
env CHARACTER_IDS=mio PETIT_HOUSE_TABLE=t bash "$SCRIPT" sleep > /dev/null 2>&1
[ ! -s "$FAKE_CALLS" ]; check "どちらも無い家 API では呼ばない" $?

# --- diary(20:30) → autonomous-action.sh --diary ---
grep -q '^      /opt/petit/scripts/autonomous-action.sh "$CHARACTER_ID" --diary$' "$SCRIPT"
check "diary は autonomous-action.sh <id> --diary を呼ぶ" $?
! grep -q 'write_diary.py' <<<"$(sed -n '/^    diary)/,/^      ;;/p' "$SCRIPT")"
check "diary は write_diary.py を呼ばない(家 API に書かせるのは sleep の受け皿だけ)" $?

# --- cron と entrypoint ---
CRON="$HERE/../cron/petit.cron"
grep -q '^30 20 \* \* \* /opt/petit/scripts/run-for-each-character.sh diary' "$CRON"; check "cron: 日記(今日をふり返る回)は毎晩 20:30" $?
grep -q '^0 4 \* \* \* /opt/petit/scripts/run-for-each-character.sh sleep' "$CRON"; check "cron: 寝る(セッションを切る)は毎晩 4:00 のまま" $?
grep -q '^5 4 \* \* \* /opt/petit/scripts/run-for-each-character.sh memory-sleep' "$CRON"; check "cron: 記憶の整理は 4:05 のまま(sleep の後)" $?
! grep -q '^0 4 .* diary' "$CRON"; check "cron: 4:00 の diary の行は無い" $?

# entrypoint.sh の PETIT_DIARY_AT: entrypoint と同じ sed(行をそのまま写す)で cron を書き換えて diary の行だけ変わること
SED_LINE="$(grep -o 'sed -E "s|^\[0-9\]+ \[0-9\]+ ([^"]*"' "$HERE/entrypoint.sh" | head -n 1)"
[ -n "$SED_LINE" ]; check "entrypoint.sh に PETIT_DIARY_AT で diary の行を書き換える sed がある" $?
REWRITTEN="$(bash -c 'PETIT_DIARY_AT=21:05; [[ "$PETIT_DIARY_AT" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]] && '"$SED_LINE"' "$1"' _ "$CRON")"
grep -q '^5 21 \* \* \* /opt/petit/scripts/run-for-each-character.sh diary' <<<"$REWRITTEN"; check "PETIT_DIARY_AT=21:05 で diary の行だけ 21:05 になる" $?
grep -q '^0 4 \* \* \* /opt/petit/scripts/run-for-each-character.sh sleep' <<<"$REWRITTEN"; check "sleep の行は変わらない" $?
grep -q '^\*/20 \* \* \* \* /opt/petit/scripts/run-for-each-character.sh autonomous' <<<"$REWRITTEN"; check "自律行動の行は変わらない" $?

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
