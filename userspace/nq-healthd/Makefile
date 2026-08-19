# nq-healthd — C rewrite of the shell health monitor. Same JSONL schema.
CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra
PREFIX  ?= /usr

nq-healthd: nq-healthd.c
	$(CC) $(CFLAGS) -o $@ $<

install: nq-healthd
	install -Dm755 nq-healthd $(DESTDIR)$(PREFIX)/bin/nq-healthd

clean:
	rm -f nq-healthd

.PHONY: install clean
