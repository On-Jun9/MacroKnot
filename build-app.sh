#!/bin/zsh
set -euo pipefail

project_root="${0:A:h}"
build_root="$project_root/.build"
app_path="$build_root/MacroKnot.app"
executable_path="$build_root/arm64-apple-macosx/debug/MacroKnotApp"
signing_identity="${MACROKNOT_SIGNING_IDENTITY:-Local Self-Signed}"
cache_path="$build_root/cache"
config_path="$build_root/config"
security_path="$build_root/security"
module_cache_path="$build_root/module-cache"

mkdir -p "$cache_path" "$config_path" "$security_path" "$module_cache_path"
export CLANG_MODULE_CACHE_PATH="$module_cache_path"
export SWIFT_MODULECACHE_PATH="$module_cache_path"

swift build \
    --disable-sandbox \
    --package-path "$project_root" \
    --scratch-path "$build_root" \
    --cache-path "$cache_path" \
    --config-path "$config_path" \
    --security-path "$security_path" \
    --configuration debug \
    --triple arm64-apple-macosx14.0 \
    --product MacroKnotApp

# 이전 디버그 인스턴스가 살아 있는 채로 같은 경로의 실행 파일을 덮어쓰면, 그 프로세스가
# 아직 읽지 않은 코드 페이지를 읽는 순간 커널이 코드 서명 위반으로 SIGKILL한다. 그러면
# macOS가 "예기치 않게 종료되었습니다" 알림을 띄우고, 그 알림의 `다시 열기`가 또 다음
# 빌드에서 죽을 인스턴스를 만든다. 덮어쓰기 전에 이 번들의 프로세스만 정리한다.
bundle_executable="$app_path/Contents/MacOS/MacroKnot"
if pgrep -f "$bundle_executable" > /dev/null 2>&1; then
    echo "실행 중인 이전 디버그 인스턴스를 종료합니다."
    pkill -f "$bundle_executable" || true
    for _ in {1..25}; do
        pgrep -f "$bundle_executable" > /dev/null 2>&1 || break
        sleep 0.2
    done
    if pgrep -f "$bundle_executable" > /dev/null 2>&1; then
        pkill -9 -f "$bundle_executable" || true
        sleep 0.5
    fi
fi

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$project_root/Info.plist" "$app_path/Contents/Info.plist"
cp "$executable_path" "$app_path/Contents/MacOS/MacroKnot"
cp "$project_root/Resources/MacroKnot.icns" "$app_path/Contents/Resources/MacroKnot.icns"
codesign \
    --force \
    --sign "$signing_identity" \
    --identifier dev.macroknot.app.local \
    --options runtime \
    --timestamp=none \
    "$app_path"

echo "$app_path"
