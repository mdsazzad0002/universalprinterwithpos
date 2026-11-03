package com.bdsoft.universal_print

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Starts the background service after a reboot or app update, if it is on. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
                if (PrintForegroundService.isEnabled(context)) PrintForegroundService.start(context)
        }
    }
}
