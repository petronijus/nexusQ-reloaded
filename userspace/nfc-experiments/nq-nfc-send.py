#!/usr/bin/env python3
"""
nq-nfc-send — Nexus Q reverse-HCE reader (prototype).

The Q is the ISO-DEP READER; the phone runs a HostApduService (HCE). We poll for
an ISO14443-A/B target (the phone presenting a card), open a raw NFC socket to it,
SELECT our custom AID, then send a payload APDU carrying UTF-8 text. The phone's
HCE service receives it.

Pure-Python: generic netlink to the kernel "nfc" genl family for device up /
start-poll / target discovery, then a PF_NFC/SOCK_SEQPACKET/NFC_SOCKPROTO_RAW
socket for the APDU exchange (net/nfc/rawsock.c).

Run with neard STOPPED (it otherwise owns the netlink device):
    systemctl stop neard
    python3 nq-nfc-send.py "hello world"
"""
import socket, struct, sys, os, time, errno

# --- uapi/linux/nfc.h -------------------------------------------------------
AF_NFC              = 39
NFC_SOCKPROTO_RAW   = 0
NETLINK_GENERIC     = 16
GENL_ID_CTRL        = 16

# generic netlink control
CTRL_CMD_GETFAMILY  = 3
CTRL_ATTR_FAMILY_ID   = 1
CTRL_ATTR_FAMILY_NAME = 2
CTRL_ATTR_MCAST_GROUPS = 7
CTRL_ATTR_MCAST_GRP_NAME = 1
CTRL_ATTR_MCAST_GRP_ID   = 2

# nfc_commands
NFC_CMD_GET_DEVICE       = 1
NFC_CMD_DEV_UP           = 2
NFC_CMD_DEV_DOWN         = 3
NFC_CMD_START_POLL       = 6
NFC_CMD_STOP_POLL        = 7
NFC_CMD_GET_TARGET       = 8
NFC_EVENT_TARGETS_FOUND  = 9
NFC_EVENT_TARGET_LOST    = 12

# nfc_attrs
NFC_ATTR_DEVICE_INDEX    = 1
NFC_ATTR_DEVICE_NAME     = 2
NFC_ATTR_PROTOCOLS       = 3
NFC_ATTR_TARGET_INDEX    = 4
NFC_ATTR_COMM_MODE       = 10
NFC_ATTR_RF_MODE         = 11
NFC_ATTR_IM_PROTOCOLS    = 13

# nfc_protocols -> masks
NFC_PROTO_ISO14443       = 4
NFC_PROTO_ISO14443_B     = 6
ISO_MASK = (1 << NFC_PROTO_ISO14443) | (1 << NFC_PROTO_ISO14443_B)  # 0x50

NLM_F_REQUEST = 0x01
NLM_F_ACK     = 0x04
NLMSG_ERROR   = 0x2
NLMSG_DONE    = 0x3

# --- our reverse-HCE protocol (MUST match the phone HostApduService) --------
AID = bytes.fromhex("F0010203040506")
SELECT_AID = bytes([0x00, 0xA4, 0x04, 0x00, len(AID)]) + AID + bytes([0x00])
def payload_apdu(text: bytes) -> bytes:
    return bytes([0x80, 0x10, 0x00, 0x00, len(text)]) + text


def nla(attr_type, payload):
    ln = 4 + len(payload)
    pad = (4 - (ln % 4)) % 4
    return struct.pack("HH", ln, attr_type) + payload + b"\x00" * pad


def parse_attrs(buf):
    out = {}
    i = 0
    while i + 4 <= len(buf):
        ln, atype = struct.unpack_from("HH", buf, i)
        if ln < 4:
            break
        out[atype] = buf[i + 4:i + ln]
        i += (ln + 3) & ~3
    return out


class Genl:
    def __init__(self):
        self.s = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_GENERIC)
        self.s.bind((0, 0))
        self.seq = 0
        self.pid = self.s.getsockname()[0]

    def _msg(self, family, cmd, attrs=b"", flags=NLM_F_REQUEST):
        self.seq += 1
        genl = struct.pack("BBH", cmd, 1, 0)
        body = genl + attrs
        total = 16 + len(body)
        nlh = struct.pack("IHHII", total, family, flags, self.seq, self.pid)
        return nlh + body

    def request(self, family, cmd, attrs=b"", flags=NLM_F_REQUEST):
        self.s.send(self._msg(family, cmd, attrs, flags))
        return self._recv_one()

    def _recv_one(self, timeout=2.0):
        self.s.settimeout(timeout)
        data = self.s.recv(65536)
        # walk netlink messages
        msgs = []
        i = 0
        while i + 16 <= len(data):
            ln, mtype, flags, seq, pid = struct.unpack_from("IHHII", data, i)
            payload = data[i + 16:i + ln]
            msgs.append((mtype, payload))
            i += (ln + 3) & ~3
        return msgs

    def resolve_nfc(self):
        msgs = self.request(GENL_ID_CTRL, CTRL_CMD_GETFAMILY,
                            nla(CTRL_ATTR_FAMILY_NAME, b"nfc\x00"))
        for mtype, payload in msgs:
            if mtype == NLMSG_ERROR:
                continue
            attrs = parse_attrs(payload[4:])  # skip genlmsghdr
            fam = None
            grp = None
            if CTRL_ATTR_FAMILY_ID in attrs:
                fam = struct.unpack("H", attrs[CTRL_ATTR_FAMILY_ID][:2])[0]
            if CTRL_ATTR_MCAST_GROUPS in attrs:
                # nested: each group is a nested attr with NAME + ID
                gbuf = attrs[CTRL_ATTR_MCAST_GROUPS]
                j = 0
                while j + 4 <= len(gbuf):
                    gln, gtype = struct.unpack_from("HH", gbuf, j)
                    ginner = parse_attrs(gbuf[j + 4:j + gln])
                    name = ginner.get(CTRL_ATTR_MCAST_GRP_NAME, b"").rstrip(b"\x00")
                    if name == b"events" and CTRL_ATTR_MCAST_GRP_ID in ginner:
                        grp = struct.unpack("I", ginner[CTRL_ATTR_MCAST_GRP_ID][:4])[0]
                    j += (gln + 3) & ~3
            return fam, grp
        return None, None


def hexs(b):
    return b.hex(" ")


import ctypes


def wait_for_target(g, fam, DEV, window):
    """(Re)start the ISO14443 poll and block until a target appears or `window`
    seconds elapse. Returns the target index, or None on timeout."""
    attrs = nla(NFC_ATTR_DEVICE_INDEX, struct.pack("I", DEV))
    attrs += nla(NFC_ATTR_IM_PROTOCOLS, struct.pack("I", ISO_MASK))
    attrs += nla(NFC_ATTR_PROTOCOLS, struct.pack("I", ISO_MASK))
    g.request(fam, NFC_CMD_START_POLL, attrs, NLM_F_REQUEST | NLM_F_ACK)
    g.s.settimeout(window)
    t0 = time.time()
    while time.time() - t0 < window:
        try:
            data = g.s.recv(65536)
        except socket.timeout:
            return None
        i = 0
        while i + 16 <= len(data):
            ln, mtype, flags, seq, pid = struct.unpack_from("IHHII", data, i)
            payload = data[i + 16:i + ln]
            if len(payload) >= 4 and payload[0] == NFC_EVENT_TARGETS_FOUND:
                a = parse_attrs(payload[4:])
                if NFC_ATTR_TARGET_INDEX in a:
                    return struct.unpack("I", a[NFC_ATTR_TARGET_INDEX][:4])[0]
                for mt, pl in g.request(fam, NFC_CMD_GET_TARGET,
                                        nla(NFC_ATTR_DEVICE_INDEX, struct.pack("I", DEV)),
                                        NLM_F_REQUEST | 0x300):
                    if mt not in (NLMSG_ERROR, NLMSG_DONE) and len(pl) >= 4:
                        ta = parse_attrs(pl[4:])
                        if NFC_ATTR_TARGET_INDEX in ta:
                            return struct.unpack("I", ta[NFC_ATTR_TARGET_INDEX][:4])[0]
            i += (ln + 3) & ~3
    return None


def send_to_target(g, fam, DEV, libc, target_idx, text):
    """RATS-activated target already found: connect a raw ISO-DEP socket, SELECT
    our AID and push the payload. Returns True on a confirmed 90 00 send."""
    # settle on the activated target: stop the poll loop
    g.request(fam, NFC_CMD_STOP_POLL, nla(NFC_ATTR_DEVICE_INDEX, struct.pack("I", DEV)),
              NLM_F_REQUEST | NLM_F_ACK)

    def connect_target():
        rs = socket.socket(AF_NFC, socket.SOCK_SEQPACKET, NFC_SOCKPROTO_RAW)
        saddr = struct.pack("H2xIII", AF_NFC, DEV, target_idx, NFC_PROTO_ISO14443)
        rc = libc.connect(rs.fileno(), saddr, len(saddr))
        if rc != 0:
            e = ctypes.get_errno()
            rs.close()
            raise OSError(e, os.strerror(e))
        return rs

    def xchg(rs, apdu):
        rs.send(apdu)
        rs.settimeout(5.0)         # HCE first-APDU can be slow (service cold start)
        resp = rs.recv(4096)
        if resp and resp[0] == 0:   # kernel prefixes a 1-byte NULL header
            resp = resp[1:]
        return resp

    # Android HCE is SLOW on the first APDU (binds the service on demand), so don't
    # hammer with rapid re-activations — give the phone time between spaced tries.
    for attempt in range(6):
        if attempt:
            time.sleep(0.6)
        try:
            rs = connect_target()
        except OSError:
            continue
        try:
            time.sleep(0.15)
            r = xchg(rs, SELECT_AID)
            if r[-2:] == b"\x90\x00":
                r2 = xchg(rs, payload_apdu(text))
                if r2[-2:] == b"\x90\x00":
                    print(f"[nfc] *** SENT '{text.decode(errors='replace')}' — phone received it ***", flush=True)
                    return True
        except OSError:
            pass
        finally:
            rs.close()
    return False


def main():
    # message: NQ_NFC_MESSAGE env (used by the systemd service, tolerates spaces)
    # takes precedence over argv[1]; falls back to a default.
    text = (os.environ.get("NQ_NFC_MESSAGE")
            or (sys.argv[1] if len(sys.argv) > 1 else "Ahoj z Nexus Q!")).encode()
    loop = os.environ.get("NQ_NFC_LOOP") == "1"
    WINDOW = float(os.environ.get("NQ_NFC_WINDOW", "8" if loop else "40"))

    g = Genl()
    fam, grp = g.resolve_nfc()
    if not fam:
        print("!! could not resolve nfc genl family (CONFIG_NFC?)")
        return 2

    DEV = 0  # nfc0
    g.request(fam, NFC_CMD_DEV_UP, nla(NFC_ATTR_DEVICE_INDEX, struct.pack("I", DEV)), NLM_F_REQUEST | NLM_F_ACK)
    if grp:
        g.s.setsockopt(270, 1, grp)  # SOL_NETLINK, NETLINK_ADD_MEMBERSHIP
    libc = ctypes.CDLL(None, use_errno=True)

    if loop:
        print(f"[nfc] daemon: listening continuously (ISO14443, window {WINDOW:g}s). "
              f"Tap the phone (companion app foreground) on the dome.", flush=True)
        # Send once per tap: after a successful send, disarm and do NOT re-send
        # while the same phone stays in the field — only re-arm once it has left
        # (a poll cycle finds no target). A minimum cooldown guards against a
        # momentary drop-and-reacquire counting as a fresh tap.
        COOLDOWN = float(os.environ.get("NQ_NFC_COOLDOWN", "3"))
        armed = True
        last_send = 0.0
        while True:
            tid = wait_for_target(g, fam, DEV, WINDOW)
            if tid is None:
                if not armed and (time.time() - last_send) > COOLDOWN:
                    armed = True  # field empty long enough → ready for the next tap
                continue
            if armed:
                if send_to_target(g, fam, DEV, libc, tid, text):
                    last_send = time.time()
                armed = False
                time.sleep(0.3)
            else:
                time.sleep(1.0)  # phone still on the dome — wait for it to leave
    else:
        print(f"[nfc] polling {WINDOW:g}s — TAP THE PHONE ON THE DOME", flush=True)
        tid = wait_for_target(g, fam, DEV, WINDOW)
        if tid is None:
            print("!! no ISO-DEP target seen (phone not on the dome / screen off / app not foreground)")
            return 1
        return 0 if send_to_target(g, fam, DEV, libc, tid, text) else 1


if __name__ == "__main__":
    sys.exit(main())
