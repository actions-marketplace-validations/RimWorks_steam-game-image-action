#!/usr/bin/env bash
# Fails when <registry>/<name> is anonymously pullable.
#   assert-private.sh <registry> <repository-name>
# Follows the Distribution v2 auth challenge, so it works on ghcr, Docker Hub, GitLab,
# quay and anything else implementing the spec.
set -uo pipefail

HTTPS_ONLY=(--proto "=https" --proto-redir "=https")

REGISTRY="${1:?usage: assert-private.sh <registry> <name>}"
NAME="${2:?repository name}"

# docker hub serves its v2 api from a different host than the one you docker login to
api="$REGISTRY"
[[ "$api" == "docker.io" ]] && api="registry-1.docker.io"

url="https://${api}/v2/${NAME}/tags/list"
headers="$(curl -sS -o /dev/null -D - -w '%{http_code}' "${HTTPS_ONLY[@]}" "$url")" || {
  echo "could not reach ${api}; treating as unverified" >&2
  exit 1
}
code="$(printf '%s' "$headers" | tail -1)"

# a registry that answers without a challenge has already served it anonymously
if [[ "$code" == "401" ]]; then
  challenge="$(printf '%s' "$headers" | grep -i '^www-authenticate' | tr -d '\r')"
  realm="$(printf '%s' "$challenge" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')"
  service="$(printf '%s' "$challenge" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"

  if [[ -n "$realm" ]]; then
    token="$(curl -sS "${HTTPS_ONLY[@]}" --get "$realm" \
      --data-urlencode "service=${service}" \
      --data-urlencode "scope=repository:${NAME}:pull" \
      | jq -r '.token // .access_token // empty')" || token=''
    if [[ -n "$token" ]]; then
      code="$(curl -sS -o /dev/null -w '%{http_code}' "${HTTPS_ONLY[@]}" \
        -H "Authorization: Bearer ${token}" "$url")"
    fi
  fi
fi

if [[ "$code" == "200" ]]; then
  echo "::error::${api}/${NAME} is anonymously pullable and contains the game." \
       "Set the package to private before running this again." >&2
  exit 1
fi

echo "not anonymously pullable (HTTP ${code})"
