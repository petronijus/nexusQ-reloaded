package org.nexusq.nexusq_companion

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.UUID
import kotlin.concurrent.thread

/**
 * BT Classic RFCOMM transport for device setup (PROTOCOL.md §8).
 * One connection at a time; newline-JSON lines are relayed verbatim to Dart.
 */
class BtSetupChannel(private val activity: Activity, messenger: BinaryMessenger) {

    companion object {
        private const val TAG = "BtSetupChannel"
        const val PERMISSION_REQUEST = 0x4251
        val SETUP_UUID: UUID = UUID.fromString("8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a")
    }

    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    @Volatile private var socket: BluetoothSocket? = null
    private var scanReceiver: BroadcastReceiver? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    init {
        MethodChannel(messenger, "nexusq/btsetup").setMethodCallHandler { call, result ->
            when (call.method) {
                "ensurePermissions" -> ensurePermissions(result)
                "startScan" -> { startScan(); result.success(null) }
                "stopScan" -> { stopScan(); result.success(null) }
                "connect" -> {
                    val mac = call.argument<String>("mac")
                    if (mac == null) result.error("bad_args", "missing mac|line", null)
                    else connect(mac, result)
                }
                "sendLine" -> {
                    val line = call.argument<String>("line")
                    if (line == null) result.error("bad_args", "missing mac|line", null)
                    else sendLine(line, result)
                }
                "disconnect" -> { disconnect(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "nexusq/btsetup/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) { events = sink }
                override fun onCancel(args: Any?) { events = null }
            })
    }

    private fun emit(map: Map<String, Any?>) = main.post { events?.success(map) }

    // --- permissions -----------------------------------------------------
    private fun neededPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        else
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasPermissions() = neededPermissions().all {
        ActivityCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun ensurePermissions(result: MethodChannel.Result) {
        if (hasPermissions()) { result.success(true); return }
        if (pendingPermissionResult != null) {
            result.error("permission_request_pending", "a permission request is already in flight", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(activity, neededPermissions(), PERMISSION_REQUEST)
    }

    /** Call from MainActivity.onRequestPermissionsResult. */
    fun onPermissionResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        pendingPermissionResult?.success(hasPermissions())
        pendingPermissionResult = null
    }

    // --- discovery -------------------------------------------------------
    @SuppressLint("MissingPermission")
    private fun startScan() {
        val ad = adapter ?: return
        stopScan()
        val recv = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                if (i?.action != BluetoothDevice.ACTION_FOUND) return
                val dev: BluetoothDevice = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE) ?: return
                emit(mapOf("type" to "scan", "name" to (dev.name ?: ""), "mac" to dev.address))
            }
        }
        activity.registerReceiver(recv, IntentFilter(BluetoothDevice.ACTION_FOUND))
        scanReceiver = recv
        ad.startDiscovery()
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        scanReceiver?.let { runCatching { activity.unregisterReceiver(it) } }
        scanReceiver = null
        // cancelDiscovery throws SecurityException without BLUETOOTH_SCAN;
        // it is advisory here (no discovery may be running at all).
        runCatching { adapter?.cancelDiscovery() }
    }

    // --- connection ------------------------------------------------------
    @SuppressLint("MissingPermission")
    /**
     * Bond BEFORE opening the socket, and wait for it to actually complete.
     *
     * Letting [BluetoothSocket.connect] bond on demand does NOT work here
     * (measured 2026-07-15): the implicit bond a secure socket triggers against
     * an unbonded Just-Works peer forms and then immediately collapses —
     * bluetoothd logs `bonding_attempt_complete status 0x5` (auth failed) then
     * `0x0e` (disconnected), no link key is ever written, and the RFCOMM
     * connection never reaches the device (setupd logs no connection at all).
     * Android surfaces this as the misleading "incorrect PIN" toast, even though
     * no PIN exists anywhere in a Just-Works flow.
     *
     * Bonding explicitly first and only then connecting is reliable: verified
     * live — pairing from the phone's own BT settings and *then* running the app
     * bonded, persisted the link key, authorized A2DP and delivered the RFCOMM
     * connection. This method just does that same order in-app.
     *
     * Returns true once bonded. Safe to call when already bonded (no-op).
     */
    private fun ensureBonded(dev: BluetoothDevice, timeoutMs: Long = 30_000): Boolean {
        if (dev.bondState == BluetoothDevice.BOND_BONDED) return true

        val done = java.util.concurrent.CountDownLatch(1)
        // AtomicBoolean, not a captured var: the broadcast lands on the main
        // thread while this method blocks on a worker.
        val bonded = java.util.concurrent.atomic.AtomicBoolean(false)
        val rx = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                val d = i?.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                if (d?.address != dev.address) return
                when (i.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) {
                    BluetoothDevice.BOND_BONDED -> { bonded.set(true); done.countDown() }
                    // BOND_NONE after BOND_BONDING is a failure, not "not started".
                    BluetoothDevice.BOND_NONE -> done.countDown()
                }
            }
        }
        activity.registerReceiver(rx, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
        try {
            // Already bonding (e.g. a previous attempt) -> just wait it out.
            if (dev.bondState != BluetoothDevice.BOND_BONDING && !dev.createBond()) {
                Log.w(TAG, "createBond() refused for ${dev.address}")
                return false
            }
            done.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (e: SecurityException) {
            Log.w(TAG, "createBond denied", e)
            return false
        } finally {
            runCatching { activity.unregisterReceiver(rx) }
        }
        return bonded.get() || dev.bondState == BluetoothDevice.BOND_BONDED
    }

    private fun connect(mac: String, result: MethodChannel.Result) {
        val ad = adapter
        if (ad == null) { result.error("no_bt", "Bluetooth unavailable", null); return }
        disconnect()
        stopScan()   // discovery kills RFCOMM connect reliability
        thread(name = "bt-setup-connect") {
            try {
                val dev = ad.getRemoteDevice(mac)
                if (!ensureBonded(dev)) {
                    emit(mapOf("type" to "state", "connected" to false))
                    main.post {
                        result.error("pair_failed",
                            "Could not pair with the Nexus Q. If it was paired before, " +
                            "forget it in Bluetooth settings and try again.", null)
                    }
                    return@thread
                }
                // SECURE (bonded) RFCOMM: this channel carries the user's WiFi
                // PSK, and an authenticated link is encrypted by the controller,
                // so the PSK never crosses the air in the clear. Connecting
                // triggers Just-Works pairing — the Q answers with a permanent
                // NoInputNoOutput auto-accept agent (nexusq-btagent), so nothing
                // is prompted on either end, and the resulting bond is the SAME
                // one BT audio (A2DP) then uses. The device side must match:
                // nexusq-setupd registers the profile RequireAuthentication=True.
                //
                // An earlier build used createInsecureRfcommSocketToServiceRecord
                // because the secure socket appeared to deadlock. That was NOT a
                // BCM4330 limitation: blueman-applet's DisplayYesNo agent was
                // forcing SSP into Numeric Comparison, whose Confirm/Deny dialog
                // no input device on the Q can ever click. Fixed by dropping that
                // applet from the image; secure pairing + A2DP verified live
                // 2026-07-15. Do not "fix" a timeout here by going insecure again.
                val sock = dev.createRfcommSocketToServiceRecord(SETUP_UUID)
                sock.connect()
                socket = sock
                emit(mapOf("type" to "state", "connected" to true))
                main.post { result.success(true) }
                readerLoop(sock)
            } catch (e: Exception) {
                Log.w(TAG, "connect failed", e)
                emit(mapOf("type" to "state", "connected" to false))
                main.post { result.error("connect_failed", e.message, null) }
            }
        }
    }

    private fun readerLoop(sock: BluetoothSocket) {
        try {
            val reader = BufferedReader(InputStreamReader(sock.inputStream, Charsets.UTF_8))
            while (true) {
                val line = reader.readLine() ?: break
                emit(mapOf("type" to "line", "line" to line))
            }
        } catch (e: Exception) {
            Log.d(TAG, "reader ended: ${e.message}")
        } finally {
            emit(mapOf("type" to "state", "connected" to false))
            runCatching { sock.close() }
            if (socket === sock) socket = null
        }
    }

    private fun sendLine(line: String, result: MethodChannel.Result) {
        val sock = socket
        if (sock == null) { result.error("not_connected", "no RFCOMM connection", null); return }
        thread(name = "bt-setup-send") {
            try {
                sock.outputStream.write((line + "\n").toByteArray(Charsets.UTF_8))
                sock.outputStream.flush()
                main.post { result.success(null) }
            } catch (e: Exception) {
                main.post { result.error("send_failed", e.message, null) }
            }
        }
    }

    fun disconnect() {
        socket?.let { runCatching { it.close() } }
        socket = null
    }

    /** Call from MainActivity.onDestroy to release scan receiver + socket. */
    fun dispose() {
        stopScan()
        disconnect()
    }
}
