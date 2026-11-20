#!/bin/sh
set -eu

queue=${MP250_QUEUE:-Canon_MP250}

if [ "$#" -ne 1 ]; then
  echo "Usage: mp250-print FILE.pdf|FILE.docx|FILE.doc" >&2
  exit 2
fi

input=$1
if [ ! -f "$input" ]; then
  echo "mp250-print: file not found: $input" >&2
  exit 2
fi
if ! /usr/bin/lpstat -p "$queue" >/dev/null 2>&1; then
  echo "mp250-print: printer queue '$queue' is not installed" >&2
  exit 1
fi

case $(printf '%s' "${input##*.}" | tr '[:upper:]' '[:lower:]') in
  pdf)
    exec /usr/bin/lp -d "$queue" "$input"
    ;;
  doc|docx)
    temp_dir=$(mktemp -d /private/tmp/mp250-print.XXXXXX)
    trap 'rm -rf "$temp_dir"' EXIT HUP INT TERM
    pdf="$temp_dir/document.pdf"
    /usr/bin/osascript - "$input" "$pdf" <<'APPLESCRIPT'
on run argv
  set inputPath to item 1 of argv
  set outputPath to item 2 of argv
  tell application "Microsoft Word"
    activate
    set openedDocument to open (POSIX file inputPath) read only true add to recent files false
    save as openedDocument file name outputPath file format format PDF
    close openedDocument saving no
  end tell
end run
APPLESCRIPT
    if [ ! -s "$pdf" ]; then
      echo "mp250-print: Microsoft Word did not create a PDF" >&2
      exit 1
    fi
    /usr/bin/lp -d "$queue" "$pdf"
    ;;
  *)
    echo "mp250-print: supported input formats are PDF, DOC, and DOCX" >&2
    exit 2
    ;;
esac
