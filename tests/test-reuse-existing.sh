#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/reuse-existing.sh"

FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT

cat > "$FAKE/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
args="$*"
if [[ "$args" == *"--config"* ]]; then
    cat >> "$FAKE_STDIN_LOG"
    echo '{"token":"tok"}'
    exit 0
fi
if [[ "$args" == *"Authorization: Bearer"* ]]; then
    [[ "$args" == *"$WANT_TAG"* ]] && echo 200 || echo "${MISS_CODE:-404}"
    exit 0
fi
printf 'HTTP/1.1 401\r\nwww-authenticate: Bearer realm="https://auth.example/token",service="reg"\r\n401'
CURL
chmod +x "$FAKE/curl"
export PATH="$FAKE:$PATH"
export FAKE_LOG="$FAKE/log" FAKE_STDIN_LOG="$FAKE/stdin" WANT_TAG="latest-public"
: > "$FAKE_LOG"; : > "$FAKE_STDIN_LOG"
export IMAGE=ghcr.io/rimworks/game REGISTRY=ghcr.io REGISTRY_USER=bot REGISTRY_PASSWORD=hunter2

got="$(BRANCH_TAG=latest-public bash "$SCRIPT")"
if [[ "$got" != "ghcr.io/rimworks/game:latest-public" ]]; then
    echo "FAIL: existing tag got '$got'" >&2
    exit 1
fi
echo "PASS: existing tag -> $got"

if grep -q hunter2 "$FAKE_LOG"; then
    echo "FAIL: password reached curl's argument list" >&2
    exit 1
fi
if ! grep -q hunter2 "$FAKE_STDIN_LOG"; then
    echo "FAIL: password never reached curl at all, so the check proves nothing" >&2
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

if MISS_CODE=403 BRANCH_TAG=latest-beta bash "$SCRIPT" >/dev/null 2>"$FAKE/err"; then
    echo "FAIL: a refused token did not fail" >&2
    exit 1
fi
if grep -q "does not exist yet" "$FAKE/err"; then
    echo "FAIL: a 403 still reads as a missing image, which sends the reader hunting" >&2
    exit 1
fi
if ! grep -q "Actions access" "$FAKE/err"; then
    echo "FAIL: a refused token error does not name the access list" >&2
    exit 1
fi
echo "PASS: a refused token names the access list, not a missing image"
echo "all reuse tests passed"
