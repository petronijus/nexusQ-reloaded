# shellcheck shell=sh  # sourced, not run: no shebang
# Nexus Q (steelhead): the default wlroots renderer is the software one (Pixman).
# The system Mesa has no driver for the PowerVR SGX540; only the desktop
# session gets the GPU, through mesa-sgx on a private library path
# (/usr/libexec/nexusq-desktop-session switches to gles2 when the SGX is up).
# Everything else that starts a wlroots compositor stays on Pixman, because
# GLES2/EGL and Vulkan would fail and labwc aborts with "unable to create
# renderer". tinydm sources /etc/profile (hence this /etc/profile.d snippet)
# before launching the session, so the session wrapper starts from here.
export WLR_RENDERER=pixman
export WLR_NO_HARDWARE_CURSORS=1

# Prepend the device XDG config dir. /etc/xdg/nexusq/autostart holds
# Hidden=true overrides that keep the LXQt session from autostarting a second
# sound server (pipewire/wireplumber) next to PulseAudio — per the autostart
# spec the same-named .desktop in the most-important config dir wins.
export XDG_CONFIG_DIRS="/etc/xdg/nexusq:${XDG_CONFIG_DIRS:-/etc/xdg}"
