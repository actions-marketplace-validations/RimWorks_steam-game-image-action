#!/usr/bin/env bash
# Guards scripts/reuse-existing.sh with a fake crane: the ref comes back when the tag exists,
# the script fails loudly when it does not, and the password never lands on the command line.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/reuse-existing.sh"

FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
cat > "$FAKE/crane" <<'CRANE'
#!/usr/bin/env bash
case "$1" in
    auth) cat >/dev/null; echo "login ok $*" >> "$FAKE_LOG" ;;
    manifest) [[ "$2" == "ghcr.io/rimworks/game:latest-public" ]] || exit 1 ;;
    *) exit 2 ;;
esac
CRANE
chmod +x "$FAKE/crane"
export PATH="$FAKE:$PATH"
export FAKE_LOG="$FAKE/log"
export IMAGE=ghcr.io/rimworks/game REGISTRY=ghcr.io REGISTRY_USER=bot REGISTRY_PASSWORD=hunter2

got="$(BRANCH_TAG=latest-public bash "$SCRIPT")"
if [[ "$got" != "ghcr.io/rimworks/game:latest-public" ]]; then
    echo "FAIL: existing tag got '$got'" >&2
    exit 1
fi
echo "PASS: existing tag -> $got"

if grep -q hunter2 "$FAKE_LOG"; then
    echo "FAIL: password reached crane's argument list" >&2
    exit 1
fi
echo "PASS: password stays on stdin"

if BRANCH_TAG=latest-beta bash "$SCRIPT" >/dev/null 2>"$FAKE/err"; then
    echo "FAIL: missing tag did not fail" >&2
    exit 1
fi
if ! grep -q "does not exist yet" "$FAKE/err"; then
    echo "FAIL: missing tag error did not say why" >&2
    exit 1
fi
echo "PASS: missing tag fails with a reason"
echo "all reuse tests passed"
