/* userspace/nexusqd/include/sdnotify.h
 *
 * Minimal, dependency-free sd_notify(3) sender — just enough of the protocol to
 * arm the systemd watchdog (no libsystemd link). Used so a *hang* in the LED
 * render loop (vs a crash, which Restart= already handles) is noticed: the
 * daemon pings WATCHDOG=1 from the render loop, and systemd restarts it if the
 * pings stop for WatchdogSec.
 */
#ifndef NEXUSQD_SDNOTIFY_H
#define NEXUSQD_SDNOTIFY_H

/* Send one sd_notify datagram (e.g. "READY=1", "WATCHDOG=1") to $NOTIFY_SOCKET.
 * No-op (and harmless) when NOTIFY_SOCKET is unset — i.e. when nexusqd is run
 * outside systemd or without WatchdogSec=, so it never affects manual runs. */
void sdnotify_send(const char *state);

#endif /* NEXUSQD_SDNOTIFY_H */
