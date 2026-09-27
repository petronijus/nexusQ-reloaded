# The ALSA control plugin `nexusq_vol` (libasound_module_ctl_nexusq_vol.so).
#
#   make            build the plugin
#   make test       host test of the scale (tests/test_scale.c)
#   make install DESTDIR=... PLUGINDIR=/usr/lib/alsa-lib
#
# The end-to-end test against a real PulseAudio and alsa-lib's simple mixer is
# tests/run-integration.sh (an Alpine container).

CC       ?= cc
CFLAGS   ?= -O2 -g
# What the plugin cannot be built without, in a variable of its own: abuild
# passes CFLAGS on the make command line, which overrides every assignment
# here, `+=` included -- the first packaged build came out non-PIC (TEXTREL,
# refused by abuild's postcheck). Nothing the caller passes reaches these.
# -DPIC: alsa-lib's plugin-symbol macro references the static-link registry
# (snd_dlsym_start) unless it is told this is a shared object. No
# -fvisibility=hidden: the entry point _snd_ctl_nexusq_vol_open is exported by
# name, and the macro does not mark it visible.
NQV_CFLAGS = -Wall -Wextra -Werror -std=gnu11 -fPIC -DPIC
PKGS      = alsa libpulse
PLUGINDIR ?= /usr/lib/alsa-lib

PLUGIN = libasound_module_ctl_nexusq_vol.so

all: $(PLUGIN)

$(PLUGIN): ctl_nexusq_vol.c nexusq_vol_scale.h
	$(CC) $(CFLAGS) $(NQV_CFLAGS) -shared -o $@ ctl_nexusq_vol.c \
		$$(pkg-config --cflags --libs $(PKGS)) -lm $(LDFLAGS)

build/test_scale: tests/test_scale.c nexusq_vol_scale.h
	@mkdir -p build
	$(CC) -O2 -Wall -Wextra -Werror -I. -o $@ tests/test_scale.c \
		$$(pkg-config --cflags --libs libpulse) -lm

test: build/test_scale
	./build/test_scale

install: $(PLUGIN)
	install -Dm755 $(PLUGIN) $(DESTDIR)$(PLUGINDIR)/$(PLUGIN)

clean:
	rm -rf $(PLUGIN) build

.PHONY: all test install clean
