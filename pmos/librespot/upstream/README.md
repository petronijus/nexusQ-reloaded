# librespot override: upstream base and how to re-base

- `APKBUILD.alpine` — Alpine's `testing/librespot/APKBUILD`, verbatim, as the
  override was taken from it (0.8.0-r0). The three-way merge base.
- `upstream.json` — what `scripts/check-overrides.py` compares: the Alpine
  path, the GitHub repo, the release the patches were taken for and the heads
  of the carried pull requests.

Why the override exists: `docs/2026-11-14-spotify-connection-drop.md`.

## When `check-overrides` says so

- **Alpine changed their APKBUILD:** `just overrides` merges it, bumps the
  pkgrel and takes the new base; review `git diff pmos/librespot`, add a
  CHANGELOG line, commit. A conflict is merged by hand the same way.
- **A PR's head moved:** fetch it and re-take the patches (below), then
  update its `head` in `upstream.json`.
- **A new librespot release, or a new pkgver at Alpine:** re-base on the
  release. Drop the patches it carries; re-take the rest; update `release`,
  `pkgver`, `pkgrel` (back to 100) and `APKBUILD.alpine`.
- **Everything is in a release:** delete `pmos/librespot/`, its phase in
  `docker-build.sh` and its line in `pmos/ota-packages.list`.

## Re-taking the patches

```sh
git clone https://github.com/librespot-org/librespot && cd librespot
git checkout -B nq v0.8.0
git fetch origin pull/1871/head:pr1871 pull/1787/head:pr1787
git cherry-pick -x $(git rev-list --reverse "$(git merge-base origin/dev pr1871)..pr1871")
git cherry-pick -x $(git rev-list --reverse "$(git merge-base origin/dev pr1787)..pr1787")
git am /path/to/pmos/librespot/0007-*.patch
cargo test --workspace --features alsa-backend
git format-patch --no-signature --zero-commit -o /path/to/pmos/librespot v0.8.0..HEAD
```

Conflicts seen on 0.8.0: `CHANGELOG.md` (keep ours), core's
`[dev-dependencies]` (tokio with `test-util`, no `[lints]`), and
`Session::shutdown()`, where #1871 adds `self.audio_key().shutdown();` and
#1787 `self.dealer().shutdown();` — keep both, in that order.
