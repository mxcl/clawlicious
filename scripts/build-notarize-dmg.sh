#!/usr/local/bin/av inject +APPLE_PASSWORD +APPLE_USERNAME /bin/sh
# shellcheck shell=sh disable=SC2096
set -eu

/usr/bin/xcrun notarytool submit \
  --apple-id "${APPLE_USERNAME}" \
  --team-id "${APPLE_TEAM_ID}" \
  --password "${APPLE_PASSWORD}" \
  --wait \
  "$1"
