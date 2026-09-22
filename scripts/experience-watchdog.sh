#!/usr/bin/env bash
# 体験デーモンの見張りスクリプト(コンテナ内、汎用版プレースホルダー)。
#
# Phase 1(2026-07)時点では、体験デーモン(experience-daemon)相当のコンポーネントが
# まだ存在しない。そのため、このスクリプトは EXPERIENCE_DAEMON_DIR が
# 見つかった場合のみ起動を試み、無ければ何もせず正常終了する。
# 将来 petit-experience (仮) が用意されたら、EXPERIENCE_DAEMON_DIR を合わせるか
# 環境変数で上書きするだけで有効化できる。
set -u

CHARACTER_ID="${1:-}"
if [ -z "$CHARACTER_ID" ]; then
  echo "Usage: $0 <character_id>" >&2
  exit 1
fi

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
EXPERIENCE_DAEMON_DIR="${EXPERIENCE_DAEMON_DIR:-/opt/petit/repos/petit-experience}"
LOG_DIR="$PETIT_DATA_DIR/logs"
mkdir -p "$LOG_DIR"

if [ ! -d "$EXPERIENCE_DAEMON_DIR" ]; then
  echo "[experience-watchdog] $EXPERIENCE_DAEMON_DIR が未提供のためスキップ (character=$CHARACTER_ID)。Phase 1時点では体験デーモンは未公開コンポーネント。"
  exit 0
fi

START_SCRIPT="$EXPERIENCE_DAEMON_DIR/start_experienced.sh"
if [ -x "$START_SCRIPT" ]; then
  PETIT_DATA_DIR="$PETIT_DATA_DIR" "$START_SCRIPT" "$CHARACTER_ID"
else
  echo "[experience-watchdog] $START_SCRIPT が実行できない。スキップ (character=$CHARACTER_ID)" >&2
fi
