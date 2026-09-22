#!/usr/bin/env bash
# 各コンポーネントリポジトリを repos/ に clone / pull する。
#
# TeamPuchi の fork は m5- 接頭辞を落とした名前(petit-mcp 等)だが、
# repos/ 配下のディレクトリ名はコンテナ内パスとして compose・autonomous-mcp.json・
# 各スクリプトから参照される。そのため sync_repo は
#   <配置先ディレクトリ名> <owner/repo> <ブランチ>
# の3引数を取り、「リポジトリ名」と「ディレクトリ名」を分離する。
# 音声系は TeamPuchi に fork が無いため上流(PetitOnes)を指したままにしている。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_DIR="$ROOT_DIR/repos"
GITHUB_BASE="${GITHUB_BASE:-https://github.com}"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi

mkdir -p "$REPOS_DIR"

sync_repo() {
  local dir="$1" slug="$2" branch="$3"
  local url="$GITHUB_BASE/$slug.git"
  local path="$REPOS_DIR/$dir"

  if [ -d "$path/.git" ]; then
    echo "Updating $dir <- $slug ($branch)..."
    git -C "$path" fetch origin "$branch"
    git -C "$path" checkout "$branch"
    git -C "$path" pull --ff-only origin "$branch"
  else
    echo "Cloning $dir <- $slug ($branch)..."
    git clone --branch "$branch" "$url" "$path"
  fi

  if [ -f "$path/pyproject.toml" ] && command -v uv >/dev/null 2>&1; then
    echo "uv sync: $dir"
    (cd "$path" && uv sync) || echo "警告: $dir の uv sync に失敗(後で確認してください)" >&2
  fi
}

sync_repo "petit-mcp"     "TeamPuchi/petit-mcp"     "${PETIT_MCP_BRANCH:-main}"
# TODO(なぎ確認): ダッシュボードの正本は TeamPuchi/m5-petit-app か TeamPuchi/petit-app か。
# 上流と同名の m5-petit-app を暫定採用している。差し替えるならこの1行だけ変える。
sync_repo "petit-app"     "TeamPuchi/m5-petit-app"  "${PETIT_APP_BRANCH:-main}"
sync_repo "petit-memory"  "TeamPuchi/petit-memory"  "${PETIT_MEMORY_BRANCH:-main}"
sync_repo "petit-desire"  "TeamPuchi/petit-desire"  "${PETIT_DESIRE_BRANCH:-main}"
sync_repo "petit-scripts" "TeamPuchi/petit-scripts" "${PETIT_SCRIPTS_BRANCH:-main}"

# 音声(TTS/ASR)はオプション。WITH_SPEECH=1のときだけ取得する(GPUプロファイル用)。
# TeamPuchi に fork が無いため上流を指している。fork したらここを差し替える。
if [ "${WITH_SPEECH:-0}" = "1" ]; then
  sync_repo "petit-speech"            "PetitOnes/m5-petit-speech"            "${PETIT_SPEECH_BRANCH:-main}"
  sync_repo "petit-voice-recognition" "PetitOnes/m5-petit-voice-recognition" "${PETIT_VOICE_RECOGNITION_BRANCH:-main}"
fi

echo "sync-repos.sh 完了"
