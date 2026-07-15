package org.nexusq.nexusq_companion

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
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
 * NFC EXISTS FOR THIS APP ONLY WHILE ITS UI IS IN THE FOREGROUND.
 *
 * [NqHceService] ships `android:enabled="false"` and is switched on in onResume
 * / off in onPause (see [setHceServiceEnabled]). A disabled component is absent
 * from the NFC routing table entirely, so an installed-but-unopened app has zero
 * NFC surface. A tap only ever worked with this UI foregrounded anyway, so this
 * costs nothing.
 *
 * Why it is written this way — this app broke the user's contactless payment
 * twice, only ever after a dev session (2026-07-15). The previous design claimed
 * `CardEmulation.setPreferredService()` on every onResume and released it on
 * onPause, which is wrong in both halves:
 *
 *  - it grabbed foreground NFC routing priority merely because the app was open,
 *    with no tap expected, and the NFC stack toggled global observe mode at that
 *    moment;
 *  - the release hung off onPause, which NEVER RUNS when the process is killed
 *    outright (`pm clear`, `adb install -r`, a crash) — all routine during
 *    development — leaving routing claimed by a dead app.
 *
 * Toggling the component instead fails SAFE: the platform persists a component's
 * enabled state across process death, so being killed leaves NFC OFF, not stuck
 * on. A companion app for a speaker has no business influencing how this phone
 * pays for groceries. Do not re-add a blanket onResume routing claim.
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

    override fun onResume() {
        super.onResume()
        setHceServiceEnabled(true)
    }

    override fun onPause() {
        setHceServiceEnabled(false)
        super.onPause()
    }

    override fun onDestroy() {
        btSetup?.dispose()
        super.onDestroy()
    }

    /**
     * Add/remove [NqHceService] from the NFC routing table by enabling or
     * disabling the component itself.
     *
     * A tap only ever worked with this UI in the foreground, so there is nothing
     * to lose by not being registered the rest of the time — and plenty to gain:
     * a disabled component is absent from the routing table entirely, so the app
     * cannot influence NFC while the user is paying for groceries.
     *
     * This is the fail-SAFE direction, which is the whole point. The platform
     * persists a component's enabled state across process death, so if we are
     * killed outright (`pm clear`, `adb install -r`, a crash) the service simply
     * stays OFF. The previous design released NFC routing from onPause — which
     * never runs in exactly those cases, leaving routing claimed by a dead app.
     *
     * DONT_KILL_APP: we are toggling our own component from inside our own
     * process; without it the platform would kill us mid-callback.
     */
    private fun setHceServiceEnabled(enabled: Boolean) {
        // Nothing to route on a device with no NFC — don't churn package state.
        if (NfcAdapter.getDefaultAdapter(this) == null) return
        val component = ComponentName(this, NqHceService::class.java)
        val target = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        try {
            if (packageManager.getComponentEnabledSetting(component) == target) return
            packageManager.setComponentEnabledSetting(
                component, target, PackageManager.DONT_KILL_APP
            )
            Log.d(TAG, "HCE service ${if (enabled) "enabled" else "disabled"}")
        } catch (e: Exception) {
            // Never let NFC bookkeeping take the UI down.
            Log.w(TAG, "setComponentEnabledSetting($enabled) failed", e)
        }
    }
}
