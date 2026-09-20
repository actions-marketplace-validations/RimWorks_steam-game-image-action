# steam-game-image-action

[![Quality Gate Status](https://sonarcloud.io/api/project_badges/quality_gate?project=RimWorks_steam-game-image-action)](https://sonarcloud.io/summary/new_code?id=RimWorks_steam-game-image-action)

Downloads a Steam game with `steamcmd` and pushes it as a private OCI image to a registry you
control. CI can then build mods against the real shipped assemblies and launch the game in a
container. Defaults to RimWorld (app `294100`) but works for any Steam app you own.

This tool never publishes the game image. You build it from your own Steam-owned copy and push
it to your own private registry. Only the tooling here is open source (MIT). Redistributing the
publisher's game binaries is not allowed, and keeping the image private is on you.

## Quick start

Prime a steamcmd session once, locally, on an account that owns the game:

```sh
steamcmd +login your-steam-account     # complete Steam Guard
base64 -w0 ~/Steam/config/config.vdf   # copy this
```

Save the base64 blob as a repo secret named `STEAM_CONFIG_VDF`. The session expires eventually.
When it does, re-run these two commands and update the secret.

Then add a workflow:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions: { packages: write, contents: read }
    steps:
      - uses: RimWorks/steam-game-image-action@v1
        with:
          steam-username: your-steam-account
          steam-config-vdf: ${{ secrets.STEAM_CONFIG_VDF }}
          image: ghcr.io/${{ github.repository_owner }}/rimworld-game
          registry-password: ${{ secrets.GITHUB_TOKEN }}
```

That pushes `ghcr.io/you/rimworld-game:<version>`, `:latest` and a branch-scoped
`:latest-<branch>`, all private and labeled with `steam.buildid`.

The action then fails the job if that image is anonymously pullable, because a public game image
is redistribution. It follows the registry's own auth challenge, so it works on GHCR, Docker Hub,
GitLab, quay and anything else implementing the Distribution v2 spec. The check runs on every
invocation, including one the build-id gate skipped, because a package can be flipped to public
in the registry UI long after its last push. Set `require-private: false` to turn it off.

To keep the image fresh, copy [`examples/watch-and-build.yml`](examples/watch-and-build.yml). A
scheduled run compares the published buildid against your image's `steam.buildid` label and
downloads nothing when they match, so cron runs stay cheap.

## Launch the game

The runnable base ships a `run-headless` wrapper. It gives the game a virtual display, hands the
game user the directories Docker created for your mounts, then drops to an unprivileged user:

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

For a Windows game on a Linux runner, use `run-headless-windows` and pass Wine paths, where `Z:`
is the container root:

```sh
docker run --rm ghcr.io/you/rimworld-game-windows:latest \
  run-headless-windows 'Z:\game\RimWorldWin64.exe' '-logfile' 'Z:\out\Player.log'
```

## Build a mod against the real assemblies

A community reference package, such as `Krafs.Rimworld.Ref` for RimWorld, is usually the easier
path. Reach for the image when you need a member the reference package does not expose, or when
you want the exact assemblies a specific game build shipped.

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
builds.

A smaller image is enough for this. Set `include-paths: RimWorldLinux_Data/Managed` and
`runnable: false` to get the assemblies on a minimal base instead of the whole game. The full
runnable copy of this workflow is in
[`examples/build-mod-against-game.yml`](examples/build-mod-against-game.yml).

## Inputs

| input | default | notes |
|---|---|---|
| `steam-username` | `""` | account that owns the game. Empty means no Steam access, see below |
| `steam-config-vdf` | `""` | base64 of a steamcmd `config.vdf` (a secret) |
| `app-id` | `294100` | Steam app id (RimWorld) |
| `branch` | `public` | Steam branch, e.g. `1.5`, `1.4` |
| `branch-password` | `""` | for password-protected betas |
| `steam-platform` | `""` (the host's) | depot platform: `linux`, `windows`, `macos`. Pair `windows` with the Proton base |
| `image` | N/A | target ref without tag, e.g. `ghcr.io/you/rimworld-game` |
| `registry` / `registry-username` / `registry-password` | `ghcr.io` / actor / N/A | push auth (GHCR and `GITHUB_TOKEN` works) |
| `runnable` | `true` | `true` appends onto the xvfb base; `false` gives a minimal build-only base |
| `include-paths` | `""` (whole game) | space or newline separated subpaths, e.g. `RimWorldLinux_Data/Managed` |
| `skip-if-unchanged` | `true` | gate on the `steam.buildid` label of `:latest-<branch>` |
| `base-image` | the xvfb base | override, e.g. the Proton base for a Windows depot |

Outputs: `image-ref`, `version`, `buildid`, `skipped`. `image-ref` is the `image:version` ref
when the action built, and the `image:latest-<branch>` ref when the gate skipped, so it is
always pullable.

### Runs without Steam credentials

A pull request from a fork gets no repository secrets, so `steam-username` and
`steam-config-vdf` arrive empty. The action then skips steamcmd entirely and outputs the
`image:latest-<branch>` ref a credentialed run already pushed, with `skipped` set to `true`.
`registry-password` is still needed to pull it; `GITHUB_TOKEN` with `packages: read` is enough.
If that tag does not exist yet the action fails and says so, since only a run with credentials
can build it.

Three combinations cover most uses:

- **Runnable (default).** `runnable: true` with `include-paths` empty puts the whole game on the
  xvfb base, so you can launch it. It is about a gigabyte.
- **Build only.** `include-paths: RimWorldLinux_Data/Managed` with `runnable: false` gets you the
  managed assemblies on a minimal base. (`include-paths` is relative to the game install. The
  `*_Data/Managed` layout is a Unity convention.)
- **Windows on a Linux runner.** Set `steam-platform: windows` and point `base-image` at
  `ghcr.io/rimworks/steam-game-image-action/runtime-base-proton:latest`. That base carries Proton
  and Mesa's software Vulkan driver. A CI runner has no GPU, so the game renders on the CPU and
  boots slowly.

## How it works

`steamcmd` downloads the game. `crane append` layers it onto a public, game-free
[`runtime-base`](Dockerfile.runtime-base) image, needing no Docker daemon, and pushes to your
registry with a `steam.buildid` OCI label. That label is the only state the build-id gate needs.

Two caches keep it cheap. The build-id gate skips the whole download when the published buildid
matches the label on the branch's `latest-<branch>` tag. On a real rebuild, `actions/cache`
restores the prior install so `app_update` fetches only the changed files.

## License

MIT, see [LICENSE](LICENSE). Applies to this tooling only, not to any game content.
