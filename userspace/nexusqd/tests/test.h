#ifndef TEST_H
#define TEST_H
#include <stdio.h>
static int _fails;
#define CHECK(cond) do { if (!(cond)) { _fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define RUN(fn) do { printf("== %s\n", #fn); fn(); } while (0)
#define REPORT() (printf(_fails ? "FAILED (%d)\n" : "OK\n", _fails), _fails ? 1 : 0)
#endif
