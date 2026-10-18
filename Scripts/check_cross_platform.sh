#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "$repo_root/Scripts/check_platform_layout.py"
python3 "$repo_root/Scripts/tests/test_check_platform_layout.py"
"$repo_root/Scripts/check_android_wrapper_integrity.sh"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "Web verification requires Node.js 22 or newer and npm." >&2
    exit 1
fi
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) {
    console.error("Web verification requires Node.js 22 or newer."); process.exit(1);
}'

detect_java_major() {
    if ! command -v java >/dev/null 2>&1; then
        return 0
    fi

    java -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p' || true
}

java_major="$(detect_java_major)"
if [[ -z "$java_major" || "$java_major" -lt 17 ]]; then
    if command -v brew >/dev/null 2>&1; then
        jdk_prefix="$(brew --prefix openjdk@17 2>/dev/null || true)"
        if [[ -n "$jdk_prefix" ]]; then
            jdk_root="$jdk_prefix/libexec/openjdk.jdk/Contents/Home"
            if [[ -x "$jdk_root/bin/java" ]]; then
                export JAVA_HOME="$jdk_root"
                export PATH="$JAVA_HOME/bin:$PATH"
            fi
        fi
    fi
fi

java_major="$(detect_java_major)"
if [[ -z "$java_major" || "$java_major" -lt 17 ]]; then
    echo "Android verification requires JDK 17 or newer." >&2
    exit 1
fi

if [[ -z "${ANDROID_HOME:-}" && "$(uname -s)" == "Darwin" ]]; then
    android_sdk="$HOME/Library/Android/sdk"
    if [[ -d "$android_sdk" ]]; then
        export ANDROID_HOME="$android_sdk"
    fi
fi

"$repo_root/Platforms/Android/gradlew" \
    -p "$repo_root/Platforms/Android" \
    testDebugUnitTest \
    :innonetwork-ksp:test \
    lint \
    :innonetwork-ksp:checkKotlinAbi \
    publishAllPublicationsToPreviewRepository

"$repo_root/Scripts/check_android_release_artifacts.sh"
"$repo_root/Scripts/check_android_public_api.sh"

"$repo_root/Platforms/Android/gradlew" \
    -p "$repo_root/SmokeTests/AndroidConsumer" \
    :consumer:testDebugUnitTest \
    :consumer:assembleDebug \
    :runtime:assembleRelease \
    -PusePublishedPreview=true

"$repo_root/Scripts/check_android_test_counts.sh"
"$repo_root/Scripts/check_android_codegen_failures.sh"

npm --prefix "$repo_root/Platforms/Web" ci --ignore-scripts --no-audit
npm --prefix "$repo_root/Platforms/Web" run check
npm --prefix "$repo_root/Platforms/Web" test
npm --prefix "$repo_root/Platforms/Web" run build
(
    cd "$repo_root/Platforms/Web"
    npm pack --dry-run
)
"$repo_root/Scripts/check_web_public_api.sh"
"$repo_root/Scripts/check_web_tarball_consumer.sh"

npm --prefix "$repo_root/SmokeTests/WebConsumer" ci --ignore-scripts --no-audit
npm --prefix "$repo_root/SmokeTests/WebConsumer" run check

npm --prefix "$repo_root/SmokeTests/ReactConsumer" ci --ignore-scripts --no-audit
npm --prefix "$repo_root/SmokeTests/ReactConsumer" run check
npm --prefix "$repo_root/SmokeTests/ReactConsumer" test

echo "InnoNetwork Android and Web release-candidate gates: OK"
