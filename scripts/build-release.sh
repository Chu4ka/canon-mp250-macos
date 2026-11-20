#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$project_dir"
version=$(cat VERSION)
name=Canon-MP250-Driver-$version-macOS-arm64
source_name=Canon-MP250-Driver-$version-source
deps_prefix=$(/bin/sh scripts/deps-prefix.sh)
xml="$deps_prefix/share/gutenprint/5.3/xml"
dist="$project_dir/dist"

if [ "$(id -u)" -eq 0 ] || [ "$(uname -m)" != arm64 ]; then
  echo "Build the package as a regular user on Apple Silicon." >&2
  exit 2
fi
if [ "$(build/bin/canon-mp250-app --version)" != "$version" ] ||
   [ ! -s "$xml/printers/canon.xml" ]; then
  echo "Build version $version and its Gutenprint data before packaging." >&2
  exit 2
fi

mkdir -p "$dist"
stage=$(mktemp -d "$dist/.release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
release_dir="$stage/$name"
sources="$stage/$source_name"
mkdir -p "$release_dir/payload/bin" "$release_dir/payload/libexec" \
  "$release_dir/payload/launchd" "$release_dir/payload/share/gutenprint/5.3" \
  "$release_dir/Документация" "$release_dir/licenses" "$sources/.cache"

install -m 755 packaging/release-install.sh "$release_dir/install.sh"
install -m 755 packaging/release-uninstall.sh "$release_dir/uninstall.sh"
install -m 755 build/bin/canon-mp250-app build/bin/mp250-diag "$release_dir/payload/bin/"
install -m 755 scripts/mp250-print.sh "$release_dir/payload/bin/mp250-print"
install -m 755 scripts/autoadd-watch.sh "$release_dir/payload/libexec/canon-mp250-autoadd"
install -m 644 scripts/mp250-queue.sh "$release_dir/payload/libexec/canon-mp250-queue.sh"
install -m 644 packaging/*.plist "$release_dir/payload/launchd/"
cp -R "$xml" "$release_dir/payload/share/gutenprint/5.3/"
install -m 644 docs/Canon-MP250-Driver-Инструкция.docx \
  docs/Canon-MP250-Driver-Инструкция.pdf "$release_dir/Документация/"
install -m 644 packaging/release-README.txt "$release_dir/ПРОЧТИ-МЕНЯ.txt"
install -m 644 VERSION LICENSE THIRD_PARTY.md "$release_dir/"
install -m 644 licenses/*.txt "$release_dir/licenses/"

for executable in "$release_dir/payload/bin/canon-mp250-app" "$release_dir/payload/bin/mp250-diag"; do
  test "$(/usr/bin/lipo -archs "$executable")" = arm64
  /usr/bin/strip -S "$executable"
  if /usr/bin/strings "$executable" | /usr/bin/grep -Eq '/(Users/|home/|var/folders/|private/tmp/)'; then
    echo "Local build path remains in ${executable##*/}." >&2
    exit 2
  fi
  /usr/bin/codesign --force --sign - "$executable"
  /usr/bin/codesign --verify --strict "$executable"
done

# Explicit inputs keep .git, local artifacts, logs and device data out.
cp .gitignore VERSION LICENSE THIRD_PARTY.md Makefile README.md "$sources/"
mkdir -p "$sources/licenses" "$sources/src" "$sources/packaging" \
  "$sources/scripts" "$sources/tests" "$sources/docs"
cp licenses/*.txt "$sources/licenses/"
cp src/*.c "$sources/src/"
cp packaging/*.sh packaging/*.plist packaging/*.txt "$sources/packaging/"
cp scripts/*.sh scripts/*.py scripts/pkg-config-lite "$sources/scripts/"
cp tests/*.sh tests/*.c "$sources/tests/"
cp docs/Canon-MP250-Driver-Инструкция.docx docs/Canon-MP250-Driver-Инструкция.pdf "$sources/docs/"
cp .cache/libusb-1.0.30.tar.bz2 .cache/gutenprint-5.3.4.tar.xz \
  .cache/openssl-3.5.8.tar.gz .cache/pappl-1.4.10.tar.gz "$sources/.cache/"

/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noacl --noqtn \
  "$release_dir" "$stage/$name.zip"
COPYFILE_DISABLE=1 /usr/bin/tar --no-xattrs --no-acls --no-fflags \
  --uid 0 --gid 0 --uname root --gname wheel \
  -czf "$stage/$source_name.tar.gz" -C "$stage" "$source_name"
/usr/bin/unzip -tq "$stage/$name.zip"
/usr/bin/tar -tzf "$stage/$source_name.tar.gz" >/dev/null
(cd "$stage" && /usr/bin/shasum -a 256 "$name.zip" "$source_name.tar.gz" > "$name.sha256")

for artifact in "$name.zip" "$source_name.tar.gz" "$name.sha256"; do
  mv -f "$stage/$artifact" "$dist/$artifact"
  printf '%s\n' "$dist/$artifact"
done
