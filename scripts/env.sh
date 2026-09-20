#!/usr/bin/env bash
# Source this from the project root when using the locally bootstrapped tools.
export LOCALBEAT_TOOLS="${LOCALBEAT_TOOLS:-/private/tmp/localbeat-tools}"
export JAVA_HOME="$LOCALBEAT_TOOLS/java/Contents/Home"
export ANDROID_HOME="$LOCALBEAT_TOOLS/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export GRADLE_USER_HOME="$LOCALBEAT_TOOLS/gradle"
export PUB_CACHE="$LOCALBEAT_TOOLS/pub-cache"
export PATH="$LOCALBEAT_TOOLS/flutter/bin:$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"
