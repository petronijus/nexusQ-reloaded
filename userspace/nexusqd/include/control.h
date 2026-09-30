/* userspace/nexusqd/include/control.h */
#ifndef NEXUSQD_CONTROL_H
#define NEXUSQD_CONTROL_H
enum ctl_kind { CTL_THEME, CTL_SET, CTL_MUTE, CTL_OFF, CTL_STATUS, CTL_VOL, CTL_MTOGGLE, CTL_AUTO, CTL_SCENE, CTL_BRIGHTNESS, CTL_BREATHE, CTL_SETMUTED, CTL_SPIN, CTL_PROGRESS, CTL_MBLINK, CTL_DEBUG, CTL_DARK, CTL_ATTEND };
/* speed: spin revolutions/second (0 = daemon default). Only CTL_SPIN reads it. */
/* ms: CTL_BRIGHTNESS's transition time (0 = at once). */
struct ctl_cmd { enum ctl_kind kind; char name[32]; int rgb[3]; int value; double speed; int ms; };
int ctl_parse(const char *line, struct ctl_cmd *out);
/* Does an `mblink` command change the blink? `blinking`/`cur` is the blink now,
 * `on`/`rgb` the command (on = 0 for `mblink stop`). The bridge re-asserts the
 * blink every 30 s (nexusq-control r63), so a repeat must be a no-op: restarting
 * the blink would shift its phase, and a stop that stops nothing would rewrite
 * the mute LED for nothing. */
int ctl_mblink_changes(int blinking, const int cur[3], int on, const int rgb[3]);
#endif
