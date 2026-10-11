#!/bin/zsh
# 시뮬레이터용 빌드 (서명 없이)
cd "$(dirname "$0")" && xcodegen generate -q
xcodebuild -project RSSReader.xcodeproj -scheme RSSReader \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO "$@" build 2>&1 \
  | grep -E "error:|warning: .*(Sendable|isolat)|BUILD (SUCCEEDED|FAILED)" | sort -u | head -40
