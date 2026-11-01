package com.example.watchnotify

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.net.Uri
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.example.watchnotify.ServiceWatchdog
import com.example.watchnotify.ble.BleManager
import com.example.watchnotify.ble.BleService
import com.example.watchnotify.telegram.TelegramManager

@SuppressLint("MissingPermission")
class MainActivity : AppCompatActivity() {

    private companion object {
        const val STATUS_REFRESH_INTERVAL_MS = 1_000L
    }

    private val statusHandler = Handler(Looper.getMainLooper())
    private val statusRefreshRunnable = object : Runnable {
        override fun run() {
            updateUI()
            statusHandler.postDelayed(this, STATUS_REFRESH_INTERVAL_MS)
        }
    }

    private var tvServiceStatus: TextView? = null
    private var tvConnectionStatus: TextView? = null
    private var tvConnectionDuration: TextView? = null
    private var watchBatteryRing: WatchBatteryRingView? = null
    private var tvModeStatus: TextView? = null
    private var tvNotificationStatus: TextView? = null
    private var tvBleStatus: TextView? = null
    private var tvPhoneStatus: TextView? = null
    private var tvBatteryStatus: TextView? = null
    private var btnLog: Button? = null
    private var btnStart: Button? = null
    private var btnStop: Button? = null
    private var btnNotificationAccess: Button? = null
    private var btnBatteryOptimization: Button? = null
    private var btnModeToggle: Button? = null
    private var btnTest: Button? = null
    private var serviceStatusRing: View? = null
    private var connectionStatusRing: View? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        initViews()
        checkPermissions()
        if (AppSettings.isServiceEnabled(this)) {
            startBleService()
        }
        updateUI()
    }

    override fun onResume() {
        super.onResume()
        updateUI()
        statusHandler.removeCallbacks(statusRefreshRunnable)
        statusHandler.postDelayed(statusRefreshRunnable, STATUS_REFRESH_INTERVAL_MS)
    }

    override fun onPause() {
        statusHandler.removeCallbacks(statusRefreshRunnable)
        super.onPause()
    }

    private fun initViews() {
        val mainRoot = findViewById<View>(R.id.mainRoot)
        val basePaddingTop = mainRoot.paddingTop
        ViewCompat.setOnApplyWindowInsetsListener(mainRoot) { view, windowInsets ->
            val topInset = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars()).top
            view.setPadding(
                view.paddingLeft,
                basePaddingTop + topInset,
                view.paddingRight,
                view.paddingBottom
            )
            windowInsets
        }
        ViewCompat.requestApplyInsets(mainRoot)

        tvServiceStatus = findViewById(R.id.tvServiceStatus)
        tvConnectionStatus = findViewById(R.id.tvConnectionStatus)
        tvConnectionDuration = findViewById(R.id.tvConnectionDuration)
        watchBatteryRing = findViewById(R.id.watchBatteryRing)
        serviceStatusRing = findViewById(R.id.serviceStatusRing)
        connectionStatusRing = findViewById(R.id.connectionStatusRing)
        tvModeStatus = findViewById(R.id.tvModeStatus)
        tvNotificationStatus = findViewById(R.id.tvNotificationStatus)
        tvBleStatus = findViewById(R.id.tvBleStatus)
        tvPhoneStatus = findViewById(R.id.tvPhoneStatus)
        tvBatteryStatus = findViewById(R.id.tvBatteryStatus)
        btnLog = findViewById(R.id.btnLog)
        btnStart = findViewById(R.id.btnStart)
        btnStop = findViewById(R.id.btnStop)
        btnNotificationAccess = findViewById(R.id.btnNotificationAccess)
        btnBatteryOptimization = findViewById(R.id.btnBatteryOptimization)
        btnModeToggle = findViewById(R.id.btnModeToggle)
        btnTest = findViewById(R.id.btnTest)

        // 1. 연결 로그 보기 버튼
        btnLog?.setOnClickListener {
            startActivity(Intent(this, LogActivity::class.java))
        }

        // 2. 서비스 시작 버튼
        btnStart?.setOnClickListener {
            AppSettings.setServiceEnabled(this, true)
            startBleService()
            Toast.makeText(this, "서비스가 시작되었습니다", Toast.LENGTH_SHORT).show()
            updateUI()
        }

        // 3. 서비스 중지 버튼
        btnStop?.setOnClickListener {
            AppSettings.setServiceEnabled(this, false)
            ServiceWatchdog.cancel(this)
            val intent = Intent(this, BleService::class.java)
            stopService(intent)
            Toast.makeText(this, "서비스를 중지했습니다. 직접 시작할 때까지 자동 실행되지 않습니다.", Toast.LENGTH_SHORT).show()
            updateUI()
        }

        // 4. 알림 접근 권한 설정 버튼
        btnNotificationAccess?.setOnClickListener {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }

        btnBatteryOptimization?.setOnClickListener {
            requestBatteryOptimizationExemption()
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
                    0L,
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
        val serviceStatus = if (isRunning) "서비스 실행 중" else "서비스 중지됨"
        val currentMode = AppSettings.getMode(this)
        val bleManager = BleManager.getInstance(applicationContext)
        val isBleConnected = bleManager.connectionState == BleManager.ConnectionState.CONNECTED
        val connectionStatus = when {
            currentMode != AppSettings.MODE_BLE -> "BLE 연결 상태 확인 안 함 · API 모드"
            isRunning && isBleConnected && bleManager.isWatchResponsive -> "워치 연결됨 · 응답 정상"
            isRunning && isBleConnected && bleManager.hasWatchHeartbeat -> "워치 응답 지연 · 복구 중"
            isRunning && isBleConnected -> "워치 연결됨 · 응답 확인 중"
            isRunning -> "워치 연결 안 됨"
            else -> "서비스 중지로 연결 확인 불가"
        }
        val connectionDuration = if (currentMode == AppSettings.MODE_BLE &&
            isRunning && isBleConnected && bleManager.isWatchResponsive
        ) {
            bleManager.watchConnectedSinceMillis?.let { connectedSince ->
                val elapsedSeconds = ((System.currentTimeMillis() - connectedSince) / 1_000)
                    .coerceAtLeast(0)
                val hours = elapsedSeconds / 3_600
                val minutes = (elapsedSeconds % 3_600) / 60
                val seconds = elapsedSeconds % 60
                when {
                    hours > 0 -> "정상 연동 · ${hours}시간 ${minutes}분"
                    minutes > 0 -> "정상 연동 · ${minutes}분 ${seconds}초"
                    else -> "정상 연동 · ${seconds}초"
                }
            } ?: "정상 연동 시간 확인 중"
        } else {
            ""
        }
        val watchBattery = WatchNotifyWidget.getBatteryLevel(applicationContext)
        val notiStatus = if (isNotificationListenerEnabled()) "알림 권한 · 허용됨" else "알림 권한 · 설정 필요"
        val bleStatus = if (hasBlePermissions()) "Bluetooth · 허용됨" else "Bluetooth · 권한 필요"
        val phoneStatus = if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) ==
            PackageManager.PERMISSION_GRANTED) {
            "전화 권한 · 허용됨"
        } else {
            "전화 권한 · 설정 필요"
        }
        val batteryOptimizationExempt = isIgnoringBatteryOptimizations()
        val batteryStatus = if (batteryOptimizationExempt) {
            "배터리 · 제한 제외됨"
        } else {
            "배터리 · 예외 필요"
        }
        tvServiceStatus?.text = serviceStatus
        tvConnectionStatus?.text = connectionStatus
        tvConnectionDuration?.text = connectionDuration
        tvConnectionDuration?.visibility =
            if (connectionDuration.isEmpty()) View.GONE else View.VISIBLE
        watchBatteryRing?.setBatteryLevel(watchBattery)
        serviceStatusRing?.setRingColor(
            if (isRunning) R.color.status_green else R.color.status_red
        )
        val connectionRingColor = when {
            currentMode != AppSettings.MODE_BLE -> R.color.status_neutral
            isRunning && isBleConnected && bleManager.isWatchResponsive -> R.color.status_green
            isRunning && isBleConnected -> R.color.status_warning
            else -> R.color.status_red
        }
        connectionStatusRing?.setRingColor(connectionRingColor)
        tvModeStatus?.text = "전송 방식 · $currentMode"
        tvNotificationStatus?.text = notiStatus
        tvBleStatus?.text = bleStatus
        tvPhoneStatus?.text = phoneStatus
        tvBatteryStatus?.text = batteryStatus
        btnBatteryOptimization?.apply {
            isEnabled = !batteryOptimizationExempt
            text = if (batteryOptimizationExempt) "배터리 최적화 제외됨" else "배터리 제한 설정"
        }

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

    private fun View.setRingColor(colorResource: Int) {
        background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(android.graphics.Color.TRANSPARENT)
            setStroke(
                (2 * resources.displayMetrics.density).toInt().coerceAtLeast(1),
                ContextCompat.getColor(context, colorResource)
            )
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = getSystemService(PowerManager::class.java)
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            isIgnoringBatteryOptimizations()) {
            updateUI()
            return
        }

        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
        } catch (e: Exception) {
            Toast.makeText(
                this,
                "배터리 최적화 설정을 열지 못했습니다: ${e.localizedMessage}",
                Toast.LENGTH_LONG
            ).show()
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (fallbackError: Exception) {
                Toast.makeText(
                    this,
                    "설정 화면을 열 수 없습니다: ${fallbackError.localizedMessage}",
                    Toast.LENGTH_LONG
                ).show()
            }
        }
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
        permissions.add(Manifest.permission.READ_PHONE_STATE)
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
        val hasPhoneStatePermission =
            ContextCompat.checkSelfPermission(this, Manifest.permission.READ_PHONE_STATE) ==
                PackageManager.PERMISSION_GRANTED
        if (!hasBlePermissions() || !hasPhoneStatePermission) {
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
