#!/usr/bin/env bash
# Point a run that has no Steam login at the image a credentialed run already pushed.
# A pull request from a fork gets no secrets, so it cannot build, but it can still pull.
#
# Requires: crane on PATH. Env: IMAGE (lowercase ref), BRANCH_TAG (latest-<branch>),
# REGISTRY, REGISTRY_USER, REGISTRY_PASSWORD. Prints the image ref to stdout, or fails
# when that tag has not been built yet.
set -euo pipefail

: "${IMAGE:?set IMAGE}"
: "${BRANCH_TAG:?set BRANCH_TAG}"
: "${REGISTRY:?set REGISTRY}"
: "${REGISTRY_USER:?set REGISTRY_USER}"
: "${REGISTRY_PASSWORD:?set REGISTRY_PASSWORD}"

printf '%s' "$REGISTRY_PASSWORD" | crane auth login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin >/dev/null

if ! crane manifest "$IMAGE:$BRANCH_TAG" >/dev/null 2>&1; then
    echo "::error::No Steam credentials and $IMAGE:$BRANCH_TAG does not exist yet." \
         "A run with credentials (a push to the default branch) has to build it first." >&2
    exit 1
fi

echo "$IMAGE:$BRANCH_TAG"
