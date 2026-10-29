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

A GitHub Action that downloads a Steam game and pushes it as a private OCI image to a registry
you control. CI can then launch the game in a container or build mods against the real game
assemblies. It defaults to RimWorld, and works for any Steam app you own that has a gamecrate
plugin.

The action does not do the work itself. It installs `@gamecrate/cli` with a game plugin and runs
`gamecrate steam build <game> --push --image <ref> --json`. Everything specific to a game lives
in the plugin: the app id, the depots, the branches, and the image variants. So most changes
here are about wiring, not about Steam. See `README.md` for the inputs and `examples/` for
consumer workflows.

## Project structure

- `action.yml` - the composite action: inputs, outputs, and the step order
- `scripts/build.sh` - runs one `gamecrate steam build` and turns its JSON into step outputs
- `scripts/reuse-existing.sh` - the no-credentials path: points a run at the published image
- `scripts/assert-private.sh` - fails the job when the pushed image is anonymously pullable
- `tests/` - bash tests and fixtures
- `examples/` - example workflows for consumers

## Setup and build

```bash
npm install    # devDependencies only, for semantic-release
# There is no build step. The action is action.yml plus bash.
```

## Testing

```bash
bash tests/test-reuse-existing.sh      # the reuse path, with a fake crane
shellcheck scripts/*.sh tests/*.sh     # shell lint
actionlint                             # workflow lint
```

- Run all three before committing. They are exactly what CI runs.
- Never delete, weaken, or rewrite a test to make a change pass.
- Do not claim that an interrupted or timed-out run passed.

`tests/test-reuse-existing.sh` is the only real test in the repo. It puts a fake `crane` on
`PATH` and checks three things: an existing tag comes back as a ref, a missing tag fails with a
reason, and the registry password never reaches `crane`'s argument list. That last one is why
the script pipes the password to `--password-stdin`.

Everything else is proved by a real workflow run, either `build-image.yml` here or a consumer's
own workflow. Say which one you did.

## The pipeline

`action.yml` is a composite action, and the step order is the design:

1. **Resolve the image ref.** Lowercases it, because OCI refs must be lowercase and
   `github.repository_owner` is not. Derives a `latest-<branch>` tag for the reuse path.
2. **Check for Steam credentials.** Missing ones route the run to step 3 and skip 4 through 7.
3. **Reuse the published image** and stop.
4. **Install gamecrate** and the plugin from npm.
5. **Restore the download cache**, keyed per app, branch and depot.
6. **Build and push** with `scripts/build.sh`, then **save the cache** when a cell built.
7. **Refuse to leave the image public**, then **wipe Steam credentials** under `if: always()`.

The private check and the credential wipe run either way, on purpose. The image still exists
when every cell skipped, and someone can flip it public in a registry UI long after the last
push.

## Results and outputs

`gamecrate steam build --json` prints an array with one entry per branch and variant. `build.sh`
reads it with `jq` and decides the step outputs from it:

- `downloaded=true` when at least one cell has `status == "built"`. That is what gates the cache
  save, because only a build brings in new bytes.
- `skipped=true` when nothing built.
- Any cell with `status == "failed"` prints a `::error::` line with its branch, variant and
  reason, then exits non-zero.
- `image-ref` is the first tag of the first cell that pushed one.

The table gamecrate prints goes to stderr so it lands in the job log. Only the JSON goes to
stdout, and `build.sh` redirects that to a file. When the command fails, the script prints that
file to stderr before exiting, so a failure is never silent.

`branch-password` is exported as `STEAM_BRANCH_PASSWORD_<BRANCH>` rather than a flag. A build of
two branches must not send one branch's password to both.

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
  a publisher's binaries is not allowed, and only the tooling here is MIT. `require-private`
  defaults to `true` and `assert-private.sh` enforces it by following the Distribution v2
  auth challenge, so it works on any spec-compliant registry.
- Steam credentials and registry tokens come from repository secrets, and the wipe step runs
  under `if: always()` so a failed run does not leave a session behind.
- A new input means two edits: `action.yml` and the input table in `README.md`. Other repos
  consume this action, so the inputs are a public API.
- Game facts belong in a gamecrate plugin, not in an input here. An input that only one game
  would ever set is a sign the plugin should declare it instead.
- This image is what every consuming repo builds against, so a break here breaks their CI
  before it breaks anything here. Bump consumers deliberately, not as a side effect.
