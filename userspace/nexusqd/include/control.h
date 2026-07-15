/* userspace/nexusqd/include/control.h */
#ifndef NEXUSQD_CONTROL_H
#define NEXUSQD_CONTROL_H
enum ctl_kind { CTL_THEME, CTL_SET, CTL_MUTE, CTL_OFF, CTL_STATUS, CTL_VOL, CTL_MTOGGLE, CTL_AUTO, CTL_SCENE, CTL_BRIGHTNESS, CTL_BREATHE, CTL_SETMUTED, CTL_SPIN };
/* speed: spin revolutions/second (0 = daemon default). Only CTL_SPIN reads it. */
struct ctl_cmd { enum ctl_kind kind; char name[32]; int rgb[3]; int value; double speed; };
int ctl_parse(const char *line, struct ctl_cmd *out);
#endif
