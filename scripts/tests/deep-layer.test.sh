#!/usr/bin/env bash
# 深い層のファイルと、頭脳の言葉の直し（brain-plan T2・T5〜T10・2026-10-12）を確かめる。
# - seed-character-files.sh: characters/<id>/ に無いファイルだけ雛形から置く。あるファイルは触らない。ディレクトリの無いぷちには何もしない
# - sample-character: 深い層4ファイルがあり、SOUL.md に「参照ルール」「行動原則」、ROUTINES.md は表で記憶の整理・統合がある
# - autonomous-action.sh（--dry-run）:
#   - ルーチン回の文に ROUTINES_DETAIL.md。allowedTools に記憶の整理・統合の道具（T5）
#   - 欲求の文: 「参考にとどめてよい」が無く、shape_desire で直す（T7）。ルーチン回も同じ
#   - 行動原則（1つか2つ・日誌・全部声にしない・二度 remember しない）がプロンプトに無い（T8）
#   - 声: 里親の呼び名（config.json の companion_name → PETIT_USER_NAME → 里親さん）で「部屋にいれば積極的に」（T9）。深夜の禁止はそのまま
#   - 記憶: 「印象に残ったことはその回のうちに remember」（T10）
# claude と家 API には触らない（dry-run）。
#
# Usage: bash scripts/tests/deep-layer.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$HERE/autonomous-action.sh"
SEED="$HERE/seed-character-files.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
export PETIT_SAMPLE_CHARACTER_DIR="$ROOT/sample-character"
CHAR="$PETIT_DATA_DIR/characters/mio"
mkdir -p "$CHAR/config" "$CHAR/state" "$PETIT_MCP_DIR"
echo '{"active_hours": [[0, 24]]}' > "$CHAR/config/settings.json"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
DEEP=(SOUL_REFLECTIONS.md REFLECTION_INDEX.md ROUTINES_DETAIL.md TODO_ARCHIVE.md)

# 1. 雛形
for f in "${DEEP[@]}" SOUL.md ROUTINES.md TODO_ACTIVE.md; do
  [ -s "$ROOT/sample-character/$f" ]; check "雛形に $f" $?
done
grep -q "^## 参照ルール" "$ROOT/sample-character/SOUL.md"; check "雛形 SOUL.md に参照ルールの節" $?
grep -q "^## 行動原則" "$ROOT/sample-character/SOUL.md"; check "雛形 SOUL.md に行動原則の節" $?
grep -q "1つか2つで足りる" "$ROOT/sample-character/SOUL.md" && grep -q "日誌のように" "$ROOT/sample-character/SOUL.md"
check "雛形 SOUL.md の行動原則に、プロンプトから移した例（1つか2つ・日誌）" $?
! grep -q "参考にとどめ" "$ROOT/sample-character/SOUL.md"; check "雛形 SOUL.md に「参考にとどめてよい」は無い" $?
grep -q "^| 記憶の整理 |" "$ROOT/sample-character/ROUTINES.md" && grep -q "^| 記憶の統合 |" "$ROOT/sample-character/ROUTINES.md"
check "雛形 ROUTINES.md は表で、記憶の整理・統合（週1）がある" $?
grep -q "ROUTINES_DETAIL.md" "$ROOT/sample-character/ROUTINES.md"; check "雛形 ROUTINES.md が手順と前回は ROUTINES_DETAIL.md と言う" $?
grep -q "^## 記憶の整理" "$ROOT/sample-character/ROUTINES_DETAIL.md" && grep -q "前回" "$ROOT/sample-character/ROUTINES_DETAIL.md"
check "雛形 ROUTINES_DETAIL.md にルーチンごとの手順と「前回」" $?

# 2. seed-character-files.sh
echo "mio の SOUL" > "$CHAR/SOUL.md"
echo "mio の ROUTINES" > "$CHAR/ROUTINES.md"
OUT=$(CHARACTER_IDS=mio bash "$SEED" 2>&1)
for f in "${DEEP[@]}" TODO_ACTIVE.md; do
  cmp -s "$ROOT/sample-character/$f" "$CHAR/$f"; check "無い $f を雛形から置く" $?
done
[ "$(cat "$CHAR/SOUL.md")" = "mio の SOUL" ] && [ "$(cat "$CHAR/ROUTINES.md")" = "mio の ROUTINES" ]
check "あるファイル（SOUL.md・ROUTINES.md）は触らない" $?
grep -q "mio: 雛形から置いた: .*SOUL_REFLECTIONS.md" <<< "$OUT"; check "置いたファイルをログに出す" $?
echo "mio の DETAIL" > "$CHAR/ROUTINES_DETAIL.md"
OUT=$(CHARACTER_IDS=mio bash "$SEED" 2>&1)
[ "$(cat "$CHAR/ROUTINES_DETAIL.md")" = "mio の DETAIL" ] && grep -q "mio: 置くものは無い" <<< "$OUT"
check "2回目は何も置き換えない（ぷちが書いたものを雛形に戻さない）" $?
OUT=$(CHARACTER_IDS="mio, nobody" bash "$SEED" 2>&1)
[ ! -d "$PETIT_DATA_DIR/characters/nobody" ] && grep -q "nobody: .*が無い" <<< "$OUT"
check "ディレクトリの無いぷちは作らない（カンマ区切り・空白つきの CHARACTER_IDS も読める）" $?
rm -f "$CHAR/TODO_ARCHIVE.md"
bash "$SEED" mio > /dev/null 2>&1
[ -f "$CHAR/TODO_ARCHIVE.md" ]; check "引数でぷちを指定しても置く" $?
OUT=$(PETIT_SAMPLE_CHARACTER_DIR="$WORK/none" CHARACTER_IDS=mio bash "$SEED" 2>&1); code=$?
[ "$code" -eq 0 ] && grep -q "雛形が無い" <<< "$OUT"; check "雛形が無ければ何もせず 0 で抜ける（起動を止めない）" $?

# 3. 自律行動のプロンプト（dry-run）
DATE="2026-10-12 19:20"
dry() { env PETIT_HOUSE_TABLE= "$BASH" "$SCRIPT" mio --dry-run --date "$DATE" "$@" 2>/dev/null; }
# dry-run はその回のログ（名前は秒単位 YYYYMMDD_HHMMSS.log）に書き足してから cat する。同じ秒に 2 回 dry-run を
# 回すと 1 つのログに 2 回ぶんが並び、--- PROMPT --- が 2 つ出る（本番では 20 分に 1 回なので起きない）。
# 最後の 1 回ぶんだけを見る
last_run() { awk '/^=== DRY RUN ===$/{buf=""} {buf=buf $0 "
"} END{printf "%s", buf}'; }
prompt_of() { last_run | sed -n '/--- PROMPT ---/,/--- ALLOWED_TOOLS ---/p'; }
tools_of() { last_run | sed -n '/--- ALLOWED_TOOLS ---/,$p'; }

OUT=$(dry --force-routine)
grep -q "手順と前回のことは ROUTINES_DETAIL.md" <<< "$OUT" && grep -q "ROUTINES_DETAIL.md の「前回」を更新" <<< "$OUT"
check "ルーチン回: 手順と前回は ROUTINES_DETAIL.md、実行したら前回を更新" $?
for t in consolidate_memories link_memories get_working_memory refresh_working_memory recall_with_associations; do
  tools_of <<< "$OUT" | grep -qx "mcp__memory__$t"; check "allowedTools に mcp__memory__$t（T5）" $?
done

OUT=$(dry --force-normal)
P=$(prompt_of <<< "$OUT")
for s in "1つか2つで足りる" "日誌のように" "全部声にしない" "もう一度 remember しなくてよい" "参考にとどめてよい" "強い欲求が無ければ" "行動せよ"; do
  ! grep -q "$s" <<< "$P"; check "プロンプトに「$s」は無い（T7・T8）" $?
done
grep -q "印象に残ったことは、この回のうちに memory の remember で残す" <<< "$P"; check "記憶: 印象に残ったことはその回のうちに remember（T10）" $?
[ "$(grep -c "remember" <<< "$P")" -le 2 ]; check "remember の指示が重なっていない（2 か所以下）" $?
[ "$(grep -c "ここでは書かない" <<< "$P")" -eq 1 ] && ! grep -q "ノート(house の note_write)は日記ではなく" <<< "$P"
check "「日記はここでは書かない」は 1 か所で、ノートの説明は重ねない" $?
grep -q "里親さんが部屋にいれば、声(body_speak)を積極的に使ってよい" <<< "$P"; check "声: 里親の名前が無ければ「里親さん」で「部屋にいれば積極的に」（T9）" $?
! grep -q "あなたの部屋" <<< "$P"; check "「あなたの部屋」は無い" $?
grep -q "SOUL.md の行動原則で自分が決めたとおりに" <<< "$P"; check "作法は SOUL.md の行動原則で自分が決める、と言う" $?

# 欲求の文（desire-status を偽物にして出す）
mkdir -p "$PETIT_REPOS_DIR/petit-desire/.venv/bin"
echo '[project]' > "$PETIT_REPOS_DIR/petit-desire/pyproject.toml"
printf '#!/usr/bin/env bash\necho "curiosity 0.8"\n' > "$PETIT_REPOS_DIR/petit-desire/.venv/bin/desire-status"
chmod +x "$PETIT_REPOS_DIR/petit-desire/.venv/bin/desire-status"
echo '{"mcpServers":{}}' > "$PETIT_MCP_DIR/mio.json"
for mode in --force-normal --force-routine; do
  P=$(dry $mode | prompt_of)
  grep -q "これは自分の欲求で、自分のもの。当たり前に従う" <<< "$P" && grep -q "shape_desire で定義(増え方・減り方も)を自分で直す" <<< "$P" \
    && ! grep -q "参考にとどめ" <<< "$P"
  check "欲求（$mode）: 自分のもの・当たり前に従う・shape_desire で直す。「参考」は無い（T7）" $?
done
# お願いの回（--ask）は無くなった（家 API が会話で応える・2026-10-12）ので、その確かめも無い

# 里親の呼び名
echo '{"character_id":"mio","companion_name":"なぎ"}' > "$CHAR/config/config.json"
P=$(dry | prompt_of)
grep -q "なぎが部屋にいれば、声(body_speak)を積極的に使ってよい" <<< "$P"; check "声: config.json の companion_name を使う（T9）" $?
P=$(PETIT_USER_NAME="envの名前" dry | prompt_of)
grep -q "なぎが部屋にいれば" <<< "$P"; check "config.json の companion_name が env PETIT_USER_NAME より先" $?
echo '{"character_id":"mio","companion_name":""}' > "$CHAR/config/config.json"
P=$(PETIT_USER_NAME="envの名前" dry | prompt_of)
grep -q "envの名前が部屋にいれば" <<< "$P"; check "companion_name が空なら env PETIT_USER_NAME" $?
# 深夜の声の禁止の文は残っているが、深夜に来る回（お願いの回）が無くなったので確かめない

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
