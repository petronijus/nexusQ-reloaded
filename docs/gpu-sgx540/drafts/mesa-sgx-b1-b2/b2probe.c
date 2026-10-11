/*
 * B2 probe: does DDK 1.17 dma-buf import work for what wlroots needs?
 *
 * wlroots' GLES2 renderer allocates its render targets with GBM, exports
 * them as dma-buf fds and imports them back through
 * eglCreateImageKHR(EGL_LINUX_DMA_BUF_EXT), then renders into them as an
 * FBO. This probe does the same, then checks every frame twice: through
 * glReadPixels on the FBO, and through a CPU mmap of the dma-buf (what
 * omapdrm scans out). Colours alternate per frame, so a stale cache or a
 * missing flush shows as a mismatch.
 *
 * Case "gbm":  buffer allocated by GBM on card0 (the SGX DRI driver).
 * Case "dumb": buffer allocated by omapdrm (DRM dumb BO, prime-exported),
 *              like a client dma-buf the compositor imports.
 *
 * Usage: b2probe <gbm|dumb> [frames]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_mode.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#define W 256
#define H 128

static PFNEGLCREATEIMAGEKHRPROC create_image;
static PFNEGLDESTROYIMAGEKHRPROC destroy_image;
static PFNGLEGLIMAGETARGETRENDERBUFFERSTORAGEOESPROC image_target_rb;

static int fail(const char *what)
{
	fprintf(stderr, "FAIL: %s (egl 0x%x gl 0x%x errno %d)\n", what,
		eglGetError(), glGetError(), errno);
	return 1;
}

/* XRGB8888 in memory is B,G,R,X bytes; compare the RGB channels only. */
static int check_mem(const uint8_t *p, uint32_t stride, uint8_t r, uint8_t g, uint8_t b)
{
	for (int y = 0; y < H; y += 7)
		for (int x = 0; x < W; x += 5) {
			const uint8_t *px = p + y * stride + x * 4;
			if (px[0] != b || px[1] != g || px[2] != r)
				return -1 - (y * W + x);
		}
	return 0;
}

static int check_read(uint8_t r, uint8_t g, uint8_t b)
{
	static uint8_t buf[W * H * 4];
	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, buf);
	for (int i = 0; i < W * H; i += 37)
		if (buf[i * 4] != r || buf[i * 4 + 1] != g || buf[i * 4 + 2] != b)
			return -1 - i;
	return 0;
}

int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "gbm";
	int frames = argc > 2 ? atoi(argv[2]) : 200;
	int drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (drm < 0)
		return fail("open card0");

	struct gbm_device *gbm = gbm_create_device(drm);
	if (!gbm)
		return fail("gbm_create_device");

	EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, NULL, NULL))
		return fail("eglInitialize");
	const char *exts = eglQueryString(dpy, EGL_EXTENSIONS);
	printf("EGL_EXT_image_dma_buf_import: %s\n",
	       strstr(exts, "EGL_EXT_image_dma_buf_import") ? "advertised" : "ABSENT");

	create_image = (void *)eglGetProcAddress("eglCreateImageKHR");
	destroy_image = (void *)eglGetProcAddress("eglDestroyImageKHR");
	image_target_rb = (void *)eglGetProcAddress("glEGLImageTargetRenderbufferStorageOES");

	eglBindAPI(EGL_OPENGL_ES_API);
	static const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctx_attr);
	if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx))
		return fail("surfaceless context");
	printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));

	int fd;
	uint32_t stride;
	struct gbm_bo *bo = NULL;
	if (!strcmp(mode, "gbm")) {
		bo = gbm_bo_create(gbm, W, H, GBM_FORMAT_XRGB8888,
				   GBM_BO_USE_RENDERING | GBM_BO_USE_SCANOUT);
		if (!bo)
			return fail("gbm_bo_create");
		fd = gbm_bo_get_fd(bo);
		stride = gbm_bo_get_stride(bo);
	} else {
		struct drm_mode_create_dumb cd = { .width = W, .height = H, .bpp = 32 };
		if (ioctl(drm, DRM_IOCTL_MODE_CREATE_DUMB, &cd))
			return fail("CREATE_DUMB");
		struct drm_prime_handle ph = { .handle = cd.handle, .flags = DRM_CLOEXEC | DRM_RDWR };
		if (ioctl(drm, DRM_IOCTL_PRIME_HANDLE_TO_FD, &ph))
			return fail("PRIME_HANDLE_TO_FD");
		fd = ph.fd;
		stride = cd.pitch;
	}
	if (fd < 0)
		return fail("export fd");
	printf("buffer: %s %dx%d stride %u fd %d\n", mode, W, H, stride, fd);

	EGLint attr[] = {
		EGL_WIDTH, W, EGL_HEIGHT, H,
		EGL_LINUX_DRM_FOURCC_EXT, DRM_FORMAT_XRGB8888,
		EGL_DMA_BUF_PLANE0_FD_EXT, fd,
		EGL_DMA_BUF_PLANE0_OFFSET_EXT, 0,
		EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)stride,
		EGL_NONE,
	};
	EGLImageKHR img = create_image(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attr);
	if (img == EGL_NO_IMAGE_KHR)
		return fail("eglCreateImageKHR(EGL_LINUX_DMA_BUF_EXT)");

	GLuint rb, fbo;
	glGenRenderbuffers(1, &rb);
	glBindRenderbuffer(GL_RENDERBUFFER, rb);
	image_target_rb(GL_RENDERBUFFER, img);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
	GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	if (st != GL_FRAMEBUFFER_COMPLETE) {
		fprintf(stderr, "FBO status 0x%x\n", st);
		return fail("FBO incomplete");
	}

	uint8_t *map = mmap(NULL, (size_t)stride * H, PROT_READ, MAP_SHARED, fd, 0);
	if (map == MAP_FAILED)
		return fail("mmap dma-buf");

	int bad_read = 0, bad_mem = 0;
	for (int f = 0; f < frames; f++) {
		uint8_t r = (f * 37) & 0xff, g = (f & 1) ? 0xff : 0x00, b = (f * 11 + 64) & 0xff;
		glViewport(0, 0, W, H);
		glClearColor(r / 255.0f, g / 255.0f, b / 255.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glFinish();
		int rr = check_read(r, g, b);
		/* DMA_BUF_IOCTL_SYNC brackets the CPU read, as a scanout reader would. */
		struct { uint64_t flags; } sync = { (1 << 0) | (0 << 2) }; /* READ | START */
		ioctl(fd, _IOW('b', 0, uint64_t), &sync);
		int rm = check_mem(map, stride, r, g, b);
		sync.flags = (1 << 0) | (1 << 2); /* READ | END */
		ioctl(fd, _IOW('b', 0, uint64_t), &sync);
		if (rr)
			bad_read++;
		if (rm) {
			if (bad_mem < 3) {
				int i = -1 - rm;
				const uint8_t *px = map + (i / W) * stride + (i % W) * 4;
				fprintf(stderr, "frame %d: dma-buf px %d = %02x%02x%02x, want %02x%02x%02x\n",
					f, i, px[2], px[1], px[0], r, g, b);
			}
			bad_mem++;
		}
	}
	printf("frames %d: glReadPixels mismatches %d, dma-buf mmap mismatches %d\n",
	       frames, bad_read, bad_mem);
	printf("RESULT %s: %s\n", mode, (bad_read || bad_mem) ? "FAIL" : "PASS");

	munmap(map, (size_t)stride * H);
	glDeleteFramebuffers(1, &fbo);
	glDeleteRenderbuffers(1, &rb);
	destroy_image(dpy, img);
	if (bo)
		gbm_bo_destroy(bo);
	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(dpy, ctx);
	eglTerminate(dpy);
	gbm_device_destroy(gbm);
	close(drm);
	return (bad_read || bad_mem) ? 2 : 0;
}
