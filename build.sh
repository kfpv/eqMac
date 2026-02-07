#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 app|driver" >&2
}

clear_ui_cache() {
  local app_support
  app_support="$HOME/Library/Application Support/com.bitgapp.eqmac"
  if [[ -d "$app_support" ]]; then
    rm -rf "$app_support/ui"
    rm -f "$app_support"/ui-*.zip
  fi
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  app)
    (cd ui && bun run build)
    (cd native && xcodebuild -workspace eqMac.xcworkspace -scheme eqMac -configuration Debug build)
    clear_ui_cache
    ;;
  driver)
    (cd native/driver && xcodebuild -project Driver.xcodeproj -scheme "Driver - Debug" -configuration Debug build)
    ;;
  *)
    usage
    exit 1
    ;;
esac
