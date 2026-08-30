#!/bin/zsh
set -euo pipefail

if [ "$#" -ne 2 ]; then
  print -u2 'usage: task-audit.sh begin|end task-id'
  exit 64
fi

action="$1"
task_id="$2"
if [[ ! "$task_id" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]]; then
  print -u2 'usage: task-audit.sh begin|end task-id'
  exit 64
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
snapshot_root=".build/plan-audit/$task_id"

capture() {
  destination="$1"
  if [ -e "$destination" ]; then
    print -u2 "audit snapshot already exists: $destination"
    exit 65
  fi
  mkdir -p "$destination"
  if [ -e Package.swift ]; then
    /usr/bin/rsync -aR -- Package.swift "$destination/"
  fi
  if [ -e Sources ]; then
    /usr/bin/rsync -aR -- Sources "$destination/"
  fi
  if [ -e Tests ]; then
    /usr/bin/rsync -aR -- Tests "$destination/"
  fi
  if [ -e Scripts ]; then
    /usr/bin/rsync -aR -- Scripts "$destination/"
  fi
}

case "$action" in
  begin)
    capture "$snapshot_root/before"
    ;;
  end)
    test -d "$snapshot_root/before"
    capture "$snapshot_root/after"
    evidence_dir="docs/superpowers/audit/$task_id"
    mkdir -p "$evidence_dir"
    set +e
    diff -ruN "$snapshot_root/before" "$snapshot_root/after" > "$evidence_dir/changes.diff"
    diff_status="$?"
    set -e
    if [ "$diff_status" -ne 0 ] && [ "$diff_status" -ne 1 ]; then
      exit "$diff_status"
    fi
    : > "$evidence_dir/after.sha256"
    find "$snapshot_root/after" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      shasum -a 256 "$file" >> "$evidence_dir/after.sha256"
    done
    ;;
  *)
    print -u2 'usage: task-audit.sh begin|end task-id'
    exit 64
    ;;
esac
