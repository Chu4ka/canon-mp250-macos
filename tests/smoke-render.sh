#!/bin/sh
set -eu

user_id=$(id -u)
if [ "$user_id" -eq 0 ]; then
  echo 'Run this file-backed smoke test as a regular user.' >&2
  exit 2
fi

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
prefix=${CANON_MP250_DEPS_PREFIX:-$(/bin/sh "$project_dir/scripts/deps-prefix.sh")}
port=${CANON_MP250_SMOKE_PORT:-18080}
raster="$project_dir/build/bin/make-test-raster"
umask 077
test_root=$(mktemp -d /private/tmp/canon-mp250-smoke.XXXXXX)
# PAPPL derives the Unix socket name from argv[0], even on macOS builds that
# use /tmp for the socket. Give each run a unique server name as well.
app_name=${test_root##*/}
app="$test_root/$app_name"
socket_path="/private/tmp/$app_name$user_id.sock"
server_pid=

cleanup()
{
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    attempt=0
    while kill -0 "$server_pid" 2>/dev/null && [ "$attempt" -lt 20 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    kill -KILL "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    if [ -S "$socket_path" ] && [ -O "$socket_path" ]; then
      rm -f "$socket_path"
    fi
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail()
{
  printf '%s\n' "$*" >&2
  if [ -f "$test_root/server.log" ]; then
    tail -n 100 "$test_root/server.log" >&2
  fi
  exit 1
}

case "$port" in
  ''|*[!0-9]*) fail "Invalid smoke test port: $port" ;;
esac
[ "$port" -gt 0 ] && [ "$port" -le 65535 ] || fail "Invalid smoke test port: $port"
if nc -z -w 1 localhost "$port" 2>/dev/null; then
  fail "Smoke test port $port is in use"
fi

export TMPDIR="$test_root" XDG_CONFIG_HOME="$test_root/config"
export STP_DATA_PATH="$prefix/share/gutenprint/5.3/xml"
unset SNAP_COMMON
mkdir "$XDG_CONFIG_HOME" "$test_root/spool" "$test_root/output" "$test_root/no-xml"
ln -s "$project_dir/build/bin/canon-mp250-app" "$app"
# Loading an empty state suppresses PAPPL's startup scan of physical printers.
touch "$XDG_CONFIG_HOME/$app_name.state"

if STP_DATA_PATH="$test_root/no-xml" "$app" drivers > "$test_root/no-xml.log" 2>&1; then
  fail 'The CLI accepted a missing Gutenprint data directory'
else
  [ "$?" -eq 1 ] || fail 'The CLI did not exit cleanly for missing Gutenprint data'
fi
grep -q 'Gutenprint XML printers/canon.xml' "$test_root/no-xml.log" || fail 'Missing Gutenprint data diagnostic'

"$raster" "$test_root/color.pwg" --two-pages
"$raster" "$test_root/gray-legal.pwg" --gray --legal-600
"$raster" "$test_root/gray.urf" --gray --apple

"$app" server -o "server-port=$port" -o listen-hostname=localhost \
  -o server-options=no-tls,no-web-interface \
  -o "spool-directory=$test_root/spool" \
  -o "log-file=$test_root/server.log" -o log-level=debug &
server_pid=$!

attempt=0
until curl --noproxy '*' --max-time 1 -s -o /dev/null "http://localhost:$port/"; do
  kill -0 "$server_pid" 2>/dev/null || fail 'Smoke server exited during startup'
  [ "$attempt" -lt 50 ] || fail "Smoke server did not start on port $port"
  sleep 0.1
  attempt=$((attempt + 1))
done
kill -0 "$server_pid" 2>/dev/null || fail 'Smoke server exited during startup'

server_uri="ipp://localhost:$port"
printer_uri="$server_uri/ipp/print/canonmp250"
"$app" -u "$server_uri" add -d canonmp250 -m canon-pixma-mp250-gutenprint \
  -v "file://$test_root/output" || fail 'Unable to add the test queue'

check_job()
{
  name=$1
  fixture=$2
  pages=$3
  shift 3
  job_id=$("$app" -u "$printer_uri" submit -d canonmp250 -t "$name" "$@" "$test_root/$fixture") ||
    fail "Unable to submit $name"
  case "$job_id" in
    ''|*[!0-9]*) fail "Unexpected job ID for $name: $job_id" ;;
  esac
  cat > "$test_root/check-job.test" <<EOF
{
  NAME "Check job $name completion and impression count"
  OPERATION Get-Job-Attributes
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR naturalLanguage attributes-natural-language en
  ATTR uri printer-uri \$uri
  ATTR integer job-id $job_id
  ATTR keyword requested-attributes job-state,job-impressions-completed
  STATUS successful-ok
  EXPECT job-state OF-TYPE enum WITH-VALUE 9
  EXPECT job-impressions-completed OF-TYPE integer WITH-VALUE $pages
}
EOF
  /usr/bin/ipptool -t -T 2 "$printer_uri" "$test_root/check-job.test" || fail "Job $name failed its IPP checks"

  output="$test_root/output/$name.prn"
  if [ ! -s "$output" ] || ! grep -a -q 'www.canon.com/ns/cmd' "$output"; then
    fail "Gutenprint did not produce a Canon command stream for $name"
  fi
  bytes=$(wc -c < "$output" | tr -d ' ')
  printf 'PASS: %s, %s impression(s), %s Canon bytes\n' "$name" "$pages" "$bytes"
}

check_job pwg-color color.pwg 2 -o printer-resolution=300dpi -o print-color-mode=color
check_job pwg-gray-legal gray-legal.pwg 1 -o printer-resolution=600dpi -o media=na_legal_8.5x14in \
  -o print-color-mode=monochrome
check_job apple-gray gray.urf 1 -o printer-resolution=300dpi -o print-color-mode=monochrome \
  -o document-format=image/urf
