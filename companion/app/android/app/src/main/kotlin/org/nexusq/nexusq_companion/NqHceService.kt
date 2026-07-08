package org.nexusq.nexusq_companion

import android.nfc.cardemulation.HostApduService
import android.os.Bundle
import android.util.Log

/**
 * HCE card-emulation endpoint for the Nexus Q "tap-to-send" link. The Q acts as
 * the NFC READER and pushes a short UTF-8 text to this phone, which emulates a
 * card under a custom AID.
 *
 * Wire protocol (must match the Q reader side exactly):
 *   1. SELECT by AID:  00 A4 04 00 07 F0 01 02 03 04 05 06 00
 *        → if the AID equals [AID] we answer SW=9000.
 *   2. Payload APDU:   80 10 00 00 <Lc> <Lc UTF-8 text bytes>
 *        → we extract data[0 until Lc], forward it to Flutter via [HceBridge],
 *          and answer SW=9000.
 *   3. Anything else   → SW=6A82 (or 6D00 for an unsupported INS).
 *
 * The parser is defensive: every field is bounds-checked so a truncated or
 * malformed APDU yields a clean error status instead of an exception (an
 * uncaught throw here would drop the whole card-emulation transaction).
 */
class NqHceService : HostApduService() {

    companion object {
        private const val TAG = "NqHceService"

        /** Custom application identifier, 7 bytes: F0 01 02 03 04 05 06. */
        private val AID = byteArrayOf(
            0xF0.toByte(), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06
        )

        // Instruction class/codes we understand.
        private const val CLA_ISO: Byte = 0x00
        private const val INS_SELECT: Byte = 0xA4.toByte()
        private const val P1_SELECT_BY_AID: Byte = 0x04
        private const val CLA_PROPRIETARY: Byte = 0x80.toByte()
        private const val INS_PAYLOAD: Byte = 0x10

        // ISO 7816-4 status words.
        private val SW_OK = byteArrayOf(0x90.toByte(), 0x00)               // success
        private val SW_FILE_NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())   // AID/data not found
        private val SW_INS_NOT_SUPPORTED = byteArrayOf(0x6D, 0x00)         // unknown INS
    }

    override fun processCommandApdu(commandApdu: ByteArray?, extras: Bundle?): ByteArray {
        val apdu = commandApdu ?: return SW_FILE_NOT_FOUND
        Log.d(TAG, "APDU <- ${apdu.toHex()}")

        // Minimum ISO 7816-4 header is 4 bytes (CLA INS P1 P2).
        if (apdu.size < 4) return SW_FILE_NOT_FOUND

        val cla = apdu[0]
        val ins = apdu[1]
        val p1 = apdu[2]

        return when {
            // --- SELECT (by AID) -------------------------------------------
            cla == CLA_ISO && ins == INS_SELECT && p1 == P1_SELECT_BY_AID ->
                handleSelect(apdu)

            // --- payload carrying the text ---------------------------------
            cla == CLA_PROPRIETARY && ins == INS_PAYLOAD ->
                handlePayload(apdu)

            // --- unknown instruction ---------------------------------------
            else -> {
                Log.w(TAG, "unhandled APDU (CLA=${cla.hex()} INS=${ins.hex()})")
                SW_INS_NOT_SUPPORTED
            }
        }
    }

    /** SELECT-by-AID: succeed only when the requested AID matches ours. */
    private fun handleSelect(apdu: ByteArray): ByteArray {
        // Layout: CLA INS P1 P2 Lc [AID ...] [Le]
        if (apdu.size < 5) return SW_FILE_NOT_FOUND
        val lc = apdu[4].toInt() and 0xFF
        if (lc == 0 || apdu.size < 5 + lc) return SW_FILE_NOT_FOUND
        val requested = apdu.copyOfRange(5, 5 + lc)
        return if (requested.contentEquals(AID)) {
            Log.d(TAG, "SELECT ok — AID matched")
            SW_OK
        } else {
            Log.w(TAG, "SELECT rejected — AID ${requested.toHex()} != ${AID.toHex()}")
            SW_FILE_NOT_FOUND
        }
    }

    /** Extract the UTF-8 text from `80 10 00 00 <Lc> <text>` and forward it. */
    private fun handlePayload(apdu: ByteArray): ByteArray {
        // Layout: CLA INS P1 P2 Lc [data ...]
        if (apdu.size < 5) return SW_FILE_NOT_FOUND
        val lc = apdu[4].toInt() and 0xFF
        // Tolerate a payload whose declared Lc overruns the buffer by clamping
        // to what actually arrived, rather than dropping the message.
        val end = minOf(5 + lc, apdu.size)
        if (end <= 5) {
            Log.w(TAG, "payload APDU has no data (Lc=$lc)")
            return SW_FILE_NOT_FOUND
        }
        val text = String(apdu.copyOfRange(5, end), Charsets.UTF_8)
        Log.i(TAG, "received text: \"$text\"")
        HceBridge.post(applicationContext, text)
        return SW_OK
    }

    override fun onDeactivated(reason: Int) {
        // reason: DEACTIVATION_LINK_LOSS (0) or DEACTIVATION_DESELECTED (1).
        Log.d(TAG, "onDeactivated (reason=$reason)")
    }

    // --- hex helpers (debug logging) -----------------------------------------
    private fun ByteArray.toHex(): String =
        joinToString(" ") { "%02X".format(it.toInt() and 0xFF) }

    private fun Byte.hex(): String = "%02X".format(toInt() and 0xFF)
}
