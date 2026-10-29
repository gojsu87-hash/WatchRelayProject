package com.example.watchnotify

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.example.watchnotify.ble.BleManager
import com.example.watchnotify.ble.BleService
import com.example.watchnotify.telegram.TelegramManager

@SuppressLint("MissingPermission")
class MainActivity : AppCompatActivity() {

    private var tvStatus: TextView? = null
    private var btnLog: Button? = null
    private var btnStart: Button? = null
    private var btnStop: Button? = null
    private var btnNotificationAccess: Button? = null
    private var btnModeToggle: Button? = null
    private var btnTest: Button? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        initViews()
        checkPermissions()
        updateUI()
    }

    override fun onResume() {
        super.onResume()
        updateUI()
    }

    private fun initViews() {
        tvStatus = findViewById(R.id.tvStatus)
        btnLog = findViewById(R.id.btnLog)
        btnStart = findViewById(R.id.btnStart)
        btnStop = findViewById(R.id.btnStop)
        btnNotificationAccess = findViewById(R.id.btnNotificationAccess)
        btnModeToggle = findViewById(R.id.btnModeToggle)
        btnTest = findViewById(R.id.btnTest)

        // 1. 연결 로그 보기 버튼
        btnLog?.setOnClickListener {
            startActivity(Intent(this, LogActivity::class.java))
        }

        // 2. 서비스 시작 버튼
        btnStart?.setOnClickListener {
            startBleService()
            Toast.makeText(this, "서비스가 시작되었습니다", Toast.LENGTH_SHORT).show()
            updateUI()
        }

        // 3. 서비스 중지 버튼
        btnStop?.setOnClickListener {
            val intent = Intent(this, BleService::class.java)
            stopService(intent)
            Toast.makeText(this, "서비스가 중지되었습니다", Toast.LENGTH_SHORT).show()
            updateUI()
        }

        // 4. 알림 접근 권한 설정 버튼
        btnNotificationAccess?.setOnClickListener {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }

        // 5. 모드 전환 버튼 (BLE ↔ API)
        btnModeToggle?.setOnClickListener {
            val currentMode = AppSettings.getMode(this)
            val newMode = if (currentMode == AppSettings.MODE_BLE) AppSettings.MODE_API else AppSettings.MODE_BLE
            AppSettings.setMode(this, newMode)
            Toast.makeText(this, "모드가 변경되었습니다: $newMode", Toast.LENGTH_SHORT).show()
            updateUI()
        }

        // 6. 테스트 알림 전송 버튼
        btnTest?.setOnClickListener {
            val mode = AppSettings.getMode(this)
            if (mode == AppSettings.MODE_BLE) {
                BleManager.getInstance(this).sendNotification(
                    System.currentTimeMillis(),
                    "com.kakao.talk",
                    "테스트 알림",
                    "WatchNotify 테스트 메시지입니다."
                )
            } else {
                TelegramManager.getInstance(this).sendNotification(
                    "com.kakao.talk",
                    "테스트 알림",
                    "WatchNotify 테스트 메시지입니다."
                )
            }
            Toast.makeText(this, "테스트 알림을 전송했습니다 ($mode 모드)", Toast.LENGTH_SHORT).show()
        }
    }

    private fun startBleService() {
        val intent = Intent(this, BleService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun updateUI() {
        val isRunning = BleService.isRunning
        val serviceStatus = if (isRunning) "🟢 서비스 가동 중" else "🔴 서비스 중지됨"
        val notiStatus = if (isNotificationListenerEnabled()) "알림 접근 권한: 허용됨" else "알림 접근 권한: 설정 필요"
        val bleStatus = if (hasBlePermissions()) "BLE 권한: 허용됨" else "BLE 권한: 요청 필요"
        val currentMode = AppSettings.getMode(this)

        tvStatus?.text = "$serviceStatus | 현재 모드: $currentMode\n$notiStatus\n$bleStatus"

        btnModeToggle?.text = if (currentMode == AppSettings.MODE_BLE) {
            "BLE 모드 (API 모드로 전환)"
        } else {
            "API 모드 (BLE 모드로 전환)"
        }
    }

    private fun isNotificationListenerEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        return flat?.contains(packageName) == true
    }

    private fun hasBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                    ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
                    ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestBlePermissions() {
        val permissions = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.add(Manifest.permission.BLUETOOTH_SCAN)
            permissions.add(Manifest.permission.BLUETOOTH_CONNECT)
            permissions.add(Manifest.permission.BLUETOOTH_ADVERTISE)
        } else {
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        val notGranted = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (notGranted.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, notGranted.toTypedArray(), 1001)
        }
    }

    private fun checkPermissions() {
        if (!hasBlePermissions()) {
            requestBlePermissions()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1001) {
            updateUI()
        }
    }
}
