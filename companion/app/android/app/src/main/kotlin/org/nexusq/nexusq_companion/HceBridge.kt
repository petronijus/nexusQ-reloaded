package org.nexusq.nexusq_companion

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel

/**
 * Process-local hand-off between [NqHceService] (a HostApduService that runs
 * outside the Flutter engine / Activity lifecycle) and the Flutter side.
 *
 * The HCE service and the Activity live in the SAME OS process, so a plain
 * singleton is enough to bridge them — but the service can fire while no
 * Flutter engine is attached (app backgrounded, or the reader tapped before
 * the UI came up). We therefore:
 *   - buffer messages that arrive while no EventChannel sink is listening, and
 *     drain them the instant one attaches;
 *   - also persist the last message to SharedPreferences so a cold/resumed
 *     Activity can pull it via the "getLastMessage" MethodChannel call.
 *
 * All sink interaction is marshalled onto the main thread (EventChannel sinks
 * are not thread-safe); HostApduService callbacks already run on the main
 * thread, but posting keeps us correct regardless of caller.
 */
object HceBridge {
    const val PREFS = "nexusq_hce"
    const val KEY_LAST = "last_message"
    const val KEY_LAST_TS = "last_message_ts"

    private val main = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<String>()
    private var sink: EventChannel.EventSink? = null

    /** Called from MainActivity's EventChannel.onListen (main thread). */
    fun attach(newSink: EventChannel.EventSink) {
        main.post {
            sink = newSink
            // Drain anything that arrived before the UI was listening.
            while (pending.isNotEmpty()) {
                newSink.success(pending.removeFirst())
            }
        }
    }

    /** Called from MainActivity's EventChannel.onCancel (main thread). */
    fun detach() {
        main.post { sink = null }
    }

    /**
     * Publish a received text. Safe to call from any thread. Persists to prefs
     * first (survives process death / resume), then delivers to the live sink
     * or buffers it for the next listener.
     */
    fun post(context: Context, text: String) {
        // commit() (synchronous), NOT apply(): a HostApduService can be killed the
        // instant the transaction ends, before an async apply() flushes to disk —
        // which loses the message. commit() blocks until it is persisted.
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_LAST, text)
            .putLong(KEY_LAST_TS, System.currentTimeMillis())
            .commit()
        Log.i("HceBridge", "post: persisted \"$text\" (sink=${sink != null})")

        main.post {
            val s = sink
            if (s != null) s.success(text) else pending.addLast(text)
        }
    }
}
