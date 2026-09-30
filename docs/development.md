# Development

How to set up a machine, what the checks are, and how the repo is wired for
humans and coding agents. The rules themselves are in `AGENTS.md`; building
and flashing the image is `README.md` ("Build from source") and `INSTALL.md`.

## Machines

| Machine | Lanes | Notes |
|---|---|---|
| Linux desktop (petronijus-PC) | all but `build-ios` | the image builds run here too (Docker, the warm pmbootstrap volume) |
| MacBook | all (`just ci`) | Docker Desktop for the docker lane; the only machine with the iOS build |
| macOS VM (Proxmox 108) | iOS release | driven by the nexusq-ios-release agent, not by `just` |
| Windows | none | not set up for the checks; the image build runs from PowerShell (Git Bash rewrites `/src` in `docker run`) |

There is deliberately no hosted CI: the recipes are the CI, and the pre-push
hook runs the fast lane on every push.

## Toolchain

| Tool | Version | Why pinned |
|---|---|---|
| Flutter | 3.47.5 | `dart format` output and the analyzer are tied to the SDK |
| ktlint | 1.8.0 | its fixes change between releases |
| ruff | 0.16.9 (`tools/dev/format.sh`, fetched by uvx) | formatter output changes between releases |
| Python | 3.14 via uv | the device runs Alpine's 3.14; the host tests run the same minor |
| python3 | ≥ 3.9 | the Claude Code hooks and the docs check (standard library only) |
| shellcheck | ≥ 0.10 | `source-path=SCRIPTDIR` and reasons after directives |
| e2fsprogs | any | the OTA-parity and A/B suites build ext4 images (`mkfs.ext4 -d`, `debugfs`) |
| cc, make, libpulse headers | any | Linux: the C unit tests build on the host. macOS: they build in an Alpine container (the daemons use Linux APIs), so Docker is part of the fast lane there |
| Docker | any | the docker test lane, the ALSA integration test, the image build |
| just, lefthook, gitleaks, uv | current | task runner, git hooks, secret scan, Python |

`just doctor` checks all of it and prints the fix for anything missing.

### macOS

```sh
brew install just lefthook gitleaks uv shellcheck ktlint e2fsprogs
```

e2fsprogs is keg-only; `tools/dev/test-shell.sh` puts it on PATH itself.
Flutter is a git checkout of the tag.

### Linux

`apt install shellcheck e2fsprogs build-essential libpulse-dev docker.io`; the rest from
Homebrew on Linux (`brew install just lefthook gitleaks uv ktlint`) or the
projects' own installers. Flutter is a git checkout of the tag.

### Then, in every clone

```sh
just setup
```

## Checks

| Recipe | Runs | When |
|---|---|---|
| `just check` | `fmt-check`, `lint`, `lint-docs`, `test-py`, `test-c`, `test-dart`, `test-sh` (~25 s) | pre-push hook; Claude Code Stop hook |
| `just fmt-check` | ruff format + lint, `dart format`, ktlint, shellcheck, `just --fmt` | |
| `just lint` | `flutter analyze --fatal-infos` | |
| `just lint-docs` | `tools/dev/docs-check.py`: every `just` recipe, relative link, heading anchor, repo path in inline code and `@import` the docs name exists; AGENTS.md and CLAUDE.md within 200 lines. `HANDOFF.md` and the dated notes are history and excluded | pre-commit hook, `just check` |
| `just test-py` | every `*/tests/test_*.py` suite with `python -m unittest` on Python 3.14 | |
| `just test-c` | `make test` in nexusqd, nq-healthd, nexusq-alsa-vol (`tools/dev/test-c.sh`: host cc on Linux, Alpine elsewhere) | |
| `just test-dart` | `flutter test` in `companion/app` | |
| `just test-sh` | the shell suites without `# needs: docker` | |
| `just test-sh-docker` | the shell suites that run the code in an Alpine container playing the device | `just ci` |
| `just test-alsa-integration` | the ALSA volume plugin against a real PulseAudio in Alpine | `just ci` |
| `just build-apk` / `build-ios` | debug builds of the companion app | `just ci` |
| `just ci` | all of the above | before a commit that is meant to be pushed |

What the tests cover:

- **Python** — the daemons' logic behind their edges (subprocess, sockets and
  paths mocked): control's protocol verbs, EQ math, volume, Roon/AirPlay/
  Spotify transports; the MQTT client and Home Assistant discovery; BT
  pairing; WiFi setup; the diag report's accounting; device tools (HDMI, NFC
  payload, the UAC2 silence producer).
- **C** — nexusqd's effects, compositor, themes and control socket;
  nq-healthd's counters against fixture trees; the ALSA volume scale.
- **Shell** — the device scripts' logic with stubbed tools (WiFi watchdog,
  loopbacks, librespot cache), and in containers the upgrade and A/B paths
  (`.post-upgrade` migrations, the persist store, the first-boot split, the
  kernel OTA identity).
- **Dart** — the app's state and widgets, the protocol client, Spotify.
- **Repo tripwires** (`tests/test_aports.py`) — every kernel patch is applied,
  every aport file is in `source=`, the shipped nq-healthd is the tested one.

None of this runs on the device. A change that reaches it needs a build, a
flash or `apk upgrade`, and the full diagnostic sweep (the nexusq-diag agent).

## Git hooks (lefthook)

| Hook | Does |
|---|---|
| pre-commit | formats staged files and re-stages them; gitleaks scans the staged diff; the docs check |
| commit-msg | Conventional Commits, subject ≤ 72 characters; also accepts `autosync(<branch>): …` |
| pre-push | `just check` |

ai-config's project-sync commits and pushes this repo at the end of a
session; the hooks run for it too, and a failing hook stops that autosync
rather than pushing a broken tree. Personal overrides go into
`lefthook-local.yml` (gitignored).

The one-off conversion to ruff, `dart format` and ktlint (2026-09-29) is in
`.git-blame-ignore-revs`; `git config blame.ignoreRevsFile
.git-blame-ignore-revs` makes `git blame` skip it.

## Coding agents

- `AGENTS.md` holds the rules for every agent; Claude Code reads `CLAUDE.md`,
  which imports it.
- `.claude/` (committed): `settings.json` (permissions, hooks, the auto-mode
  fastboot rules), `hooks/` (format and guard every write, shell writes
  included; refuse to print key material, also through wrappers and
  recursive searches, and deny a call the guard cannot parse; run
  `just check` before a turn ends), `agents/` (test-runner, fleet-safety-reviewer, nexusq-docs,
  nexusq-build, nexusq-connect, nexusq-diag, stock-parity-auditor,
  nexusq-ios-release), `rules/` (aports, kernel, daemons, companion app),
  `skills/` (nexusq-build, nexusq-connect, nexusq-diag, nexusq-ios-release),
  and `harness-version` — the version of Petr's harness standard this repo
  follows (`/project-setup upgrade` brings it up to date).
- Personal Claude settings: `.claude/settings.local.json`, `CLAUDE.local.md`
  (gitignored).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `./docker-build.sh` on the host exits 1: "no repo at /src" | It runs inside the builder container; use the `docker run` in the README. (Until 2026-09-29 it exited 0 having built nothing.) |
| A build fails with `cannot execute cc1: posix_spawn` | Another build zapped the shared work volume. One build at a time: `docker ps` first. |
| ruff turned `except (A, B):` into `except A, B:` | That is PEP 758 syntax, Python ≥ 3.14 only; `target-version` in `ruff.toml` must stay at the oldest interpreter the code meets (py39). |
| `flutter analyze` finds `curly_braces_in_flow_control_structures` after a format | The tall style wrapped a one-line `if`; `dart fix --apply --code=curly_braces_in_flow_control_structures`. |
| A shell `check` fails though the pattern is there | `printf … \| grep -q` under `set -o pipefail`: grep quits at the first match and the writer gets SIGPIPE. Feed grep a here-string. |
| A size comparison flips between runs on Linux only | GNU `stat -f` is `--file-system` and prints free-block counts before failing; use `wc -c`. |
| A heredoc writes a mangled line and runs a stray command | Backticks in an unquoted heredoc (`<<EOF`) are command substitution; quote the delimiter or avoid backticks. |
| `SOCK_CLOEXEC` undeclared building the C tests | That is macOS's compiler: the daemons are Linux code. `tools/dev/test-c.sh` builds them in Alpine off Linux; start Docker. |
| `mkfs.ext4: command not found` on macOS | `brew install e2fsprogs` (keg-only; `test-shell.sh` finds it). |
| The docker lane says Docker is not running | Start Docker Desktop (macOS) or `systemctl start docker`. |
| A `# needs: docker` suite runs in the host lane | The marker must be in the suite's first five lines. |
| `docs-check` names a path or recipe that is right in context (another repo's file, a future file in a plan) | write the reference so it cannot be misread, or put `<!-- docs-check: ignore -->` on that line (above a code fence: the whole block); docs that record history go to `EXCLUDE` in `tools/dev/docs-check.py` |
