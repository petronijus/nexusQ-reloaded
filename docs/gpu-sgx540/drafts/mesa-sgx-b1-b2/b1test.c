/*
 * B1 test: GL_EXT_unpack_subimage as wlroots and weston use it.
 *
 * A source image whose every texel encodes its own coordinates is uploaded
 * in parts with GL_UNPACK_ROW_LENGTH_EXT / _SKIP_ROWS_EXT / _SKIP_PIXELS_EXT,
 * through glTexImage2D and glTexSubImage2D, in RGBA, BGRA and RGB (the RGB
 * rows exercise GL_UNPACK_ALIGNMENT). The texture is drawn with a nearest
 * sampler into an RGBA FBO and every pixel is compared with what the
 * extension specifies. Without the emulation the DDK rejects the pixel-store
 * names and uploads the wrong rows, so the test fails.
 *
 * Usage: b1test   (exit 0 = all cases pass)
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#ifndef GL_UNPACK_ROW_LENGTH_EXT
#define GL_UNPACK_ROW_LENGTH_EXT  0x0CF2
#define GL_UNPACK_SKIP_ROWS_EXT   0x0CF3
#define GL_UNPACK_SKIP_PIXELS_EXT 0x0CF4
#endif

#define SW 61 /* source width: odd, so RGB rows need alignment padding */
#define SH 40
#define TW 32 /* texture */
#define TH 20

static GLuint prog, fbo, rb;

/* Expected RGBA of source texel (x, y). */
static void texel(int x, int y, uint8_t out[4])
{
	out[0] = (uint8_t)(x * 4 + 1);
	out[1] = (uint8_t)(y * 6 + 2);
	out[2] = (uint8_t)((x ^ y) * 3 + 50);
	out[3] = 255;
}

/* Source image in the given client format, rows padded to `align`. */
static uint8_t *make_source(GLenum format, unsigned align, size_t *stride)
{
	unsigned bpp = format == GL_RGB ? 3 : 4;
	*stride = ((size_t)SW * bpp + align - 1) / align * align;
	uint8_t *p = calloc(*stride * SH, 1);
	for (int y = 0; y < SH; y++)
		for (int x = 0; x < SW; x++) {
			uint8_t c[4];
			texel(x, y, c);
			uint8_t *d = p + y * *stride + x * bpp;
			if (format == GL_BGRA_EXT) {
				d[0] = c[2]; d[1] = c[1]; d[2] = c[0]; d[3] = c[3];
			} else {
				memcpy(d, c, bpp);
			}
		}
	return p;
}

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	return s;
}

static void setup_draw(void)
{
	prog = glCreateProgram();
	glAttachShader(prog, shader(GL_VERTEX_SHADER,
		"attribute vec2 p; varying vec2 t;"
		"void main(){ t = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }"));
	glAttachShader(prog, shader(GL_FRAGMENT_SHADER,
		"precision mediump float; varying vec2 t; uniform sampler2D s;"
		"void main(){ gl_FragColor = texture2D(s, t); }"));
	glBindAttribLocation(prog, 0, "p");
	glLinkProgram(prog);
	glGenRenderbuffers(1, &rb);
	glBindRenderbuffer(GL_RENDERBUFFER, rb);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, TW, TH);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
}

/* Draw `tex` into the FBO and compare with expect(x, y) for every pixel. */
static int verify(GLuint tex, const char *name, void (*expect)(int, int, uint8_t[4]))
{
	static const GLfloat quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
	static uint8_t px[TW * TH * 4];
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glViewport(0, 0, TW, TH);
	glUseProgram(prog);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);
	glEnableVertexAttribArray(0);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	glReadPixels(0, 0, TW, TH, GL_RGBA, GL_UNSIGNED_BYTE, px);
	int bad = 0;
	for (int y = 0; y < TH; y++)
		for (int x = 0; x < TW; x++) {
			uint8_t want[4];
			expect(x, y, want);
			const uint8_t *got = px + (y * TW + x) * 4;
			if (memcmp(got, want, 3)) {
				if (!bad)
					fprintf(stderr, "  %s: (%d,%d) got %02x%02x%02x want %02x%02x%02x\n",
						name, x, y, got[0], got[1], got[2], want[0], want[1], want[2]);
				bad++;
			}
		}
	printf("%-44s %s (%d/%d wrong)\n", name, bad ? "FAIL" : "PASS", bad, TW * TH);
	return bad != 0;
}

/* Case geometry, shared with the expectation callbacks. */
static int c_skip_x, c_skip_y, c_sub_x, c_sub_y, c_sub_w, c_sub_h;

/* Whole texture = source window starting at (c_skip_x, c_skip_y). */
static void expect_window(int x, int y, uint8_t out[4])
{
	texel(x + c_skip_x, y + c_skip_y, out);
}

/* Base fill = source (x, y); sub-rect at (c_sub_x, c_sub_y) = source window. */
static void expect_patch(int x, int y, uint8_t out[4])
{
	if (x >= c_sub_x && x < c_sub_x + c_sub_w && y >= c_sub_y && y < c_sub_y + c_sub_h)
		texel(x - c_sub_x + c_skip_x, y - c_sub_y + c_skip_y, out);
	else
		texel(x + 40, y + 30, out);
}

static void set_unpack(int row_length, int skip_x, int skip_y, int align)
{
	glPixelStorei(GL_UNPACK_ALIGNMENT, align);
	glPixelStorei(GL_UNPACK_ROW_LENGTH_EXT, row_length);
	glPixelStorei(GL_UNPACK_SKIP_PIXELS_EXT, skip_x);
	glPixelStorei(GL_UNPACK_SKIP_ROWS_EXT, skip_y);
}

static int run_format(GLenum format, const char *fname, unsigned align)
{
	size_t stride;
	uint8_t *src = make_source(format, align, &stride);
	GLenum ifmt = format == GL_BGRA_EXT ? GL_BGRA_EXT : format;
	int fails = 0;
	char name[64];
	GLuint tex;

	/* 1. glTexImage2D of a window of the source. */
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	c_skip_x = 7;
	c_skip_y = 5;
	set_unpack(SW, c_skip_x, c_skip_y, align);
	glTexImage2D(GL_TEXTURE_2D, 0, ifmt, TW, TH, 0, format, GL_UNSIGNED_BYTE, src);
	snprintf(name, sizeof(name), "%s TexImage2D row_length+skip", fname);
	fails += verify(tex, name, expect_window);

	/* 2. glTexSubImage2D of a damaged rect, as wlroots does. */
	set_unpack(SW, 40, 30, align);
	glTexImage2D(GL_TEXTURE_2D, 0, ifmt, TW, TH, 0, format, GL_UNSIGNED_BYTE, NULL);
	/* base fill: a tight TW x TH image of source texels from (40, 30) */
	set_unpack(0, 0, 0, align);
	{
		/* build the base fill as its own tight image to keep the source simple */
		unsigned bpp = format == GL_RGB ? 3 : 4;
		size_t bstride = ((size_t)TW * bpp + align - 1) / align * align;
		uint8_t *base = calloc(bstride * TH, 1);
		for (int y = 0; y < TH; y++)
			for (int x = 0; x < TW; x++) {
				uint8_t c[4];
				texel(x + 40, y + 30, c);
				uint8_t *d = base + y * bstride + x * bpp;
				if (format == GL_BGRA_EXT) {
					d[0] = c[2]; d[1] = c[1]; d[2] = c[0]; d[3] = c[3];
				} else {
					memcpy(d, c, bpp);
				}
			}
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, TW, TH, format, GL_UNSIGNED_BYTE, base);
		free(base);
	}
	c_sub_x = 9; c_sub_y = 4; c_sub_w = 13; c_sub_h = 11;
	c_skip_x = 21; c_skip_y = 17;
	set_unpack(SW, c_skip_x, c_skip_y, align);
	glTexSubImage2D(GL_TEXTURE_2D, 0, c_sub_x, c_sub_y, c_sub_w, c_sub_h, format,
			GL_UNSIGNED_BYTE, src);
	snprintf(name, sizeof(name), "%s TexSubImage2D damaged rect", fname);
	fails += verify(tex, name, expect_patch);

	/* 3. Rows already contiguous (row_length == width): pointer-offset path. */
	{
		unsigned bpp = format == GL_RGB ? 3 : 4;
		size_t wstride = ((size_t)TW * bpp + align - 1) / align * align;
		uint8_t *win = calloc(wstride * (TH + 6), 1);
		for (int y = 0; y < TH + 6; y++)
			for (int x = 0; x < TW; x++) {
				uint8_t c[4];
				texel(x + 3, y, c);
				uint8_t *d = win + y * wstride + x * bpp;
				if (format == GL_BGRA_EXT) {
					d[0] = c[2]; d[1] = c[1]; d[2] = c[0]; d[3] = c[3];
				} else {
					memcpy(d, c, bpp);
				}
			}
		c_skip_x = 3;
		c_skip_y = 6;
		set_unpack(TW, 0, 6, align);
		glTexImage2D(GL_TEXTURE_2D, 0, ifmt, TW, TH, 0, format, GL_UNSIGNED_BYTE, win);
		snprintf(name, sizeof(name), "%s TexImage2D skip_rows, contiguous", fname);
		fails += verify(tex, name, expect_window);
		free(win);
	}

	set_unpack(0, 0, 0, 4);
	glDeleteTextures(1, &tex);
	free(src);
	return fails;
}

int main(void)
{
	int drm = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	struct gbm_device *gbm = gbm_create_device(drm);
	EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, NULL, NULL)) {
		fprintf(stderr, "FAIL: eglInitialize\n");
		return 1;
	}
	eglBindAPI(EGL_OPENGL_ES_API);
	static const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctx_attr);
	if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
		fprintf(stderr, "FAIL: eglMakeCurrent\n");
		return 1;
	}
	printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
	const char *ext = (const char *)glGetString(GL_EXTENSIONS);
	int advertised = ext && strstr(ext, "GL_EXT_unpack_subimage") != NULL;
	printf("GL_EXT_unpack_subimage: %s\n", advertised ? "advertised" : "ABSENT");

	setup_draw();
	int fails = !advertised;
	fails += run_format(GL_RGBA, "RGBA", 4);
	fails += run_format(GL_BGRA_EXT, "BGRA", 4);
	fails += run_format(GL_RGB, "RGB align 4", 4);
	fails += run_format(GL_RGB, "RGB align 1", 1);

	GLint v = -1;
	glPixelStorei(GL_UNPACK_ROW_LENGTH_EXT, 123);
	glGetIntegerv(GL_UNPACK_ROW_LENGTH_EXT, &v);
	glPixelStorei(GL_UNPACK_ROW_LENGTH_EXT, 0);
	printf("%-44s %s (%d)\n", "glGetIntegerv(UNPACK_ROW_LENGTH)", v == 123 ? "PASS" : "FAIL", v);
	fails += v != 123;
	GLenum err = glGetError();
	printf("%-44s %s (0x%x)\n", "glGetError after all cases", err ? "FAIL" : "PASS", err);
	fails += err != 0;

	printf("RESULT: %s (%d failing)\n", fails ? "FAIL" : "PASS", fails);
	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(dpy, ctx);
	eglTerminate(dpy);
	gbm_device_destroy(gbm);
	close(drm);
	return fails ? 2 : 0;
}
