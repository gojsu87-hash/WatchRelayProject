package com.example.watchnotify

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.example.watchnotify.ble.BleManager
import com.example.watchnotify.ble.BleService

class ServiceWatchdog : BroadcastReceiver() {

    companion object {
        private const val TAG = "ServiceWatchdog"
        private const val ACTION_WATCHDOG = "com.example.watchnotify.WATCHDOG"
        private const val INTERVAL_MS = 15 * 60 * 1000L

        fun schedule(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, ServiceWatchdog::class.java).apply {
                action = ACTION_WATCHDOG
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                android.os.SystemClock.elapsedRealtime() + INTERVAL_MS,
                pendingIntent
            )
        }

        fun cancel(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val intent = Intent(context, ServiceWatchdog::class.java).apply {
                action = ACTION_WATCHDOG
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            alarmManager.cancel(pendingIntent)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (!AppSettings.isServiceEnabled(context)) {
            cancel(context)
            return
        }

        if (!BleService.isRunning) {
            Log.d(TAG, "서비스 미실행 → 재시작")
            try {
                context.startForegroundService(
                    Intent(context, BleService::class.java)
                )
            } catch (e: Exception) {
                Log.e(TAG, "재시작 실패: ${e.message}")
            }
        } else {
            Log.d(TAG, "서비스 정상 실행 중")
            // 서비스는 살아있어도 BLE 광고가 멈췄을 수 있음 → 별도 확인
            val bleManager = BleManager.getInstance(context)
            if (!bleManager.isAdvertising &&
                bleManager.connectionState == BleManager.ConnectionState.OFFLINE) {
                Log.d(TAG, "BLE 광고 중단 감지 → 재시작")
                bleManager.restartAdvertising()
            }
        }
        schedule(context)
    }
}