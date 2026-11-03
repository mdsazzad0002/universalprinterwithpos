package com.bdsoft.universal_print

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bluetooth: BluetoothBridge? = null
    private var usb: UsbBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bluetooth = BluetoothBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        usb = UsbBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bluetooth?.onPermissionResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        bluetooth?.dispose()
        bluetooth = null
        usb?.dispose()
        usb = null
        super.onDestroy()
    }
}
