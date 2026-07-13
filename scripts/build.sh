#!/usr/bin/env bash
set -euo pipefail

install=0
run=0

for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    --run) run=1 ;;
    -h|--help)
      echo "usage: scripts/build.sh [--install] [--run]"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      echo "usage: scripts/build.sh [--install] [--run]" >&2
      exit 2
      ;;
  esac
done

swift build
bin_dir="$(swift build --show-bin-path)"
app="$bin_dir/Clawlicious.app"
installed_app="/Applications/Clawlicious.app"
helper="$app/Contents/Library/LoginItems/Clawlicious Menu.app"

osascript -e 'tell application id "dev.mxcl.clawlicious" to quit' >/dev/null 2>&1 || true
pkill -x Clawlicious >/dev/null 2>&1 || true
pkill -x ClawliciousMenuBarHelper >/dev/null 2>&1 || true
sleep 0.2

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$helper/Contents/MacOS" "$helper/Contents/Resources"
cp "$bin_dir/Clawlicious" "$app/Contents/MacOS/Clawlicious"
cp Sources/Clawlicious/Info.plist "$app/Contents/Info.plist"
cp Sources/Clawlicious/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin_dir/ClawliciousMenuBarHelper" "$helper/Contents/MacOS/ClawliciousMenuBarHelper"
cp Sources/ClawliciousMenuBarHelper/Info.plist "$helper/Contents/Info.plist"
ln -s ../../../../../Resources/AppIcon.icns "$helper/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Clawlicious" "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ClawliciousMenuBarHelper" "$helper/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$helper/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$helper/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "$helper/Contents/Info.plist" >/dev/null

xattr -cr "$app"
codesign --force --sign - "$helper" >/dev/null
xattr -cr "$app"
codesign --force --deep --sign - "$app" >/dev/null

if (( install )); then
  rm -rf "$installed_app"
  cp -R "$app" "$installed_app"
fi

if (( run )); then
  if (( install )); then
    open -n "$installed_app"
  else
    open -n "$app"
  fi
fi
