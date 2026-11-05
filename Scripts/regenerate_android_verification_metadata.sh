#!/usr/bin/env bash

# Regenerate both strict dependency-verification files after a human Android
# dependency or Gradle wrapper update. Dependabot cannot write them, so every
# Gradle update lands through a replacement PR (docs/CIAutomation.md).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gradlew="$repo_root/Platforms/Android/gradlew"
helper="$repo_root/Scripts/android_verification_metadata.py"
metadata=(
    "$repo_root/Platforms/Android/gradle/verification-metadata.xml"
    "$repo_root/SmokeTests/AndroidConsumer/gradle/verification-metadata.xml"
)

# Never execute a wrapper whose pinned checksums were not updated and reviewed.
"$repo_root/Scripts/check_android_wrapper_integrity.sh"

java_major() {
    "$1/bin/java" -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p' || true
}

# CI's lowest Android lane and CodeQL build run JDK 17; regenerate with it.
if [[ -z "${JAVA_HOME:-}" || "$(java_major "$JAVA_HOME")" != "17" ]]; then
    JAVA_HOME=""
    if command -v brew >/dev/null 2>&1; then
        jdk_prefix="$(brew --prefix openjdk@17 2>/dev/null || true)"
        if [[ -n "$jdk_prefix" && -x "$jdk_prefix/libexec/openjdk.jdk/Contents/Home/bin/java" ]]; then
            JAVA_HOME="$jdk_prefix/libexec/openjdk.jdk/Contents/Home"
        fi
    fi
    if [[ -z "$JAVA_HOME" && -x /usr/libexec/java_home ]]; then
        JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
    fi
fi
if [[ -z "$JAVA_HOME" || "$(java_major "$JAVA_HOME")" != "17" ]]; then
    echo "Regenerating verification metadata requires JDK 17 (set JAVA_HOME)." >&2
    exit 1
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

if [[ -z "${ANDROID_HOME:-}" && "$(uname -s)" == "Darwin" && -d "$HOME/Library/Android/sdk" ]]; then
    export ANDROID_HOME="$HOME/Library/Android/sdk"
fi

# A warm cache reuses parsed module metadata and skips POM and .module files
# that a clean CI runner still verifies. Resolve everything from scratch.
gradle_home="$(mktemp -d "${TMPDIR:-/tmp}/innonetwork-gradle-home.XXXXXX")"
trap 'rm -rf "$gradle_home"' EXIT
export GRADLE_USER_HOME="$gradle_home"

# Start from empty components so entries for replaced versions do not survive.
python3 -B "$helper" clear "${metadata[@]}"

# Every Gradle task set CI runs: cross-platform.yml, the CodeQL build and the
# check_android_* scripts, whose invalid KSP fixture resolves only what the
# consumer tasks already do. A missed task leaves its artifacts unverified.
"$gradlew" \
    -p "$repo_root/Platforms/Android" \
    --write-verification-metadata sha256 \
    --no-configuration-cache \
    --rerun-tasks \
    testDebugUnitTest \
    :innonetwork-ksp:test \
    lint \
    :innonetwork-ksp:checkKotlinAbi \
    publishAllPublicationsToPreviewRepository \
    assemble \
    :innonetwork-ksp:classes \
    :innonetwork-ksp:jar

"$gradlew" \
    -p "$repo_root/SmokeTests/AndroidConsumer" \
    --write-verification-metadata sha256 \
    --no-configuration-cache \
    --rerun-tasks \
    :consumer:testDebugUnitTest \
    :consumer:assembleDebug \
    :runtime:assembleRelease \
    -PusePublishedPreview=true

python3 -B "$helper" add-aapt2-platforms "${metadata[@]}"
python3 -B "$helper" check "${metadata[@]}"

echo "Regenerated Android verification metadata with JDK 17."
echo "Review the component diff, then run Scripts/check_cross_platform.sh with strict verification."
