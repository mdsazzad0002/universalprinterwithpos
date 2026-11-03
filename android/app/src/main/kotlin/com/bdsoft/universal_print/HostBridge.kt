package com.bdsoft.universal_print

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * App-level glue between Dart and Android: background service on/off,
 * battery and notification settings, and print requests from Intents.
 */
class HostBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.bdsoft.universal_print/host"
        const val NOTIFICATION_PERMISSION_REQUEST = 4102
    }

    var activity: Activity? = null

    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private var pendingPermission: MethodChannel.Result? = null

    /** Calls to Dart that arrived before it finished starting. */
    private val queued = ArrayList<Pair<() -> Unit, () -> Unit>>()
    private var dartReady = false

    /** Latest status line from Dart, shown in the service notification. */
    var status: String = "Starting…"
        private set

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> {
                dartReady = true
                queued.toList().forEach { (run, _) -> run() }
                queued.clear()
                result.success(null)
            }
            "getBackground" -> result.success(PrintForegroundService.isEnabled(context))
            "setBackground" -> {
                val enabled = call.argument<Boolean>("enabled") == true
                PrintForegroundService.setEnabled(context, enabled)
                result.success(enabled)
            }
            "updateStatus" -> {
                status = call.argument<String>("text") ?: status
                PrintForegroundService.refresh(context)
                result.success(null)
            }
            "notifyPairing" -> {
                // Only needed when nobody sees the in-app dialog.
                if (activity == null) {
                    PrintForegroundService.notifyPairing(
                        context,
                        call.argument<String>("name") ?: "",
                        call.argument<String>("code") ?: "",
                    )
                }
                result.success(null)
            }
            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBattery())
            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBattery()
                result.success(null)
            }
            "openPrintSettings" -> {
                val intent = Intent(Settings.ACTION_PRINT_SETTINGS)
                activity?.startActivity(intent) ?: context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
            }
            "hasNotificationPermission" -> result.success(hasNotificationPermission())
            "requestNotificationPermission" -> requestNotificationPermission(result)
            else -> result.notImplemented()
        }
    }

    /** Sends a print request to Dart; [done] gets the API-style result map. */
    fun submit(args: Map<String, Any?>, done: (Map<*, *>) -> Unit) = request("submitIntent", args, done)

    /**
     * Calls [method] in Dart once it is ready; [done] always gets a map, with
     * `success: false` and `error` when the call failed.
     */
    fun request(method: String, args: Any?, done: (Map<*, *>) -> Unit) {
        val run = {
            channel.invokeMethod(method, args, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    done(result as? Map<*, *> ?: mapOf("success" to false, "error" to "No result"))
                }

                override fun error(code: String, message: String?, details: Any?) {
                    done(mapOf("success" to false, "error" to (message ?: code)))
                }

                override fun notImplemented() {
                    done(mapOf("success" to false, "error" to "App is not ready"))
                }
            })
        }
        if (dartReady) run() else queued.add(run to { done(mapOf("success" to false, "error" to "App was closed")) })
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        pendingPermission?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        pendingPermission = null
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        queued.forEach { (_, cancel) -> cancel() }
        queued.clear()
    }

    private fun isIgnoringBattery(): Boolean =
        (context.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(context.packageName)

    /** Without this, Doze cuts the network and the API stops answering. */
    @SuppressLint("BatteryLife") // in-house POS app; the user asked for always-on printing
    private fun requestIgnoreBattery() {
        if (isIgnoringBattery()) return
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
        activity?.startActivity(intent) ?: context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    private fun hasNotificationPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled()
        }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        val ui = activity
        if (hasNotificationPermission() || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || ui == null) {
            result.success(hasNotificationPermission())
            return
        }
        pendingPermission?.success(false)
        pendingPermission = result
        ui.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST)
    }
}
