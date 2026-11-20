#!/bin/sh
set -eu

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
. /usr/local/libexec/canon-mp250-queue.sh

# PAPPL de-duplicates devices, so this is safe to run when the printer is
# plugged in after installation as well as at boot.
discover_usb_printers
endpoint=$(printer_endpoint)
[ -n "$endpoint" ] || exit 0
if existing=$(queue_uri); then
  if ! owned_queue_uri "$existing"; then
    echo "Queue $queue already points to another printer. Its settings were preserved." >&2
    exit 1
  fi
  exit 0
fi
/usr/sbin/lpadmin -h "$cups_socket" -p "$queue" -E -v "$endpoint" -m everywhere
