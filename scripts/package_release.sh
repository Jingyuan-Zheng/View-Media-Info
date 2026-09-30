#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_DIR="${PROJECT_DIR}/release"
WORKFLOW_TEMPLATE="${PROJECT_DIR}/Workflow/View Media Data.workflow"
ARCHIVE_PATH="${PROJECT_DIR}/build/View Media Info.app.zip"
DMG_MAKER_DIR="${DMG_MAKER_DIR:-${PROJECT_DIR:h}/Dmg Maker}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_DIR}/Info.plist")"
STAGING_DIR="$(mktemp -d /tmp/view-media-info-release.XXXXXX)"
APP_DIR="${STAGING_DIR}/View Media Info.app"
WORKFLOW_DIR="${STAGING_DIR}/View Media Data.workflow"

trap 'rm -rf "${STAGING_DIR}"' EXIT

[[ -d "${WORKFLOW_TEMPLATE}" ]] || { print -u2 "Missing workflow template: ${WORKFLOW_TEMPLATE}"; exit 1; }
[[ -x "${DMG_MAKER_DIR}/dmg.sh" ]] || { print -u2 "Missing Dmg Maker script: ${DMG_MAKER_DIR}/dmg.sh"; exit 1; }

"${PROJECT_DIR}/build_app.sh"
mkdir -p "${OUTPUT_DIR}"
ditto -x -k "${ARCHIVE_PATH}" "${STAGING_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

ditto "${WORKFLOW_TEMPLATE}" "${WORKFLOW_DIR}"
mkdir -p "${WORKFLOW_DIR}/Contents/Resources"
ditto "${APP_DIR}" "${WORKFLOW_DIR}/Contents/Resources/View Media Info.app"
rm -f "${OUTPUT_DIR}/View Media Data Quick Action-${VERSION}.zip"
(
    cd "${STAGING_DIR}"
    /usr/bin/zip -r -X "${OUTPUT_DIR}/View Media Data Quick Action-${VERSION}.zip" "View Media Data.workflow" -x '*/._*'
)

(
    cd "${DMG_MAKER_DIR}"
    "${DMG_MAKER_DIR}/dmg.sh" "${APP_DIR}" "${DMG_MAKER_DIR}/Background.png"
    mv "${DMG_MAKER_DIR}/View Media Info.dmg" "${OUTPUT_DIR}/Media Information-${VERSION}.dmg"
)

print "Created release assets in ${OUTPUT_DIR}"
