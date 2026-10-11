#!/usr/bin/env bash
# ぷちの characters/<id>/ に無いファイルを、雛形(sample-character)から置く(2026-10-12・T2)。
#
# PetitOnes と同じ「深い層」(必要なときだけ読むファイル): SOUL_REFLECTIONS.md(発見の詳細)・
# REFLECTION_INDEX.md(その索引)・ROUTINES_DETAIL.md(ルーチンの手順と前回)・TODO_ARCHIVE.md(終わった TODO の移し先)と、
# 毎回読む層(SOUL.md・TODO_ACTIVE.md)・ルーチン回に読む ROUTINES.md。
# 新しいぷちは雛形から必ず置き、すでに動いているぷち(澪など)も「無ければ置く」。**あるファイルは触らない**
# (中身の比較もしない。ぷちが書き換えたものを雛形に戻さないため)。
# entrypoint.sh が起動のたびに CHARACTER_IDS の各ぷちに対して呼ぶ。引数でぷちを指定すればそのぷちだけ。
#
# Usage:
#   seed-character-files.sh            # CHARACTER_IDS の全員
#   seed-character-files.sh <id>...    # 指定したぷちだけ
# env:
#   PETIT_DATA_DIR(既定 /data)・PETIT_SAMPLE_CHARACTER_DIR(既定 /opt/petit/sample-character)
set -u

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
SAMPLE_DIR="${PETIT_SAMPLE_CHARACTER_DIR:-/opt/petit/sample-character}"
SEED_FILES=(SOUL.md TODO_ACTIVE.md ROUTINES.md ROUTINES_DETAIL.md SOUL_REFLECTIONS.md REFLECTION_INDEX.md TODO_ARCHIVE.md)

if [ ! -d "$SAMPLE_DIR" ]; then
  echo "[seed-character-files] 雛形が無い: $SAMPLE_DIR(何もしない)" >&2
  exit 0
fi

if [ $# -gt 0 ]; then
  IDS=("$@")
else
  IFS=',' read -ra IDS <<< "${CHARACTER_IDS:-}"
fi

for raw in "${IDS[@]}"; do
  id="$(echo "$raw" | xargs)"
  [ -z "$id" ] && continue
  dir="$PETIT_DATA_DIR/characters/$id"
  if [ ! -d "$dir" ]; then
    # ぷちのディレクトリ自体が無いときは作らない(人格は里親が置くもの。autonomous-action.sh が「無い」と言って止まる)
    echo "[seed-character-files] $id: $dir が無い(何もしない)" >&2
    continue
  fi
  placed=()
  for f in "${SEED_FILES[@]}"; do
    [ -e "$dir/$f" ] && continue
    [ -f "$SAMPLE_DIR/$f" ] || continue
    if cp "$SAMPLE_DIR/$f" "$dir/$f"; then
      placed+=("$f")
    else
      echo "[seed-character-files] $id: $f を置けなかった" >&2
    fi
  done
  if [ "${#placed[@]}" -gt 0 ]; then
    echo "[seed-character-files] $id: 雛形から置いた: ${placed[*]}"
  else
    echo "[seed-character-files] $id: 置くものは無い(全部ある)"
  fi
done
