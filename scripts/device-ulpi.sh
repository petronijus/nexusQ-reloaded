#!/bin/sh
# ULPI register read/write on the OMAP EHCI port-1 (USB3320 PHY) via the
# INSNREG05 viewport, from user space using devmem. For Nexus Q ethernet
# bring-up diagnosis. PORTSEL is 1-based (port 1).
DM=/usr/local/bin/devmem
I5=0x4A064CA4          # EHCI INSNREG05_ULPI (regs base 0x4A064C00 + 0xA4)
PORTSC=0x4A064C54      # port_status[0]
PORT=1

_poll() { for i in $(seq 1 200); do v=$($DM $I5 32); [ $(( (v >> 31) & 1 )) -eq 0 ] && return 0; done; echo "TIMEOUT"; }

ulpi_rd() {  # $1=reg
  w=$(( (1<<31) | ($PORT<<24) | (3<<22) | ($1<<16) ))
  $DM $I5 32 $(printf 0x%X $w) >/dev/null
  _poll
  printf "0x%02x" $(( $($DM $I5 32) & 0xff ))
}
ulpi_wr() {  # $1=set-reg-addr $2=val
  w=$(( (1<<31) | ($PORT<<24) | (2<<22) | ($1<<16) | $2 ))
  $DM $I5 32 $(printf 0x%X $w) >/dev/null
  _poll
}

case "$1" in
  dump)
    echo "VID        =$(ulpi_rd 0x00):$(ulpi_rd 0x01)"
    echo "PID        =$(ulpi_rd 0x02):$(ulpi_rd 0x03)"
    echo "FUNC_CTRL  =$(ulpi_rd 0x04)   (bit6=SuspendM bit5=Reset; OpMode[4:3] TermSel[2] XcvrSel[1:0])"
    echo "IFACE_CTRL =$(ulpi_rd 0x07)"
    echo "OTG_CTRL   =$(ulpi_rd 0x0a)   (bit6=DrvVbusExt bit5=DrvVbus bit1=DpPd bit0=IdPullup)"
    echo "USB_INT_EN =$(ulpi_rd 0x0d)"
    echo "USB_INT_STS=$(ulpi_rd 0x13)"
    echo "USB_INT_LAT=$(ulpi_rd 0x14)"
    echo "DEBUG      =$(ulpi_rd 0x15)   (bit1=LineState1 bit0=LineState0; 00=SE0)"
    echo "PORTSC     =$($DM $PORTSC 32)"
    ;;
  drvvbus)   # set DrvVbus + DrvVbusExternal via OTG_CTRL SET (0x0b)
    echo "OTG_CTRL before=$(ulpi_rd 0x0a)"
    ulpi_wr 0x0b 0x60
    echo "OTG_CTRL after =$(ulpi_rd 0x0a)"
    ;;
  wake)      # clear SuspendM? set FUNC_CTRL SuspendM via SET(0x05)=bit6
    ulpi_wr 0x05 0x40
    echo "FUNC_CTRL=$(ulpi_rd 0x04)"
    ;;
  rd) ulpi_rd "$2"; echo ;;
  wr) ulpi_wr "$2" "$3" ;;
esac
