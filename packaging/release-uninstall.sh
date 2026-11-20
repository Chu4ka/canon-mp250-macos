#!/bin/sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

label=com.github.local.canon-mp250-app
watch_label=com.github.local.canon-mp250-autoadd
plist=/Library/LaunchDaemons/$label.plist
watch_plist=/Library/LaunchDaemons/$watch_label.plist

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите удаление через sudo: sudo ./uninstall.sh" >&2
  exit 2
fi
package_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ "${package_dir##*/}" = packaging ]; then
  . "$package_dir/../scripts/mp250-queue.sh"
else
  . "$package_dir/payload/libexec/canon-mp250-queue.sh"
fi

for dir in /usr/local /usr/local/libexec /usr/local/bin /usr/local/share \
  /usr/local/var /usr/local/var/spool /Library/LaunchDaemons /private/var/lib; do
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    check_system_directory "$dir"
  fi
done
if ! /usr/bin/lpstat -h "$cups_socket" -r >/dev/null 2>&1; then
  echo "Локальная служба CUPS недоступна. Повторите удаление после её запуска." >&2
  exit 1
fi
stop_service "$watch_label"
stop_service "$label"
if existing=$(queue_uri); then
  if owned_queue_uri "$existing"; then
    /usr/sbin/lpadmin -h "$cups_socket" -x "$queue"
  else
    echo "Очередь $queue указывает на другой принтер и сохранена."
  fi
fi
/bin/rm -f "$plist" "$watch_plist" \
  /usr/local/libexec/canon-mp250-app \
  /usr/local/libexec/canon-mp250-autoadd /usr/local/libexec/canon-mp250-queue.sh \
  /private/var/lib/canon-mp250-app.state \
  /usr/local/bin/mp250-diag /usr/local/bin/mp250-print
/bin/rm -rf /usr/local/share/canon-mp250 /usr/local/var/spool/canon-mp250-app

echo "Canon MP250 Driver удален."
echo "Журналы оставлены в /usr/local/var/log/canon-mp250-*.log"
