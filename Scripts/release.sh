#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

source "$ROOT/version.env"
source "$HOME/Projects/agent-scripts/release/sparkle_lib.sh"

APPCAST="$ROOT/appcast.xml"
APP_NAME="CodexBar"
ARTIFACT_PREFIX="CodexBar-"
BUNDLE_ID="com.steipete.codexbar"
TAG="v${MARKETING_VERSION}"
SPARKLE_TEMP_KEY_FILE=""
KEY_FILE=""
NOTES_FILE=""

err() { echo "ERROR: $*" >&2; exit 1; }

if [[ -z "${SPARKLE_PRIVATE_KEY_FILE:-}" && -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  SPARKLE_TEMP_KEY_FILE=$(mktemp /tmp/codexbar-sparkle-key.XXXXXX)
  printf "%s" "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_TEMP_KEY_FILE"
  SPARKLE_PRIVATE_KEY_FILE="$SPARKLE_TEMP_KEY_FILE"
  export SPARKLE_PRIVATE_KEY_FILE
fi

trap 'rm -f "$KEY_FILE" "$NOTES_FILE" "$SPARKLE_TEMP_KEY_FILE"' EXIT

require_clean_worktree
ensure_changelog_finalized "$MARKETING_VERSION"
ensure_appcast_monotonic "$APPCAST" "$MARKETING_VERSION" "$BUILD_NUMBER"

swiftformat Sources Tests >/dev/null
swiftlint --strict
swift test

# Note: run this script in the foreground; do not background it so it waits to completion.
"$ROOT/Scripts/sign-and-notarize.sh"

KEY_FILE=$(clean_key "$SPARKLE_PRIVATE_KEY_FILE")

probe_sparkle_key "$KEY_FILE"

clear_sparkle_caches "$BUNDLE_ID"

NOTES_FILE=$(mktemp /tmp/codexbar-notes.XXXXXX.md)
extract_notes_from_changelog "$MARKETING_VERSION" "$NOTES_FILE"

git tag -f "$TAG"
git push -f origin "$TAG"

gh release create "$TAG" ${APP_NAME}-${MARKETING_VERSION}.zip ${APP_NAME}-${MARKETING_VERSION}.dSYM.zip \
  --title "${APP_NAME} ${MARKETING_VERSION}" \
  --notes-file "$NOTES_FILE"

SPARKLE_PRIVATE_KEY_FILE="$KEY_FILE" \
  "$ROOT/Scripts/make_appcast.sh" \
  "${APP_NAME}-${MARKETING_VERSION}.zip" \
  "https://raw.githubusercontent.com/steipete/CodexBar/main/appcast.xml"

verify_appcast_entry "$APPCAST" "$MARKETING_VERSION" "$KEY_FILE"

git add "$APPCAST"
git commit -m "docs: update appcast for ${MARKETING_VERSION}"
git push origin main

if [[ "${RUN_SPARKLE_UPDATE_TEST:-0}" == "1" ]]; then
  PREV_TAG=$(git tag --sort=-v:refname | sed -n '2p')
  [[ -z "$PREV_TAG" ]] && err "RUN_SPARKLE_UPDATE_TEST=1 set but no previous tag found"
  "$ROOT/Scripts/test_live_update.sh" "$PREV_TAG" "v${MARKETING_VERSION}"
fi

check_assets "$TAG" "$ARTIFACT_PREFIX"

git push origin --tags

echo "Release ${MARKETING_VERSION} complete."
