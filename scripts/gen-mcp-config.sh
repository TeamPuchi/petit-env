#!/usr/bin/env bash
# claude CLI に渡す MCP 設定（記憶 MCP・SNS-MCP・欲求 MCP）を CHARACTER_IDS のぷちごとに作る（K14）。
#
#   gen-mcp-config.sh            → $PETIT_MCP_DIR/<id>.json を CHARACTER_IDS 全員ぶん書く
#   gen-mcp-config.sh <id>       → そのぷちの分だけ書く
#
# entrypoint.sh が起動のたびに呼ぶ（置き場はイメージ内の /opt/petit/run/mcp。/data には置かない
# ＝版を上げたら作り直される）。autonomous-action.sh はここを --mcp-config に渡す。
#
# 🔴 秘密（PETIT_SNS_INTERNAL_SECRET・ANTHROPIC_API_KEY・AWS の認証情報）はこのファイルに書かない。
#    claude は MCP サーバーを自分の環境変数を引き継いで起動するので、コンテナの env
#    （petit-infra の petit-mio.env・compose の environment:）からそのまま届く。
#    ここの "env" に書くのは「ぷちごとに変わる、秘密でない値」だけ。
#
# 記憶の置き場:
#   PETIT_MEMORY_STORE が空なら、PETIT_HOUSE_TABLE があれば dynamo（家の表・pk は P#<pid>）、
#   無ければ sqlite（/data/characters/<id>/memory.db。手元・dev 用）。
#   表名は PETIT_MEMORY_DYNAMO_TABLE、無ければ PETIT_HOUSE_TABLE。
#   PETIT_MEMORY_HOUSE_ID は渡さない（空＝ pk が P#<pid>。アカウント根・2026-09-23）。
#
# 欲求（desire-system。petit-desire があるときだけ載せる・2026-09-26）:
#   PETIT_HOUSE_TABLE があれば家の表の STATE#DESIRES、無ければ /data/characters/<id>/data/desires.json。
#   ここで渡すのは CHARACTER_ID・記憶の置き場（記憶 MCP と同じ値）・boto3 のリージョンだけ。
#   鍵の表・KMS・SNS の URL と秘密はコンテナの env をそのまま読む（petit-desire petit_desire/service.py の表）。
#   run-for-each-character.sh の desire（5 分ごとの更新）もこの env を使う（置き場の決め方を1か所に）。
set -euo pipefail

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
REPOS_DIR="${PETIT_REPOS_DIR:-/opt/petit/repos}"
OUT_DIR="${PETIT_MCP_DIR:-/opt/petit/run/mcp}"

command -v jq >/dev/null 2>&1 || { echo "[gen-mcp-config] jq が無い" >&2; exit 1; }

# venv が焼き込まれていればその実行ファイルを直接使う（uv run だと起動のたびに同期を確かめ、
# petit-memory は lock どおりの CUDA 版 torch を入れ直そうとするため）。無ければ uv run（dev）。
server_cmd() {
  local dir="$1" exe="$2"
  if [[ -x "$dir/.venv/bin/$exe" ]]; then
    jq -n --arg c "$dir/.venv/bin/$exe" '{command: $c, args: []}'
  else
    jq -n --arg d "$dir" --arg e "$exe" '{command: "uv", args: ["run", "--directory", $d, $e]}'
  fi
}

memory_store() {
  if [[ -n "${PETIT_MEMORY_STORE:-}" ]]; then echo "$PETIT_MEMORY_STORE"
  elif [[ -n "${PETIT_HOUSE_TABLE:-}" ]]; then echo dynamo
  else echo sqlite
  fi
}

gen_one() {
  local id="$1"
  [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "[gen-mcp-config] id が変: $id" >&2; return 1; }

  local store table region
  store="$(memory_store)"
  table="${PETIT_MEMORY_DYNAMO_TABLE:-${PETIT_HOUSE_TABLE:-}}"
  # petit-memory の boto3 は AWS_REGION を読まず AWS_DEFAULT_REGION だけを見る（K14 で NoRegionError を確認）。
  # petit-infra の petit-mio.env は AWS_REGION だけを渡すので、ここで写す。
  region="${AWS_DEFAULT_REGION:-${AWS_REGION:-}}"

  local memory sns
  memory="$(server_cmd "$REPOS_DIR/petit-memory" memory-mcp | jq \
    --arg store "$store" --arg table "$table" --arg region "$region" --arg id "$id" \
    --arg db "$PETIT_DATA_DIR/characters/$id/memory.db" '
    .env = ({PETIT_MEMORY_STORE: $store, PETIT_MEMORY_PETIT_ID: $id, MEMORY_DB_PATH: $db}
            + (if $table != "" then {PETIT_MEMORY_DYNAMO_TABLE: $table} else {} end)
            + (if $region != "" then {AWS_DEFAULT_REGION: $region} else {} end))')"
  sns="$(server_cmd "$REPOS_DIR/petit-sns" petit-sns-mcp | jq \
    --arg id "$id" --arg url "${PETIT_SNS_URL:-http://sns-api:8780}" \
    --arg state "$PETIT_DATA_DIR/sns/$id" '
    .env = {PETIT_ID: $id, PETIT_SNS_URL: $url, PETIT_SNS_STATE_DIR: $state}')"

  # 欲求 MCP（petit-desire が焼き込まれている／dev でマウントされているときだけ）。
  # 記憶の置き場は記憶 MCP と同じ値を渡す（どの記憶を見て「満たされた」と数えるかを揃える）
  local desire="null"
  if [[ -f "$REPOS_DIR/petit-desire/pyproject.toml" ]]; then
    desire="$(server_cmd "$REPOS_DIR/petit-desire" desire-system | jq \
      --arg store "$store" --arg table "$table" --arg region "$region" --arg id "$id" \
      --arg data "$PETIT_DATA_DIR" --arg db "$PETIT_DATA_DIR/characters/$id/memory.db" '
      .env = ({CHARACTER_ID: $id, PETIT_DATA_DIR: $data, PETIT_MEMORY_STORE: $store, MEMORY_DB_PATH: $db}
              + (if $table != "" then {PETIT_MEMORY_DYNAMO_TABLE: $table} else {} end)
              + (if $region != "" then {AWS_DEFAULT_REGION: $region} else {} end))')"
  fi

  mkdir -p "$OUT_DIR" "$PETIT_DATA_DIR/sns/$id"
  jq -n --argjson m "$memory" --argjson s "$sns" --argjson d "$desire" \
    '{mcpServers: ({memory: $m, "petit-sns": $s} + (if $d != null then {"desire-system": $d} else {} end))}' \
    > "$OUT_DIR/$id.json.tmp"
  mv "$OUT_DIR/$id.json.tmp" "$OUT_DIR/$id.json"
  echo "[gen-mcp-config] $OUT_DIR/$id.json (memory=$store${table:+:$table} desire=$([[ "$desire" != null ]] && echo on || echo off))"
}

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
(( n > 0 )) || echo "[gen-mcp-config] CHARACTER_IDS が未設定。何も作らない" >&2
