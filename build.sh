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

# rxd is not in here: setup.sh installs a pinned pid1/rxd release, checked by
# SHA-256. Refuse to publish a placeholder pin.
grep -qE '^    local RXD_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$script" \
  || { echo "setup.sh has no RXD_VERSION=X.Y.Z" >&2; exit 1; }
grep -qE '^    local RXD_SHA256=[0-9a-f]{64}$' "$script" \
  || { echo "setup.sh has no 64-hex RXD_SHA256" >&2; exit 1; }

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
