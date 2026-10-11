/*
 * LD_PRELOAD shim for the sandbox's kmscube: the SGX DRI driver has no
 * modifier support, so gbm_bo_get_modifier() returns DRM_FORMAT_MOD_INVALID
 * and this kmscube passes it to AddFB2 with DRM_MODE_FB_MODIFIERS set, which
 * omapdrm (correctly) rejects at SETCRTC. Report LINEAR (0) instead, so
 * kmscube takes the plain AddFB2 path.
 */
#include <stdint.h>

struct gbm_bo;

uint64_t gbm_bo_get_modifier(struct gbm_bo *bo)
{
	(void)bo;
	return 0; /* DRM_FORMAT_MOD_LINEAR */
}
