@AGENTS.md

## Claude Code in this repo

Project configuration lives in `.claude/` (committed). What it does for you:

- **Hooks** (`.claude/settings.json`):
  - every file you write — with the edit tools or from the shell (`sed -i`,
    `>`, heredocs) — goes through `tools/dev/format.sh`: Python and Dart are
    reformatted, Kotlin fixed, shell run through shellcheck; a complaint it
    cannot fix comes back to you (a Python import you just added is kept for
    the edit that uses it; `just fmt` and the pre-commit hook still drop it if
    it stays unused);
  - writing key material (`private/access/`, WiFi profiles outside `pmos/`, `*.rsa`,
    `.nexus_pw`, keystores), generated files and lockfiles is refused, from
    the shell too, and so is a shell command that prints key material;
    editing `kernel/patches/*.patch` by hand asks first;
  - when you finish a turn with code changes, `just check` runs; if it fails,
    you get the output and must fix it before stopping.
- **fastboot**: `fastboot flash boot|userdata` and friends are allowed without
  asking; writing the `bootloader` or `xloader` partition — by fastboot, or
  `dd` on the unit — is denied by the guard hook, whatever the allow rules say.
- **Rules** (`.claude/rules/`) load when you read files under `pmos/`,
  `kernel/`, `userspace/` or `companion/app/`.

## Subagents — delegate to them

| Agent | When |
|---|---|
| `test-runner` | after code changes, on any failing test or build, and to write tests |
| `fleet-safety-reviewer` | before committing anything under `pmos/`, `userspace/`, `kernel/`, `scripts/` or `docker-build.sh` |
| `nexusq-docs` | after a success or a notable failure, and after a change to commands, pins or behaviour |
| `nexusq-build` | to build the image or the rootfs (it knows the build's failure modes) |
| `nexusq-connect` | to find a working link to a booted Q |
| `nexusq-diag` | after every flash or upgrade, and to diagnose a unit |
| `stock-parity-auditor` | before building a kernel/DTS/driver fix, to compare with stock |
| `nexusq-ios-release` | to ship the app's iOS build to TestFlight |

## Skills

- `/nexusq-build`, `/nexusq-connect`, `/nexusq-ios-release` — hand the job to
  the agent of the same name.
- `/nexusq-diag` — the full diagnostic procedure and its fault catalogue.
