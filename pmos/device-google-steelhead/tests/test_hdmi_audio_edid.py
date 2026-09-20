"""Does the Q correctly decide whether an HDMI sink can hear it?

This is the gate that decides whether HDMI is offered as an audio output at
all, so getting it wrong is user-visible in both directions: offer HDMI on a
DVI monitor and the user picks an output that can never make a sound; refuse it
on a real receiver and the feature does not exist.

The fixtures are not invented. SOUNDBAR_EDID is the exact 256 bytes read from
/sys/class/drm/card0-HDMI-A-1/edid on the device on 2026-09-20, with the
Samsung soundbar that GitHub issue #5 is about attached; it is the sink that
was confirmed audible. The DVI fixture is shaped like the Philips monitor this
project was developed against, whose lack of a CTA extension is the whole
reason HDMI audio sat untested and PULSE_IGNORE'd for months.
"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "nq-hdmi")


def load_tool():
    spec = importlib.util.spec_from_loader(
        "nq_hdmi", importlib.machinery.SourceFileLoader("nq_hdmi", TOOL))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# The real thing: base block + one CTA-861 extension carrying "basic audio",
# an Audio Data Block (LPCM 2ch / AC-3 6ch / DTS 6ch) and the HDMI VSDB.
SOUNDBAR_EDID = bytes.fromhex(
    "00ffffffffffff004c2d48540100000015130103800000780aee91a3544c9926"
    "0f505420000001010101010101010101010101010101023a801871382d40582c"
    "450010090000001e8c0ad08a20e02d10103e9600040300000018000000fc0053"
    "414d53554e470a2020202020000000fd003b3d0f2e08000a20202020202001fb"
    "020331714d82050401101114131f06150312290907071507503d07c083010000"
    "6c030c002100801e0000000000e3050301011d007251d01e206e285500100900"
    "00001ed60980a020e02d101060a2000403000000188c0ad08a20e02d10103e96"
    "00100900000018000000000000000000000000000000000000000000000000cf"
)


def _dvi_edid():
    """A 128-byte base block and no extension — a DVI-class sink."""
    e = bytearray(128)
    e[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    e[126] = 0  # no extension blocks
    return bytes(e)


def _cta_without_audio():
    """A CTA-861 extension that exists but declares no audio: the basic-audio
    flag clear and no Audio Data Block. A sink like this speaks HDMI but the
    link carries video only."""
    base = bytearray(_dvi_edid())
    base[126] = 1
    ext = bytearray(128)
    ext[0] = 0x02       # CTA-861
    ext[1] = 0x03       # revision 3
    ext[2] = 4          # DTD offset: collection is empty
    ext[3] = 0x00       # no basic audio, no YCbCr
    return bytes(base) + bytes(ext)


class TestAudioCapability(unittest.TestCase):
    def test_real_soundbar_is_audio_capable(self):
        mod = load_tool()
        ok, detail = mod.parse_edid_audio(SOUNDBAR_EDID)
        self.assertTrue(ok, detail)
        self.assertIn("basic audio", detail)
        # The Audio Data Block must actually be parsed, not merely the flag:
        # this sink advertises 2-channel LPCM and that is what we route to it.
        self.assertIn("LPCM up to 2ch", detail)

    def test_dvi_monitor_has_no_audio_path(self):
        mod = load_tool()
        ok, detail = mod.parse_edid_audio(_dvi_edid())
        self.assertFalse(ok)
        self.assertIn("DVI-class", detail)

    def test_cta_present_but_silent_is_refused(self):
        # The subtle case: an extension block exists, so a naive "len >= 256"
        # check would pass it, but there is no audio path.
        mod = load_tool()
        ok, detail = mod.parse_edid_audio(_cta_without_audio())
        self.assertFalse(ok)
        self.assertIn("declares no audio", detail)

    def test_missing_or_short_edid_is_refused(self):
        mod = load_tool()
        for bad in (b"", None, b"\x00" * 64):
            ok, _ = mod.parse_edid_audio(bad)
            self.assertFalse(ok, f"accepted {bad!r}")

    def test_audio_data_block_alone_is_enough(self):
        # Basic-audio clear but a Short Audio Descriptor present: still audio.
        base = bytearray(_dvi_edid())
        base[126] = 1
        ext = bytearray(128)
        ext[0], ext[1] = 0x02, 0x03
        ext[3] = 0x00                       # basic-audio flag NOT set
        ext[4] = (1 << 5) | 3               # Audio Data Block, 3 bytes
        ext[5] = (1 << 3) | 1               # LPCM, 2 channels
        ext[6], ext[7] = 0x07, 0x07
        ext[2] = 8                          # DTD offset past the block
        ok, detail = load_tool().parse_edid_audio(bytes(base) + bytes(ext))
        self.assertTrue(ok, detail)
        self.assertIn("LPCM up to 2ch", detail)


class TestSinkName(unittest.TestCase):
    def test_reads_product_name_descriptor(self):
        self.assertEqual(load_tool().parse_edid_name(SOUNDBAR_EDID), "SAMSUNG")

    def test_no_name_descriptor_is_none(self):
        self.assertIsNone(load_tool().parse_edid_name(_dvi_edid()))


if __name__ == "__main__":
    unittest.main()
