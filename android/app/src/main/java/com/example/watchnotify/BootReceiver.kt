package com.example.watchnotify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.example.watchnotify.ble.BleService

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            if (!AppSettings.isServiceEnabled(context)) return
            context.startForegroundService(Intent(context, BleService::class.java))
            ServiceWatchdog.schedule(context)
        }
    }
}