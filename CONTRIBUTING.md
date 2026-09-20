# Contributing to steam-game-image-action

## AI usage

Vibecoding is not welcome here. Use AI if it helps, but read what it wrote and understand it
before it lands. You own what ships whether or not a model typed it.

Nobody can stop you from working the way you want to. Guardrails are the next best thing, and
the rest of this file is those guardrails. Run the tests, match the code around yours, stay
inside the request, and report failures instead of guessing past them.

If AI helped with a commit in any way, add an `AI-assisted: <tool name>` trailer to the
commit message.

Agents: if the user commits by hand, remind them to add the trailer.

## Project overview

A GitHub Action that downloads a Steam game with `steamcmd` and pushes it as a private OCI
image to a registry you control. CI can then build mods against the real game assemblies and
launch the game in a container. It defaults to RimWorld (app `294100`), but works for any
Steam app you own. Most of the logic lives in `action.yml` and the bash under `scripts/`. See
`README.md` for the inputs and `examples/` for consumer workflows.

## Project structure

- `action.yml` - the composite action: inputs, outputs, and most of the logic
- `scripts/` - bash helpers: `build-image.sh`, `published-buildid.sh`, `steam-login.sh`,
  `assert-private.sh`, and the headless launchers (`run-headless.sh`,
  `run-headless-windows.sh`, `headless-common.sh`) that get baked into the runtime bases
- `Dockerfile.runtime-base`, `Dockerfile.runtime-base-proton` - the runtime base images
- `tests/` - bash tests and fixtures
- `examples/` - example workflows for consumers

## Setup and build

```bash
npm install    # devDependencies only, for semantic-release
# There is no build step. The action is action.yml plus bash.
```

## Testing

```bash
bash tests/test-published-buildid.sh   # the parser tests
shellcheck scripts/*.sh tests/*.sh     # shell lint
actionlint                             # workflow lint
```

- Run all three before committing. They are exactly what CI runs.
- Never delete, weaken, or rewrite a test to make a change pass.
- Do not claim that an interrupted or timed-out run passed.

## The pipeline

`action.yml` is a composite action, and the step order is the design:

1. **Install steamcmd, crane, jq.** crane's tarball hash is pinned in an input, and bumping
   `crane-version` without `crane-sha256` fails the step on purpose. steamcmd is not pinned -
   Valve ships it from one unversioned URL, so there is no stable hash to pin to.
2. **Steam login** writes `config.vdf` from the base64 secret.
3. **Resolve base image** picks the base, lowercases the image ref (OCI refs must be
   lowercase and `github.repository_owner` is not), and derives a `latest-<branch>` tag.
4. **Build-id gate** decides whether there is anything to do at all.
5. **Restore cache, download, verify, save cache.**
6. **Build and push** with crane, stamping the `steam.buildid` label.
7. **Refuse to leave the image public**, then **wipe Steam credentials** under `if: always()`.

Steps 4 onward are all `if: steps.gate.outputs.skipped != 'true'`, with two deliberate
exceptions: the private check and the credential wipe run either way. The image still exists
when the build was skipped, and it can be flipped public in a registry UI long after the last
push.

## The build-id gate

`published-buildid.sh` asks steamcmd for the app info and pulls the buildid out of the nested
VDF. **The parse is anchored on purpose:** `branches` block first, then the requested branch,
then its first `buildid`. The branch name appears in several places in that output. An
unanchored grep returns the wrong branch's id, and the action then builds or skips against a
number that means nothing. `tests/test-published-buildid.sh` is the only real test in the
repo, and it exists to hold that parse still.

The gate compares the published id to the `steam.buildid` label on `IMAGE:latest-<branch>`
and skips when they match. Its `published=` and `built=` lines explain every skip, so read
those two numbers first. A skip that looks wrong is usually an empty `published` from a
steamcmd hiccup rather than a genuine match.

A failed lookup prints nothing, and the gate tolerates that instead of failing. The verify
step treats an empty `WANT` the same way, so a steamcmd hiccup degrades to building rather
than to a wrong skip.

The install cache keys on that same buildid. The exact key never hits on a real rebuild,
because the gate only lets you here when the buildid changed. The prefix `restore-keys` does
the work instead, restoring the previous install so `app_update` fetches a delta.

`appmanifest_<app>.acf` is the proof the download worked: `StateFlags` has to be `4` and its
`buildid` has to match. A partial install otherwise ships as a complete image.

## Bases and runnability

| `runnable` | Base | For |
| --- | --- | --- |
| `true` (default) | `runtime-base` | Launching the game in a container: xvfb and the native deps |
| `false` | `debian:stable-slim` | Building mods against the assemblies, nothing launches |

`base-image` overrides both. Pair `runnable: false` with `include-paths` (for example
`RimWorldLinux_Data/Managed`) for a reference image that is a fraction of the size.

`steam-platform: windows` needs the Proton base, not the default one, which has no wine.
Proton renders D3D through DXVK and DXVK needs a Vulkan driver, so the Proton base carries
Mesa's lavapipe for GPU-less runners. **Wine's own OpenGL path is not a fallback** - it hangs
RimWorld on boot whether or not the display is real.

`runtime-base.yml` builds and publishes both bases publicly. They contain no game, which is
what makes that legal. The game layer only ever lands in the private image.

## Code style

- Linter: shellcheck for shell, actionlint for workflows. There is no formatter, so follow the
  patterns already in neighboring scripts: `#!/usr/bin/env bash` and a short comment saying
  what the script is for.
- Do not add comments that restate the code.
- Do not reformat code you are not otherwise changing.

## Git workflow

- Commit format: Angular Conventional Commits, one line, lowercase.
- All CI checks must pass. semantic-release tags a release from every push to `main`.

## Other

- **Never make the built game image public, and never commit game binaries.** Redistributing
  a publisher's binaries is not allowed; only the tooling here is MIT. `require-private`
  defaults to `true` and `assert-private.sh` enforces it by following the Distribution v2
  auth challenge, so it works on any spec-compliant registry.
- Steam credentials and registry tokens come from repository secrets, and the wipe step runs
  under `if: always()` so a failed run does not leave a session behind.
- A new input means two edits: `action.yml` and the input table in `README.md`. The action is
  consumed from other repos, so the inputs are a public API.
- There is no way to run this locally. shellcheck, actionlint and the parser test are the
  whole local story; everything else is proved by a real workflow run (`build-image.yml` here,
  or a consumer's `game-image.yml`). Say which one you did.
- This image is what every consuming repo builds against, so a break here breaks their CI
  before it breaks anything here. Bump consumers deliberately, not as a side effect.
