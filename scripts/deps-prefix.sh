#!/bin/sh
set -eu

# Darwin returns a per-user directory without spaces, needed by upstream makefiles.
user_tmp=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)
[ -n "$user_tmp" ] && [ -d "$user_tmp" ] && [ -O "$user_tmp" ] || exit 1
printf '%s\n' "${user_tmp%/}/canon-mp250-deps/prefix-release"
