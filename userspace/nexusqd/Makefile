CC      ?= cc
CFLAGS  ?= -std=c11 -O2 -Wall -Wextra -Iinclude
SRC      = src/frame.c src/themes.c src/avr.c src/compositor.c src/keys.c src/control.c \
           src/reaction.c src/screensaver.c src/audio.c src/audiocap.c src/themecolor.c \
           src/jrandom.c src/ledcfg.c src/fx_waveform.c src/fx_waveformsolid.c \
           src/fx_circles.c src/fx_pointmorph.c src/fx_starfield.c src/music.c \
           src/sdnotify.c
DAEMON   = src/nexusqd.c $(SRC)
CLI      = src/nexusled.c src/avr.c src/frame.c
TESTS    = $(wildcard tests/test_*.c)
LDLIBS  ?= -lm          # screensaver/audiocap/effects use libm (cos/fmod/sqrt/lroundf)

all: nexusqd nexusled
nexusqd: $(DAEMON); $(CC) $(CFLAGS) -o $@ $(DAEMON) $(LDLIBS)
nexusled: $(CLI); $(CC) $(CFLAGS) -o $@ $(CLI)

test: $(patsubst tests/test_%.c,build/test_%,$(TESTS))
	@fail=0; for t in $^; do echo "### $$t"; ./$$t || fail=1; done; exit $$fail
# each test links against all modules (+libm); cross-module effect deps make
# per-module linking impractical, and over-linking unused modules is harmless.
build/test_%: tests/test_%.c $(SRC) | build
	$(CC) $(CFLAGS) -Itests -o $@ $< $(SRC) $(LDLIBS)
build:; mkdir -p build
clean:; rm -rf build nexusqd nexusled
.PHONY: all test clean
