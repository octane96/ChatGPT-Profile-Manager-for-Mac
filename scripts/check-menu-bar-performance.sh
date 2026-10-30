#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/profile-manager-menu-bar.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT HUP INT TERM

xcrun swiftc -O -swift-version 6 -parse-as-library \
  "$repo_root/Sources/ChatGPTProfileManager/MenuBarUsageLabel.swift" \
  "$repo_root/Sources/ChatGPTProfileManager/MenuBarStatusPresentation.swift" \
  "$repo_root/scripts/MenuBarPerformanceCheck.swift" \
  -o "$probe_dir/MenuBarPerformanceCheck"
"$probe_dir/MenuBarPerformanceCheck" "${1:-600}"
