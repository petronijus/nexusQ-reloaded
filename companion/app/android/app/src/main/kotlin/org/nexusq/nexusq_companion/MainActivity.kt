package org.nexusq.nexusq_companion

import android.content.ComponentName
import android.content.Context
import android.nfc.NfcAdapter
import android.nfc.cardemulation.CardEmulation
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
 * While this Activity is in the foreground we also register our service as the
 * PREFERRED HCE service for its AID via [CardEmulation.setPreferredService], so
 * routing is unambiguous and the "which app should handle this?" chooser never
 * appears. All NFC access is guarded for devices that lack it.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val EVENTS_CHANNEL = "nexusq/hce/messages"
        private const val METHOD_CHANNEL = "nexusq/hce"
    }

    private var cardEmulation: CardEmulation? = null
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

    override fun onResume() {
        super.onResume()
        setPreferredHceService(true)
    }

    override fun onPause() {
        setPreferredHceService(false)
        super.onPause()
    }

    /**
     * Claim (or release) preferred-service routing for our AID while in the
     * foreground. No-op on devices without NFC/HCE. `setPreferredService`
     * requires the Activity to be resumed, hence the onResume/onPause pairing.
     */
    private fun setPreferredHceService(preferred: Boolean) {
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return
        val emulation = cardEmulation ?: try {
            CardEmulation.getInstance(adapter)
        } catch (e: Exception) {
            Log.w(TAG, "CardEmulation unavailable", e)
            return
        }.also { cardEmulation = it }

        val component = ComponentName(this, NqHceService::class.java)
        try {
            if (preferred) {
                emulation.setPreferredService(this, component)
                Log.d(TAG, "requested preferred HCE service")
            } else {
                emulation.unsetPreferredService(this)
                Log.d(TAG, "released preferred HCE service")
            }
        } catch (e: Exception) {
            Log.w(TAG, "setPreferredService($preferred) failed", e)
        }
    }
}
