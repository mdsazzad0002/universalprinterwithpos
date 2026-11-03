package com.bdsoft.universal_print

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The one Flutter engine of the app. It runs the print queue and the local
 * API, so it is shared by [MainActivity], [PrintForegroundService] and
 * [PrintIntentActivity] and outlives the UI while the background service is
 * on.
 */
object PrintEngine {
    private const val ENGINE_ID = "main"

    var bluetooth: BluetoothBridge? = null
        private set
    var usb: UsbBridge? = null
        private set
    var host: HostBridge? = null
        private set

    /** The open UI, if any. */
    var activity: Activity? = null
        private set

    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        val messenger = engine.dartExecutor.binaryMessenger
        // Channels must exist before Dart starts calling them.
        bluetooth = BluetoothBridge(app, messenger).also { it.activity = activity }
        usb = UsbBridge(app, messenger)
        host = HostBridge(app, messenger).also { it.activity = activity }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    fun attach(activity: Activity) {
        this.activity = activity
        bluetooth?.activity = activity
        host?.activity = activity
    }

    fun detach(activity: Activity) {
        if (this.activity !== activity) return
        this.activity = null
        bluetooth?.activity = null
        host?.activity = null
    }

    /** Stops Dart, the API server and the queue. */
    fun destroy() {
        val engine = FlutterEngineCache.getInstance().get(ENGINE_ID) ?: return
        FlutterEngineCache.getInstance().remove(ENGINE_ID)
        bluetooth?.dispose()
        usb?.dispose()
        host?.dispose()
        bluetooth = null
        usb = null
        host = null
        engine.destroy()
    }
}
