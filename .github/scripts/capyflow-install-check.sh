#!/usr/bin/env bash
set -euo pipefail
adb logcat -c
adb shell getprop ro.build.version.release | tee install-check/android-version.txt
adb shell pm list packages com.seph.capyflow | tee install-check/packages-before.txt
if grep -q 'package:com.seph.capyflow' install-check/packages-before.txt; then
  echo 'Test emulator is not a fresh install'; exit 1
fi
set +e
adb install install-check/CapyFlow.apk 2>&1 | tee install-check/install-result.txt
result=${PIPESTATUS[0]}
set -e
adb logcat -d > install-check/install-log.txt
if [ "$result" -ne 0 ]; then exit "$result"; fi
adb shell pm path com.seph.capyflow | tee install-check/installed-path.txt
adb shell dumpsys package com.seph.capyflow > install-check/installed-package.txt
adb shell am start -W -n com.seph.capyflow/.MainActivity | tee install-check/launch-result.txt
sleep 3
adb logcat -d > install-check/launch-log.txt
adb shell pidof com.seph.capyflow | tee install-check/process.txt
