#!/usr/bin/env bash
# build.sh against a fake gamecrate. The fake refuses what the real binary refuses.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../scripts/build.sh"
fails=0

setup() {
  work="$(mktemp -d)"
  export RUNNER_TEMP="$work"
  export GITHUB_OUTPUT="$work/out"
  : > "$GITHUB_OUTPUT"
  bin="$work/bin"
  mkdir -p "$bin"
  export PATH="$bin:$PATH"
}

# the real command writes its JSON to stdout and refuses a build with no --image
fake_gamecrate() {
  cat > "$bin/gamecrate" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$work/argv"
case " \$* " in
  *" --image "*) ;;
  *) echo "gamecrate: --image is required with --push" >&2; exit 2 ;;
esac
cat <<'JSON'
$1
JSON
FAKE
  chmod +x "$bin/gamecrate"
}

check() {
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    echo "  want: $3"
    echo "  got:  $2"
    fails=$((fails + 1))
  fi
}

setup
fake_gamecrate '[{"branch":"public","variant":"linux","status":"built","reason":"forced","tags":["1.6.4871-linux","latest-linux"]}]'
GAME=atlas IMAGE=ghcr.io/me/atlas BRANCH=public bash "$script" > /dev/null
check "a built cell reports the versioned tag" \
  "$(grep '^image-ref=' "$GITHUB_OUTPUT")" "image-ref=ghcr.io/me/atlas:1.6.4871-linux"
check "a built cell marks the cache dirty" \
  "$(grep -c '^downloaded=true' "$GITHUB_OUTPUT")" "1"
check "the branch reaches gamecrate as --beta" \
  "$(grep -c -- '--beta public' "$work/argv")" "1"
check "the game reaches gamecrate as --game, never as a positional" \
  "$(grep -c -- '--game atlas' "$work/argv")" "1"
check "no bare game argument survives before the flags" \
  "$(grep -c -- 'steam build --game' "$work/argv")" "1"
check "a push never loads the image into the runner's docker daemon" \
  "$(grep -c -- '--no-load' "$work/argv")" "1"

setup
fake_gamecrate '[{"branch":"public","variant":"linux","status":"skipped","reason":"up-to-date","tags":[]}]'
GAME=atlas IMAGE=ghcr.io/me/atlas bash "$script" > /dev/null
check "an all-skipped run says so and leaves the cache alone" \
  "$(grep -c '^skipped=true' "$GITHUB_OUTPUT")" "1"
check "an all-skipped run saves no cache" \
  "$(grep -c '^downloaded=true' "$GITHUB_OUTPUT" || true)" "0"

setup
fake_gamecrate '[{"branch":"public","variant":"linux","status":"failed","reason":"crane push failed","tags":[]}]'
if GAME=atlas IMAGE=ghcr.io/me/atlas bash "$script" > /dev/null 2>"$work/err"; then
  echo "FAIL: a failed cell must fail the step"
  fails=$((fails + 1))
else
  check "a failed cell names the branch and the reason" \
    "$(grep -c 'public/linux: crane push failed' "$work/err")" "1"
fi

setup
fake_gamecrate '[{"branch":"version-1.6","variant":"linux","status":"skipped","reason":"up-to-date","tags":["latest-version-1.6","1.6"]}]'
GAME=atlas IMAGE=ghcr.io/me/atlas BRANCH=version-1.6 bash "$script" > /dev/null
check "a skipped cell that kept its tags still reports a ref" \
  "$(grep '^image-ref=' "$GITHUB_OUTPUT")" "image-ref=ghcr.io/me/atlas:latest-version-1.6"

setup
cat > "$bin/gamecrate" <<'FAKE'
#!/usr/bin/env bash
echo "gamecrate: unknown flag --alias" >&2
exit 7
FAKE
chmod +x "$bin/gamecrate"
set +e
GAME=atlas IMAGE=ghcr.io/me/atlas bash "$script" > /dev/null 2>&1
code=$?
set -e
check "a gamecrate that exits non-zero fails the step with its own code" "$code" "7"

setup
fake_gamecrate '[]'
GAME=atlas IMAGE=ghcr.io/me/atlas BRANCH=phoenix STEAM_BRANCH_PASSWORD=hunter2 bash "$script" > /dev/null
check "a beta password never reaches the argv" \
  "$(grep -c hunter2 "$work/argv" || true)" "0"

[ "$fails" -eq 0 ] || { echo "$fails test(s) failed"; exit 1; }
echo "all build tests passed"
