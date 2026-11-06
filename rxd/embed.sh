#!/usr/bin/env bash
# Copy rxd, its two clients, its JS8 decoder and the callsign database's
# installer into setup.sh, replacing the body of each
#   write_file DEST MODE <<'MARKER'
# heredoc listed below. setup.sh is piped into a root shell as one file, so it
# carries them inline; this keeps those copies byte-identical to the sources.
# Running it again with nothing changed leaves setup.sh as is.
#
#   rxd/embed.sh           embed
#   rxd/embed.sh --check   change nothing; fail if any copy differs (build.sh)

set -euo pipefail

cd "$(dirname "$0")/.."

dst=setup.sh

# source, then the heredoc's opening line in setup.sh, then its marker.
EMBEDS=(
  "rxd/rxd.py"         "    write_file /usr/local/bin/rxd 0755 <<'RXD'"                       RXD
  "rxd/rxd_tui.py"     "    write_file /usr/local/bin/rxd-tui 0755 <<'RXDTUI'"                RXDTUI
  "rxd/web/index.html" "    write_file /usr/local/share/rxd/index.html 0644 <<'RXDWEB'"       RXDWEB
  "rxd/js8.py"         "    write_file /usr/local/lib/rxd/js8.py 0644 <<'RXDJS8'"             RXDJS8
  "rxd/callsign_db.py" "    write_file /usr/local/share/rxd/callsign_db.py 0644 <<'RXDCALLDB'" RXDCALLDB
)

check=false
case ${1:-} in
  --check) check=true ;;
  '') ;;
  *) echo "usage: rxd/embed.sh [--check]" >&2; exit 2 ;;
esac

fail() { echo "embed.sh: $*" >&2; exit 1; }

# What write_file writes is what bash read from the heredoc, cut of trailing
# newlines by $(cat) and given back exactly one. A source survives that byte
# for byte only if it ends in exactly one newline and holds no NUL, and the
# heredoc survives only if no line equals its marker. The heredocs are quoted,
# so $, backticks and backslashes pass through untouched.
vet() {
  local src=$1 marker=$2
  [[ -f $src ]] || fail "$src is missing"
  [[ -s $src ]] || fail "$src is empty"
  if [[ $(LC_ALL=C tr -d '\000' < "$src" | wc -c) != $(wc -c < "$src") ]]; then
    fail "$src contains a NUL byte, which a heredoc cannot carry"
  fi
  [[ $(tail -c 1 "$src" | od -An -c | tr -d ' ') == '\n' ]] \
    || fail "$src does not end in a newline"
  [[ $(tail -c 2 "$src" | od -An -c | tr -d ' ') != '\n\n' ]] \
    || fail "$src ends in a blank line, which write_file would drop"
  if grep -qxF "$marker" "$src"; then
    fail "$src has a line reading exactly '$marker', which would end its heredoc"
  fi
}

# The body of the heredoc that opens with $1 and ends at $2.
body() {
  awk -v open="$1" -v marker="$2" '
    on && $0 == marker { found = 1; exit }
    on { print }
    $0 == open { on = 1 }
    END { if (!found) exit 1 }
  ' "$dst"
}

tmp=$(mktemp "$dst.XXXXXX")
next=$(mktemp "$dst.XXXXXX")
trap 'rm -f "$tmp" "$next"' EXIT
cat "$dst" > "$tmp"

stale=()
for (( i = 0; i < ${#EMBEDS[@]}; i += 3 )); do
  src=${EMBEDS[i]} open=${EMBEDS[i+1]} marker=${EMBEDS[i+2]}

  vet "$src" "$marker"
  n=$(grep -cxF "$open" "$dst" || true)
  [[ $n == 1 ]] || fail "expected one $marker heredoc in $dst, found $n"

  if $check; then
    body "$open" "$marker" > "$next" || fail "unterminated $marker heredoc in $dst"
    cmp -s "$next" "$src" || stale+=("$src")
    continue
  fi

  awk -v open="$open" -v marker="$marker" -v src="$src" '
    skip && $0 == marker { skip = 0 }
    skip { next }
    { print }
    $0 == open {
      while ((getline line < src) > 0) print line
      close(src)
      skip = 1
    }
    END { if (skip) { print "unterminated " marker " heredoc" > "/dev/stderr"; exit 1 } }
  ' "$tmp" > "$next"
  cat "$next" > "$tmp"
done

if $check; then
  (( ${#stale[@]} == 0 )) \
    || fail "the copy in $dst differs from ${stale[*]}; run rxd/embed.sh"
  echo "setup.sh carries the current ${EMBEDS[0]} ${EMBEDS[3]} ${EMBEDS[6]} ${EMBEDS[9]} ${EMBEDS[12]}"
elif cmp -s "$tmp" "$dst"; then
  echo "setup.sh already carries the current rxd and its clients"
else
  cat "$tmp" > "$dst"   # in place, keeping setup.sh's mode
  echo "embedded rxd and its clients into setup.sh"
fi
