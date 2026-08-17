#!/bin/bash
# 最新のソースを取得して .app を作り直し、/Applications のアプリを差し替える。
#
#   ./scripts/update.sh                 # GitHub の main を取得して更新
#   ./scripts/update.sh --ref v0.3.0    # タグ / ブランチを指定
#   ./scripts/update.sh --zip ~/dl.zip  # 手元の ZIP から更新 (ネットワーク制限がある環境用)
#   ./scripts/update.sh --local         # このリポジトリのまま作り直すだけ
#
# git は不要。ZIP を展開してビルドするだけなので、社用 PC でも同じ手順で使える。
set -euo pipefail

REPO="${AGENTRECIPES_REPO:-k1kk1/agent-skill-snippet}"
REF="main"
ZIP=""
LOCAL=false
INSTALL_DIR="${AGENTRECIPES_INSTALL_DIR:-/Applications}"
CLI_DIR="${AGENTRECIPES_CLI_DIR:-}"
APP_NAME="AgentRecipes"

while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF="$2"; shift 2 ;;
        --zip) ZIP="$2"; shift 2 ;;
        --local) LOCAL=true; shift ;;
        --install-cli) CLI_DIR="${2:-/usr/local/bin}"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "不明な引数: $1" >&2; exit 1 ;;
    esac
done

say() { printf '==> %s\n' "$1"; }

if [ "$LOCAL" = true ]; then
    SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    say "ローカルのソースを使用: ${SOURCE_DIR}"
else
    WORK="$(mktemp -d)"
    trap 'rm -rf "${WORK}"' EXIT
    if [ -n "${ZIP}" ]; then
        say "ZIP を展開: ${ZIP}"
        cp "${ZIP}" "${WORK}/source.zip"
    else
        URL="https://codeload.github.com/${REPO}/zip/refs/heads/${REF}"
        say "ダウンロード: ${URL}"
        # ブランチで見つからなければタグとして取り直す。
        curl -fsSL "${URL}" -o "${WORK}/source.zip" \
            || curl -fsSL "https://codeload.github.com/${REPO}/zip/refs/tags/${REF}" -o "${WORK}/source.zip"
    fi
    unzip -q "${WORK}/source.zip" -d "${WORK}/src"
    SOURCE_DIR="$(find "${WORK}/src" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "${SOURCE_DIR}" ] || { echo "ZIP の中身が想定と違います" >&2; exit 1; }
fi

cd "${SOURCE_DIR}"

say "テスト"
swift test

say "ビルド"
./scripts/build-app.sh release

TARGET="${INSTALL_DIR}/${APP_NAME}.app"
RUNNING=false
if pgrep -x "${APP_NAME}App" >/dev/null 2>&1; then
    RUNNING=true
    say "起動中のアプリを終了"
    pkill -x "${APP_NAME}App" || true
    sleep 1
fi

say "差し替え: ${TARGET}"
rm -rf "${TARGET}"
cp -R "build/${APP_NAME}.app" "${TARGET}"
# ダウンロードした ZIP 由来の隔離属性が残ると Gatekeeper に止められる。
xattr -dr com.apple.quarantine "${TARGET}" 2>/dev/null || true

if [ -n "${CLI_DIR}" ]; then
    say "CLI を配置: ${CLI_DIR}/agentrecipes"
    cp .build/release/agentrecipes "${CLI_DIR}/agentrecipes"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'print :CFBundleShortVersionString' "${TARGET}/Contents/Info.plist" 2>/dev/null || echo unknown)"
say "更新しました (version ${VERSION})"

if [ "${RUNNING}" = true ]; then
    open -a "${TARGET}"
    say "アプリを再起動しました"
else
    echo "起動: open -a \"${TARGET}\""
fi
