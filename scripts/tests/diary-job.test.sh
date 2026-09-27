#!/usr/bin/env bash
# run-for-each-character.sh diary(ぷちが寝て日記を書く・akatsuki-petit#133)の呼び方を確かめる。
# 家 API の write_diary.py の代わりに、引数を書き残す偽の python を置く。claude・AWS には触らない。
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
echo '# placeholder' > "$APP/scripts/write_diary.py"
cat > "$APP/.venv/bin/python" <<'PY'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CALLS"
echo "[call_claude:x] stderr noise"
echo "diary: 2026-09-26 written (sessions ended: 1)"
PY
chmod +x "$APP/.venv/bin/python"
export FAKE_CALLS="$WORK/calls"

fails=0
check() {  # 名前 条件(0=ok)
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

: > "$FAKE_CALLS"
OUT="$(env CHARACTER_IDS="mio, rin" PETIT_HOUSE_TABLE=t bash "$SCRIPT" diary 2>&1)"
grep -qx "$APP/scripts/write_diary.py mio" "$FAKE_CALLS"; check "ぷちごとに write_diary.py <id> を呼ぶ(mio)" $?
grep -qx "$APP/scripts/write_diary.py rin" "$FAKE_CALLS"; check "ぷちごとに write_diary.py <id> を呼ぶ(rin)" $?
grep -q "mio: diary: 2026-09-26 written" <<<"$OUT"; check "結果の1行をログに出す" $?
! grep -q "stderr noise" <<<"$OUT"; check "最後の1行だけを残す" $?

: > "$FAKE_CALLS"
OUT="$(env CHARACTER_IDS=mio PETIT_HOUSE_TABLE= bash "$SCRIPT" diary 2>&1)"
[ ! -s "$FAKE_CALLS" ]; check "家の表が無い環境では呼ばない" $?
grep -q "diaryスキップ" <<<"$OUT"; check "スキップをログに残す" $?

rm "$APP/scripts/write_diary.py"
: > "$FAKE_CALLS"
env CHARACTER_IDS=mio PETIT_HOUSE_TABLE=t bash "$SCRIPT" diary > /dev/null 2>&1
[ ! -s "$FAKE_CALLS" ]; check "write_diary.py の無い古い家 API では呼ばない" $?

grep -q '^0 4 \* \* \* /opt/petit/scripts/run-for-each-character.sh diary' "$HERE/../cron/petit.cron"; check "cron は毎晩 4:00" $?

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
