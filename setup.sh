#!/usr/bin/env bash
# setup.sh  Fetch the pinned upstream toolchain listed in versions.lock into ./libs.
#   Safe to re-run: existing clones are fetched and checked out at the pinned commit;
#   clones with local changes are skipped. Nothing outside ./libs is touched.
#   Requires: git, bash.
#
# Usage:
#   ./setup.sh            fetch/check out every repo in versions.lock
#   ./setup.sh pulseg     fetch/check out just one

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$ROOT/versions.lock"
LIBS="$ROOT/libs"
ONLY="${1:-}"

[ -f "$LOCK" ] || { echo "error: no versions.lock next to setup.sh" >&2; exit 1; }
mkdir -p "$LIBS"

fail=0

while read -r name url sha ref; do
    case "$name" in ''|\#*) continue ;; esac
    [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue

    dir="$LIBS/$name"
    printf '\n=== %s (%s @ %s)\n' "$name" "$ref" "${sha:0:8}"

    if [ -d "$dir/.git" ]; then
        # Never overwrite local edits to an upstream clone.
        if [ -n "$(git -C "$dir" status --porcelain)" ]; then
            echo "    SKIPPED: $dir has uncommitted local changes." >&2
            echo "    Commit, stash, or delete the directory, then re-run." >&2
            fail=1
            continue
        fi
        current="$(git -C "$dir" rev-parse HEAD)"
        if [ "$current" = "$sha" ]; then
            echo "    already at pinned commit"
            continue
        fi
        echo "    fetching..."
        git -C "$dir" fetch --quiet origin
    else
        echo "    cloning..."
        rm -rf "$dir"
        git clone --quiet "$url" "$dir"
    fi

    if ! git -C "$dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        echo "    ERROR: commit $sha not found in $url" >&2
        echo "    The pin may reference a force-pushed or deleted commit." >&2
        fail=1
        continue
    fi

    git -C "$dir" -c advice.detachedHead=false checkout --quiet "$sha"
    echo "    checked out $(git -C "$dir" rev-parse --short HEAD)"
done < "$LOCK"

if [ "$fail" -ne 0 ]; then
    printf '\n*** setup finished with errors (see above) ***\n' >&2
    exit 1
fi

cat <<'MSG'

Done. In MATLAB:

    run('<this-folder>/matlab/startup_pulseq.m')

then run a sequence writer; see README.md.
MSG
