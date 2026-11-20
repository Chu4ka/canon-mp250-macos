#!/bin/sh

queue=Canon_MP250
cups_socket=/private/var/run/cupsd
system_ipp=ipp://127.0.0.1:8000/ipp/system

check_system_directory()
{
  if [ -L "$1" ] || [ ! -d "$1" ] || [ "$(stat -f %u "$1")" != 0 ]; then
    echo "Expected a root-owned directory: $1" >&2
    return 1
  fi
  mode=$(stat -f %Lp "$1")
  if [ "$((0$mode & 022))" -ne 0 ] || [ -n "$(ls -lde "$1" | sed -n '2p')" ]; then
    echo "Directory has unsafe write permissions or an ACL: $1" >&2
    return 1
  fi
}

stop_service()
{
  if /bin/launchctl print "system/$1" >/dev/null 2>&1; then
    /bin/launchctl bootout "system/$1"
  fi
}

queue_uri()
{
  queue_line=$(LC_ALL=C /usr/bin/lpstat -h "$cups_socket" -v "$queue" 2>/dev/null) || return 1
  case "$queue_line" in
    *" $queue: "*) printf '%s\n' "${queue_line#*"$queue: "}" ;;
    *) return 1 ;;
  esac
}

owned_queue_uri()
{
  # Accept the canonical PAPPL resource and the localhost URI from 0.2.0.
  case "$1" in
    ipp://localhost:8000/*|ipp://127.0.0.1:8000/*) ;;
    *) return 1 ;;
  esac
  case "${1#*://*:8000}" in
    /ipp/print/Canon_MP250_series_%28USB%29|"/ipp/print/Canon_MP250_series_(USB)") return 0 ;;
    *) return 1 ;;
  esac
}

probe_ipp()
{
  LC_ALL=C /usr/bin/ipptool -T 2 -q "$system_ipp" /dev/stdin <<'IPP'
{
  OPERATION Get-System-Attributes
  GROUP operation
  ATTR charset attributes-charset utf-8
  ATTR language attributes-natural-language en
  ATTR uri system-uri $uri
  ATTR keyword requested-attributes system-state
  STATUS successful-ok
  EXPECT system-state OF-TYPE enum
}
IPP
}

discover_usb_printers()
{
  # PAPPL-Create-Printers (0x402d). An explicit request prevents the PAPPL CLI
  # from starting a second server if launchd is still bringing up the service.
  LC_ALL=C /usr/bin/ipptool -T 5 -q "$system_ipp" /dev/stdin <<'IPP'
{
  OPERATION 0x402d
  GROUP operation
  ATTR charset attributes-charset utf-8
  ATTR language attributes-natural-language en
  ATTR uri system-uri $uri
  ATTR keyword smi55357-device-type usb
  STATUS successful-ok
  STATUS client-error-not-found
}
IPP
}

printer_endpoint()
{
  attributes=$(LC_ALL=C /usr/bin/ipptool -T 2 -tv "$system_ipp" /dev/stdin <<'IPP'
{
  OPERATION CUPS-Get-Printers
  GROUP operation
  ATTR charset attributes-charset utf-8
  ATTR language attributes-natural-language en
  ATTR keyword requested-attributes printer-uri-supported
  STATUS successful-ok
  STATUS client-error-not-found
}
IPP
  ) || return 1

  # Use the resource that PAPPL actually advertises, with parentheses encoded
  # for CUPS. Only this project's MP250 USB queue is managed here.
  printf '%s\n' "$attributes" | /usr/bin/awk '
    /printer-uri-supported \(uri\) = / {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /\/ipp\/print\/Canon_MP250_series_(\(USB\)|%28USB%29)(,|$)/) {
          print "ipp://127.0.0.1:8000/ipp/print/Canon_MP250_series_%28USB%29"
          exit
        }
      }
    }'
}
