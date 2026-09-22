#!/usr/bin/env bash
# petit-env コンテナのエントリポイント。
#
# supercronic(cron代替)・ダッシュボード・体験デーモン見張りをまとめて起動する。
# 各サービスの起動失敗が全体を道連れにしないよう、失敗してもコンテナ自体は生き続ける
# (バックグラウンド実行 + 個別ログファイルへ隔離)。
set -u

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
LOG_DIR="$PETIT_DATA_DIR/logs"
mkdir -p "$LOG_DIR" "$PETIT_DATA_DIR/characters"

echo "[entrypoint] $(date -Iseconds) 起動開始 (CHARACTER_IDS=${CHARACTER_IDS:-未設定})"

# --- 1. supercronic (cron) ---
if [ -f /opt/petit/cron/petit.cron ]; then
  supercronic /opt/petit/cron/petit.cron >> "$LOG_DIR/supercronic.log" 2>&1 &
  echo "[entrypoint] supercronic 起動 (log: $LOG_DIR/supercronic.log)"
else
  echo "[entrypoint] 警告: /opt/petit/cron/petit.cron が見つからない。cronはスキップ" >&2
fi

# --- 2. 家コンテナ内の HTTP サービス (m5-petit-app, FastAPI :8765) ---
# クラウド版 SPA (TeamPuchi/petit-app) とは別物。詳細は scripts/sync-repos.sh のコメント。
# 存在チェックはディレクトリではなく main.py で行う。イメージ側に .venv を先に掘ってある
# (Dockerfile.core・T3 の匿名ボリューム用)ので、未同期でもディレクトリ自体は必ず存在するため。
DASHBOARD_DIR="/opt/petit/repos/m5-petit-app"
if [ -f "$DASHBOARD_DIR/main.py" ]; then
  (
    cd "$DASHBOARD_DIR" && exec uv run python main.py
  ) >> "$LOG_DIR/dashboard.log" 2>&1 &
  echo "[entrypoint] ダッシュボード起動を試行 (log: $LOG_DIR/dashboard.log, port: 8765)"
else
  echo "[entrypoint] 警告: $DASHBOARD_DIR/main.py が見つからない(sync-repos未実行?)。ダッシュボードはスキップ" >&2
fi

# --- 3. 体験デーモン見張り (起動時に一度だけ起こす。以後はcronの見張りジョブに任せる) ---
if [ -f /opt/petit/scripts/experience-watchdog.sh ]; then
  IFS=',' read -ra CHARS <<< "${CHARACTER_IDS:-}"
  for c in "${CHARS[@]}"; do
    c_trimmed="$(echo "$c" | xargs)"
    [ -z "$c_trimmed" ] && continue
    /opt/petit/scripts/experience-watchdog.sh "$c_trimmed" >> "$LOG_DIR/experience-$c_trimmed.log" 2>&1 &
    echo "[entrypoint] 体験デーモン見張りを起動: $c_trimmed"
  done
else
  echo "[entrypoint] 警告: experience-watchdog.sh が見つからない。体験デーモンはスキップ" >&2
fi

echo "[entrypoint] 起動完了。フォアグラウンドで待機します"

# コンテナを生かし続ける(いずれかの子プロセスの終了を待つのではなく無限待機)。
# SIGTERM/SIGINTは tail -f に届き、docker compose down / stop で正常終了する。
exec tail -f /dev/null
