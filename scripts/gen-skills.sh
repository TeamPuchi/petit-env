#!/usr/bin/env bash
# ぷちが使うスキル（Claude Code の Skills。`.claude/skills/<名前>/SKILL.md`）を、ぷちごとに1つの置き場へまとめる（W11）。
#
#   gen-skills.sh            → CHARACTER_IDS 全員ぶん
#   gen-skills.sh <id>       → そのぷちの分だけ
#
# まとめるもの:
#   1. 共通のスキル   $PETIT_SKILLS_SRC/<名前>/SKILL.md（既定 /opt/petit/skills。petit-env の skills/ を焼き込んだもの。
#                    例: 読書の reading）
#   2. そのぷちだけ   /data/characters/<id>/skills/<名前>/SKILL.md（sample-character/skills/README.md）
#                    共通と同じ名前なら、共通のものを丸ごと置き換える。中身が空の SKILL.md なら、その共通スキルを使わない。
# 置き場: $PETIT_SKILLS_DIR/<id>/.claude/skills/<名前>/（既定 /opt/petit/run/skills。/data には置かない＝版を上げたら作り直される）
#
# claude には --add-dir $PETIT_SKILLS_DIR/<id> で渡す（claude CLI は --add-dir の下の .claude/skills/ を読む）。
#   自律行動: autonomous-action.sh（毎回ここを呼び直すので、ぷちのスキルを書き換えれば次の回から効く）
#   会話    : 家 API（petit-api main.py の PETIT_SKILLS_DIR）
# entrypoint.sh が起動のたびに全員ぶんを作る。
set -euo pipefail

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
SRC_DIR="${PETIT_SKILLS_SRC:-/opt/petit/skills}"
OUT_DIR="${PETIT_SKILLS_DIR:-/opt/petit/run/skills}"

# スキルの名前は Claude Code と同じく英小文字・数字・ハイフン
valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; }

# copy_skills <元のディレクトリ> <先の .claude/skills> — 名前が正しく SKILL.md のあるものだけ写す（あれば置き換え）
copy_skills() {
  local from="$1" to="$2" d name
  [[ -d "$from" ]] || return 0
  for d in "$from"/*/; do
    [[ -f "$d/SKILL.md" ]] || continue
    name="$(basename "$d")"
    valid_name "$name" || { echo "[gen-skills] 名前が変なので飛ばす: $name" >&2; continue; }
    rm -rf "${to:?}/$name"
    if [[ -s "$d/SKILL.md" ]]; then
      cp -R "$d" "$to/$name"
    fi
  done
}

gen_one() {
  local id="$1"
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "[gen-skills] id が変: $id" >&2; return 1; }

  local tmp="$OUT_DIR/.$id.tmp.$$" dest="$OUT_DIR/$id"
  rm -rf "$tmp"
  mkdir -p "$tmp/.claude/skills"
  copy_skills "$SRC_DIR" "$tmp/.claude/skills"
  copy_skills "$PETIT_DATA_DIR/characters/$id/skills" "$tmp/.claude/skills"

  # 入れ替え（読んでいる claude がいても、置き場が消えている時間を短くする）
  rm -rf "$dest.old"
  [[ -d "$dest" ]] && mv "$dest" "$dest.old"
  mv "$tmp" "$dest"
  rm -rf "$dest.old"

  local names
  names="$(cd "$dest/.claude/skills" && ls -1 2>/dev/null | paste -sd, -)"
  echo "[gen-skills] $dest (${names:-なし})"
}

mkdir -p "$OUT_DIR"

if [[ -n "${1:-}" ]]; then
  gen_one "$1"
  exit 0
fi

IFS=',' read -ra CHARS <<< "${CHARACTER_IDS:-}"
n=0
for c in "${CHARS[@]}"; do
  c="$(echo "$c" | xargs)"
  [[ -z "$c" ]] && continue
  gen_one "$c"
  n=$((n + 1))
done
(( n > 0 )) || echo "[gen-skills] CHARACTER_IDS が未設定。何も作らない" >&2
