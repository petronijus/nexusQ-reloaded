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
    private var socket: BluetoothSocket? = null
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
                "connect" -> connect(call.argument<String>("mac")!!, result)
                "sendLine" -> sendLine(call.argument<String>("line")!!, result)
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
        adapter?.cancelDiscovery()
    }

    // --- connection ------------------------------------------------------
    @SuppressLint("MissingPermission")
    private fun connect(mac: String, result: MethodChannel.Result) {
        val ad = adapter
        if (ad == null) { result.error("no_bt", "Bluetooth unavailable", null); return }
        disconnect()
        stopScan()   // discovery kills RFCOMM connect reliability
        thread(name = "bt-setup-connect") {
            try {
                val dev = ad.getRemoteDevice(mac)
                val sock = dev.createRfcommSocketToServiceRecord(SETUP_UUID)
                sock.connect()   // triggers Just-Works pairing on first contact
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
}
