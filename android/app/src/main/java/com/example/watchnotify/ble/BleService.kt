package com.example.watchnotify.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.watchnotify.ScreenReceiver
import com.example.watchnotify.ServiceWatchdog

class BleService : Service() {

    companion object {
        private const val CHANNEL_ID = "BleServiceChannel"
        private const val NOTIFICATION_ID = 1

        @Volatile
        var isRunning = false
            private set
    }

    private var screenReceiver: ScreenReceiver? = null
    private var btAclReceiver: BroadcastReceiver? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "WatchNotify::BleWakeLock"
        )
        wakeLock?.acquire()

        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        BleManager.getInstance(applicationContext).startGattServer()
        registerScreenReceiver()
        registerBtAclReceiver()
        ServiceWatchdog.schedule(applicationContext)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (BleManager.getInstance(applicationContext).isAdvertising) {
            return START_STICKY
        }
        BleManager.getInstance(applicationContext).startGattServer()
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false

        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (e: Exception) { }

        try {
            screenReceiver?.let { unregisterReceiver(it) }
        } catch (e: Exception) { }

        try {
            btAclReceiver?.let { unregisterReceiver(it) }
        } catch (e: Exception) { }

        BleManager.getInstance(applicationContext).disconnect()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun registerBtAclReceiver() {
        btAclReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    BluetoothDevice.ACTION_ACL_CONNECTED -> {
                        val ble = BleManager.getInstance(applicationContext)
                        ble.saveLog("📱 외부 BT 기기 연결 감지 → 3초 후 BLE 상태 점검")
                        Handler(Looper.getMainLooper()).postDelayed({
                            if (ble.connectionState == BleManager.ConnectionState.OFFLINE
                                && !ble.isAdvertising) {
                                ble.saveLog("📱 BLE 광고 중단 확인 → 재광고 시작")
                                ble.restartAdvertising()
                            } else {
                                ble.saveLog("📱 외부 BT 기기 연결 후 BLE 정상 유지 중")
                            }
                        }, 3000L)
                    }
                    BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                        val ble = BleManager.getInstance(applicationContext)
                        Handler(Looper.getMainLooper()).postDelayed({
                            if (ble.connectionState == BleManager.ConnectionState.OFFLINE
                                && !ble.isAdvertising) {
                                ble.saveLog("📱 외부 BT 기기 해제 후 BLE 광고 중단 → 재광고 시작")
                                ble.restartAdvertising()
                            }
                        }, 1000L)
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        registerReceiver(btAclReceiver, filter)
    }

    private fun registerScreenReceiver() {
        screenReceiver = ScreenReceiver()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        registerReceiver(screenReceiver, filter)
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "WatchNotify 서비스",
            NotificationManager.IMPORTANCE_LOW
        )
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("WatchNotify 실행 중")
            .setContentText("애플워치로 알림을 전달하고 있어요")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}