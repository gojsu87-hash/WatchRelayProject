package com.example.watchnotify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.example.watchnotify.ble.BleService

class ScreenReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> {
                if (!AppSettings.isServiceEnabled(context)) return
                try { context.startForegroundService(Intent(context, BleService::class.java)) } catch (e: Exception) { }
            }
        }
    }
}