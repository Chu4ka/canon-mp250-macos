#!/bin/sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

package_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
label=com.github.local.canon-mp250-app
watch_label=com.github.local.canon-mp250-autoadd
plist=/Library/LaunchDaemons/$label.plist
watch_plist=/Library/LaunchDaemons/$watch_label.plist
payload=$package_dir/payload
xml_parent=/usr/local/share/canon-mp250/gutenprint/5.3

if [ "$(id -u)" -ne 0 ]; then
  echo "Запустите установщик через sudo: sudo ./install.sh" >&2
  exit 2
fi
if [ "$(uname -m)" != arm64 ]; then
  echo "Этот пакет предназначен для Mac с Apple Silicon (arm64)." >&2
  exit 2
fi
os_version=$(sw_vers -productVersion)
if [ "${os_version%%.*}" -lt 27 ]; then
  echo "Требуется macOS 27 или новее." >&2
  exit 2
fi
for required in "$package_dir/VERSION" "$payload/bin/canon-mp250-app" \
  "$payload/bin/mp250-diag" "$payload/bin/mp250-print" \
  "$payload/libexec/canon-mp250-autoadd" "$payload/libexec/canon-mp250-queue.sh" \
  "$payload/share/gutenprint/5.3/xml/printers/canon.xml" \
  "$payload/launchd/$label.plist" "$payload/launchd/$watch_label.plist"; do
  if [ ! -s "$required" ] || [ ! -f "$required" ] || [ -L "$required" ]; then
    echo "Пакет поврежден: отсутствует $required" >&2
    exit 2
  fi
done
/usr/bin/plutil -lint "$payload/launchd/$label.plist" "$payload/launchd/$watch_label.plist"
for executable in "$payload/bin/canon-mp250-app" "$payload/bin/mp250-diag"; do
  /usr/bin/codesign --verify --strict "$executable"
done
version=$(cat "$package_dir/VERSION")
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Invalid package version." >&2
  exit 2
fi
. "$payload/libexec/canon-mp250-queue.sh"

safe_directory()
{
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    /usr/bin/install -d -o root -g wheel -m 755 "$1"
  fi
  check_system_directory "$1"
}

for dir in /usr/local /usr/local/libexec /usr/local/bin /usr/local/share \
  /usr/local/share/canon-mp250 /usr/local/share/canon-mp250/gutenprint "$xml_parent" \
  /usr/local/var /usr/local/var/spool /usr/local/var/spool/canon-mp250-app \
  /usr/local/var/log /Library/LaunchDaemons; do
  safe_directory "$dir"
done

xml_stage=$(mktemp -d "$xml_parent/.install.XXXXXX")
managed_files="/usr/local/libexec/canon-mp250-app
/usr/local/bin/mp250-diag
/usr/local/bin/mp250-print
/usr/local/libexec/canon-mp250-autoadd
/usr/local/libexec/canon-mp250-queue.sh
$plist
$watch_plist"
changing=no
xml_moved=no
old_app=no
old_watch=no
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then old_app=yes; fi
if /bin/launchctl print "system/$watch_label" >/dev/null 2>&1; then old_watch=yes; fi

restore_previous()
{
  stop_service "$watch_label" && stop_service "$label" || return 1
  for target in $managed_files; do
    if [ -f "$xml_stage/backup$target" ]; then
      /bin/mv -f "$xml_stage/backup$target" "$target" || return 1
    else
      /bin/rm -f "$target" || return 1
    fi
  done
  if [ "$xml_moved" = yes ]; then
    /bin/rm -rf "$xml_parent/xml" || return 1
  fi
  if [ -d "$xml_stage/previous" ]; then
    /bin/mv "$xml_stage/previous" "$xml_parent/xml" || return 1
  fi
  if [ "$old_app" = yes ]; then /bin/launchctl bootstrap system "$plist" || return 1; fi
  if [ "$old_watch" = yes ]; then /bin/launchctl bootstrap system "$watch_plist" || return 1; fi
}

cleanup()
{
  status=$?
  trap - EXIT
  if [ "$changing" = yes ]; then
    if ! restore_previous; then
      echo "Не удалось восстановить предыдущую установку. Резервные файлы: $xml_stage" >&2
      exit 1
    fi
    echo "Восстановлено состояние до установки." >&2
  fi
  /bin/rm -rf "$xml_stage"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

for target in $managed_files; do
  if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
    echo "Unexpected file type at $target." >&2
    exit 2
  fi
  if [ -f "$target" ]; then
    file_mode=$(stat -f %Lp "$target")
    if [ "$(stat -f %u "$target")" != 0 ] || [ "$((0$file_mode & 022))" -ne 0 ]; then
      echo "Existing file must be root-owned and writable only by root: $target." >&2
      exit 2
    fi
    mkdir -p "$xml_stage/backup${target%/*}"
    /bin/cp -p "$target" "$xml_stage/backup$target"
  fi
done
for log in app launchd autoadd; do
  log_file=/usr/local/var/log/canon-mp250-$log.log
  if [ ! -e "$log_file" ] && [ ! -L "$log_file" ]; then
    /usr/bin/install -o root -g wheel -m 600 /dev/null "$log_file"
  elif [ -L "$log_file" ] || [ ! -f "$log_file" ] ||
       [ "$(stat -f %u "$log_file")" != 0 ]; then
    echo "Unexpected log file: $log_file." >&2
    exit 2
  else
    chmod 600 "$log_file"
  fi
done

/bin/cp -R "$payload/share/gutenprint/5.3/xml" "$xml_stage/"
if [ -n "$(find "$xml_stage/xml" \! -type d \! -type f -print)" ]; then
  echo "Unexpected file type in Gutenprint data." >&2
  exit 2
fi
/usr/sbin/chown -R root:wheel "$xml_stage/xml"
find "$xml_stage/xml" -type d -exec chmod 755 {} +
find "$xml_stage/xml" -type f -exec chmod 644 {} +

if [ -L "$xml_parent/xml" ] || { [ -e "$xml_parent/xml" ] && [ ! -d "$xml_parent/xml" ]; }; then
  echo "Unexpected file at $xml_parent/xml." >&2
  exit 2
fi
changing=yes
stop_service "$watch_label"
stop_service "$label"
if [ -d "$xml_parent/xml" ]; then
  /bin/mv "$xml_parent/xml" "$xml_stage/previous"
fi
xml_moved=yes
/bin/mv "$xml_stage/xml" "$xml_parent/xml"
/usr/bin/install -S -o root -g wheel -m 755 "$payload/bin/canon-mp250-app" /usr/local/libexec/canon-mp250-app
/usr/bin/install -S -o root -g wheel -m 755 "$payload/bin/mp250-diag" /usr/local/bin/mp250-diag
/usr/bin/install -S -o root -g wheel -m 755 "$payload/bin/mp250-print" /usr/local/bin/mp250-print
/usr/bin/install -S -o root -g wheel -m 755 "$payload/libexec/canon-mp250-autoadd" /usr/local/libexec/canon-mp250-autoadd
/usr/bin/install -S -o root -g wheel -m 644 "$payload/libexec/canon-mp250-queue.sh" /usr/local/libexec/canon-mp250-queue.sh
/usr/bin/install -S -o root -g wheel -m 644 "$payload/launchd/$label.plist" "$plist"
/usr/bin/install -S -o root -g wheel -m 644 "$payload/launchd/$watch_label.plist" "$watch_plist"

/bin/launchctl bootstrap system "$plist"
echo "Ожидание запуска службы печати..."
attempt=0
while :; do
  if /usr/bin/curl -q --noproxy '*' --fail --silent --head --max-time 2 http://127.0.0.1:8000/ |
    grep -Fiq "Server: canon-mp250-app/$version PAPPL/" && probe_ipp >/dev/null 2>&1; then
      break
  fi
  if [ "$attempt" -ge 15 ]; then
    echo "Служба IPP $version не ответила. Проверьте порт 8000 и журнал /usr/local/var/log/canon-mp250-launchd.log" >&2
    exit 1
  fi
  /bin/sleep 1
  attempt=$((attempt + 1))
done

/bin/launchctl bootstrap system "$watch_plist"
changing=no
if ! /usr/local/libexec/canon-mp250-autoadd; then
  echo "Служба запущена, но очередь macOS пока не создана." >&2
fi

echo
echo "Canon MP250 Driver $version установлен."
if existing=$(queue_uri) && ! owned_queue_uri "$existing"; then
  echo "Имя Canon_MP250 занято другой очередью. Освободите имя, чтобы добавить MP250."
elif [ -n "${existing:-}" ] && [ -n "$(printer_endpoint)" ]; then
  echo "Очередь Canon_MP250 доступна. Откройте документ в Word и нажмите Command-P."
else
  echo "Включите принтер и подключите USB: очередь появится автоматически в течение 30 секунд."
fi
echo "Диагностика USB: /usr/local/bin/mp250-diag --open"
echo "Веб-интерфейс: http://127.0.0.1:8000/"
