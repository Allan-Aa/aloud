#!/bin/zsh
set -euo pipefail

if [ "$#" -ne 2 ] && [ "$#" -ne 3 ]; then
  print -u2 'usage: privacy-audit-scan.sh evidence-dir source-root [registry]'
  exit 64
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
registry="${3:-${ALOUD_PRIVACY_REGISTRY:-$project_root/.build/task-21-fix6-canaries.txt}}"
evidence_dir="$1"
source_root="$2"
required=(changes.diff after.sha256 report.md)
optional=(parallel-full.log parallel-command.txt verification-hashes.txt)

if [ ! -s "$registry" ]; then
  print -u2 'privacy audit failed: canary registry missing'
  exit 65
fi
version="$(sed -n '1s/^version=//p' "$registry")"
run_id="$(sed -n '2s/^run=//p' "$registry")"
declared_payload_sha="$(sed -n '3s/^payload_sha256=//p' "$registry")"
if [ "$version" != 1 ] || [ -z "$run_id" ] || [ -z "$declared_payload_sha" ]; then
  print -u2 'privacy audit failed: invalid registry metadata'
  exit 67
fi
actual_payload_sha="$(tail -n +4 "$registry" | shasum -a 256 | awk '{print $1}')"
if [ "$actual_payload_sha" != "$declared_payload_sha" ]; then
  print -u2 'privacy audit failed: registry payload hash mismatch'
  exit 68
fi
registry_sha="$(shasum -a 256 "$registry" | awk '{print $1}')"
for name in $required; do
  if [ ! -f "$evidence_dir/$name" ]; then
    print -u2 "privacy audit failed: evidence missing category=$name"
    exit 66
  fi
done
for name in $optional; do
  if [ -f "$evidence_dir/$name" ]; then required+=("$name"); fi
done

source_index=0
while IFS= read -r canary; do
  [ -n "$canary" ] || continue
  source_index=$((source_index + 1))
  total=${#canary}
  fragments=("$canary")
  for width in 4 8 12 16 20; do
    if [ "$total" -ge "$width" ]; then
      middle=$(((total - width) / 2 + 1))
      suffix=$((total - width + 1))
      fragments+=("${canary[1,$width]}" "${canary[$middle,$((middle + width - 1))]}" "${canary[$suffix,$total]}")
    fi
  done
  fragment_index=0
  for fragment in $fragments; do
    fragment_index=$((fragment_index + 1))
    for name in $required; do
      if /usr/bin/grep -F -q -- "$fragment" "$evidence_dir/$name"; then
        print -u2 "privacy audit failed: source=$source_index fragment=$fragment_index sink=$name matched=true"
        exit 1
      fi
    done
  done
done < <(tail -n +4 "$registry")

raw_sink_pattern='Diag\.log|(NSLog|print)\([^\n]*(localizedDescription|response\.body|httpBody|headers|secret|authorizedText)'
if /usr/bin/grep -R -E -l -- "$raw_sink_pattern" "$source_root/Sources" > /dev/null; then
  print -u2 'privacy audit failed: raw-sensitive-sink-pattern matched=true'
  exit 1
fi

credential_fixture_1="fake-release"'-key'
credential_fixture_2="recovery"'-key'
credential_fixture_3="fake-openai"'-key'
text_fixture_1="fixed fake release"' sentence'
text_fixture_2="fixed local release"' sentence'
text_fixture_3="first isolated"' sentence'
raw_data_prefix='Data(#'
raw_data_prefix="${raw_data_prefix}\"{"
raw_response_prefix="${raw_data_prefix}\"error\""
response_fixture_code="invalid"'_api_key'
for forbidden_fixture in \
  "$credential_fixture_1" \
  "$credential_fixture_2" \
  "$credential_fixture_3" \
  "$text_fixture_1" \
  "$text_fixture_2" \
  "$text_fixture_3" \
  "$raw_response_prefix" \
  "$raw_data_prefix" \
  "$response_fixture_code"; do
  for name in $required; do
    if /usr/bin/grep -F -q -- "$forbidden_fixture" "$evidence_dir/$name"; then
      print -u2 "privacy audit failed: known-fixture-pattern sink=$name matched=true"
      exit 1
    fi
  done
done

print "privacy audit passed: version=$version run=$run_id registry_sha256=$registry_sha sources=$source_index evidence=${#required} raw-sensitive-sink-patterns=0 known-fixture-patterns=0"
