#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
version="${MARKETING_VERSION:-1.0.0}"
build="${CURRENT_PROJECT_VERSION:-1}"
app="$root/.build/Clawlicious.app"
installed_app="/Applications/Clawlicious.app"
helper="$app/Contents/Library/LoginItems/Clawlicious Menu.app"
dmg_path="${DMG_PATH:-$root/dist/clawlicious-$version.dmg}"
install=false
run=false
dmg=false
notarize=false
publish=false

usage() {
  printf 'usage: %s [--install] [--run] [--dmg] [--notarize] [--publish]\n' "${0##*/}"
}

die() {
  printf '%s\n' "$1" >&2
  exit 64
}

require_tool() {
  command -v "$1" >/dev/null || die "$1 is required"
}

while (($#)); do
  case "$1" in
    --install) install=true ;;
    --run) run=true ;;
    --dmg) dmg=true ;;
    --notarize) dmg=true; notarize=true ;;
    --publish) dmg=true; notarize=true; publish=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MARKETING_VERSION must be X.Y.Z"

if $publish; then
  require_tool gh
  require_tool git
  require_tool brew
  [[ -z "$(git -C "$root" status --porcelain)" ]] || die "Commit or stash changes before publishing"
  git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 ||
    die "The current branch needs an upstream before publishing"

  tap="${TAP_ROOT:-$HOME/src/homebrew-made}"
  [[ -d "$tap/.git" ]] || die "Set TAP_ROOT to the homebrew-made checkout"
  [[ -z "$(git -C "$tap" status --porcelain)" ]] || die "$tap has uncommitted changes"
  git -C "$tap" pull --ff-only
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  sign_identity="$CODESIGN_IDENTITY"
else
  sign_identity="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }')"
  [[ -n "$sign_identity" ]] || sign_identity="-"
fi

if [[ -z "${APPLE_TEAM_ID:-}" && "$sign_identity" =~ \(([A-Z0-9]+)\)$ ]]; then
  export APPLE_TEAM_ID="${BASH_REMATCH[1]}"
fi
if $notarize; then
  [[ "$sign_identity" != "-" ]] || die "CODESIGN_IDENTITY is required for --notarize"
  [[ -n "${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}" ]] ||
    die "APPLE_TEAM_ID or DEVELOPMENT_TEAM is required for --notarize"
  export APPLE_TEAM_ID="${APPLE_TEAM_ID:-$DEVELOPMENT_TEAM}"
fi

codesign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
  codesign_args+=(--options runtime --timestamp)
fi

swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

osascript -e 'tell application id "dev.mxcl.clawlicious" to quit' >/dev/null 2>&1 || true
pkill -x Clawlicious >/dev/null 2>&1 || true
pkill -x ClawliciousMenuBarHelper >/dev/null 2>&1 || true

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$helper/Contents/MacOS" "$helper/Contents/Resources"
cp "$bin_dir/Clawlicious" "$app/Contents/MacOS/Clawlicious"
cp "$root/Sources/Clawlicious/Info.plist" "$app/Contents/Info.plist"
cp "$root/Sources/Clawlicious/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$bin_dir/ClawliciousMenuBarHelper" "$helper/Contents/MacOS/ClawliciousMenuBarHelper"
cp "$root/Sources/ClawliciousMenuBarHelper/Info.plist" "$helper/Contents/Info.plist"
ln -s ../../../../../Resources/AppIcon.icns "$helper/Contents/Resources/AppIcon.icns"

for bundle in "$app" "$helper"; do
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$bundle/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build" "$bundle/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$bundle/Contents/Info.plist" >/dev/null
done
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string Clawlicious" "$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ClawliciousMenuBarHelper" "$helper/Contents/Info.plist" >/dev/null

xattr -cr "$app"
codesign "${codesign_args[@]}" "$helper" >/dev/null
codesign "${codesign_args[@]}" "$app" >/dev/null
codesign --verify --strict --deep "$app"

if $dmg; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/dmg" "$(dirname "$dmg_path")"
  cp -R "$app" "$work/dmg/Clawlicious.app"
  ln -s /Applications "$work/dmg/Applications"
  rm -f "$dmg_path"
  hdiutil create -volname Clawlicious -srcfolder "$work/dmg" -ov -format UDZO "$dmg_path" >/dev/null
fi

if $notarize; then
  "$root/scripts/build-notarize-dmg.sh" "$dmg_path"
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi

if $publish; then
  tag="v$version"
  gh release view "$tag" >/dev/null 2>&1 && die "GitHub release $tag already exists"
  git -C "$root" push
  gh release create "$tag" "$dmg_path" \
    --target "$(git -C "$root" rev-parse HEAD)" \
    --title "Clawlicious $version" \
    --generate-notes

  sha256="$(shasum -a 256 "$dmg_path" | cut -d ' ' -f 1)"
  mkdir -p "$tap/Casks"
  sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha256/g" \
    "$root/scripts/clawlicious.rb.in" > "$tap/Casks/clawlicious.rb"
  (cd "$tap" && brew style Casks/clawlicious.rb)
  git -C "$tap" add Casks/clawlicious.rb
  if ! git -C "$tap" diff --cached --quiet; then
    git -C "$tap" commit -m "clawlicious v$version"
    git -C "$tap" push
  fi
fi

if $install; then
  rm -rf "$installed_app"
  ditto "$app" "$installed_app"
fi

printf 'Built %s\n' "$app"
if $dmg; then
  printf 'Created %s\n' "$dmg_path"
fi

if $run; then
  if $install; then
    open -n "$installed_app"
  else
    open -n "$app"
  fi
fi
