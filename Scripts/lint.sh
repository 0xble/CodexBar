#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/.build/lint-tools/bin"

ensure_tools() {
  # Always delegate to the installer so pinned versions are enforced.
  # The installer is idempotent and exits early when the expected versions are already present.
  "${ROOT_DIR}/Scripts/install_lint_tools.sh"
}

configure_sourcekit_runtime() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  [[ -n "${XCODE_DEFAULT_TOOLCHAIN_OVERRIDE:-}" ]] && return 0

  local developer_dir
  developer_dir="$(xcode-select -p 2>/dev/null || true)"

  local candidate_paths=()
  if [[ -n "${developer_dir}" ]]; then
    candidate_paths+=("${developer_dir}")
    candidate_paths+=("${developer_dir}/Toolchains/XcodeDefault.xctoolchain")
  fi
  candidate_paths+=("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain")

  local sourcekit_runtime=""
  local candidate
  for candidate in "${candidate_paths[@]}"; do
    if [[ -e "${candidate}/usr/lib/sourcekitdInProc.framework/Versions/A/sourcekitdInProc" ]]; then
      sourcekit_runtime="${candidate}"
      break
    fi
  done

  if [[ -z "${sourcekit_runtime}" ]]; then
    return 0
  fi

  export XCODE_DEFAULT_TOOLCHAIN_OVERRIDE="${sourcekit_runtime}"
  export TOOLCHAIN_DIR="${sourcekit_runtime}"
}

cmd="${1:-lint}"

case "$cmd" in
  lint)
    ensure_tools
    configure_sourcekit_runtime
    "${BIN_DIR}/swiftformat" Sources Tests --lint
    "${BIN_DIR}/swiftlint" --strict
    ;;
  format)
    ensure_tools
    "${BIN_DIR}/swiftformat" Sources Tests
    ;;
  *)
    printf 'Usage: %s [lint|format]\n' "$(basename "$0")" >&2
    exit 2
    ;;
esac
