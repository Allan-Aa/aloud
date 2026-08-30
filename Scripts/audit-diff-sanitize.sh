#!/bin/zsh
set -euo pipefail

if [ "$#" -ne 2 ]; then
  print -u2 'usage: audit-diff-sanitize.sh raw-diff sanitized-diff'
  exit 64
fi

raw_diff="$1"
sanitized_diff="$2"
if [ ! -f "$raw_diff" ]; then
  print -u2 'audit diff sanitization failed: raw diff missing'
  exit 65
fi
if [ "$raw_diff" = "$sanitized_diff" ]; then
  print -u2 'audit diff sanitization failed: input and output must differ'
  exit 66
fi

tmp="${sanitized_diff}.tmp.$$"
trap 'rm -f "$tmp"' EXIT

# These are historical test fixtures, not production credentials or user text.
# The official audit diff preserves paths, hunks, and code structure while
# replacing payload-bearing fixture values with typed category markers.
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
sed \
  -e "s@$credential_fixture_1@<redacted-runtime-credential-fixture>@g" \
  -e "s@$credential_fixture_2@<redacted-runtime-credential-fixture>@g" \
  -e "s@$credential_fixture_3@<redacted-runtime-credential-fixture>@g" \
  -e "s@$text_fixture_1@<redacted-runtime-text-fixture>@g" \
  -e "s@$text_fixture_2@<redacted-runtime-text-fixture>@g" \
  -e "s@$text_fixture_3@<redacted-runtime-text-fixture>@g" \
  -e "s@$response_fixture_code@<redacted-response-code-fixture>@g" \
  -e "s@$raw_data_prefix@<redacted-raw-response-prefix>@g" \
  -e 's@Data(#".*"#.utf8)@Data(<redacted-structured-response-fixture>)@g' \
  "$raw_diff" > "$tmp"

for forbidden in \
  "$credential_fixture_1" \
  "$credential_fixture_2" \
  "$credential_fixture_3" \
  "$text_fixture_1" \
  "$text_fixture_2" \
  "$text_fixture_3" \
  "$raw_response_prefix" \
  "$raw_data_prefix" \
  "$response_fixture_code"; do
  if /usr/bin/grep -F -q -- "$forbidden" "$tmp"; then
    print -u2 'audit diff sanitization failed: forbidden fixture remains'
    exit 1
  fi
done

mv "$tmp" "$sanitized_diff"
trap - EXIT
print 'audit diff sanitized: credential-fixtures=3 text-fixtures=3 structured-response-fixtures=1 response-code-fixtures=1'
