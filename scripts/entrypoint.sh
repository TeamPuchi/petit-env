#!/usr/bin/env bash
# petit-env コンテナのエントリポイント。
#
# MCP 設定の生成・supercronic(cron代替)・家 API・体験デーモン見張りをまとめて起動する。
# PID 1 は tini(Dockerfile.core の ENTRYPOINT)。孤児プロセスの回収とシグナルの中継はそちら。
# 各サービスの起動失敗が全体を道連れにしないよう、失敗してもコンテナ自体は生き続ける
# (バックグラウンド実行 + 個別ログファイルへ隔離)。
set -u

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
LOG_DIR="$PETIT_DATA_DIR/logs"
mkdir -p "$LOG_DIR" "$PETIT_DATA_DIR/characters"

echo "[entrypoint] $(date -Iseconds) 起動開始 (CHARACTER_IDS=${CHARACTER_IDS:-未設定})"

# --- 0. ぷちごとの MCP 設定(記憶 MCP・SNS-MCP)を作る(K14) ---
# 秘密は書かない(scripts/gen-mcp-config.sh の冒頭)。失敗しても起動は続ける。
/opt/petit/scripts/gen-mcp-config.sh || echo "[entrypoint] 警告: MCP 設定の生成に失敗" >&2

# --- 1. supercronic (cron) ---
if [ -f /opt/petit/cron/petit.cron ]; then
  supercronic /opt/petit/cron/petit.cron >> "$LOG_DIR/supercronic.log" 2>&1 &
  echo "[entrypoint] supercronic 起動 (log: $LOG_DIR/supercronic.log)"
else
  echo "[entrypoint] 警告: /opt/petit/cron/petit.cron が見つからない。cronはスキップ" >&2
fi

# --- 2. 家 API (m5-petit-app, FastAPI :8765) ---
# petit-infra の Caddy が /house/* と /public/* をここ(petit-mio:8765)へ向ける。
# クラウド版 SPA (TeamPuchi/petit-app) とは別物。詳細は scripts/sync-repos.sh のコメント。
# 存在チェックはディレクトリではなく main.py で行う。イメージ側に .venv を先に掘ってある
# (Dockerfile.core・T3 の匿名ボリューム用)ので、未同期でもディレクトリ自体は必ず存在するため。
#
# 落ちたら起こし直す(K14)。起動時に設定不足で落ちる(例: PETIT_AUTH_MODE=gateway なのに
# PETIT_GATEWAY_SECRET が無い)場合も、コンテナごと落とさずログに理由を残して待ち、間隔を倍々に延ばす。
# 出力は docker compose logs でも見えるよう、ログファイルと標準出力の両方へ出す。
DASHBOARD_DIR="/opt/petit/repos/m5-petit-app"
if [ -f "$DASHBOARD_DIR/main.py" ]; then
  if [ -x "$DASHBOARD_DIR/.venv/bin/python" ]; then
    DASHBOARD_CMD=("$DASHBOARD_DIR/.venv/bin/python" main.py)   # 焼き込み済み(release)
  else
    DASHBOARD_CMD=(uv run python main.py)                       # dev(バインドマウント)
  fi
  (
    cd "$DASHBOARD_DIR" || exit 1
    delay=5
    while true; do
      started=$(date +%s)
      echo "[house-api] $(date -Iseconds) 起動: ${DASHBOARD_CMD[*]} (port ${PORT:-8765})"
      "${DASHBOARD_CMD[@]}" 2>&1
      code=$?
      # 1分以上動いていたなら、間隔を最初に戻す
      [ $(( $(date +%s) - started )) -ge 60 ] && delay=5
      echo "[house-api] $(date -Iseconds) 終了 (exit=$code)。${delay}秒後に起こし直す"
      sleep "$delay"
      delay=$(( delay * 2 > 300 ? 300 : delay * 2 ))
    done
  ) 2>&1 | tee -a "$LOG_DIR/dashboard.log" &
  echo "[entrypoint] 家 API 起動 (log: $LOG_DIR/dashboard.log, port: ${PORT:-8765})"
else
  echo "[entrypoint] 警告: $DASHBOARD_DIR/main.py が見つからない(焼き込み・sync-repos 未実行?)。家 API はスキップ" >&2
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
# exec tail にすると、このシェルが起こした子(体験デーモン見張り等)が終わっても tail が
# 回収せずゾンビとして残る(K14 で確認)。bash のまま待てば bash が回収する。
# SIGTERM/SIGINT は tini(PID 1)からこの bash に届き、docker compose down / stop で正常終了する。
sleep infinity &
wait $!
