#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
version="${MARKETING_VERSION:-1.2.0}"
build="${CURRENT_PROJECT_VERSION:-1}"
app="$root/.build/Clawlicious.app"
installed_app="/Applications/Clawlicious.app"
helper="$app/Contents/Library/LoginItems/Clawlicious Menu.app"
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

script_version() {
  sed -n 's/^version="${MARKETING_VERSION:-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)}"$/\1/p' "$root/scripts/build.sh"
}

version_gt() {
  local left="$1" right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch

  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"
  if ((10#$left_major != 10#$right_major)); then
    ((10#$left_major > 10#$right_major))
  elif ((10#$left_minor != 10#$right_minor)); then
    ((10#$left_minor > 10#$right_minor))
  else
    ((10#$left_patch > 10#$right_patch))
  fi
}

plan_release_version() {
  local current_version="$1"
  local previous_tag target_ref version_path planned_version

  previous_tag="$(gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')"
  [[ -n "$previous_tag" && "$previous_tag" != "null" ]] || die "Unable to find the previous GitHub release"
  git -C "$root" rev-parse --verify --quiet "$previous_tag^{commit}" >/dev/null ||
    git -C "$root" fetch --quiet origin "refs/tags/$previous_tag:refs/tags/$previous_tag" ||
    die "Unable to fetch release tag $previous_tag"

  target_ref="$(git -C "$root" rev-parse HEAD)"
  version_path="$(mktemp "${TMPDIR:-/tmp}/clawlicious-release-version.XXXXXX")"
  printf '%s\n' "Choosing release version with Codex" >&2
  codex exec \
    --cd "$root" \
    --sandbox read-only \
    --config approval_policy=\"never\" \
    --color never \
    --ephemeral \
    --output-last-message "$version_path" \
    "Inspect the git history and diff for $previous_tag..$target_ref and choose the next Clawlicious SemVer version after $current_version. Use patch for compatible fixes, minor for new user-visible behavior, and major only for intentional breaking changes. Do not edit files or create commits. Output only the X.Y.Z version." \
    >&2 || die "Codex release version planning failed"
  planned_version="$(awk '/^[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }' "$version_path")"
  rm -f "$version_path"
  [[ -n "$planned_version" ]] || die "Codex did not return an X.Y.Z version"
  printf '%s\n' "$planned_version"
}

bump_release_version() {
  local new_version="$1"

  VERSION="$new_version" perl -0pi -e '
    my $version = $ENV{VERSION};
    s/^version="\$\{MARKETING_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"$/version="\${MARKETING_VERSION:-$version}"/m
      or die "Unable to update default version in scripts/build.sh\n";
  ' "$root/scripts/build.sh"
  git -C "$root" add scripts/build.sh
  git -C "$root" diff --cached --quiet && die "scripts/build.sh was unchanged after version bump"
  git -C "$root" commit -m "v$new_version"
  git -C "$root" push
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

if $dmg; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
fi

if $publish; then
  require_tool codex
  require_tool gh
  require_tool git
  require_tool brew
  [[ -z "$(git -C "$root" status --porcelain)" ]] || die "Commit or stash changes before publishing"
  git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1 ||
    die "The current branch needs an upstream before publishing"

  tap="$work/homebrew-made"
  gh repo clone homebrew-made "$tap"

  current_version="$(script_version)"
  [[ -n "$current_version" ]] || die "Unable to read the default version from scripts/build.sh"
  version="$(plan_release_version "$current_version")"
  version_gt "$version" "$current_version" ||
    die "Codex proposed $version, which is not newer than $current_version"
  git -C "$root" rev-parse --verify --quiet "v$version^{commit}" >/dev/null &&
    die "Tag v$version already exists"
  bump_release_version "$version"
fi

dmg_path="${DMG_PATH:-$root/dist/clawlicious-$version.dmg}"

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
  mkdir -p "$work/dmg" "$(dirname "$dmg_path")"
  cp -R "$app" "$work/dmg/Clawlicious.app"
  ln -s /Applications "$work/dmg/Applications"
  rm -f "$dmg_path"
  hdiutil create -volname Clawlicious -srcfolder "$work/dmg" -ov -format UDZO "$dmg_path" >/dev/null
  if [[ "$sign_identity" != "-" ]]; then
    codesign --force --sign "$sign_identity" --timestamp "$dmg_path"
  fi
fi

if $notarize; then
  "$root/scripts/build-notarize-dmg.sh" "$dmg_path"
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi

if $publish; then
  tag="v$version"
  gh release view "$tag" >/dev/null 2>&1 && die "GitHub release $tag already exists"
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
