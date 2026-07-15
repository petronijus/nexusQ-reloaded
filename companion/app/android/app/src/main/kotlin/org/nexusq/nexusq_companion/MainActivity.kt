package org.nexusq.nexusq_companion

import android.content.Context
import android.nfc.NfcAdapter
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and bridges the native HCE endpoint ([NqHceService]) to
 * Dart:
 *   - EventChannel "nexusq/hce/messages" streams each received text as it
 *     arrives (buffered by [HceBridge] until Dart is listening);
 *   - MethodChannel "nexusq/hce" exposes "getLastMessage" (resume/cold-start
 *     fallback) and "isNfcAvailable".
 *
 * WE DELIBERATELY DO NOT TOUCH NFC ROUTING.
 *
 * An earlier revision claimed `CardEmulation.setPreferredService()` on every
 * onResume and released it on onPause. That was both unnecessary and harmful:
 *
 *  - Unnecessary: nothing else on the phone registers our AID, so the platform
 *    already routes it to us. `dumpsys nfc` shows
 *      "F0010203040506" (category: other)
 *          *DEFAULT* ApduService: ...NqHceService
 *    with this app NOT running and no preferred service set. setPreferredService
 *    only breaks ties between services competing for the SAME AID; we have no
 *    competitor.
 *  - Harmful: it grabbed foreground NFC routing priority merely because the app
 *    was open — no tap expected — and the NFC stack toggled global observe mode
 *    at that moment. Worse, the release hung off onPause, which NEVER RUNS when
 *    the process is killed outright (`pm clear`, `adb install -r`, a crash) —
 *    leaving routing claimed by a dead app. Contactless payment failed twice for
 *    the user, only ever after a dev session (2026-07-15).
 *
 * A companion app for a speaker has no business influencing how this phone pays
 * for groceries. If a tie-break is ever genuinely needed, scope it to the exact
 * moment a tap is expected and release it from a lifecycle callback that also
 * survives process death — do not re-add a blanket onResume claim.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val EVENTS_CHANNEL = "nexusq/hce/messages"
        private const val METHOD_CHANNEL = "nexusq/hce"
    }

    private var btSetup: BtSetupChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Stream of received HCE texts.
        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    HceBridge.attach(events)
                }

                override fun onCancel(arguments: Any?) {
                    HceBridge.detach()
                }
            }
        )

        // Method channel: pull-last (resume fallback) + NFC capability probe.
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getLastMessage" -> {
                    val prefs = getSharedPreferences(HceBridge.PREFS, Context.MODE_PRIVATE)
                    val text = prefs.getString(HceBridge.KEY_LAST, null)
                    val ts = prefs.getLong(HceBridge.KEY_LAST_TS, 0L)
                    result.success(
                        if (text == null) null
                        else mapOf("text" to text, "timestamp" to ts)
                    )
                }
                "clearLastMessage" -> {
                    getSharedPreferences(HceBridge.PREFS, Context.MODE_PRIVATE)
                        .edit().remove(HceBridge.KEY_LAST).remove(HceBridge.KEY_LAST_TS).apply()
                    result.success(null)
                }
                "isNfcAvailable" -> result.success(NfcAdapter.getDefaultAdapter(this) != null)
                else -> result.notImplemented()
            }
        }

        btSetup = BtSetupChannel(this, messenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        btSetup?.onPermissionResult(requestCode)
    }

    override fun onDestroy() {
        btSetup?.dispose()
        super.onDestroy()
    }
}
