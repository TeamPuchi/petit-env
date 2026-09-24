#!/usr/bin/env bash
# ぷちコンテナ（petit-core）に焼き込むコンポーネントを vendor/ に展開する（K14・TODO T4）。
#
#   ./scripts/vendor-components.sh
#       components.lock の各行について、そのリポの「固定した SHA」を vendor/<名前>/ に展開する。
#       この後 `docker build -f Dockerfile.core .` で焼き込める（手元・CI 用）。
#   ./scripts/vendor-components.sh --bundle <出力ディレクトリ>
#       上に加えて、「petit-env の HEAD ＋ vendor/」を1つの git リポ（コミット1つ）にまとめる。
#       petit-infra の `house-compose-deploy.sh upload-src <出力ディレクトリ> petit-core` が
#       そのまま束ねられる形（upload-src は HEAD を git archive するため、vendor/ を
#       コミットに含める必要がある）。 EC2 ホストに GitHub の鍵を置かずに済む。
#
# 取り込み方式（2026-09-24 決定）: build 時に EC2 ホストから git clone するのではなく、
# GitHub に触れる手元（社長 PC）で固定 SHA を取り出し、build context に入れて渡す。
# 理由: m5-petit-app・petit-sns は private で、 EC2 ホストに読み取りトークンを置かない方針
# （petit-infra README §9.11）。SSM send-command でトークンを渡すと実行履歴に残る。
#
# 認証は手元の git に任せる（Git Credential Manager・gh auth 等）。このスクリプトは秘密を扱わない。
# 取得元は PETIT_GIT_BASE で差し替えられる（既定 https://github.com/。SSH なら git@github.com:）。
#
# 🔴 vendor/ と出力ディレクトリは git に入れない（.gitignore 済み）。petit-env は public、
#    m5-petit-app・petit-sns は private なので、コミットすると中身が漏れる。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/components.lock"
VENDOR_DIR="$ROOT_DIR/vendor"
CACHE_DIR="${PETIT_COMPONENT_CACHE:-$ROOT_DIR/.cache/components}"
GIT_BASE="${PETIT_GIT_BASE:-https://github.com/}"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

BUNDLE_DIR=""
case "${1:-}" in
  "") ;;
  --bundle)
    BUNDLE_DIR="${2:-}"
    [[ -n "$BUNDLE_DIR" ]] || die "使い方: $0 --bundle <出力ディレクトリ>"
    ;;
  *) die "使い方: $0 [--bundle <出力ディレクトリ>]" ;;
esac

command -v git >/dev/null 2>&1 || die "git が無い"
command -v tar >/dev/null 2>&1 || die "tar が無い"
[[ -f "$LOCK_FILE" ]] || die "components.lock が無い: $LOCK_FILE"

mkdir -p "$VENDOR_DIR" "$CACHE_DIR"

# Windows（core.autocrlf=true）でも LF のまま取り出す（petit-infra README の git archive の罠と同じ）
GIT=(git -c core.autocrlf=false -c core.eol=lf)

while read -r name repo sha subdir _rest; do
  [[ -z "${name:-}" || "$name" == \#* ]] && continue
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || die "名前が変: $name"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "$name: SHA は 40 桁で固定する（ブランチ名・短縮は不可）: $sha"
  subdir="${subdir:-.}"

  log "$name ← $repo@${sha:0:7} (${subdir})"
  cache="$CACHE_DIR/$name.git"
  if [[ ! -d "$cache" ]]; then
    "${GIT[@]}" init -q --bare "$cache"
  fi
  "${GIT[@]}" -C "$cache" remote remove origin 2>/dev/null || true
  "${GIT[@]}" -C "$cache" remote add origin "${GIT_BASE}${repo}.git"
  # GitHub は SHA を直接 fetch できる。既に持っていれば取りに行かない
  if ! "${GIT[@]}" -C "$cache" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    "${GIT[@]}" -C "$cache" fetch -q --depth 1 origin "$sha"
  fi

  treeish="$sha"
  [[ "$subdir" != "." ]] && treeish="${sha}:${subdir}"
  rm -rf "${VENDOR_DIR:?}/$name"
  mkdir -p "$VENDOR_DIR/$name"
  "${GIT[@]}" -C "$cache" archive --format=tar "$treeish" | tar -x -C "$VENDOR_DIR/$name"
  # イメージの中から「どの版が入っているか」を見られるようにする（/opt/petit/components.txt）
  printf '%s %s %s %s\n' "$name" "$repo" "$sha" "$subdir" > "$VENDOR_DIR/$name/.petit-component"
done < "$LOCK_FILE"

log "vendor/ の中身"
ls -1 "$VENDOR_DIR"

if [[ -z "$BUNDLE_DIR" ]]; then
  exit 0
fi

# ---- EC2 ホストへ渡す束（petit-env の HEAD ＋ vendor/）------------------------
if [[ -n "$("${GIT[@]}" -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]]; then
  printf '\033[33m[warn]\033[0m petit-env に未コミットの変更がある。束に入るのは HEAD の内容だけ\n' >&2
fi

log "束を作る: $BUNDLE_DIR"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
"${GIT[@]}" -C "$ROOT_DIR" archive --format=tar HEAD | tar -x -C "$BUNDLE_DIR"
rm -rf "$BUNDLE_DIR/vendor"
cp -R "$VENDOR_DIR" "$BUNDLE_DIR/vendor"

rev="$("${GIT[@]}" -C "$ROOT_DIR" rev-parse --short HEAD)"
"${GIT[@]}" -C "$BUNDLE_DIR" init -q
"${GIT[@]}" -C "$BUNDLE_DIR" config core.autocrlf false
# vendor/ は petit-env の .gitignore で除外されているので、束の中では無効にする
rm -f "$BUNDLE_DIR/.gitignore"
"${GIT[@]}" -C "$BUNDLE_DIR" add -A
"${GIT[@]}" -C "$BUNDLE_DIR" -c user.name=petit-env -c user.email=petit-env@localhost \
  commit -q -m "petit-core build context: petit-env@${rev} + components.lock"

cat <<EOS

  束ができた（petit-env@${rev}＋components.lock の版）。petit-infra から EC2 ホストへ渡す:

    ./scripts/house-compose-deploy.sh upload-src ${BUNDLE_DIR} petit-core
    ./scripts/house-compose-deploy.sh build <上で出た S3 URI> petit-core:latest . Dockerfile.core

EOS
