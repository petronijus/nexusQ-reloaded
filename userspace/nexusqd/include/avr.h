/* userspace/nexusqd/include/avr.h */
#ifndef NEXUSQD_AVR_H
#define NEXUSQD_AVR_H
#include "frame.h"
#define AVR_SYSFS "/sys/bus/i2c/devices/1-0020"
int avr_write_frame(const uint8_t pk[RING*3], int commit);
int avr_set_mute(int r, int g, int b);
#endif
