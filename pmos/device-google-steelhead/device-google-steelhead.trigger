#!/bin/sh
# apk trigger on /usr/share/pulseaudio/alsa-mixer/paths.
#
# This runs at the END of the apk transaction, AFTER any package (i.e.
# pulseaudio) has populated that directory — unlike .post-install, which apk may
# run before a dependency's files are unpacked. During the image build the device
# package's .post-install ran too early: bluez's main.conf was already unpacked
# (patched OK) but pulseaudio's mixer paths were NOT, so the Speaker-unity sed
# silently skipped ([ -f ] guard) and the baked image stacked Master+Speaker to
# +48 dB. A trigger is the correct mechanism for "patch a file another package
# owns once it is present."
#
# Pin the TAS5713 per-channel Speaker at unity ([Element Speaker] volume=zero) so
# PulseAudio drives ONLY the Master control for the sink volume (both were
# volume=merge, which PA stacks: Master 0..+24 dB then Speaker another 0..+24 dB
# -> +48 dB at 100%). With Speaker pinned at 0 dB, Master alone carries 0-100%
# (max +24 dB, comfortable near mid). Pairs with kernel patch 0038 (Master dB
# scale shift). Idempotent; re-applies if pulseaudio is ever upgraded.
for dir in "$@"; do
	conf="$dir/analog-output-speaker.conf"
	[ -f "$conf" ] || continue
	sed -i '/^\[Element Speaker\]$/,/^\[/ s/^volume = merge$/volume = zero/' "$conf"
done

# Also force PA interrupt-based scheduling (tsched=0). Timer-based scheduling was
# the biggest cause of the periodic playback crackle on this OMAP4. default.pa is
# pulseaudio-owned; patch it here (trigger) for the same reason as the mixer path.
for dir in "$@"; do
	dp="$dir/default.pa"
	[ -f "$dp" ] || continue
	sed -i 's/^load-module module-udev-detect$/load-module module-udev-detect tsched=0/' "$dp"
done

# Stop the on-screen keyboard (onboard) autostarting. It SIGSEGVs in its native
# osk module on every boot (systemd-coredump), and an on-screen keyboard has no
# purpose on an appliance with no touchscreen and no attached input device. The
# autostart file lives in an lxqt-tablet subdir, not the plain autostart/ dir our
# XDG_CONFIG_DIRS shadow covers, so a trigger neuters onboard's OWN file — the one
# that is certainly read — rather than relying on XDG merge semantics for that
# subpath. `Hidden=true` means the XDG autostart spec treats the entry as absent.
# Idempotent; re-applies if onboard is ever upgraded.
for dir in "$@"; do
	oa="$dir/onboard-autostart.desktop"
	[ -f "$oa" ] || continue
	grep -q '^Hidden=true' "$oa" || printf '\nHidden=true\n' >> "$oa"
done

exit 0
