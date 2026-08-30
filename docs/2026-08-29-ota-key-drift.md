# The OTA repo is signed with a key the current images do not trust

**2026-08-29, found while preparing the public image release v1.14.0.**
Status: **root-caused, guard added, fleet fix pending the release.**

## What is broken

The freshly flashed Šumperák Q cannot use the OTA repo at all:

```
# apk update
WARNING: updating and opening https://petronijus.github.io/nexusQ-reloaded/nexusq/armv7/APKINDEX.tar.gz:
         UNTRUSTED signature
...
1 unavailable, 0 stale; 34728 distinct packages available
```

That "1 unavailable" is our repo. Every "Nexus Q update" and "System update" in
the companion app is therefore dead on that box — not failing loudly, just never
offering anything.

## Why

Two names that must be equal, and were not:

| | key |
|---|---|
| what the published `APKINDEX.tar.gz` is signed with (`.SIGN.RSA.<key>`) | `pmos@local-6a42e957` |
| what the device holds in `/etc/apk/keys` (baked by the v1.13.0 image) | `pmos@local-6a913e9e` |

`scripts/publish-ota-repo.sh` had the signing key **hardcoded** as
`pmos@local-6a42e957`, and its header asserted, in prose, that "the Nexus Q
trusts" it. The device's trust comes from the image, the image's key comes from
whatever `config_abuild` the build workdir happened to hold, and that key had
been regenerated at some point. Nothing connected the two, so the drift was
invisible: the publish step keeps succeeding, the index keeps being signed, and
only the device knows it is being handed a signature from a stranger.

apk is behaving correctly here. This is not a bug in apk, in pmbootstrap, or in
the device — it is one hardcoded string that stopped being true.

## What changed today

- `scripts/publish-ota-repo.sh` **discovers** the key in the build workdir
  instead of naming one, and prints it.
- A **drift guard**: if `pmos/ota-signing-key.rsa.pub` exists, the key that is
  about to sign the index must be byte-identical to it, or the publish aborts
  with instructions. A publish that no device can consume is now an error, not
  a success.

## What still has to happen

The guard prevents the *next* silent outage; it does not repair the current one.
The fleet has to converge on ONE key:

1. `pmos/ota-signing-key.rsa.pub` — the fleet key's public half, committed (a
   public key is not a secret; committing it is what makes every build host able
   to check itself).
2. The image bakes it, so a fresh flash trusts it.
3. Boxes already in the field get it installed once, over ssh:
   `scp <key>.rsa.pub root@<box>:/etc/apk/keys/` — no reflash needed.
4. The private half belongs in 1Password, not in one machine's docker volume.
   That is what makes "which machine builds the packages" stop being a rule
   anyone has to remember.

Until step 4, device packages remain bound to the host holding the key — see
HANDOFF.md "WHICH MACHINE BUILDS WHAT".

---

## Resolved 2026-08-30 (steps 1, 2 and 4) — see the next day's note

- **Step 1 done.** `pmos/ota-signing-key.rsa.pub` is committed — copied from the
  **live Prague Q**, not from what we believed, and verified byte-identical to the
  desktop's `nexusq-workdir/config_abuild` key and to the `.SIGN.RSA` member of the
  published `APKINDEX.tar.gz`. All three are `pmos@local-6a42e957`. So the drift
  guard added here finally has a reference and fails closed; until the file existed
  it was wrapped in `if [ -f … ]` with no `else` and **did nothing, always**.
- **Step 2 done, differently.** Rather than trusting the bake, the release now
  *checks* it: `scripts/verify-ota-parity.sh` (run by `package-release.sh`, and not
  skippable) fails a release whose image bakes a different key from the one that
  signed the index.
- **Step 4 done.** The private half is backed up in 1Password, document
  **"nexusQ OTA signing key (fleet)"**. Until 2026-08-30 its only copy was inside
  the `nexusq-workdir` docker volume.
- **Step 3 still open for the Šumperák Q**, which trusts `pmos@local-6a913e9e` and
  therefore still cannot OTA at all.

Full record: `docs/2026-08-30-release-reaches-nobody-and-the-flag-the-gadget-had.md`.
