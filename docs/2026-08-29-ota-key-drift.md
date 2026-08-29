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
