#!/bin/zsh
# 시뮬레이터에 설치하고 실행: ./run.sh "iPhone 17" [-demo]
cd "$(dirname "$0")"
DEVICE="${1:-${SIM_DEVICE:-iPhone 17}}"; shift
xcrun simctl boot "$DEVICE" 2>/dev/null
xcrun simctl install "$DEVICE" build/Build/Products/Debug-iphonesimulator/RSSReader.app
xcrun simctl terminate "$DEVICE" com.anpigon.RSSReader 2>/dev/null
xcrun simctl launch "$DEVICE" com.anpigon.RSSReader "$@"
