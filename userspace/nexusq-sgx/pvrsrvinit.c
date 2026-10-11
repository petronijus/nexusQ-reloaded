/*
 * pvrsrvinit: start the PowerVR SGX services (SrvInit) once per load of the
 * kernel module.
 *
 * SrvInit() lives in the TI DDK's libsrv_init.so.1: it uploads the SGX
 * microkernel and its init script through the pvr DRM device and must run as
 * root (the kernel checks CAP_SYS_MODULE), once after every modprobe. The
 * tool TI shipped (pvrsrvctl) is closed; this one only loads the library and
 * calls the entry point.
 *
 * Exit status: 0 on success, 1 when the library or the symbol cannot be
 * loaded, 2 when SrvInit() fails (its PVRSRV_ERROR code is printed).
 *
 * Copyright (c) 2026 Petr Parkan Janda <petronijus@bastla.com>
 * SPDX-License-Identifier: MIT
 */
#include <dlfcn.h>
#include <stdio.h>

int main(void)
{
	void *lib = dlopen("libsrv_init.so.1", RTLD_NOW | RTLD_LOCAL);
	int (*srv_init)(void);
	int rc;

	if (!lib) {
		fprintf(stderr, "pvrsrvinit: %s\n", dlerror());
		return 1;
	}
	*(void **)&srv_init = dlsym(lib, "SrvInit");
	if (!srv_init) {
		fprintf(stderr, "pvrsrvinit: %s\n", dlerror());
		return 1;
	}
	rc = srv_init();
	if (rc) {
		fprintf(stderr, "pvrsrvinit: SrvInit failed: PVRSRV_ERROR %d\n", rc);
		return 2;
	}
	printf("pvrsrvinit: SGX services initialised\n");
	return 0;
}
