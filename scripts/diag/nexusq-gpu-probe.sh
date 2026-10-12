#!/bin/sh
# Read-only SGX540 probe; used by nq-opp-study2.sh GPU=1 (moved from the GPU
# drafts 2026-10-11). The everyday GPU checks are in nq-diag-snapshot's
# GPU_SGX540 section (device r129); this one adds --pmic and --regs.
#
# nexusq-gpu-probe.sh -- read-only state of the PowerVR SGX540 on a Nexus Q.
#
# Phase 0 step 2 of docs/2026-10-11-gpu-sgx540-groundwork.md: is the GPU
# device there and unbound, where does its clock come from, is the GFX power
# domain off, what does the kernel say. Later phases rerun it unchanged: the
# same checks then report the driver bound, the stock clock and GFX idling.
#
# Read-only by construction:
#   * only reads of /proc, /sys and debugfs; no file is written, nothing is
#     loaded, bound, played or enabled;
#   * every external command runs under `timeout` and `nice -n 19` (r() below),
#     so a blocking sysfs read cannot hang the probe or compete with audio;
#   * with --pmic only: single-byte SMBus reads of the TWL6030 at 0x48 on its
#     own bus (i2cget -f; never i2cset), see the VDD_CORE section. They show
#     the VCORE1 block raw; the live VDD_CORE setpoint is not readable there;
#   * no access to the GPU's own registers. /dev/mem is used only with --regs,
#     only for an allowlist of PRM/CM addresses (always-on), and an address in
#     0x56000000-0x57ffffff is refused outright: touching the SGX window while
#     GFX is off raises an L3 error / imprecise abort [groundwork §7, pm §8.1].
#   * Caveat: reading debugfs pm_debug/time makes the kernel take one
#     power-domain sample (pwrdm_dbg_show_timer, pm §6.1). That is bookkeeping,
#     not a device state change; use --no-pmdebug to skip it.
#
# The first remote command is still `hostname` (AGENTS.md); this script checks
# it again and refuses to run anywhere but the expected unit.
#
# Usage (as root on the Q; without root the debugfs checks are skipped):
#   nexusq-gpu-probe.sh [--host NAME] [--client] [--regs] [--pmic] [--no-pmdebug]
#   ssh root@<unit> 'sh -s -- [options]' <nexusq-gpu-probe.sh
#     --host NAME   expected hostname (default: $NQ_EXPECT_HOST or "steelhead")
#     --client      a GPU client is running on purpose: GFX ON is not a failure
#     --regs        also read PRM/CM registers with busybox devmem (allowlisted)
#     --pmic        also read the TWL6030 VCORE1 block (raw; VDD_CORE itself
#                   is not readable there, see the VDD_CORE section)
#     --no-pmdebug  do not read debugfs pm_debug (see caveat above)
#   NQ_TIMEOUT=s    per-command timeout (default 5)
#
# Output: one line per check, "PASS|FAIL|WARN|INFO|SKIP  check  detail".
# Exit:   0 no FAIL, 1 at least one FAIL, 2 wrong host or bad usage.
#
# Seen failing first (groundwork §4 Phase 0): on 6.18.48-r20 `gpu_driver` and
# `gpu_clock` must report FAIL (no driver; mux on dpll_core_m7x2_ck at
# 266666667, snapshot.txt:465-470). `gpu_clock` must flip to PASS after the
# 0062 DT block, `gpu_driver` after Phase 1.
#
# Evidence for every path and value is cited inline; short names as in the
# groundwork note (pm = power-clocks-pm.md, kdp = kernel-driver-port.md,
# ml = mainline-6.18.md).
set -u

TO="${NQ_TIMEOUT:-5}"
EXPECT_HOST="${NQ_EXPECT_HOST:-steelhead}"
CLIENT=0
REGS=0
PMIC=0
PMDEBUG=1
SETTLE_S=2   # pm §8.3 step 3: GFX must be off within 1 s of idling; 2 s margin

# Every external command goes through r(): bounded in time, lowest priority.
r() { timeout "$TO" nice -n 19 "$@"; }
# Read one small file; empty output (not an error) when it is missing.
rd() { r cat "$1" 2>/dev/null; }

# Kept in step with the header by hand: under `sh -s` there is no $0 to read.
usage() {
	r cat <<-'EOF'
		Usage (as root on the Q; without root the debugfs checks are skipped):
		  nexusq-gpu-probe.sh [--host NAME] [--client] [--regs] [--pmic] [--no-pmdebug]
		  ssh root@<unit> 'sh -s -- [options]' <nexusq-gpu-probe.sh
		    --host NAME   expected hostname (default: $NQ_EXPECT_HOST or "steelhead")
		    --client      a GPU client is running on purpose: GFX ON is not a failure
		    --regs        also read PRM/CM registers with busybox devmem (allowlisted)
		    --pmic        also read the TWL6030 VCORE1 block (raw; VDD_CORE itself
		                  is not readable there, see the VDD_CORE section)
		    --no-pmdebug  do not read debugfs pm_debug
		  NQ_TIMEOUT=s    per-command timeout (default 5)
		Output: one line per check, "PASS|FAIL|WARN|INFO|SKIP  check  detail".
		Exit:   0 no FAIL, 1 at least one FAIL, 2 wrong host or bad usage.
	EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--host) [ $# -ge 2 ] || { usage >&2; exit 2; }; EXPECT_HOST="$2"; shift 2 ;;
		--client) CLIENT=1; shift ;;
		--regs) REGS=1; shift ;;
		--pmic) PMIC=1; shift ;;
		--no-pmdebug) PMDEBUG=0; shift ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done

FAILS=0
res() {   # res <PASS|FAIL|WARN|INFO|SKIP> <check> <detail>
	printf '%-4s  %-14s %s\n' "$1" "$2" "$3"
	if [ "$1" = FAIL ]; then FAILS=$((FAILS + 1)); fi
}

# ---------------------------------------------------------------- host ------
host=$(r hostname 2>/dev/null)
if [ "$host" != "$EXPECT_HOST" ]; then
	res FAIL hostname "is '$host', expected '$EXPECT_HOST': wrong host, nothing probed"
	exit 2
fi
compat=$(r tr '\0' ' ' </proc/device-tree/compatible 2>/dev/null)
case "$compat" in
	*google,steelhead*) res PASS hostname "$host; DT compatible: $compat" ;;
	*) res FAIL hostname "$host is not a steelhead (DT compatible: '$compat')"; exit 2 ;;
esac
res INFO kernel "$(r uname -r 2>/dev/null)"

uid=$(r id -u 2>/dev/null)
DBG=/sys/kernel/debug
if [ "$uid" = 0 ] && [ -d "$DBG/clk" ]; then
	DBG_OK=1
else
	DBG_OK=0
	res WARN privileges "uid=$uid or debugfs not mounted: clock, genpd and pm_debug checks are skipped"
fi

# ------------------------------------------------------------ device tree ---
# sgx_module: target-module@56000000 with child gpu@0, inherited from
# omap4.dtsi:484-509 [ml §1, pm §1.1]; no status means okay.
DT=/proc/device-tree/ocp/target-module@56000000
dt_status() {   # dt_status <node dir>: the status string, "okay" when absent
	if [ -e "$1/status" ]; then r tr -d '\0' <"$1/status" 2>/dev/null; else echo okay; fi
}
if [ -d "$DT" ]; then
	st=$(dt_status "$DT")
	if [ "$st" = okay ]; then res PASS dt_target "target-module@56000000 status=$st"
	else res FAIL dt_target "target-module@56000000 status=$st"; fi
else
	res FAIL dt_target "$DT missing"
fi

if [ -d "$DT/gpu@0" ]; then
	gcompat=$(r tr '\0' ' ' <"$DT/gpu@0/compatible" 2>/dev/null)
	st=$(dt_status "$DT/gpu@0")
	case "$gcompat" in
		*ti,omap4430-gpu*)
			if [ "$st" = okay ]; then res PASS dt_gpu "gpu@0 '$gcompat' status=$st"
			else res FAIL dt_gpu "gpu@0 status=$st"; fi ;;
		*) res FAIL dt_gpu "gpu@0 compatible is '$gcompat', expected ti,omap4430-gpu" ;;
	esac
else
	res FAIL dt_gpu "$DT/gpu@0 missing"
fi

# The 0062 draft puts assigned-clocks on the target module (the binding forbids
# them on gpu@0). Second cell of assigned-clock-rates = the dpll_per_m7x2_ck rate.
if [ -e "$DT/assigned-clock-rates" ]; then
	hex=$(r od -An -tx1 -v "$DT/assigned-clock-rates" 2>/dev/null | r tr -d ' \n')
	cell=$(printf '%s' "$hex" | r cut -c9-16)
	if [ -n "$cell" ]; then dtrate=$(printf '%d' "0x$cell"); else dtrate=unreadable; fi
	res INFO dt_clock "assigned-clocks present on target-module@56000000, rate cell=$dtrate"
else
	res INFO dt_clock "no assigned-clocks on target-module@56000000 (0062 DT block not applied)"
fi

# ------------------------------------------------------- platform devices ---
# ti-sysc names the module 5600fe00.target-module (its rev register), the
# child 56000000.gpu [pm §1.3, §6.1]. Whether the child exists on our image
# is open question 2 [groundwork §8].
TM=/sys/bus/platform/devices/5600fe00.target-module
GPU=/sys/bus/platform/devices/56000000.gpu

if [ -e "$TM" ]; then
	res INFO gpu_module_rpm "status=$(rd "$TM/power/runtime_status") active_ms=$(rd "$TM/power/runtime_active_time") suspended_ms=$(rd "$TM/power/runtime_suspended_time") control=$(rd "$TM/power/control")"
else
	res FAIL gpu_module_rpm "$TM missing"
fi

BOUND=0
if [ -e "$GPU" ]; then
	usage_cnt=$(rd "$GPU/power/runtime_usage")   # needs CONFIG_PM_ADVANCED_DEBUG
	res INFO gpu_dev_rpm "status=$(rd "$GPU/power/runtime_status") usage=${usage_cnt:-n/a}"
	if [ -e "$GPU/driver" ]; then
		drv=$(r readlink "$GPU/driver" 2>/dev/null)
		res PASS gpu_driver "56000000.gpu bound to ${drv##*/}"
		BOUND=1
	else
		res FAIL gpu_driver "56000000.gpu has no driver (expected before Phase 1)"
	fi
else
	res FAIL gpu_driver "56000000.gpu not created: no driver can bind (groundwork §8 q2)"
fi

# ------------------------------------------------------------------ clock ---
# l3-gfx-clkctrl:0000:24 is the SGX mux (bit 24, parents dpll_core_m7x2_ck /
# dpll_per_m7x2_ck, clk-44xx.c:327-331); :0 is the gate. Stock parity is
# dpll_per_m7x2_ck at 307.2 MHz; 153.6 MHz is the VDD_CORE fallback; 384 MHz
# needs VDD_CORE 1.25 V and is never acceptable on mainline [pm §2, §4].
MUX=l3-gfx-clkctrl:0000:24
GATE=l3-gfx-clkctrl:0000:0
if [ "$DBG_OK" = 1 ]; then
	parent=$(rd "$DBG/clk/$MUX/clk_parent")   # debugfs file, 0444 (clk.c, 6.12.12:3743)
	rate=$(rd "$DBG/clk/$MUX/clk_rate")
	if [ -z "$parent" ]; then
		# Fallback: walk clk_summary. A clock line has a numeric enable count in
		# field 2; children are indented 3 columns deeper (snapshot.txt:465-470).
		# shellcheck disable=SC2016  # an awk program: $2/$5 are awk fields
		pr=$(r awk -v want="$MUX" '
			$2 ~ /^[0-9]+$/ && NF >= 9 {
				match($0, /[^ ]/); ind = RSTART; name[ind] = $1
				if ($1 == want) { print name[ind - 3], $5; exit }
			}' "$DBG/clk/clk_summary" 2>/dev/null)
		parent=${pr% *}; rate=${pr#* }
	fi
	case "$parent:$rate" in
		dpll_per_m7x2_ck:307200000)
			res PASS gpu_clock "$MUX <- $parent at $rate (stock OPP100)" ;;
		dpll_per_m7x2_ck:153600000)
			res WARN gpu_clock "$MUX <- $parent at $rate (OPP50: only right if VDD_CORE < 1.127 V, pm §4 gate)" ;;
		*:384000000)
			res FAIL gpu_clock "$MUX at 384 MHz: needs VDD_CORE 1.25 V, which mainline cannot set" ;;
		dpll_core_m7x2_ck:*)
			res FAIL gpu_clock "$MUX <- $parent at $rate: not stock (0062 DT block missing)" ;;
		:*)
			res FAIL gpu_clock "$MUX not found in debugfs" ;;
		*)
			res FAIL gpu_clock "$MUX <- $parent at $rate: unexpected" ;;
	esac
	res INFO gpu_clk_gate "$GATE enable=$(rd "$DBG/clk/$GATE/clk_enable_count") prepare=$(rd "$DBG/clk/$GATE/clk_prepare_count")"
	# Does the unused M7 output autoidle once the mux moves? (groundwork §8 q14)
	for c in dpll_core_m7x2_ck dpll_per_m7x2_ck; do
		res INFO dpll_m7 "$c rate=$(rd "$DBG/clk/$c/clk_rate") enable=$(rd "$DBG/clk/$c/clk_enable_count") prepare=$(rd "$DBG/clk/$c/clk_prepare_count")"
	done
else
	res SKIP gpu_clock "needs root and debugfs"
fi

# ----------------------------------------------------------- GFX domain -----
# genpd prm_gfx (ON/OFF only, omap_prm_onoff_noauto) is the authority for GFX
# power; runtime PM of the target module the second source. Never mix them with
# pm_debug in one ratio [pm §6.1, groundwork §5 P12].
G="$DBG/pm_genpd/prm_gfx"
gfx_state() { rd "$G/current_state"; }
if [ "$DBG_OK" = 1 ] && [ -d "$G" ]; then
	st=$(gfx_state)
	res INFO prm_gfx "state=$st active_time=$(rd "$G/active_time") total_idle_time=$(rd "$G/total_idle_time")"
	case "$st" in
		off*) res PASS gfx_idle "prm_gfx $st" ;;
		*)
			if [ "$CLIENT" = 1 ]; then
				res INFO gfx_idle "prm_gfx $st with --client (expected while rendering)"
			else
				r sleep "$SETTLE_S"
				st=$(gfx_state)
				case "$st" in
					off*) res PASS gfx_idle "prm_gfx $st after ${SETTLE_S} s" ;;
					*)
						if [ "$BOUND" = 1 ]; then
							res FAIL gfx_idle "prm_gfx $st with the driver bound and no client: pinned ON (risk P1, kdp §8 d)"
						else
							res FAIL gfx_idle "prm_gfx $st with no driver bound: something holds GFX"
						fi ;;
				esac
			fi ;;
	esac
else
	res SKIP prm_gfx "needs root and debugfs pm_genpd/prm_gfx"
fi

# pm_debug samples gfx_pwrdm only at MPUSS low-power transitions: biased while
# rendering, fine at idle [pm §6.1, groundwork §5 P12].
if [ "$DBG_OK" = 1 ] && [ "$PMDEBUG" = 1 ] && [ -r "$DBG/pm_debug/count" ]; then
	r grep -E '^(gfx|dss|core)_pwrdm' "$DBG/pm_debug/count" 2>/dev/null | while IFS= read -r l; do
		res INFO pwrdm_count "$l"
	done
	r grep -E '^(gfx|dss|core)_pwrdm' "$DBG/pm_debug/time" 2>/dev/null | while IFS= read -r l; do
		res INFO pwrdm_time "$l"
	done
else
	res SKIP pm_debug "skipped (no root/debugfs, or --no-pmdebug)"
fi

# --------------------------------------------------------------- VDD_CORE ---
# Linux exposes no VDD_CORE regulator on mainline OMAP4 [pm §4]; the voltage
# has to be measured another way before the first GPU boot (gate: >= 1.127 V
# for 307.2 MHz, else 153.6 MHz).
vcore=""
for d in /sys/class/regulator/regulator.*; do
	[ -e "$d/name" ] || continue
	n=$(rd "$d/name")
	case "$n" in
		*core*|*CORE*) vcore="$vcore $n=$(rd "$d/microvolts")uV" ;;
	esac
done
if [ -n "$vcore" ]; then
	res INFO vdd_core "regulator(s):$vcore"
else
	res INFO vdd_core "no VDD_CORE regulator in Linux (expected, pm §4); only a multimeter on VCORE1 measures it"
fi

# --pmic: TWL6030 VCORE1 block over the control i2c [pm Addendum "Live
# VDD_CORE without a device", corrected 2026-10-11 by "Live read"]. This is
# NOT a VDD_CORE reading. Measured on the Prague unit (6.18.48-r20): VCORE1
# 0x52..0x57 = 07 05 55 00 00 06 with the rail powered, while the fixed SMPSs
# beside it hold their setpoint at block+4 (V1V8 0x4a=0x3c = 1.8 V, V2V1
# 0x50=0x3e = 2.1 V). The x-loader programs VCORE1 through the SmartReflex
# interface (slave 0x12, PRM_VC_VAL_BYPASS); that setpoint does not show up
# at 0x48:0x55/0x56, so these reads cannot gate the 307.2 MHz clock. A zero
# vsel is "not programmed through this interface", never 0 uV. The gate needs
# a multimeter on VCORE1's output [pm §4 method 3].
# Block layout (stride 6 from 0x40; GRP/TRANS/STATE per twl6030-regulator.c
# VREG_GRP/TRANS/STATE, VREG_VOLTAGE_SMPS = +4; +3/+5 names UNVERIFIED).
# -f is required: twl-core is bound to 0x48, so i2c-dev would return EBUSY
# (i2c-dev.c:188-196, 414-415). The bus is found by the client name, never
# assumed: a TMP101 also answers at 0x48 on I2C2. Reads only; never i2cset.
vsel_uv() {   # vsel_uv <vsel> <smps_offset>: echo uV; empty for 0 or unmapped
	v=$(($1 & 0x3f))
	if [ $(($2 & 0x08)) -ne 0 ]; then base=709000; else base=607700; fi
	if [ "$v" -ge 1 ] && [ "$v" -le 57 ]; then
		echo $((base + (v - 1) * 12660))
	elif [ "$v" -eq 58 ]; then
		echo 1350000
	fi
}
if [ "$PMIC" = 1 ]; then
	bus=""
	for c in /sys/bus/i2c/devices/*-0048; do
		[ "$(rd "$c/name")" = twl6030 ] || continue
		bus=${c##*/}
		bus=${bus%-0048}
	done
	if [ "$uid" != 0 ] || [ -z "$bus" ] || ! command -v i2cget >/dev/null 2>&1; then
		res SKIP vdd_core_pmic "needs root, i2cget and a bound twl6030 client N-0048 (bus '${bus}')"
	else
		tw() { r i2cget -y -f "$bus" 0x48 "$1" b 2>/dev/null; }
		offs=$(tw 0xe0)
		grp=$(tw 0x52)
		trans=$(tw 0x53)
		state=$(tw 0x54)
		r55=$(tw 0x55)
		r56=$(tw 0x56)
		v1v8=$(tw 0x4a)
		raw="i2c-$bus 0x48: e0=$offs 52=$grp 53=$trans 54=$state 55=$r55 56=$r56 (V1V8 4a=$v1v8)"
		if [ -z "$offs" ] || [ -z "$state" ] || [ -z "$r55" ] || [ -z "$r56" ]; then
			res WARN vdd_core_pmic "read failed ($raw)"
		else
			# CFG_STATE bits 3:2 = APP state, 1 = ON (twl6030-regulator.c:63-70)
			if [ $(((state >> 2) & 3)) -eq 1 ]; then on="VCORE1 ON for APP"; else on="VCORE1 APP state $(((state >> 2) & 3))"; fi
			u55=$(vsel_uv "$r55" "$offs")
			u56=$(vsel_uv "$r56" "$offs")
			if [ -z "$u55" ] && [ -z "$u56" ]; then
				res WARN vdd_core_pmic "$on; setpoint not readable via the control interface (0x55/0x56 vsel 0): VDD_CORE unknown, 307.2 MHz gate needs a multimeter, else 153.6 MHz ($raw)"
			else
				res WARN vdd_core_pmic "$on; control-interface value(s) 0x55=${u55:-n/a} uV 0x56=${u56:-n/a} uV, not proven to be the active setpoint: no gate verdict ($raw)"
			fi
		fi
	fi
fi

# ---------------------------------------------- PRM/CM registers (--regs) ---
# Allowlist from pm §8.1 (PRM and CM only, always accessible). Bit layouts:
# PWRSTST POWERSTATEST 1:0, LASTPOWERSTATEENTERED 25:24 (prm.h:70,
# prm-regbits-44xx.h:42; 0 OFF, 1 RET, 2 INA, 3 ON, powerdomain.h:22-25);
# CLKCTRL MODULEMODE 1:0, IDLEST 17:16, STBYST 18 (clkctrl.c:22-35), CLKSEL
# bit 24 (clk-44xx.c:327-331); VP_CONFIG INITVOLTAGE 15:8, VP_VOLTAGE 7:0
# (prm-regbits-44xx.h:40,90). VP_CORE is expected to read 0: mainline leaves
# INITVOLTAGE 0 and never force-updates the core VP [pm §4 method 1].
reg() {   # reg <address>: prints the 32-bit value, or nothing when refused
	case "$1" in
		0x56*|0x57*) res FAIL regs "refusing $1: inside the SGX window"; return 1 ;;
		0x4a307200|0x4a307204|0x4a009200|0x4a009204|0x4a009220|0x4a307b40|0x4a307b44|0x4a307b4c) ;;
		*) res FAIL regs "refusing $1: not on the allowlist"; return 1 ;;
	esac
	r devmem "$1" 32 2>/dev/null
}
pwr() { case "$1" in 0) echo OFF ;; 1) echo RET ;; 2) echo INA ;; 3) echo ON ;; *) echo "?" ;; esac; }
if [ "$REGS" = 1 ]; then
	if [ "$uid" != 0 ] || ! command -v devmem >/dev/null 2>&1; then
		res SKIP regs "needs root and busybox devmem"
	else
		v=$(reg 0x4a307204)
		if [ -n "$v" ]; then
			res INFO PM_GFX_PWRSTST "$v now=$(pwr $((v & 3))) last=$(pwr $(((v >> 24) & 3)))"
		fi
		v=$(reg 0x4a307200); [ -n "$v" ] && res INFO PM_GFX_PWRSTCTRL "$v"
		v=$(reg 0x4a009200); [ -n "$v" ] && res INFO CM_GFX_CLKSTCTRL "$v clktrctrl=$((v & 3))"
		v=$(reg 0x4a009204); [ -n "$v" ] && res INFO CM_GFX_STATICDEP "$v (expected 0, pm §1.1)"
		v=$(reg 0x4a009220)
		if [ -n "$v" ]; then
			res INFO CM_GFX_GFX_CLKCTRL "$v modulemode=$((v & 3)) idlest=$(((v >> 16) & 3)) stbyst=$(((v >> 18) & 1)) clksel=$(((v >> 24) & 1)) (clksel 1 = dpll_per_m7x2_ck)"
		fi
		v=$(reg 0x4a307b40)
		[ -n "$v" ] && res INFO PRM_VP_CORE_CONFIG "$v initvoltage=$(((v >> 8) & 255))"
		v=$(reg 0x4a307b44); [ -n "$v" ] && res INFO PRM_VP_CORE_STATUS "$v"
		v=$(reg 0x4a307b4c); [ -n "$v" ] && res INFO PRM_VP_CORE_VOLTAGE "$v vsel=$((v & 255)) (convert per docs/2026-07-02 §1; 0 = not driven)"
	fi
fi

# ----------------------------------------------------------------- module ---
# openpvrsgx builds pvrsrvkm_omap4_sgx540_120.ko [kdp §4]; it must be
# blacklisted until runtime PM is proven [groundwork §4 Phase 1 step 3].
KM=pvrsrvkm_omap4_sgx540_120
kofile=$(r modinfo -F filename "$KM" 2>/dev/null)
if [ -n "$kofile" ]; then
	res INFO km_file "$kofile vermagic='$(r modinfo -F vermagic "$KM" 2>/dev/null)'"
else
	res INFO km_file "$KM.ko not in /lib/modules/$(r uname -r 2>/dev/null)"
fi
if r grep -q "^$KM " /proc/modules 2>/dev/null; then
	res INFO km_loaded "$KM loaded"
else
	res INFO km_loaded "$KM not loaded"
fi
bl=$(r grep -rhs "blacklist[[:space:]]\+$KM" /etc/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d 2>/dev/null)
case " $(rd /proc/cmdline) " in
	*"modprobe.blacklist="*"$KM"*) bl="$bl cmdline" ;;
esac
if [ -n "$kofile" ] && [ -z "$bl" ]; then
	res WARN km_blacklist "$KM is installed but not blacklisted: udev may autoload it (risk P11)"
else
	res INFO km_blacklist "${bl:-none (no module installed)}"
fi

# ----------------------------------------------------------- device nodes ---
# 1.17 with pvr-drv.c is a DRM render driver: card1 + renderD129 next to
# omapdrm's card0/renderD128 [kdp §12 step 6, §13]. /dev/pvrsrvkm is the old
# non-DRM node name; listed only so its absence is recorded.
if [ -e /dev/pvrsrvkm ]; then res INFO dev_pvrsrvkm "/dev/pvrsrvkm present"
else res INFO dev_pvrsrvkm "/dev/pvrsrvkm absent (expected with the DRM build)"; fi
nodes=""
for c in /sys/class/drm/card[0-9] /sys/class/drm/renderD[0-9]*; do
	[ -e "$c" ] || continue
	d=$(r readlink "$c/device/driver" 2>/dev/null)
	nodes="$nodes ${c##*/}=${d##*/}"
done
res INFO drm_nodes "${nodes:- none}"
if [ -r /proc/pvr/version ]; then
	res INFO proc_pvr "$(r head -n 3 /proc/pvr/version 2>/dev/null | r tr '\n' ' ')"
fi

# ------------------------------------------------------------- kernel log ---
# GPU IRQ: GIC SPI 21 = hwirq 53 [pm §8.1]; the Linux irq number differs.
irq=$(r grep -E 'GIC-0 +53 |pvr|sgx' /proc/interrupts 2>/dev/null)
res INFO gpu_irq "${irq:-no GPU interrupt line registered}"

log=$(r dmesg 2>/dev/null | r grep -iE 'pvr|sgx|powervr|56000000\.gpu|5600fe00|prm_gfx|gfx_pwrdm')
if [ -z "$log" ]; then
	res INFO dmesg "no GPU lines"
else
	printf '%s\n' "$log" | while IFS= read -r l; do res INFO dmesg "$l"; done
	nerr=$(printf '%s\n' "$log" | r grep -ciE 'PVR_K:\(Error\)|SGXInit.*(FAIL|Mismatch)|pm_runtime_get_sync failed|timed out')
	if [ "${nerr:-0}" -gt 0 ]; then res FAIL dmesg_errors "$nerr GPU error line(s)"
	else res PASS dmesg_errors "no GPU error lines"; fi
fi

res INFO temp "thermal_zone0=$(rd /sys/class/thermal/thermal_zone0/temp) mC"

if [ "$FAILS" -gt 0 ]; then
	res INFO summary "$FAILS FAIL"
	exit 1
fi
res INFO summary "no FAIL"
exit 0
