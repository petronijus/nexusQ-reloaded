/* userspace/nexusqd/include/control.h */
#ifndef NEXUSQD_CONTROL_H
#define NEXUSQD_CONTROL_H
enum ctl_kind { CTL_THEME, CTL_SET, CTL_MUTE, CTL_OFF, CTL_STATUS, CTL_VOL, CTL_MTOGGLE };
struct ctl_cmd { enum ctl_kind kind; char name[32]; int rgb[3]; int value; };
int ctl_parse(const char *line, struct ctl_cmd *out);
#endif
