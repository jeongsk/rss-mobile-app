#!/bin/zsh
# 시뮬레이터에서 단위 테스트 실행
cd "$(dirname "$0")" && xcodegen generate -q
xcodebuild -project RSSReader.xcodeproj -scheme RSSReader \
  -destination "platform=iOS Simulator,name=${SIM_DEVICE:-iPhone 17}" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO "$@" test 2>&1 \
  | grep -E "error:|✘|Expectation failed|Test run with|TEST (SUCCEEDED|FAILED)" | head -60
