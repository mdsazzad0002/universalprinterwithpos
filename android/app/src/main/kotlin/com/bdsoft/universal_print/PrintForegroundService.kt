package com.bdsoft.universal_print

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the process, and so the Flutter engine with the API server and print
 * queue, alive while the app is closed. Started from the app or at boot when
 * "Run in background" is on.
 */
class PrintForegroundService : Service() {

    companion object {
        private const val PREFS = "universal_print"
        private const val KEY_ENABLED = "background_enabled"
        private const val CHANNEL_SERVICE = "service"
        private const val CHANNEL_ALERTS = "alerts"
        private const val NOTIFICATION_ID = 1
        private const val PAIRING_NOTIFICATION_ID = 2
        private const val ACTION_STOP = "com.bdsoft.universal_print.STOP_SERVICE"

        @Volatile
        var isRunning = false
            private set

        /** On unless turned off: software must be able to print at any time. */
        fun isEnabled(context: Context) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_ENABLED, true)

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, enabled).apply()
            if (enabled) start(context) else context.stopService(Intent(context, PrintForegroundService::class.java))
        }

        fun start(context: Context) {
            val intent = Intent(context, PrintForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Redraws the notification with the latest status from Dart. */
        fun refresh(context: Context) {
            if (!isRunning) return
            manager(context).notify(NOTIFICATION_ID, build(context))
        }

        fun notifyPairing(context: Context, name: String, code: String) {
            createChannels(context)
            val notification = builder(context, CHANNEL_ALERTS)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("$name wants to connect")
                .setContentText("Open Universal Print to allow it · code $code")
                .setContentIntent(openApp(context))
                .setAutoCancel(true)
                .build()
            manager(context).notify(PAIRING_NOTIFICATION_ID, notification)
        }

        private fun manager(context: Context) =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun createChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            manager(context).createNotificationChannels(
                listOf(
                    NotificationChannel(CHANNEL_SERVICE, "Background printing", NotificationManager.IMPORTANCE_LOW)
                        .apply { description = "Shown while the print API runs with the app closed" },
                    NotificationChannel(CHANNEL_ALERTS, "Connection requests", NotificationManager.IMPORTANCE_HIGH),
                )
            )
        }

        @Suppress("DEPRECATION")
        private fun builder(context: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, channel)
            } else {
                Notification.Builder(context)
            }

        private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        private fun build(context: Context): Notification {
            val stop = PendingIntent.getService(
                context,
                1,
                Intent(context, PrintForegroundService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            @Suppress("DEPRECATION") // Action.Builder needs API 23 icons; this form works on all versions
            return builder(context, CHANNEL_SERVICE)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("Universal Print is ready")
                .setContentText(PrintEngine.host?.status ?: "Starting…")
                .setContentIntent(openApp(context))
                .setOngoing(true)
                .addAction(0, "Stop", stop)
                .build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannels(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, build(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, build(this))
        }
        isRunning = true
        PrintEngine.obtain(this)

        // The CPU and Wi-Fi must stay up to answer API calls with the screen off.
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "UniversalPrint::api")
            .apply { setReferenceCounted(false); acquire() }
        @Suppress("DEPRECATION") // LOW_LATENCY needs the screen on; HIGH_PERF keeps Wi-Fi up with it off
        wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "UniversalPrint::api")
            .apply { setReferenceCounted(false); acquire() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // "Stop" in the notification turns the setting off, too.
            getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_ENABLED, false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        wakeLock?.release()
        wifiLock?.release()
        // With no UI left, nothing needs the engine any more.
        if (PrintEngine.activity == null) PrintEngine.destroy()
        super.onDestroy()
    }
}
