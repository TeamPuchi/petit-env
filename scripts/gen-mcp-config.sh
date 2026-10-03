#!/usr/bin/env bash
# claude CLI に渡す MCP 設定（記憶 MCP・SNS-MCP・欲求 MCP・家の道具 MCP）を CHARACTER_IDS のぷちごとに作る（K14）。
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
#
# 家の道具（house。家 API＝m5-petit-app の house_mcp.py があるときだけ載せる・2026-09-27）:
#   ぷちが自分のノート（NOTE#）と手紙（MAIL#）を読み書きする道具（note_* / mail_*）。
#   ここで渡すのは PETIT_ID・PETIT_DATA_DIR だけ。家の表・鍵の表・KMS・リージョンは
#   コンテナの env（家 API と同じ PETIT_HOUSE_TABLE など）をそのまま読む。
#
# 道具の説明を最初から載せる（W12・2026-09-30 → 2026-10-03 一覧を1か所に）:
#   claude は MCP の道具が多いと説明を最初には載せず、要るときに ToolSearch で探す（1 往復増える）。
#   - 道具ごと: 一覧は scripts/preload-tools.txt（mcp__<サーバー>__<道具> を1行に1つ。選び方もそこに）。
#     ここでサーバーごとに分けて、各サーバーの env の PETIT_PRELOAD_TOOLS（道具の名前のカンマ区切り）に入れ、
#     サーバー（house_mcp.py・petit-memory・petit-sns・petit-desire）が `_meta` の anthropic/alwaysLoad を付ける。
#     コンテナの env PETIT_PRELOAD_TOOLS（同じ書き方・カンマ区切り）があればファイルの代わりにそれ（空なら何も載せない）。
#     道具が1つも無いサーバーにも空で入れる（コンテナの env の同じ名前を MCP サーバーが引き継がないように）。
#     どのサーバーにも当たらない名前（組み込みの道具・載せていないサーバー）は標準エラーで知らせる。
#     名前が実在するか・印が付いたかは check-preload-tools.py が本番の設定で確かめる。
#   - サーバーごと（PETIT_MCP_ALWAYS_LOAD）: カンマ区切りで書いたサーバーには "alwaysLoad": true を付け、
#     道具の説明を毎回ぜんぶ載せる。既定は空（W12 の既定 desire-system は、欲求の道具 5 つで約 5,400 トークン。
#     使うのは satisfy_desire がほとんどなので、2026-10-03 から道具ごとの一覧に入れた）。
#   本番の claude 2.1.285・haiku で測った重さ（全部載せたとき）: house 33 個 約 3.3 万・memory 24 個 約 8,300・
#   petit-sns 14 個 約 8,000・desire-system 5 個 約 5,400 トークン。
set -euo pipefail

PETIT_DATA_DIR="${PETIT_DATA_DIR:-/data}"
REPOS_DIR="${PETIT_REPOS_DIR:-/opt/petit/repos}"
OUT_DIR="${PETIT_MCP_DIR:-/opt/petit/run/mcp}"
PRELOAD_FILE="${PETIT_PRELOAD_TOOLS_FILE:-$(dirname "$0")/preload-tools.txt}"

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

# 最初から載せる道具の一覧を JSON の配列で出す（env PETIT_PRELOAD_TOOLS があればそれ、無ければファイル）
preload_json() {
  if [[ -n "${PETIT_PRELOAD_TOOLS+x}" ]]; then
    tr ',' '\n' <<< "$PETIT_PRELOAD_TOOLS"
  elif [[ -f "$PRELOAD_FILE" ]]; then
    sed 's/#.*//' "$PRELOAD_FILE"
  fi | tr -d ' \t\r' | jq -R -s 'split("\n") | map(select(. != ""))'
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

  # 家の道具 MCP（家 API に house_mcp.py がある版のときだけ）
  local house="null"
  if [[ -f "$REPOS_DIR/m5-petit-app/house_mcp.py" ]]; then
    house="$(server_cmd "$REPOS_DIR/m5-petit-app" petit-house-mcp | jq \
      --arg id "$id" --arg data "$PETIT_DATA_DIR" '
      .env = {PETIT_ID: $id, PETIT_DATA_DIR: $data}')"
  fi

  local preload
  preload="$(preload_json)"

  mkdir -p "$OUT_DIR" "$PETIT_DATA_DIR/sns/$id"
  jq -n --argjson m "$memory" --argjson s "$sns" --argjson d "$desire" --argjson h "$house" \
    --arg always "${PETIT_MCP_ALWAYS_LOAD-}" --argjson pl "$preload" '
    ($always | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != ""))) as $al
    | {mcpServers: ({memory: $m, "petit-sns": $s}
                    + (if $d != null then {"desire-system": $d} else {} end)
                    + (if $h != null then {house: $h} else {} end))}
    | .mcpServers |= with_entries(if (.key | IN($al[])) then .value.alwaysLoad = true else . end)
    | .mcpServers |= with_entries(
        ("mcp__" + .key + "__") as $p
        | ([$pl[] | select(startswith($p)) | ltrimstr($p)] | join(",")) as $t
        | .value.env.PETIT_PRELOAD_TOOLS = $t)' \
    > "$OUT_DIR/$id.json.tmp"
  # どのサーバーにも当たらない名前（組み込みの道具・ここで載せていないサーバー・書き間違い）を知らせる
  jq -r --argjson pl "$preload" '[.mcpServers | keys[] | "mcp__" + . + "__"] as $ps
    | $pl[] | select(. as $n | [$ps[] | . as $p | $n | startswith($p)] | any | not)' "$OUT_DIR/$id.json.tmp" \
    | while read -r n; do echo "[gen-mcp-config] 警告: 最初から載せる一覧の $n はどの MCP サーバーにも当たらない（載せない）" >&2; done
  mv "$OUT_DIR/$id.json.tmp" "$OUT_DIR/$id.json"
  echo "[gen-mcp-config] $OUT_DIR/$id.json (memory=$store${table:+:$table} desire=$([[ "$desire" != null ]] && echo on || echo off) house=$([[ "$house" != null ]] && echo on || echo off))"
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
