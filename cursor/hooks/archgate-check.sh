#!/bin/sh
set -eu

file_path=$(/usr/bin/jq -er '.file_path | select(type == "string" and startswith("/"))') || {
  printf 'Archgate: hook input must contain an absolute file_path.\n' >&2
  exit 1
}
directory=$(/usr/bin/dirname "$file_path")

while :; do
  if [ -d "$directory/.archgate/adrs" ] || [ -d "$directory/.archgate/lint" ]; then
    cd "$directory"
    exec "$HOME/.archgate/bin/archgate" check -- "$file_path" >&2
  fi
  if [ "$directory" = "/" ]; then
    break
  fi
  directory=$(/usr/bin/dirname "$directory")
done

printf 'Archgate: no .archgate/ governs %s; compliance check skipped.\n' "$file_path" >&2
