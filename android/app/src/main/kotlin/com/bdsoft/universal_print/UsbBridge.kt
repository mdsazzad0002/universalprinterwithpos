package com.bdsoft.universal_print

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors

/**
 * USB printing through the Android USB Host API (USB OTG).
 *
 * Devices are addressed as "vendorId:productId" (hex) because the system
 * device name changes every time the cable is replugged. Writes run on one
 * background thread, in order, with the opened connection cached.
 */
class UsbBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.bdsoft.universal_print/usb"
        private const val ACTION_PERMISSION = "com.bdsoft.universal_print.USB_PERMISSION"
        private const val CHUNK_SIZE = 16 * 1024
        private const val TIMEOUT_MS = 5000
    }

    private class Opened(
        val device: UsbDevice,
        val connection: UsbDeviceConnection,
        val iface: UsbInterface,
        val endpoint: UsbEndpoint,
    )

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val opened = HashMap<String, Opened>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> executor.execute {
                val devices = usb.deviceList.values.map {
                    mapOf(
                        "name" to displayName(it),
                        "address" to address(it),
                        "isPrinter" to (findOutEndpoint(it)?.first?.interfaceClass == UsbConstants.USB_CLASS_PRINTER),
                        "deviceId" to readDeviceId(it),
                    )
                }
                mainHandler.post { result.success(devices) }
            }
            "requestPermission" -> {
                val device = call.argument<String>("address")?.let { find(it) }
                if (device == null) {
                    result.error("NOT_FOUND", "USB device is not connected", null)
                } else {
                    requestPermission(device, result)
                }
            }
            "write" -> {
                val address = call.argument<String>("address")
                val data = call.argument<ByteArray>("data")
                if (address == null || data == null) {
                    result.error("BAD_ARGS", "address and data are required", null)
                } else {
                    write(address, data, result)
                }
            }
            else -> result.notImplemented()
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.execute { opened.keys.toList().forEach { close(it) } }
        executor.shutdown()
    }

    private fun address(d: UsbDevice) = "%04x:%04x".format(d.vendorId, d.productId)

    private fun find(address: String) = usb.deviceList.values.firstOrNull { address(it) == address }

    private fun displayName(d: UsbDevice): String {
        // Names need permission on Android 10+; fall back to the ids.
        val name = runCatching { listOfNotNull(d.manufacturerName, d.productName).joinToString(" ") }.getOrNull()
        return if (name.isNullOrBlank()) "USB device ${address(d)}" else name
    }

    /** Prefers the printer-class interface; many POS printers are vendor class with a bulk OUT. */
    private fun findOutEndpoint(d: UsbDevice): Pair<UsbInterface, UsbEndpoint>? {
        val candidates = (0 until d.interfaceCount).map { d.getInterface(it) }
            .sortedBy { if (it.interfaceClass == UsbConstants.USB_CLASS_PRINTER) 0 else 1 }
        for (iface in candidates) {
            for (i in 0 until iface.endpointCount) {
                val ep = iface.getEndpoint(i)
                if (ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.direction == UsbConstants.USB_DIR_OUT) {
                    return iface to ep
                }
            }
        }
        return null
    }

    /**
     * IEEE 1284 device ID via the printer-class GET_DEVICE_ID request, e.g.
     * "MFG:Label;CMD:TSPL;MDL:TD-401H(300dpi);". Needs permission; null if
     * unavailable. Runs on the executor so it never races a print job.
     */
    private fun readDeviceId(device: UsbDevice): String? {
        if (!usb.hasPermission(device)) return null
        val iface = (0 until device.interfaceCount).map { device.getInterface(it) }
            .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_PRINTER } ?: return null
        val cached = opened[address(device)]?.takeIf { it.device.deviceId == device.deviceId }
        val connection = cached?.connection ?: usb.openDevice(device) ?: return null
        try {
            val buf = ByteArray(1024)
            val n = connection.controlTransfer(0xA1, 0, 0, iface.id shl 8, buf, buf.size, 1000)
            if (n < 2) return null
            val len = minOf(((buf[0].toInt() and 0xFF) shl 8) or (buf[1].toInt() and 0xFF), n)
            return if (len <= 2) null else String(buf, 2, len - 2, Charsets.US_ASCII).trim()
        } catch (e: Exception) {
            return null
        } finally {
            if (cached == null) connection.close()
        }
    }

    private fun requestPermission(device: UsbDevice, result: MethodChannel.Result) {
        if (usb.hasPermission(device)) {
            result.success(true)
            return
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                context.unregisterReceiver(this)
                result.success(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
            }
        }
        val filter = IntentFilter(ACTION_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        // Explicit package + mutable: the system adds the grant extras.
        val intent = Intent(ACTION_PERMISSION).setPackage(context.packageName)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        usb.requestPermission(device, PendingIntent.getBroadcast(context, 0, intent, flags))
    }

    private fun write(address: String, data: ByteArray, result: MethodChannel.Result) {
        executor.execute {
            try {
                try {
                    send(obtain(address), data)
                } catch (e: IOException) {
                    // Cable was replugged: reopen once and retry.
                    close(address)
                    send(obtain(address), data)
                }
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                close(address)
                mainHandler.post { result.error("USB_WRITE_FAILED", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun obtain(address: String): Opened {
        val device = find(address) ?: throw IOException("USB printer $address is not connected")
        opened[address]?.let { if (it.device.deviceId == device.deviceId) return it else close(address) }

        if (!usb.hasPermission(device)) {
            throw IOException("No permission for USB printer $address. Open the printer in Universal Print to allow it.")
        }
        val (iface, endpoint) = findOutEndpoint(device)
            ?: throw IOException("USB device $address has no printer output endpoint")
        val connection = usb.openDevice(device) ?: throw IOException("Cannot open USB printer $address")
        if (!connection.claimInterface(iface, true)) {
            connection.close()
            throw IOException("USB printer $address is in use by another app")
        }
        return Opened(device, connection, iface, endpoint).also { opened[address] = it }
    }

    private fun send(o: Opened, data: ByteArray) {
        var offset = 0
        while (offset < data.size) {
            val len = minOf(CHUNK_SIZE, data.size - offset)
            val sent = o.connection.bulkTransfer(o.endpoint, data, offset, len, TIMEOUT_MS)
            if (sent < 0) throw IOException("USB transfer failed (printer off or unplugged?)")
            offset += sent
        }
    }

    private fun close(address: String) {
        opened.remove(address)?.let {
            runCatching { it.connection.releaseInterface(it.iface) }
            runCatching { it.connection.close() }
        }
    }
}
