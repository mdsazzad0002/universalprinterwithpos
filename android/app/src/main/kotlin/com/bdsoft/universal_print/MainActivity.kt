package com.bdsoft.universal_print

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/** The UI. It borrows the shared [PrintEngine] instead of owning one. */
class MainActivity : FlutterActivity() {

    override fun provideFlutterEngine(context: Context): FlutterEngine = PrintEngine.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        PrintEngine.attach(this)
        super.onCreate(savedInstanceState)
        // Started before, but stopped by the system or an update.
        if (PrintForegroundService.isEnabled(this) && !PrintForegroundService.isRunning) {
            PrintForegroundService.start(this)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        PrintEngine.bluetooth?.onPermissionResult(requestCode, grantResults)
        PrintEngine.host?.onPermissionResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        super.onDestroy()
        PrintEngine.detach(this)
        // Without the background service the app stops with its UI, as before.
        if (!isChangingConfigurations && !PrintForegroundService.isRunning) PrintEngine.destroy()
    }
}
