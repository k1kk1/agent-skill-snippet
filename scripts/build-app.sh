#!/bin/bash
# AgentRecipes.app を組み立てる。
# SwiftPM の実行ファイルだけでは LSUIElement / Bundle ID が付かないため、
# ここで .app を作り、ad-hoc 署名する (Launch at Login は bundle が前提)。
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="AgentRecipes"
# 実行ファイル名は CLI (agentrecipes) と大文字小文字だけの差にならないよう別名にする。
# 大文字小文字を区別しないファイルシステムで .build 内が衝突するため。
EXEC_NAME="AgentRecipesApp"
BUILD_DIR=".build/${CONFIG}"
APP_DIR="build/${APP_NAME}.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}" --product "${EXEC_NAME}"
swift build -c "${CONFIG}" --product agentrecipes

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BUILD_DIR}/${EXEC_NAME}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"
cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "${APP_DIR}"

echo "==> done"
echo "  app: ${APP_DIR}"
echo "  cli: ${BUILD_DIR}/agentrecipes"
echo
echo "起動:        open ${APP_DIR}"
echo "CLI を配置:  cp ${BUILD_DIR}/agentrecipes /usr/local/bin/agentrecipes"
