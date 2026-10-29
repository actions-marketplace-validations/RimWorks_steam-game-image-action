#!/usr/bin/env bash
# Runs one `gamecrate steam build` and turns its JSON into step outputs.
set -euo pipefail

: "${GAME:?game}"
: "${IMAGE:?image}"

args=(steam build --game "$GAME" --push --no-load --image "$IMAGE" --json)
[ -n "${BRANCH:-}" ] && args+=(--beta "$BRANCH")
[ -n "${VARIANT:-}" ] && args+=(--variant "$VARIANT")
while read -r alias; do
  [ -n "$alias" ] && args+=(--alias "$alias")
done <<< "$(printf '%s' "${ALIASES:-}" | tr ',' '\n')"
[ -n "${BASE_IMAGE:-}" ] && args+=(--base "$BASE_IMAGE")
[ -n "${PLATFORM:-}" ] && args+=(--platform "$PLATFORM")
[ "${SKIP_IF_UNCHANGED:-true}" != "true" ] && args+=(--force)

# keyed per branch, because a build of two branches must not send one password to both
if [ -n "${STEAM_BRANCH_PASSWORD:-}" ] && [ -n "${BRANCH:-}" ]; then
  key="STEAM_BRANCH_PASSWORD_$(printf '%s' "$BRANCH" | tr '[:lower:]-' '[:upper:]_')"
  export "$key=$STEAM_BRANCH_PASSWORD"
fi

results="$RUNNER_TEMP/gamecrate-results.json"
# the table goes to stderr and reaches the log; only the JSON is stdout
status=0
gamecrate "${args[@]}" > "$results" || status=$?
if [ "$status" -ne 0 ]; then
  cat "$results" >&2 || true
  exit "$status"
fi

jq -c . "$results" > "$results.min"
{
  echo "results<<GAMECRATE_EOF"
  cat "$results.min"
  echo
  echo "GAMECRATE_EOF"
} >> "$GITHUB_OUTPUT"

# a cell that built is one the cache has new bytes for; all-skipped means nothing moved
built="$(jq -r '[.[] | select(.status == "built")] | length' "$results")"
[ "$built" -gt 0 ] && echo "downloaded=true" >> "$GITHUB_OUTPUT"
[ "$built" -eq 0 ] && echo "skipped=true" >> "$GITHUB_OUTPUT"

failed="$(jq -r '[.[] | select(.status == "failed")] | length' "$results")"
if [ "$failed" -gt 0 ]; then
  jq -r '.[] | select(.status == "failed") | "::error::\(.branch)/\(.variant): \(.reason)"' "$results" >&2
  exit 1
fi

# the first versioned tag of the first cell, which is what a consumer pulls
ref="$(jq -r 'first(.[] | select(.tags | length > 0) | .tags[0]) // empty' "$results")"
[ -n "$ref" ] && echo "image-ref=$IMAGE:$ref" >> "$GITHUB_OUTPUT"
exit 0
