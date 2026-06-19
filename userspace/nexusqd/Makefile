CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Iinclude
SRC      = src/frame.c src/themes.c src/avr.c src/compositor.c src/keys.c src/control.c src/reaction.c
DAEMON   = src/nexusqd.c $(SRC)
CLI      = src/nexusled.c src/avr.c src/frame.c
TESTS    = $(wildcard tests/test_*.c)

all: nexusqd nexusled
nexusqd: $(DAEMON); $(CC) $(CFLAGS) -o $@ $(DAEMON)
nexusled: $(CLI); $(CC) $(CFLAGS) -o $@ $(CLI)

test: $(patsubst tests/test_%.c,build/test_%,$(TESTS))
	@fail=0; for t in $^; do echo "### $$t"; ./$$t || fail=1; done; exit $$fail
# each unit test links only its matching module (tests/test_foo.c <-> src/foo.c)
build/test_%: tests/test_%.c src/%.c | build
	$(CC) $(CFLAGS) -Itests -o $@ $< src/$*.c
# reaction renders into a frame, so its test also needs the frame module
build/test_reaction: tests/test_reaction.c src/reaction.c src/frame.c | build
	$(CC) $(CFLAGS) -Itests -o $@ tests/test_reaction.c src/reaction.c src/frame.c
build:; mkdir -p build
clean:; rm -rf build nexusqd nexusled
.PHONY: all test clean
