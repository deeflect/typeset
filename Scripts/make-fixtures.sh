#!/bin/sh
# Generates large synthetic Markdown fixtures for perf/scroll testing.
# These are gitignored (see .gitignore) — regenerate locally as needed:
#   ./Scripts/make-fixtures.sh
set -eu

cd "$(dirname "$0")/.."
OUT_DIR="Tests/Fixtures/generated"
mkdir -p "$OUT_DIR"

generate() {
  target_bytes=$1
  out_file=$2
  : > "$out_file"
  i=0
  while [ "$(wc -c < "$out_file" | tr -d ' ')" -lt "$target_bytes" ]; do
    i=$((i + 1))
    {
      echo "## Section $i"
      echo
      echo "Paragraph $i with some **bold**, _italic_, and \`inline code\`."
      echo
      echo "| Col A | Col B |"
      echo "| ----- | ----- |"
      echo "| $i    | $((i * 2)) |"
      echo
      echo '```swift'
      echo "let value_$i = $i"
      echo '```'
      echo
      echo "- [ ] task $i"
      echo "- [x] task $((i + 1))"
      echo
    } >> "$out_file"
  done
  echo "Wrote $out_file ($(wc -c < "$out_file" | tr -d ' ') bytes)"
}

generate 1000000 "$OUT_DIR/large-1mb.md"
generate 10000000 "$OUT_DIR/large-10mb.md"
