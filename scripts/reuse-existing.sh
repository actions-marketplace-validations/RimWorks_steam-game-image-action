#!/usr/bin/env bash
# Point a run that has no Steam login at the image a credentialed run already pushed.
# Follows the Distribution v2 auth challenge with curl, the same way assert-private.sh
# does, so it needs nothing on PATH that ubuntu-latest does not already ship.
# Env: IMAGE, BRANCH_TAG, REGISTRY, REGISTRY_USER, REGISTRY_PASSWORD. Prints the ref.
set -euo pipefail

: "${IMAGE:?set IMAGE}"
: "${BRANCH_TAG:?set BRANCH_TAG}"
: "${REGISTRY:?set REGISTRY}"
: "${REGISTRY_USER:?set REGISTRY_USER}"
: "${REGISTRY_PASSWORD:?set REGISTRY_PASSWORD}"

HTTPS_ONLY=(--proto "=https" --proto-redir "=https")
ACCEPT=(
    -H "Accept: application/vnd.oci.image.index.v1+json"
    -H "Accept: application/vnd.oci.image.manifest.v1+json"
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json"
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
)

api="$REGISTRY"
[[ "$api" == "docker.io" ]] && api="registry-1.docker.io"

name="${IMAGE#"${REGISTRY}/"}"
url="https://${api}/v2/${name}/manifests/${BRANCH_TAG}"

fetch_token() {
    local realm="$1" service="$2"
    printf 'user = "%s:%s"\n' "$REGISTRY_USER" "$REGISTRY_PASSWORD" \
        | curl -sS "${HTTPS_ONLY[@]}" --config - --get "$realm" \
            --data-urlencode "service=${service}" \
            --data-urlencode "scope=repository:${name}:pull" \
        | jq -r '.token // .access_token // empty'
}

headers="$(curl -sS -I -o /dev/null -D - -w '%{http_code}' "${HTTPS_ONLY[@]}" "${ACCEPT[@]}" "$url")" || {
    echo "::error::could not reach ${api} to look up ${IMAGE}:${BRANCH_TAG}." >&2
    exit 1
}
code="$(printf '%s' "$headers" | tail -1)"

if [[ "$code" == "401" ]]; then
    challenge="$(printf '%s' "$headers" | grep -i '^www-authenticate' | tr -d '\r')"
    realm="$(printf '%s' "$challenge" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')"
    service="$(printf '%s' "$challenge" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
    token=''
    [[ -n "$realm" ]] && token="$(fetch_token "$realm" "$service")"
    if [[ -z "$token" ]]; then
        echo "::error::${api} refused the registry credentials for ${name}." >&2
        exit 1
    fi
    code="$(curl -sS -I -o /dev/null -w '%{http_code}' "${HTTPS_ONLY[@]}" "${ACCEPT[@]}" \
        -H "Authorization: Bearer ${token}" "$url")"
fi

if [[ "$code" == "401" || "$code" == "403" ]]; then
    echo "::error::${api} refused this token for ${name} (HTTP ${code}), so whether" \
         "$IMAGE:$BRANCH_TAG exists is unknown. An org package carries its own Actions access" \
         "list, and a role there overrides permissions: packages: write. Check that list before" \
         "looking for a missing image." >&2
    exit 1
fi

if [[ "$code" != "200" ]]; then
    echo "::error::No Steam credentials and $IMAGE:$BRANCH_TAG does not exist yet (HTTP ${code})." \
         "A run with credentials (a push to the default branch) has to build it first." >&2
    exit 1
fi

echo "$IMAGE:$BRANCH_TAG"
