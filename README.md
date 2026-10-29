# steam-game-image-action

[![Quality Gate Status](https://sonarcloud.io/api/project_badges/quality_gate?project=RimWorks_steam-game-image-action)](https://sonarcloud.io/summary/new_code?id=RimWorks_steam-game-image-action)

Downloads a Steam game and pushes it as a private OCI image to a registry you control. CI can
then launch the game in a container or build mods against the real shipped assemblies. It
defaults to RimWorld, and works for any Steam app you own that has a gamecrate plugin.

The action installs [`@gamecrate/cli`](https://www.npmjs.com/package/@gamecrate/cli) plus a game
plugin, then runs one command: `gamecrate steam build <game> --push --image <ref> --json`.
gamecrate downloads the depots with `steamcmd` in a container and appends them onto a published
runtime base with `crane`. The plugin supplies the app id, the depots, and the branch and variant
matrix, so you name a game instead of a pile of Steam facts.

This tool never publishes the game image. You build it from your own Steam-owned copy and push
it to your own private registry. Only the tooling here is open source (MIT). Redistributing the
publisher's game binaries is not allowed, and keeping the image private is on you.

## Quick start

Prime a steamcmd session once, locally, on an account that owns the game:

```sh
steamcmd +login your-steam-account     # complete Steam Guard
base64 -w0 ~/Steam/config/config.vdf   # copy this
```

Save the base64 blob as a repo secret named `STEAM_CONFIG_VDF_B64`. The session expires eventually.
When it does, run these two commands again and update the secret.

Then add a workflow:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions: { packages: write, contents: read }
    steps:
      - uses: RimWorks/steam-game-image-action@v4
        with:
          game: rimworld
          steam-username: your-steam-account
          steam-config-vdf: ${{ secrets.STEAM_CONFIG_VDF_B64 }}
          image: ghcr.io/${{ github.repository_owner }}/rimworld-game
          registry-password: ${{ secrets.GITHUB_TOKEN }}
```

That pushes `ghcr.io/you/rimworld-game:<version>`, `:latest` and a branch-scoped
`:latest-<branch>`, all private and labeled with `steam.buildid`.

The action then fails the job if that image is anonymously pullable, because a public game image
is redistribution. It follows the registry's own auth challenge, so it works on GHCR, Docker Hub,
GitLab, quay and anything else that implements the Distribution v2 spec. The check runs on every
invocation, including one where every cell skipped, because someone can flip a package to public
in the registry UI long after its last push. Set `require-private: false` to turn it off.

To keep the image fresh, copy [`examples/watch-and-build.yml`](examples/watch-and-build.yml). A
scheduled run compares the published buildid against your image's `steam.buildid` label and
downloads nothing when they match, so cron runs stay cheap.

## Inputs

| input | default | notes |
|---|---|---|
| `game` | `rimworld` | the game the plugin provides |
| `plugin` | `""` | plugin packages, one per line. Empty means `@gamecrate/<game>` |
| `gamecrate-version` | `""` | version of `@gamecrate/cli` to install. Empty means latest |
| `steam-username` | `""` | account that owns the game. Empty means no Steam access, see below |
| `steam-config-vdf` | `""` | base64 of a steamcmd `config.vdf` (a secret) |
| `branch` | `public` | Steam branch, for example `1.5`. Empty means every branch the plugin declares |
| `branch-password` | `""` | for a password-protected beta branch |
| `variant` | `""` | one image variant. Empty means every variant the plugin declares |
| `image` | required | target ref without a tag, for example `ghcr.io/you/rimworld-game` |
| `registry` | `ghcr.io` | registry host for auth |
| `registry-username` | the GitHub actor | registry username |
| `registry-password` | required | registry token. For GHCR pass `secrets.GITHUB_TOKEN` with `packages: write` |
| `base-image` | `""` | override the published runtime base a variant appends onto |
| `platform` | `linux/amd64` | image platform |
| `require-private` | `true` | fail when the pushed image is anonymously pullable |
| `skip-if-unchanged` | `true` | skip a cell whose published buildid matches the image's `steam.buildid` label |

Outputs:

- `image-ref` is the ref to consume. It is the first versioned tag the build pushed, or the ref
  a credentialed run already pushed when this run had no secrets.
- `results` is a JSON array with one entry per branch and variant. Each entry carries its
  `status`, `reason` and `tags`.
- `skipped` is `true` when every cell skipped, or when the run had no Steam credentials.

A failed cell prints a `::error::` line naming the branch, the variant and the reason, and fails
the job.

### Runs without Steam credentials

A pull request from a fork gets no repository secrets, so `steam-username` and
`steam-config-vdf` arrive empty. The action then skips the build and outputs the
`image:latest-<branch>` ref a credentialed run already pushed, with `skipped` set to `true`.
`registry-password` is still needed to pull it, and `GITHUB_TOKEN` with `packages: read` is
enough. If that tag does not exist yet the action fails and says so, because only a run with
credentials can build it.

## Launch the game

The runnable variant ships a `run-headless` wrapper. It gives the game a virtual display, hands
the game user the directories Docker created for your mounts, then drops to an unprivileged
user:

```sh
docker run --rm ghcr.io/you/rimworld-game:latest run-headless /game/RimWorldLinux
```

That is the whole invocation. You do not need `--init`, `--user`, or a `HOME` override. Set
`SCREEN` to change the display geometry, which defaults to `1920x1080x24`.

A real CI run adds mounts and reads the results back:

```sh
mkdir -p "$PWD/out" "$PWD/config" && chmod 777 "$PWD/out" "$PWD/config"

docker run --rm \
  -v "$PWD/mods:/game/Mods:ro" \
  -v "$PWD/config:/home/app/.config/unity3d/Ludeon Studios/RimWorld by Ludeon Studios/Config" \
  -v "$PWD/out:/out" \
  ghcr.io/you/rimworld-game:latest \
  run-headless /game/RimWorldLinux -logfile /out/Player.log
```

`$HOME` in the image is `/home/app`. The game writes its saves and config under it, so mount
your config there and the game finds it.

**`chmod 777` every host directory the game writes to, including the config mount.** The game
runs as uid 1000 and your host directories do not belong to that user. RimWorld writes
`Knowledge.xml` and `LastPlayedVersion.txt` back into its config directory, so a read-only
config mount fails at the main menu with `UnauthorizedAccessException`.

The game's exit code is the container's exit code.

RimWorld has no official headless test mode. This image supplies a display and the native
libraries so a launch can proceed. You still need a test-runner mod that boots a scenario,
asserts and exits with a status. [Pickle](https://github.com/RimWorks/Rimworld-Pickle) is one.

For a Windows game on a Linux runner, build the plugin's Windows variant and use
`run-headless-windows`. Pass Wine paths, where `Z:` is the container root:

```sh
docker run --rm ghcr.io/you/rimworld-game-windows:latest \
  run-headless-windows 'Z:\game\RimWorldWin64.exe' '-logfile' 'Z:\out\Player.log'
```

That variant carries Proton and Mesa's software Vulkan driver. A CI runner has no GPU, so the
game renders on the CPU and boots slowly.

## Build a mod against the real assemblies

The image carries the exact assemblies a specific game build shipped, so what compiles in CI is
what runs on a player's machine. It also covers any Steam branch, including a beta.

Pull the image, copy the managed DLLs onto the runner, then build:

```yaml
- name: Stage real game assemblies from the image
  env:
    GAME_IMAGE: ghcr.io/${{ github.repository_owner }}/rimworld-game:latest
  run: |
    set -euo pipefail
    echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u "${{ github.actor }}" --password-stdin
    docker pull -q "$GAME_IMAGE"
    cid="$(docker create "$GAME_IMAGE")"
    docker cp "$cid:/game/RimWorldLinux_Data" "$RUNNER_TEMP/game/RimWorldLinux_Data"
    docker rm -f "$cid" >/dev/null
    test -f "$RUNNER_TEMP/game/RimWorldLinux_Data/Managed/Assembly-CSharp.dll"
```

Point your `.csproj` at the staged DLLs with a `Reference` and a `HintPath` guarded by
`Exists()`, then build. A fresh clone has no image, so an unguarded `HintPath` breaks local
builds. The shipped DLLs are not publicized, so source that touches a non-public member, or
puts `public override` on a protected one, fails with CS0122 or CS0507. Match the real access
levels, or add a publicizer. If the plugin declares a build-only variant, pass its name to
`variant` for a much smaller image. The full runnable copy of this workflow is in
[`examples/build-mod-against-game.yml`](examples/build-mod-against-game.yml).

## How it works

gamecrate asks Steam for the app info, compares the published buildid against the
`steam.buildid` label on the image's `latest-<branch>` tag, and skips the cell when they match.
On a real rebuild it downloads the depots with `steamcmd`, then `crane append` layers them onto
a public, game-free runtime base and pushes to your registry. No Docker daemon is involved in
the push.

`actions/cache` keeps the download cheap. It stores the install under
`~/.local/share/gamecrate/steam/apps`, keyed per app, branch and depot, so variants that share a
depot share a cache entry and `app_update` fetches only the changed files.

The Steam session is a live credential, so the last step wipes it under `if: always()`. A failed
run does not leave a login behind.

## License

MIT, see [LICENSE](LICENSE). Applies to this tooling only, not to any game content.
