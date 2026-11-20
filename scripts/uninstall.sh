#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
exec "$project_dir/packaging/release-uninstall.sh" "$@"
