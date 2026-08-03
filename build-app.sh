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
