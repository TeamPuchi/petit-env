#!/usr/bin/env bash
# ぷちのスキル（Claude Code の Skills・W11）の置き場と渡し方を確かめる。
# - gen-skills.sh: 共通の skills/ とぷちの characters/<id>/skills/ を <置き場>/<id>/.claude/skills/ にまとめる
#   （同じ名前はぷちの方で置き換え・空の SKILL.md なら使わない・名前の変なもの・SKILL.md の無いものは写さない）
# - autonomous-action.sh: --add-dir にその置き場を足し、allowedTools に Skill が入る（--dry-run で止める）
# - リポジトリの skills/reading/SKILL.md に name・description があり、本棚の道具の使い方が書いてある
# claude・AWS・Docker には触らない。
#
# Usage: bash scripts/tests/skills.test.sh
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PETIT_DATA_DIR="$WORK/data"
export PETIT_REPOS_DIR="$WORK/repos"
export PETIT_MCP_DIR="$WORK/mcp"
export PETIT_SKILLS_SRC="$ROOT/skills"
export PETIT_SKILLS_DIR="$WORK/run-skills"
export PETIT_GEN_SKILLS="$HERE/gen-skills.sh"
mkdir -p "$PETIT_DATA_DIR/characters/mio/config" "$PETIT_DATA_DIR/characters/rin/config" "$PETIT_REPOS_DIR" "$PETIT_MCP_DIR"

fails=0
check() {  # 名前 条件の終了コード
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# 0. 共通の reading スキル
R="$ROOT/skills/reading/SKILL.md"
head -n 1 "$R" | grep -qx -- "---" && grep -q "^name: reading$" "$R" && grep -q "^description: .*book_read" "$R"
check "skills/reading/SKILL.md に name と description（いつ使うか）がある" $?
for w in "chars=500" "book_list" "book_bookmark" "book_finish" "note_read" "note_write" "search_memories" "要約はしない" "「『題』を読みながら」" '"読書"'; do
  grep -qF -- "$w" "$R"
  check "reading に $w" $?
done

# 1. 共通だけ
bash "$HERE/gen-skills.sh" mio > /dev/null
[ -f "$PETIT_SKILLS_DIR/mio/.claude/skills/reading/SKILL.md" ] && cmp -s "$R" "$PETIT_SKILLS_DIR/mio/.claude/skills/reading/SKILL.md"
check "共通の reading がぷちの置き場に入る" $?

# 2. ぷちだけのスキル・置き換え・使わない・変な名前
C="$PETIT_DATA_DIR/characters/mio/skills"
mkdir -p "$C/reading" "$C/my-walk" "$C/Bad_Name" "$C/no-skill-md"
printf -- '---\nname: reading\ndescription: みおの読み方\n---\n' > "$C/reading/SKILL.md"
printf -- '---\nname: my-walk\ndescription: 散歩\n---\n' > "$C/my-walk/SKILL.md"
printf 'x' > "$C/Bad_Name/SKILL.md"
printf 'x' > "$C/no-skill-md/notes.md"
bash "$HERE/gen-skills.sh" mio > /dev/null 2>&1
S="$PETIT_SKILLS_DIR/mio/.claude/skills"
grep -q "みおの読み方" "$S/reading/SKILL.md"
check "同じ名前はぷちの方で置き換える" $?
[ -f "$S/my-walk/SKILL.md" ]
check "ぷちだけのスキルが入る" $?
[ ! -e "$S/Bad_Name" ] && [ ! -e "$S/no-skill-md" ]
check "名前の変なもの・SKILL.md の無いものは写さない" $?
[ ! -e "$PETIT_SKILLS_DIR/rin/.claude/skills/my-walk" ]
bash "$HERE/gen-skills.sh" rin > /dev/null
[ -f "$PETIT_SKILLS_DIR/rin/.claude/skills/reading/SKILL.md" ] && [ ! -e "$PETIT_SKILLS_DIR/rin/.claude/skills/my-walk" ] \
  && ! grep -q "みおの読み方" "$PETIT_SKILLS_DIR/rin/.claude/skills/reading/SKILL.md"
check "ほかのぷちには効かない" $?
: > "$C/reading/SKILL.md"
rm -rf "$C/my-walk"
bash "$HERE/gen-skills.sh" mio > /dev/null 2>&1
[ ! -e "$S/reading" ] && [ ! -e "$S/my-walk" ]
check "空の SKILL.md なら共通を使わない・消したぷちのスキルは残らない" $?
ls -A "$PETIT_SKILLS_DIR" | grep -q '^\.' && r=1 || r=0
check "作りかけ・古い置き場が残らない" $r
rm -rf "$C"

# 3. CHARACTER_IDS 全員ぶん
rm -rf "$PETIT_SKILLS_DIR"
CHARACTER_IDS="mio, rin" bash "$HERE/gen-skills.sh" > /dev/null
[ -d "$PETIT_SKILLS_DIR/mio/.claude/skills/reading" ] && [ -d "$PETIT_SKILLS_DIR/rin/.claude/skills/reading" ]
check "引数なしなら CHARACTER_IDS 全員ぶん" $?

# 4. 自律行動: 置き場を作り直して渡す・Skill を許可
rm -rf "$PETIT_SKILLS_DIR" "$PETIT_DATA_DIR/logs"
PETIT_HOUSE_TABLE= bash "$HERE/autonomous-action.sh" mio --dry-run > /dev/null 2>&1
log="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
grep -qx "\[SKILLS\] $PETIT_SKILLS_DIR/mio" <<<"$log"
check "自律行動は毎回スキルの置き場を作り、それを渡す" $?
grep -qx "Skill" <<<"$log"
check "allowedTools に Skill" $?
grep -q -- '--add-dir "$PETIT_DATA_DIR" ${SKILLS_DIR:+"$SKILLS_DIR"}' "$HERE/autonomous-action.sh"
check "claude の --add-dir にスキルの置き場を足す" $?

# 5. 置き場が作れないとき（gen-skills.sh が無い古いイメージ）は渡さないで続ける
rm -rf "$PETIT_SKILLS_DIR" "$PETIT_DATA_DIR/logs"
PETIT_GEN_SKILLS="$WORK/none.sh" PETIT_HOUSE_TABLE= bash "$HERE/autonomous-action.sh" mio --dry-run > /dev/null 2>&1
log="$(cat "$PETIT_DATA_DIR"/logs/mio/*.log 2>/dev/null)"
grep -qx "\[SKILLS\] なし" <<<"$log" && grep -q -- "--- PROMPT ---" <<<"$log"
check "置き場が無ければ渡さず、自律行動は続ける" $?

# 6. イメージに焼き込む・起動時に作る
grep -q "^COPY --chown=petit:petit skills/ /opt/petit/skills/" "$ROOT/Dockerfile.core" \
  && grep -q "^COPY --chown=petit:petit scripts/gen-skills.sh " "$ROOT/Dockerfile.core"
check "Dockerfile.core が skills/ と gen-skills.sh を焼き込む" $?
grep -q "^/opt/petit/scripts/gen-skills.sh" "$HERE/entrypoint.sh"
check "entrypoint.sh が起動時に作る" $?
[ -f "$ROOT/sample-character/skills/README.md" ]
check "sample-character に skills/ の雛形" $?

if [ "$fails" -gt 0 ]; then echo "$fails 件失敗"; exit 1; fi
echo "すべて ok"
