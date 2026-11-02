#!/bin/bash
set -euo pipefail
umask 077

database='fauxlore_production_candidate'
backup_dir='/var/backups/fauxlore'
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
temporary="$backup_dir/.${database}-${timestamp}.dump.tmp"
destination="$backup_dir/${database}-${timestamp}.dump"

test "$(id -un)" = postgres
install -d -o postgres -g postgres -m 0700 "$backup_dir"
trap 'rm -f -- "$temporary"' EXIT

/usr/lib/postgresql/17/bin/pg_dump -p 5433 -Fc -d "$database" -f "$temporary"
/usr/lib/postgresql/17/bin/pg_restore --list "$temporary" >/dev/null
mv -- "$temporary" "$destination"
chmod 0600 "$destination"

mapfile -t backups < <(
  find "$backup_dir" -maxdepth 1 -type f -name "${database}-*.dump" -printf '%T@ %p\n' |
    sort -rn | cut -d' ' -f2-
)
for ((index=7; index<${#backups[@]}; index++)); do
  case "${backups[index]}" in
    "$backup_dir"/"$database"-*.dump) rm -f -- "${backups[index]}" ;;
    *) exit 1 ;;
  esac
done

printf 'backup_ok database=%s size_bytes=%s path=%s\n' \
  "$database" "$(stat -c %s "$destination")" "$destination"
