---
paths:
  - "userspace/**"
  - "pmos/device-google-steelhead/**"
---
# Device daemons and scripts

- They run on two Cortex-A9 cores, mostly idle: no busy polls, and every
  periodic wakeup justifies its rate (idle power is measured by nq-healthd).
- Python is Alpine's 3.14 with the packaged modules only (stdlib, py3-dbus,
  py3-gobject3). Shell is busybox `sh`.
- Audio: nothing raises the volume, un-mutes the amplifier or plays a sound
  on its own. The volume curve is steep and the amplifier is 25 W.
- The protocol the app speaks is `companion/PROTOCOL.md`; a change to it
  changes the spec, the daemon and the app together, with their tests.
- Tests load the extensionless daemons with `SourceFileLoader`
  (`userspace/*/tests/`); run them with `just test-py`.
