#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
version=$(cat "$project_dir/VERSION")
package=Canon-MP250-Driver-$version-macOS-arm64
zip="$project_dir/dist/$package.zip"
if [ ! -f "$zip" ]; then
  echo "Run make release as your regular user before installing." >&2
  exit 2
fi

stage=$(mktemp -d "${TMPDIR:-/private/tmp}/mp250-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/ditto -x -k "$zip" "$stage"
if [ "$(id -u)" -eq 0 ]; then
  "$stage/$package/install.sh"
else
  /usr/bin/sudo "$stage/$package/install.sh"
fi
