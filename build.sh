#!/usr/bin/env bash
# Stage setup.sh for deployment, refusing to publish a script that is broken
# or truncated -- whatever lands here gets piped straight into a root shell
# by the install line. These checks came from .github/workflows/publish-rx.yml,
# which this replaces.

set -euo pipefail

script=setup.sh

bash -n "$script"

head -1 "$script" | grep -qx '#!/usr/bin/env bash' \
  || { echo "missing or unexpected shebang" >&2; exit 1; }

# The body lives inside main(); without the trailing invocation the published
# file would parse cleanly and then do nothing at all.
tail -1 "$script" | grep -qx 'main "\$@"' \
  || { echo "script does not end with 'main \"\$@\"'" >&2; exit 1; }

# setup.sh carries rxd inline, generated from rxd/rxd.py. Publishing a stale
# copy would install a different rxd from the one in the repo.
embedded=$(awk '
  $0 == "RXD" && on { exit }
  on { print }
  $0 == "    write_file /usr/local/bin/rxd 0755 <<'"'"'RXD'"'"'" { on = 1 }
' "$script")
[[ -n $embedded ]] \
  || { echo "no rxd heredoc found in $script" >&2; exit 1; }
[[ $embedded == "$(cat rxd/rxd.py)" ]] \
  || { echo "the rxd copy in $script differs from rxd/rxd.py; run rxd/embed.sh" >&2; exit 1; }

rm -rf dist
mkdir -p dist
install -m 0644 "$script" dist/setup.sh

# Identifies the deployed commit so the fallback workflow can tell whether
# Cloudflare already published this tree.
#
# Read it from the checkout rather than the environment. Workers Builds sets
# WORKERS_CI_COMMIT_SHA to the *branch name* for a manually started build, and
# the fallback compares this value against github.sha -- so trusting the
# variable would leave a deployed site permanently looking stale and make the
# fallback redeploy on every push, which is precisely what it exists to avoid.
sha=$(git rev-parse HEAD 2>/dev/null || echo "${WORKERS_CI_COMMIT_SHA:-${GITHUB_SHA:-local}}")
printf '%s\n' "$sha" > dist/.build-id

echo "verified and staged $(wc -l < "$script") lines"
