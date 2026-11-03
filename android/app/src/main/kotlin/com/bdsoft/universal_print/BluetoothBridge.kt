package com.bdsoft.universal_print

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Bluetooth Classic (SPP) printing for Flutter.
 *
 * All socket work runs on one background thread, so jobs to the same printer
 * are written strictly in order. Sockets are cached per address and reopened
 * once if a write fails (printer was switched off, out of range, ...).
 */
@SuppressLint("MissingPermission") // checked in hasPermission()
class BluetoothBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.bdsoft.universal_print/bluetooth"
        const val PERMISSION_REQUEST = 4101
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

        // Cheap printers have small buffers and silently drop data when
        // flooded, so large jobs (raster images) are written in chunks.
        private const val CHUNK_SIZE = 512
        private const val CHUNK_DELAY_MS = 8L
    }

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val sockets = HashMap<String, BluetoothSocket>()
    private var pendingPermission: MethodChannel.Result? = null

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isEnabled" -> result.success(adapter?.isEnabled == true)
            "requestPermission" -> requestPermission(result)
            "bondedDevices" -> bondedDevices(result)
            "write" -> {
                val address = call.argument<String>("address")
                val data = call.argument<ByteArray>("data")
                if (address == null || data == null) {
                    result.error("BAD_ARGS", "address and data are required", null)
                } else {
                    write(address, data, result)
                }
            }
            "disconnect" -> {
                val address = call.argument<String>("address")
                executor.execute {
                    address?.let { closeSocket(it) }
                    mainHandler.post { result.success(null) }
                }
            }
            "openSettings" -> {
                activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST) return
        pendingPermission?.success(
            grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        )
        pendingPermission = null
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.execute { sockets.keys.toList().forEach { closeSocket(it) } }
        executor.shutdown()
    }

    private fun hasPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(true)
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), PERMISSION_REQUEST)
    }

    private fun bondedDevices(result: MethodChannel.Result) {
        val bt = adapter
        when {
            bt == null -> result.error("NO_BLUETOOTH", "This device has no Bluetooth", null)
            !hasPermission() -> result.error("NO_PERMISSION", "Bluetooth permission not granted", null)
            !bt.isEnabled -> result.error("BLUETOOTH_OFF", "Bluetooth is turned off", null)
            else -> result.success(bt.bondedDevices.map {
                mapOf(
                    "name" to (it.name ?: it.address),
                    "address" to it.address,
                    "isPrinter" to (it.bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.IMAGING),
                )
            })
        }
    }

    private fun write(address: String, data: ByteArray, result: MethodChannel.Result) {
        executor.execute {
            try {
                try {
                    send(obtainSocket(address), data)
                } catch (e: IOException) {
                    // Stale cached socket: reconnect once and retry.
                    closeSocket(address)
                    send(obtainSocket(address), data)
                }
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                closeSocket(address)
                mainHandler.post { result.error("BT_WRITE_FAILED", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun obtainSocket(address: String): BluetoothSocket {
        sockets[address]?.let { if (it.isConnected) return it else closeSocket(address) }

        val bt = adapter ?: throw IOException("This device has no Bluetooth")
        if (!hasPermission()) throw IOException("Bluetooth permission not granted")
        if (!bt.isEnabled) throw IOException("Bluetooth is turned off")

        val device = bt.getRemoteDevice(address)
        bt.cancelDiscovery()
        val socket = try {
            device.createRfcommSocketToServiceRecord(SPP_UUID).also { connectOrClose(it) }
        } catch (e: IOException) {
            // Some printers only accept insecure RFCOMM.
            try {
                device.createInsecureRfcommSocketToServiceRecord(SPP_UUID).also { connectOrClose(it) }
            } catch (e2: IOException) {
                throw IOException("Cannot connect to printer $address. Is it on and in range?", e2)
            }
        }
        sockets[address] = socket
        return socket
    }

    private fun connectOrClose(socket: BluetoothSocket) {
        try {
            socket.connect()
        } catch (e: IOException) {
            runCatching { socket.close() }
            throw e
        }
    }

    private fun send(socket: BluetoothSocket, data: ByteArray) {
        val out = socket.outputStream
        var offset = 0
        while (offset < data.size) {
            val len = minOf(CHUNK_SIZE, data.size - offset)
            out.write(data, offset, len)
            out.flush()
            offset += len
            if (offset < data.size) Thread.sleep(CHUNK_DELAY_MS)
        }
    }

    private fun closeSocket(address: String) {
        sockets.remove(address)?.let { runCatching { it.close() } }
    }
}
