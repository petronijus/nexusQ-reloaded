package org.nexusq.nexusq_companion

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.nfc.cardemulation.CardEmulation
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
 * NFC IS SCOPED TO THE MOMENT A TAP IS ACTUALLY EXPECTED — two layers:
 *
 *  1. [NqHceService] ships `android:enabled="false"` and is switched on in
 *     onResume / off in onPause. A disabled component is absent from the NFC
 *     routing table entirely, so an installed-but-unopened app has ZERO NFC
 *     surface.
 *  2. `CardEmulation.setPreferredService()` is claimed only when Dart asks via
 *     the "setTapCapture" method (see [setTapCapture]) — i.e. while the UI is on
 *     a screen waiting for the user to touch the phone to the dome — and is
 *     released as soon as that screen goes away, or on onPause.
 *
 * Why the preferred-service claim is needed AT ALL (measured 2026-07-15, after I
 * removed it on the wrong theory and broke the tap): routing alone is not
 * enough. The phone sits in Android 15 OBSERVE MODE — it detects the reader's
 * field but deliberately does not answer it (`MSG_RF_FIELD_ACTIVATED` /
 * `..._DEACTIVATED` cycling with no APDU ever reaching us). The platform turns
 * observe mode off for the preferred service when that service declares
 * `shouldDefaultToObserveMode="false"`, which ours does. So claiming preferred
 * IS the mechanism that lets the Q's tap through; without it the tap is silent.
 *
 * Why it must NOT be a blanket onResume claim: this app broke the user's
 * contactless payment twice, only ever after a dev session. The old code claimed
 * routing merely because the app was open — no tap expected — and released it
 * from onPause, which NEVER RUNS when the process is killed outright
 * (`pm clear`, `adb install -r`, a crash), all routine during development.
 *
 * Honest state of knowledge: the payment link is NOT proven. The NFC telemetry
 * shows observe mode being toggled only by com.android.nfc / com.google.android
 * .gms — never by our uid — and it returns to true on its own. So this scoping
 * is risk reduction, not a confirmed fix. If payment fails again, capture
 * `dumpsys nfc` AT THE MOMENT OF FAILURE.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val EVENTS_CHANNEL = "nexusq/hce/messages"
        private const val METHOD_CHANNEL = "nexusq/hce"
    }

    private var btSetup: BtSetupChannel? = null
    private var cardEmulation: CardEmulation? = null

    /** Dart's answer to "is a tap expected right now?". Re-applied on resume. */
    private var tapExpected = false

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
                // Dart tells us when a tap is actually expected (a screen that
                // asks the user to touch the phone to the dome). We claim NFC
                // priority only for that window — never for "the app is open".
                "setTapCapture" -> {
                    setTapCapture(call.arguments as? Boolean ?: false)
                    result.success(null)
                }
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
        // Re-assert whatever Dart last asked for: setPreferredService only holds
        // while the Activity is resumed, so it must be re-claimed after a resume.
        if (tapExpected) claimPreferred(true)
    }

    override fun onPause() {
        // Release BOTH, always — never leave NFC influenced by a backgrounded app.
        claimPreferred(false)
        setHceServiceEnabled(false)
        super.onPause()
    }

    override fun onDestroy() {
        btSetup?.dispose()
        super.onDestroy()
    }

    /**
     * Dart-facing switch: "a tap is expected now" / "it is not".
     *
     * Claiming preferred is what makes the platform drop observe mode for us, so
     * this is the difference between the Q's tap being heard and silently
     * ignored. Keep the window as small as the UI honestly needs.
     */
    private fun setTapCapture(expected: Boolean) {
        if (tapExpected == expected) return
        tapExpected = expected
        claimPreferred(expected)
    }

    /** Claim/release foreground NFC priority. Requires a resumed Activity. */
    private fun claimPreferred(preferred: Boolean) {
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return
        val emulation = cardEmulation ?: run {
            try {
                CardEmulation.getInstance(adapter)
            } catch (e: Exception) {
                Log.w(TAG, "CardEmulation unavailable", e)
                return
            }.also { cardEmulation = it }
        }
        val component = ComponentName(this, NqHceService::class.java)
        try {
            if (preferred) {
                emulation.setPreferredService(this, component)
                Log.d(TAG, "NFC: claimed preferred (tap expected)")
            } else {
                emulation.unsetPreferredService(this)
                Log.d(TAG, "NFC: released preferred")
            }
        } catch (e: Exception) {
            Log.w(TAG, "setPreferredService($preferred) failed", e)
        }
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
