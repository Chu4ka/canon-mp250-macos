#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cache_dir="$project_dir/.cache"
jobs=$(sysctl -n hw.ncpu 2>/dev/null || printf '4')
export MACOSX_DEPLOYMENT_TARGET=27.0

if [ "$(id -u)" -eq 0 ]; then
  echo "Build dependencies as your regular user." >&2
  exit 2
fi
deps_prefix=$(/bin/sh "$project_dir/scripts/deps-prefix.sh")
deps_dir=${deps_prefix%/*}
umask 077
for dir in "$deps_dir" "$deps_prefix" "$cache_dir"; do
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    mkdir "$dir"
  fi
  if [ -L "$dir" ] || [ ! -d "$dir" ] ||
     [ "$(stat -f '%u:%Lp' "$dir")" != "$(id -u):700" ]; then
    # The project download cache may predate the private dependency directory.
    if [ "$dir" != "$cache_dir" ] || [ -L "$dir" ] || [ ! -d "$dir" ] ||
       [ "$(stat -f '%u:%Lp' "$dir")" != "$(id -u):755" ]; then
      echo "Unexpected owner or permissions: $dir" >&2
      exit 2
    fi
  fi
done
build_root=$(mktemp -d "$deps_dir/build.XXXXXX")
trap 'rm -rf "$build_root"' EXIT
trap 'exit 1' HUP INT TERM
source_dir="$build_root/src"
mkdir "$source_dir"
runtime_prefix=/usr/local/share/canon-mp250

fetch()
{
  output=$1
  url=$2
  if [ ! -s "$output" ]; then
    echo "Downloading $url"
    curl -fL --retry 3 -o "$build_root/download" "$url"
    mv "$build_root/download" "$output"
  fi
}

verify()
{
  file=$1
  expected=$2
  actual=$(shasum -a 256 "$file" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    echo "SHA-256 mismatch for $file" >&2
    exit 1
  fi
}

fetch "$cache_dir/libusb-1.0.30.tar.bz2" \
  "https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2"
fetch "$cache_dir/gutenprint-5.3.4.tar.xz" \
  "https://downloads.sourceforge.net/project/gimp-print/gutenprint-5.3/5.3.4/gutenprint-5.3.4.tar.xz"
fetch "$cache_dir/openssl-3.5.8.tar.gz" \
  "https://github.com/openssl/openssl/releases/download/openssl-3.5.8/openssl-3.5.8.tar.gz"
fetch "$cache_dir/pappl-1.4.10.tar.gz" \
  "https://github.com/michaelrsweet/pappl/archive/refs/tags/v1.4.10.tar.gz"

verify "$cache_dir/libusb-1.0.30.tar.bz2" "fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"
verify "$cache_dir/gutenprint-5.3.4.tar.xz" "db44a701d2b8e6a8931c83cec06c91226be266d23e5c189d20a39dd175f2023b"
verify "$cache_dir/openssl-3.5.8.tar.gz" "a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"
verify "$cache_dir/pappl-1.4.10.tar.gz" "4e6e220e960b96cb2d311b1ca2188ef61147fd7f8952864db80a251551d27724"

[ -d "$source_dir/libusb-1.0.30" ] || tar -xjf "$cache_dir/libusb-1.0.30.tar.bz2" -C "$source_dir"
[ -d "$source_dir/gutenprint-5.3.4" ] || tar -xJf "$cache_dir/gutenprint-5.3.4.tar.xz" -C "$source_dir"
[ -d "$source_dir/openssl-3.5.8" ] || tar -xzf "$cache_dir/openssl-3.5.8.tar.gz" -C "$source_dir"
[ -d "$source_dir/pappl-1.4.10" ] || tar -xzf "$cache_dir/pappl-1.4.10.tar.gz" -C "$source_dir"

if [ ! -f "$deps_prefix/lib/libusb-1.0.a" ]; then
  cd "$source_dir/libusb-1.0.30"
  ./configure --prefix="$deps_prefix" --disable-shared --enable-static
  make -j"$jobs"
  make install
fi

if [ ! -f "$deps_prefix/lib/libgutenprint.a" ]; then
  cd "$source_dir/gutenprint-5.3.4"
  # Use the installed runtime location in library constants. DESTDIR keeps
  # this unprivileged build fully inside the private build directory.
  ./configure --prefix="$runtime_prefix" --datadir="$runtime_prefix" \
    --disable-shared --enable-static --disable-nls --disable-cups-ppds \
    --disable-samples --disable-escputil --disable-test --disable-testpattern \
    --disable-libgutenprintui2 --without-cups --without-gimp2 --without-doc \
    --with-modules=static
  make -j"$jobs"
  make install DESTDIR="$build_root/gp-stage"
  mkdir -p "$deps_prefix/share"
  cp -R "$build_root/gp-stage$runtime_prefix/include" "$build_root/gp-stage$runtime_prefix/lib" "$deps_prefix/"
  cp -R "$build_root/gp-stage$runtime_prefix/gutenprint" "$deps_prefix/share/"
fi

if [ ! -f "$deps_prefix/lib/libssl.a" ]; then
  cd "$source_dir/openssl-3.5.8"
  ./Configure darwin64-arm64-cc \
    --prefix="$runtime_prefix/openssl" --openssldir="$runtime_prefix/openssl/ssl" \
    no-shared no-tests no-apps
  make -j"$jobs"
  make install_sw DESTDIR="$build_root/openssl-stage"
  cp -R "$build_root/openssl-stage$runtime_prefix/openssl/include" \
    "$build_root/openssl-stage$runtime_prefix/openssl/lib" "$deps_prefix/"
fi

if [ ! -f "$deps_prefix/lib/libpappl.a" ]; then
  cp "$project_dir/scripts/pkg-config-lite" "$build_root/pkg-config-lite"
  chmod +x "$build_root/pkg-config-lite"
  cd "$source_dir/pappl-1.4.10"
  CANON_MP250_DEPS_PREFIX="$deps_prefix" PKGCONFIG="$build_root/pkg-config-lite" CFLAGS="-O2 -arch arm64" \
    ./configure --prefix="$deps_prefix" --disable-shared --enable-libusb \
      --disable-libjpeg --disable-libpng --disable-libpam --with-tls=openssl \
      --with-dnssd=mdnsresponder
  make -j"$jobs"
  make install
fi

echo "Dependencies installed in $deps_prefix"
