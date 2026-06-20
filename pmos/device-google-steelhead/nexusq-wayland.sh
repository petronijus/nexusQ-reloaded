# Nexus Q (steelhead): no GPU driver — the PowerVR SGX540 has no mainline GLES
# driver (see docs/2026-06-19-gpu-sgx540-acceleration-research.md). Force the
# wlroots software (Pixman) renderer for labwc / LXQt-Wayland. Without this,
# wlroots tries GLES2/EGL and Vulkan, both fail, and labwc aborts at startup
# with "unable to create renderer". tinydm sources /etc/profile (hence this
# /etc/profile.d snippet) before launching the session, so labwc inherits it.
export WLR_RENDERER=pixman
export WLR_NO_HARDWARE_CURSORS=1
