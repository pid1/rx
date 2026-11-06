#!/usr/bin/env bash
# Copy rxd/rxd.py into setup.sh, replacing the body of the
#   write_file /usr/local/bin/rxd 0755 <<'RXD'
# heredoc. setup.sh is piped into a root shell as one file, so it carries rxd
# inline; this keeps that copy identical to the source. build.sh fails when
# the two differ. Running it again with nothing changed leaves setup.sh as is.

set -euo pipefail

cd "$(dirname "$0")/.."

src=rxd/rxd.py
dst=setup.sh
open="    write_file /usr/local/bin/rxd 0755 <<'RXD'"

# A line reading exactly RXD would end the heredoc early.
if grep -qx 'RXD' "$src"; then
  echo "$src has a line reading exactly 'RXD', which would end the heredoc" >&2
  exit 1
fi

n=$(grep -cxF "$open" "$dst" || true)
[[ $n == 1 ]] || { echo "expected one rxd heredoc in $dst, found $n" >&2; exit 1; }

tmp=$(mktemp "$dst.XXXXXX")
trap 'rm -f "$tmp"' EXIT

awk -v open="$open" -v src="$src" '
  skip && $0 == "RXD" { skip = 0 }
  skip { next }
  { print }
  $0 == open {
    while ((getline line < src) > 0) print line
    close(src)
    skip = 1
  }
  END { if (skip) { print "unterminated rxd heredoc" > "/dev/stderr"; exit 1 } }
' "$dst" > "$tmp"

if cmp -s "$tmp" "$dst"; then
  echo "setup.sh already carries the current rxd/rxd.py"
else
  cat "$tmp" > "$dst"   # in place, keeping setup.sh's mode
  echo "embedded rxd/rxd.py into setup.sh"
fi
