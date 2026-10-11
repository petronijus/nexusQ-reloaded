/*
 * sgxprobe: first-light GLES2 probe for the SGX540 route B sandbox.
 *
 * Opens EGL on the surfaceless platform (FBO target) or on GBM (pbuffer
 * target), prints the EGL/GL strings and limits, renders a fixed pattern
 * into 256x256, reads it back with glReadPixels and writes a PPM. With a
 * frame count > 1 it repeats the render at <= 30 fps (bounded, with a die
 * temperature stop at 90 C) to watch the power domain under a light load.
 *
 * Self-contained: libEGL/libgbm are dlopen()ed and every GL entry point
 * comes from eglGetProcAddress (EGL_KHR_get_all_proc_addresses), so it
 * cross-builds without armhf GL libraries on the host.
 *
 * Usage: sgxprobe surfaceless|gbm <out.ppm> [frames] [drm-node]
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface;
typedef int32_t EGLint;
typedef unsigned EGLBoolean, EGLenum;
typedef unsigned GLenum, GLuint, GLbitfield;
typedef int GLint, GLsizei;
typedef float GLfloat;
typedef unsigned char GLubyte, GLboolean;
typedef char GLchar;

#define EGL_NONE 0x3038
#define EGL_VENDOR 0x3053
#define EGL_VERSION 0x3054
#define EGL_EXTENSIONS 0x3055
#define EGL_CLIENT_APIS 0x308D
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_SURFACE_TYPE 0x3033
#define EGL_PBUFFER_BIT 0x0001
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_ES2_BIT 0x0004
#define EGL_RED_SIZE 0x3024
#define EGL_GREEN_SIZE 0x3023
#define EGL_BLUE_SIZE 0x3022
#define EGL_ALPHA_SIZE 0x3021
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define EGL_PLATFORM_GBM_KHR 0x31D7
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD

#define GL_VENDOR 0x1F00
#define GL_RENDERER 0x1F01
#define GL_VERSION 0x1F02
#define GL_EXTENSIONS 0x1F03
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_TEXTURE_2D 0x0DE1
#define GL_RGBA 0x1908
#define GL_UNSIGNED_BYTE 0x1401
#define GL_FRAMEBUFFER 0x8D40
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_FLOAT 0x1406
#define GL_TRIANGLES 0x0004
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_NEAREST 0x2600

#define W 256
#define H 256

static void *egl, *gbm;
static void *(*p_eglGetProcAddress)(const char *);

static void *gp(const char *name)
{
	void *f = p_eglGetProcAddress(name);
	if (!f)
		f = dlsym(egl, name);
	if (!f) {
		fprintf(stderr, "missing entry point %s\n", name);
		exit(3);
	}
	return f;
}

#define FN(ret, name, args) static ret(*name) args
FN(EGLDisplay, eglGetPlatformDisplayEXT, (EGLenum, void *, const EGLint *));
FN(EGLBoolean, eglInitialize, (EGLDisplay, EGLint *, EGLint *));
FN(const char *, eglQueryString, (EGLDisplay, EGLint));
FN(EGLBoolean, eglBindAPI, (EGLenum));
FN(EGLBoolean, eglChooseConfig, (EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *));
FN(EGLContext, eglCreateContext, (EGLDisplay, EGLConfig, EGLContext, const EGLint *));
FN(EGLSurface, eglCreatePbufferSurface, (EGLDisplay, EGLConfig, const EGLint *));
FN(EGLBoolean, eglMakeCurrent, (EGLDisplay, EGLSurface, EGLSurface, EGLContext));
FN(EGLBoolean, eglDestroyContext, (EGLDisplay, EGLContext));
FN(EGLBoolean, eglDestroySurface, (EGLDisplay, EGLSurface));
FN(EGLBoolean, eglTerminate, (EGLDisplay));
FN(EGLint, eglGetError, (void));
FN(const GLubyte *, glGetString, (GLenum));
FN(void, glGetIntegerv, (GLenum, GLint *));
FN(void, glGetFloatv, (GLenum, GLfloat *));
FN(GLenum, glGetError, (void));
FN(void, glGenTextures, (GLsizei, GLuint *));
FN(void, glBindTexture, (GLenum, GLuint));
FN(void, glTexImage2D, (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *));
FN(void, glTexParameteri, (GLenum, GLenum, GLint));
FN(void, glGenFramebuffers, (GLsizei, GLuint *));
FN(void, glBindFramebuffer, (GLenum, GLuint));
FN(void, glFramebufferTexture2D, (GLenum, GLenum, GLenum, GLuint, GLint));
FN(GLenum, glCheckFramebufferStatus, (GLenum));
FN(void, glViewport, (GLint, GLint, GLsizei, GLsizei));
FN(void, glClearColor, (GLfloat, GLfloat, GLfloat, GLfloat));
FN(void, glClear, (GLbitfield));
FN(GLuint, glCreateShader, (GLenum));
FN(void, glShaderSource, (GLuint, GLsizei, const GLchar *const *, const GLint *));
FN(void, glCompileShader, (GLuint));
FN(void, glGetShaderiv, (GLuint, GLenum, GLint *));
FN(void, glGetShaderInfoLog, (GLuint, GLsizei, GLsizei *, GLchar *));
FN(GLuint, glCreateProgram, (void));
FN(void, glAttachShader, (GLuint, GLuint));
FN(void, glBindAttribLocation, (GLuint, GLuint, const GLchar *));
FN(void, glLinkProgram, (GLuint));
FN(void, glGetProgramiv, (GLuint, GLenum, GLint *));
FN(void, glUseProgram, (GLuint));
FN(void, glVertexAttribPointer, (GLuint, GLint, GLenum, GLboolean, GLsizei, const void *));
FN(void, glEnableVertexAttribArray, (GLuint));
FN(void, glDrawArrays, (GLenum, GLint, GLsizei));
FN(void, glFinish, (void));
FN(void, glReadPixels, (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *));

static void load(void)
{
	egl = dlopen("libEGL.so.1", RTLD_NOW | RTLD_GLOBAL);
	if (!egl) {
		fprintf(stderr, "dlopen libEGL.so.1: %s\n", dlerror());
		exit(3);
	}
	p_eglGetProcAddress = dlsym(egl, "eglGetProcAddress");
#define L(n) *(void **)&n = gp(#n)
	L(eglGetPlatformDisplayEXT); L(eglInitialize); L(eglQueryString); L(eglBindAPI);
	L(eglChooseConfig); L(eglCreateContext); L(eglCreatePbufferSurface); L(eglMakeCurrent);
	L(eglDestroyContext); L(eglDestroySurface); L(eglTerminate); L(eglGetError);
}

static void load_gl(void)
{
	L(glGetString); L(glGetIntegerv); L(glGetFloatv); L(glGetError); L(glGenTextures);
	L(glBindTexture); L(glTexImage2D); L(glTexParameteri); L(glGenFramebuffers);
	L(glBindFramebuffer); L(glFramebufferTexture2D); L(glCheckFramebufferStatus);
	L(glViewport); L(glClearColor); L(glClear); L(glCreateShader); L(glShaderSource);
	L(glCompileShader); L(glGetShaderiv); L(glGetShaderInfoLog); L(glCreateProgram);
	L(glAttachShader); L(glBindAttribLocation); L(glLinkProgram); L(glGetProgramiv);
	L(glUseProgram); L(glVertexAttribPointer); L(glEnableVertexAttribArray);
	L(glDrawArrays); L(glFinish); L(glReadPixels);
}

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok = 0;
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024] = "";
		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		fprintf(stderr, "shader compile failed: %s\n", log);
		exit(4);
	}
	return s;
}

static const char *vs_src =
	"attribute vec2 pos;\n"
	"void main() { gl_Position = vec4(pos, 0.0, 1.0); }\n";
/* Left half: solid magenta. Right half: a gradient of gl_FragCoord (exercises
 * varyings/precision; compared with the software renderer on the host). */
static const char *fs_src =
	"precision mediump float;\n"
	"void main() {\n"
	"  if (gl_FragCoord.x < 128.0) gl_FragColor = vec4(1.0, 0.0, 0.5, 1.0);\n"
	"  else gl_FragColor = vec4(gl_FragCoord.x / 256.0, gl_FragCoord.y / 256.0, 0.25, 1.0);\n"
	"}\n";

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static int die_temp_mc(void)
{
	FILE *f = fopen("/sys/class/thermal/thermal_zone0/temp", "r");
	int t = 0;
	if (f) {
		char b[32] = "";
		if (fgets(b, sizeof(b), f))
			for (const char *c = b; *c >= '0' && *c <= '9'; c++)
				t = t * 10 + (*c - '0');
		fclose(f);
	}
	return t;
}

static void limits(void)
{
	static const struct {
		GLenum e;
		const char *n;
		int count;
	} q[] = {
		{0x0D33, "GL_MAX_TEXTURE_SIZE", 1},
		{0x851C, "GL_MAX_CUBE_MAP_TEXTURE_SIZE", 1},
		{0x84E8, "GL_MAX_RENDERBUFFER_SIZE", 1},
		{0x0D3A, "GL_MAX_VIEWPORT_DIMS", 2},
		{0x8872, "GL_MAX_TEXTURE_IMAGE_UNITS", 1},
		{0x8B4D, "GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS", 1},
		{0x8B4C, "GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS", 1},
		{0x8869, "GL_MAX_VERTEX_ATTRIBS", 1},
		{0x8DFB, "GL_MAX_VERTEX_UNIFORM_VECTORS", 1},
		{0x8DFD, "GL_MAX_FRAGMENT_UNIFORM_VECTORS", 1},
		{0x8DFC, "GL_MAX_VARYING_VECTORS", 1},
		{0x8B9A, "GL_IMPLEMENTATION_COLOR_READ_TYPE", 1},
		{0x8B9B, "GL_IMPLEMENTATION_COLOR_READ_FORMAT", 1},
		{0x0D50, "GL_SUBPIXEL_BITS", 1},
		{0x80A9, "GL_SAMPLES", 1},
	};
	for (unsigned i = 0; i < sizeof(q) / sizeof(q[0]); i++) {
		GLint v[2] = {0, 0};
		glGetIntegerv(q[i].e, v);
		if (q[i].count == 2)
			printf("%s = %d %d\n", q[i].n, v[0], v[1]);
		else
			printf("%s = %d (0x%x)\n", q[i].n, v[0], v[0]);
	}
	GLfloat r[2] = {0, 0};
	glGetFloatv(0x846D, r);
	printf("GL_ALIASED_POINT_SIZE_RANGE = %g %g\n", r[0], r[1]);
	glGetFloatv(0x846E, r);
	printf("GL_ALIASED_LINE_WIDTH_RANGE = %g %g\n", r[0], r[1]);
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s surfaceless|gbm <out.ppm> [frames] [drm-node]\n", argv[0]);
		return 2;
	}
	int use_gbm = !strcmp(argv[1], "gbm");
	int frames = 1;
	if (argc > 3) {
		frames = 0;
		for (const char *c = argv[3]; *c >= '0' && *c <= '9'; c++)
			frames = frames * 10 + (*c - '0');
	}
	const char *node = argc > 4 ? argv[4] : "/dev/dri/renderD129";
	if (frames < 1 || frames > 1800)
		frames = 1;
	load();

	void *native = NULL;
	if (use_gbm) {
		gbm = dlopen("libgbm.so.1", RTLD_NOW | RTLD_GLOBAL);
		if (!gbm) {
			fprintf(stderr, "dlopen libgbm.so.1: %s\n", dlerror());
			return 3;
		}
		void *(*create)(int) = (void *(*)(int))dlsym(gbm, "gbm_create_device");
		const char *(*bname)(void *) = (const char *(*)(void *))dlsym(gbm, "gbm_device_get_backend_name");
		int fd = open(node, O_RDWR | O_CLOEXEC);
		if (fd < 0 || !create) {
			perror(node);
			return 3;
		}
		native = create(fd);
		printf("gbm device on %s: %p backend=%s\n", node, native, bname && native ? bname(native) : "?");
	}
	EGLDisplay dpy =
		eglGetPlatformDisplayEXT(use_gbm ? EGL_PLATFORM_GBM_KHR : EGL_PLATFORM_SURFACELESS_MESA, native, NULL);
	EGLint maj = 0, min = 0;
	if (!dpy || !eglInitialize(dpy, &maj, &min)) {
		fprintf(stderr, "eglInitialize failed: 0x%x\n", eglGetError());
		return 5;
	}
	printf("platform = %s\n", use_gbm ? "gbm" : "surfaceless");
	printf("EGL_VERSION = %s\n", eglQueryString(dpy, EGL_VERSION));
	printf("EGL_VENDOR = %s\n", eglQueryString(dpy, EGL_VENDOR));
	printf("EGL_CLIENT_APIS = %s\n", eglQueryString(dpy, EGL_CLIENT_APIS));
	printf("EGL_EXTENSIONS = %s\n", eglQueryString(dpy, EGL_EXTENSIONS));
	printf("EGL_CLIENT_EXTENSIONS = %s\n", eglQueryString(NULL, EGL_EXTENSIONS));

	eglBindAPI(EGL_OPENGL_ES_API);
	const EGLint cfg_attr[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
				   EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
	EGLConfig cfg = NULL;
	EGLint n = 0;
	if (!eglChooseConfig(dpy, cfg_attr, &cfg, 1, &n) || n < 1) {
		fprintf(stderr, "eglChooseConfig: none (0x%x)\n", eglGetError());
		return 5;
	}
	const EGLint ctx_attr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	EGLContext ctx = eglCreateContext(dpy, cfg, NULL, ctx_attr);
	if (!ctx) {
		fprintf(stderr, "eglCreateContext failed: 0x%x\n", eglGetError());
		return 5;
	}
	EGLSurface surf = NULL;
	if (use_gbm) {
		const EGLint pb_attr[] = {EGL_WIDTH, W, EGL_HEIGHT, H, EGL_NONE};
		surf = eglCreatePbufferSurface(dpy, cfg, pb_attr);
		if (!surf) {
			fprintf(stderr, "eglCreatePbufferSurface failed: 0x%x\n", eglGetError());
			return 5;
		}
	}
	if (!eglMakeCurrent(dpy, surf, surf, ctx)) {
		fprintf(stderr, "eglMakeCurrent failed: 0x%x\n", eglGetError());
		return 5;
	}
	load_gl();
	printf("GL_VENDOR = %s\n", glGetString(GL_VENDOR));
	printf("GL_RENDERER = %s\n", glGetString(GL_RENDERER));
	printf("GL_VERSION = %s\n", glGetString(GL_VERSION));
	printf("GL_SHADING_LANGUAGE_VERSION = %s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));
	printf("GL_EXTENSIONS = %s\n", glGetString(GL_EXTENSIONS));
	limits();
	fflush(stdout);

	if (!use_gbm) {
		GLuint tex, fbo;
		glGenTextures(1, &tex);
		glBindTexture(GL_TEXTURE_2D, tex);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glGenFramebuffers(1, &fbo);
		glBindFramebuffer(GL_FRAMEBUFFER, fbo);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
		GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
		printf("fbo status = 0x%x%s\n", st, st == GL_FRAMEBUFFER_COMPLETE ? " (complete)" : "");
		if (st != GL_FRAMEBUFFER_COMPLETE)
			return 6;
	}
	GLuint prog = glCreateProgram();
	glAttachShader(prog, shader(GL_VERTEX_SHADER, vs_src));
	glAttachShader(prog, shader(GL_FRAGMENT_SHADER, fs_src));
	glBindAttribLocation(prog, 0, "pos");
	glLinkProgram(prog);
	GLint linked = 0;
	glGetProgramiv(prog, GL_LINK_STATUS, &linked);
	if (!linked) {
		fprintf(stderr, "link failed\n");
		return 4;
	}
	/* A triangle covering the lower-left half; the rest stays the clear colour. */
	static const GLfloat tri[] = {-1, -1, 1, -1, -1, 1};

	double t0 = now();
	for (int f = 0; f < frames; f++) {
		double fs = now();
		glViewport(0, 0, W, H);
		glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glUseProgram(prog);
		glVertexAttribPointer(0, 2, GL_FLOAT, 0, 0, tri);
		glEnableVertexAttribArray(0);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		glFinish();
		if (frames > 1 && f % 30 == 0) {
			int t = die_temp_mc();
			if (t > 90000) {
				fprintf(stderr, "die temperature %d mC > 90 C, stopping\n", t);
				break;
			}
		}
		double left = 1.0 / 30 - (now() - fs);
		if (frames > 1 && left > 0)
			usleep((useconds_t)(left * 1e6));
	}
	double dt = now() - t0;
	printf("frames = %d in %.3f s\n", frames, dt);

	static unsigned char px[W * H * 4];
	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	printf("glGetError after readback = 0x%x\n", glGetError());
	/* (x, y) in GL coordinates, origin bottom-left. */
	static const int pts[][2] = {{10, 10}, {200, 230}, {64, 64}, {200, 20}, {250, 5}, {127, 127}};
	for (unsigned i = 0; i < sizeof(pts) / sizeof(pts[0]); i++) {
		const unsigned char *p = px + 4 * (pts[i][1] * W + pts[i][0]);
		printf("pixel(%d,%d) = %u %u %u %u\n", pts[i][0], pts[i][1], p[0], p[1], p[2], p[3]);
	}
	FILE *o = fopen(argv[2], "wb");
	if (o) {
		fprintf(o, "P6\n%d %d\n255\n", W, H);
		for (int y = H - 1; y >= 0; y--)
			for (int x = 0; x < W; x++)
				fwrite(px + 4 * (y * W + x), 1, 3, o);
		fclose(o);
	}
	/* SGXPROBE_HOLD=<s>: keep the context current and idle before teardown
	 * (to see whether the GFX domain idles while a client is open). */
	const char *hold = getenv("SGXPROBE_HOLD");
	if (hold) {
		int hs = 0;
		for (const char *c = hold; *c >= '0' && *c <= '9'; c++)
			hs = hs * 10 + (*c - '0');
		if (hs > 300)
			hs = 300;
		printf("holding context idle for %d s\n", hs);
		fflush(stdout);
		sleep((unsigned)hs);
		/* Render again in the same context after the idle period (the GFX
		 * domain may have been powered off under the open context). */
		double r0 = now();
		glViewport(0, 0, W, H);
		glClearColor(0.0f, 1.0f, 0.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glUseProgram(prog);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		glFinish();
		glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
		const unsigned char *a = px + 4 * (20 * W + 200), *b = px + 4 * (230 * W + 200);
		printf("after hold: render+readback %.3f s, glGetError=0x%x, pixel(200,20) = %u %u %u %u, "
		       "pixel(200,230) = %u %u %u %u (expect 200 20 64 255 / 0 255 0 255)\n",
		       now() - r0, glGetError(), a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3]);
	}
	eglMakeCurrent(dpy, NULL, NULL, NULL);
	if (surf)
		eglDestroySurface(dpy, surf);
	eglDestroyContext(dpy, ctx);
	eglTerminate(dpy);
	return 0;
}
