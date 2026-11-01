package com.example.watchnotify.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.example.watchnotify.ScreenReceiver
import com.example.watchnotify.ServiceWatchdog
import com.example.watchnotify.MainActivity

class BleService : Service() {

    companion object {
        private const val CHANNEL_ID = "BleServiceChannel"
        private const val NOTIFICATION_ID = 1

        @Volatile
        var isRunning = false
            private set

        @Volatile
        var isOutgoingCall = false
            private set

        @Volatile
        var isRinging = false
            private set

        @Volatile
        var isInCall = false
            private set

        @Volatile
        var callNotificationSent = false
            internal set
    }

    private var screenReceiver: ScreenReceiver? = null
    private var btAclReceiver: BroadcastReceiver? = null
    private var bluetoothStateReceiver: BroadcastReceiver? = null
    private var phoneStateReceiver: BroadcastReceiver? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val diagnosticHandler = Handler(Looper.getMainLooper())
    private val diagnosticRunnable = object : Runnable {
        override fun run() {
            val ble = BleManager.getInstance(applicationContext)
            if (ble.connectionState == BleManager.ConnectionState.OFFLINE) {
                ble.logDiagnosticSnapshot()
                ble.ensureReady()
                diagnosticHandler.postDelayed(this, 30_000L)
            } else {
                diagnosticHandler.postDelayed(this, 2 * 60 * 1000L)
            }
        }
    }

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
        registerBluetoothStateReceiver()
        registerPhoneStateReceiver()
        ServiceWatchdog.schedule(applicationContext)
        BleManager.getInstance(applicationContext).logDiagnosticSnapshot()
        diagnosticHandler.postDelayed(diagnosticRunnable, 30_000L)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        BleManager.getInstance(applicationContext).ensureReady()
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        isOutgoingCall = false
        isRinging = false
        isInCall = false
        callNotificationSent = false
        diagnosticHandler.removeCallbacks(diagnosticRunnable)

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

        try {
            bluetoothStateReceiver?.let { unregisterReceiver(it) }
        } catch (e: Exception) { }

        try {
            phoneStateReceiver?.let { unregisterReceiver(it) }
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

    private fun registerBluetoothStateReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_OFF -> {
                        BleManager.getInstance(applicationContext).disconnect()
                        Log.i("BleManager", "Bluetooth 꺼짐 확인; BLE 세션 정리")
                    }
                    BluetoothAdapter.STATE_ON -> {
                        Log.i("BleManager", "Bluetooth 켜짐 확인; GATT/광고 즉시 복구")
                        BleManager.getInstance(applicationContext).startGattServer()
                    }
                }
            }
        }
        bluetoothStateReceiver = receiver
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        ContextCompat.registerReceiver(
            this,
            receiver,
            filter,
            ContextCompat.RECEIVER_EXPORTED
        )
    }

    private fun registerPhoneStateReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
                when (intent.getStringExtra(TelephonyManager.EXTRA_STATE)) {
                    TelephonyManager.EXTRA_STATE_RINGING -> {
                        val wasRinging = isRinging
                        isOutgoingCall = false
                        isRinging = true
                        isInCall = false
                        callNotificationSent = false
                        if (!wasRinging) {
                            BleManager.getInstance(applicationContext).sendSignal("CALL_RINGING")
                        }
                        Log.d("BleService", "수신 전화 감지")
                    }
                    TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                        if (isRinging) {
                            isRinging = false
                            isInCall = true
                            isOutgoingCall = false
                            BleManager.getInstance(applicationContext).sendSignal("CALL_ANSWERED")
                            Log.d("BleService", "수신 전화 연결됨 → CALL_ANSWERED")
                        } else {
                            isOutgoingCall = true
                            isRinging = false
                            isInCall = false
                            Log.d("BleService", "발신 전화 감지 (워치 전송 제외)")
                        }
                    }
                    TelephonyManager.EXTRA_STATE_IDLE -> {
                        val wasInCall = isInCall
                        val wasRinging = isRinging
                        val wasOutgoing = isOutgoingCall
                        isOutgoingCall = false
                        isRinging = false
                        isInCall = false
                        callNotificationSent = false

                        if (!wasOutgoing) {
                            val signal = when {
                                wasInCall -> "CANCEL_CALL"
                                wasRinging -> "MISSED_CALL"
                                else -> null
                            }
                            signal?.let {
                                BleManager.getInstance(applicationContext).sendSignal(it)
                            }
                        }
                        Log.d("BleService", "통화 종료 (wasOutgoing=$wasOutgoing)")
                    }
                }
            }
        }
        phoneStateReceiver = receiver
        ContextCompat.registerReceiver(
            this,
            receiver,
            IntentFilter(TelephonyManager.ACTION_PHONE_STATE_CHANGED),
            ContextCompat.RECEIVER_EXPORTED
        )
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
        val contentIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            contentIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("WatchNotify 실행 중")
            .setContentText("애플워치로 알림을 전달하고 있어요")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .setAutoCancel(false)
            .build()
    }
}