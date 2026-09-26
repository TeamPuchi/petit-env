#!/usr/bin/env bash
# Dockerfile.core の build 中に呼ばれ、焼き込んだコンポーネントの venv を作る（K14・TODO T4）。
# 実行時に uv sync（ネットワーク・書き込み）が走らないよう、ここで全部済ませる。
#
#   install-components.sh <repos ディレクトリ> <必須か 1|0>
#
# 必須（1・release の既定）なのに vendor/ が空なら build を落とす。
# 「build は通ったが中身が空」を二度と作らないため（T1 と同じ教訓）。
set -euo pipefail

REPOS_DIR="${1:?repos dir}"
REQUIRE="${2:-1}"
REQUIRED_COMPONENTS=(m5-petit-app petit-memory petit-sns petit-desire)

export UV_PYTHON=python3          # ubuntu 24.04 の python3.12 を使う（別の Python を落としてこない）
export UV_PYTHON_DOWNLOADS=never
export UV_LINK_MODE=copy
export UV_NO_CACHE=1              # イメージに uv のキャッシュを残さない

has() { [[ -f "$REPOS_DIR/$1/pyproject.toml" ]]; }

missing=()
for c in "${REQUIRED_COMPONENTS[@]}"; do has "$c" || missing+=("$c"); done
if (( ${#missing[@]} > 0 )); then
  if [[ "$REQUIRE" == "1" ]]; then
    echo "[install-components] vendor/ に無い: ${missing[*]}" >&2
    echo "  先に ./scripts/vendor-components.sh を実行する（dev で空のまま build するなら --build-arg PETIT_REQUIRE_COMPONENTS=0）" >&2
    exit 1
  fi
  echo "[install-components] 焼き込み無し（PETIT_REQUIRE_COMPONENTS=0）: ${missing[*]}"
fi

# ---- m5-petit-app（家 API）------------------------------------------------
if has m5-petit-app; then
  echo "[install-components] m5-petit-app"
  (cd "$REPOS_DIR/m5-petit-app" && uv sync --frozen --no-dev)
fi

# ---- petit-sns の sns-api/（SNS-MCP だけ使う）-------------------------------
if has petit-sns; then
  echo "[install-components] petit-sns (SNS-MCP)"
  (cd "$REPOS_DIR/petit-sns" && uv sync --frozen --no-dev --extra mcp)
fi

# ---- petit-desire（欲求エンジン・欲求 MCP。2026-09-26）----------------------
# desire-updater（5 分ごと）・desire-system（MCP）・desire-status（自律行動のプロンプト）の3つ。
if has petit-desire; then
  echo "[install-components] petit-desire"
  (cd "$REPOS_DIR/petit-desire" && uv sync --frozen --no-dev)
  "$REPOS_DIR/petit-desire/.venv/bin/python" -c "import petit_desire.server, petit_desire.cli; print('petit-desire ok')"
fi

# ---- petit-memory（記憶 MCP）----------------------------------------------
# uv.lock の torch は Linux では CUDA 版（nvidia-*・cuda-*・triton で数 GB）を引く。
# EC2 ホスト（t4g・GPU 無し）では使わないので、版は lock のまま CPU 版の wheel に差し替える。
# 他の依存は lock の版をそのまま（uv export）。
if has petit-memory; then
  echo "[install-components] petit-memory (CPU 版 torch)"
  cd "$REPOS_DIR/petit-memory"
  req="$(mktemp)"
  uv export --frozen --no-dev --extra dynamo --no-hashes --no-emit-project --format requirements-txt -o "$req" >/dev/null
  torch_ver="$(sed -n 's/^torch==\([^ ;]*\).*/\1/p' "$req" | head -n1)"
  [[ -n "$torch_ver" ]] || { echo "[install-components] uv.lock に torch が無い" >&2; exit 1; }
  grep -v -E '^(torch|triton|nvidia-|cuda-)' "$req" > "$req.cpu"
  uv venv -q .venv
  uv pip install -q --python .venv/bin/python --no-deps \
    --index-url https://download.pytorch.org/whl/cpu "torch==${torch_ver}"
  uv pip install -q --python .venv/bin/python --no-deps -r "$req.cpu"
  uv pip install -q --python .venv/bin/python --no-deps .
  rm -f "$req" "$req.cpu"
  # 依存の抜け（CUDA 系を外したことで壊れていないか）を build の時点で確かめる
  .venv/bin/python -c "import torch, sentence_transformers, memory_mcp.server; print('torch', torch.__version__)"
  cd - >/dev/null
fi

# どの版が入ったか（vendor-components.sh が書いた印）をまとめる
cat "$REPOS_DIR"/*/.petit-component 2>/dev/null > /opt/petit/components.txt || true
echo "[install-components] 完了"; cat /opt/petit/components.txt 2>/dev/null || true
