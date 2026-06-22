/*
 * ulpiread - read the external ULPI PHY (SMSC USB3320) registers on the OMAP4
 * EHCI port 1 via the INSNREG05 viewport, from userspace through /dev/mem.
 *
 * Works even with CONFIG_STRICT_DEVMEM: that only blocks RAM, not the device
 * MMIO at 0x4A064xxx. Static-link for ARM so it runs on any rootfs (incl. the
 * stock Android image): arm gcc -static -O2 -o ulpiread ulpiread.c
 *
 * Use it to compare the WORKING stock PHY state against the broken mainline one
 * (mainline reads OTG=0x66 FUNC=0x45 DEBUG=0x0/SE0; if stock differs there, that
 * VBUS/host-mode bit is the bring-up gap).
 */
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define EHCI_BASE   0x4A064C00u
#define OFF_PORTSC  0x54u        /* port_status[0] */
#define OFF_INSN05  0xA4u        /* INSNREG05_ULPI viewport */
#define CTRL  (1u << 31)         /* start / busy */
#define PORT1 (1u << 24)         /* PORTSEL = 1 */
#define OPRD  (3u << 22)         /* OPSEL = read */

int main(void)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("open /dev/mem"); return 1; }

	off_t page = EHCI_BASE & ~0xFFFu;
	volatile uint8_t *m = mmap(0, 0x1000, PROT_READ | PROT_WRITE,
				   MAP_SHARED, fd, page);
	if (m == MAP_FAILED) { perror("mmap"); return 1; }

	volatile uint32_t *insn   = (volatile uint32_t *)(m + (EHCI_BASE - page) + OFF_INSN05);
	volatile uint32_t *portsc = (volatile uint32_t *)(m + (EHCI_BASE - page) + OFF_PORTSC);

	struct { uint8_t reg; const char *name; } regs[] = {
		{0x00,"VID_LOW"},{0x01,"VID_HIGH"},{0x02,"PID_LOW"},{0x03,"PID_HIGH"},
		{0x04,"FUNC_CTRL"},{0x06,"IFC_CTRL"},{0x0a,"OTG_CTRL"},
		{0x0d,"USB_INT_EN"},{0x13,"USB_INT_STS"},{0x15,"DEBUG"},
	};
	for (unsigned i = 0; i < sizeof(regs)/sizeof(regs[0]); i++) {
		*insn = CTRL | PORT1 | OPRD | ((uint32_t)regs[i].reg << 16);
		int to = 1000000;
		while ((*insn & CTRL) && --to) ;
		if (!to) { printf("ULPI[0x%02x] %-11s = TIMEOUT\n", regs[i].reg, regs[i].name); continue; }
		printf("ULPI[0x%02x] %-11s = 0x%02x\n", regs[i].reg, regs[i].name, *insn & 0xff);
	}
	printf("PORTSC = 0x%08x\n", *portsc);
	return 0;
}
