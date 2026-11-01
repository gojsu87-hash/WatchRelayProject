package com.example.watchnotify.ble

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import com.example.watchnotify.AppSettings
import com.example.watchnotify.db.AppDatabase
import com.example.watchnotify.db.ConnectionLogEntity
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.*

@SuppressLint("MissingPermission")
class BleManager private constructor(context: Context) {

    enum class ConnectionState { CONNECTED, OFFLINE }

    private val appContext = context.applicationContext
    private val bluetoothManager = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter = bluetoothManager.adapter
    private var gattServer: BluetoothGattServer? = null
    @Volatile private var connectedDevice: BluetoothDevice? = null
    private var notifyCharacteristic: BluetoothGattCharacteristic? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val outgoingFrames = ArrayDeque<ByteArray>()
    private val connectionRecoveryRunnable = object : Runnable {
        override fun run() {
            checkConnectionHealth()
            mainHandler.postDelayed(this, CONNECTION_HEALTH_CHECK_INTERVAL_MS)
        }
    }
    private data class FailureLogAssembly(
        val total: Int,
        val chunks: Array<ByteArray?> = arrayOfNulls(total)
    )
    private val incomingFailureLogs = mutableMapOf<Int, FailureLogAssembly>()
    private val completedFailureLogTransfers = LinkedHashSet<Int>()
    private var advertisingRecoveryWorkItem: Runnable? = null
    private var advertisingStartTimeoutWorkItem: Runnable? = null
    private var advertisingRecoveryAttempt = 0
    private var heartbeatWorkItem: Runnable? = null
    private var heartbeatRetryTimeoutWorkItem: Runnable? = null
    private var notificationInFlight = false
    private var notificationRetryCount = 0
    private var negotiatedMtu = 23
    private var nextTransferId = 1L
    private var heartbeatSequence = 0L
    private var heartbeatHandshakeAckSent = false
    private val pendingHeartbeatTokens = mutableSetOf<Long>()
    @Volatile private var advertisingStartPending = false
    @Volatile private var gattServiceReady = false
    @Volatile private var advertisingStatus = "미시작"
    @Volatile private var lastWatchConnectionEvent = "없음"
    @Volatile private var connectionUnavailableSinceMillis = 0L
    @Volatile private var gattConnectedSinceMillis = 0L
    @Volatile var watchConnectedSinceMillis: Long? = null
        private set
    @Volatile private var watchNotificationsEnabled = false
    @Volatile private var watchHeartbeatResponded = false
    @Volatile private var heartbeatDelayed = false
    @Volatile private var lastWatchPongAt = 0L

    @Volatile var isAdvertising: Boolean = false
        private set

    val connectionState: ConnectionState
        get() = if (connectedDevice != null) ConnectionState.CONNECTED else ConnectionState.OFFLINE

    val isWatchResponsive: Boolean
        get() = connectedDevice != null &&
            watchHeartbeatResponded &&
            !heartbeatDelayed &&
            System.currentTimeMillis() - lastWatchPongAt <= HEARTBEAT_TIMEOUT_MS

    val hasWatchHeartbeat: Boolean
        get() = watchHeartbeatResponded

    private val serviceUuid = UUID.fromString("0000180D-0000-1000-8000-00805f9b34fb")
    private val charUuid = UUID.fromString("00002A37-0000-1000-8000-00805f9b34fb")

    companion object {
        private const val TAG = "BleManager"
        private const val FRAME_HEADER_SIZE = 10
        private const val FAILURE_LOG_FRAME_HEADER_SIZE = 6
        private const val MAX_INCOMING_FAILURE_LOG_TRANSFERS = 4
        private const val MAX_FAILURE_LOG_TRANSFER_BYTES = 64 * 1024
        private const val MAX_COMPLETED_FAILURE_LOG_TRANSFERS = 128
        private const val MAX_FRAME_RETRIES = 3
        private const val HEARTBEAT_INTERVAL_MS = 15_000L
        private const val HEARTBEAT_RETRY_GRACE_MS = 3_000L
        private const val HEARTBEAT_TIMEOUT_MS = HEARTBEAT_INTERVAL_MS + HEARTBEAT_RETRY_GRACE_MS
        private const val CONNECTION_HEALTH_CHECK_INTERVAL_MS = 15_000L
        private const val FULL_CONNECTION_RECOVERY_AFTER_MS = 60_000L
        private val FRAME_MAGIC = byteArrayOf(0x57.toByte(), 0x4E.toByte())
        private val FAILURE_LOG_FRAME_MAGIC = byteArrayOf(0x57.toByte(), 0x46.toByte())
        private val FAILURE_LOG_ACK_MAGIC = byteArrayOf(0x57.toByte(), 0x41.toByte())
        @Volatile private var instance: BleManager? = null

        fun getInstance(context: Context): BleManager {
            return instance ?: synchronized(this) {
                instance ?: BleManager(context.applicationContext).also { instance = it }
            }
        }
    }

    fun startGattServer() {
        mainHandler.removeCallbacks(connectionRecoveryRunnable)
        mainHandler.post(connectionRecoveryRunnable)
        if (connectedDevice == null && connectionUnavailableSinceMillis == 0L) {
            connectionUnavailableSinceMillis = System.currentTimeMillis()
        }
        if (adapter == null || !adapter.isEnabled) {
            advertisingStatus = "실패: 블루투스 비활성화"
            logDiagnostic("갤럭시 Bluetooth 어댑터가 없거나 꺼져 있습니다")
            recordFailureLog("Bluetooth 어댑터가 없거나 비활성 상태")
            return
        }
        setupGattServer()
        if (gattServiceReady) startAdvertising()
    }

    fun ensureReady() {
        if (adapter == null || !adapter.isEnabled) return
        if (connectedDevice != null || isAdvertising || advertisingStartPending) return
        restartAdvertising()
    }

    fun restartAdvertising() {
        if (adapter == null || !adapter.isEnabled) {
            advertisingStatus = "실패: 블루투스 비활성화"
            logDiagnostic("재광고 불가: 갤럭시 Bluetooth 어댑터가 없거나 꺼져 있습니다")
            return
        }
        if (gattServer == null) {
            logDiagnostic("GATT 서버가 없어 서버와 서비스를 다시 준비합니다")
            setupGattServer()
            return
        }
        if (!gattServiceReady) {
            logDiagnostic("GATT 서비스 등록 대기 중이라 광고를 시작하지 않았습니다")
            return
        }
        if (isAdvertising || advertisingStartPending) {
            logDiagnostic("기존 BLE 광고가 실행 중이거나 시작 중이어서 재시작을 생략합니다")
            return
        }
        startAdvertising()
    }

    fun disconnect() {
        try {
            mainHandler.removeCallbacks(connectionRecoveryRunnable)
            advertisingRecoveryWorkItem?.let(mainHandler::removeCallbacks)
            advertisingRecoveryWorkItem = null
            advertisingStartTimeoutWorkItem?.let(mainHandler::removeCallbacks)
            advertisingStartTimeoutWorkItem = null
            advertisingRecoveryAttempt = 0
            stopHeartbeat()
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
            gattServer?.close()
            gattServer = null
            connectedDevice = null
            connectionUnavailableSinceMillis = 0L
            gattConnectedSinceMillis = 0L
            watchConnectedSinceMillis = null
            outgoingFrames.clear()
            notificationInFlight = false
            isAdvertising = false
            advertisingStartPending = false
            gattServiceReady = false
            advertisingStatus = "중지됨"
            watchNotificationsEnabled = false
            Log.d(TAG, "BLE 서비스 정지")
        } catch (e: Exception) {
            Log.e(TAG, "BLE 정지 오류: ${e.message}")
        }
    }

    private fun checkConnectionHealth() {
        if (adapter?.isEnabled != true) return
        val now = System.currentTimeMillis()
        val device = connectedDevice
        if (device == null) {
            if (connectionUnavailableSinceMillis == 0L) {
                connectionUnavailableSinceMillis = now
            }
            if (now - connectionUnavailableSinceMillis >= FULL_CONNECTION_RECOVERY_AFTER_MS) {
                resetGattConnection("워치 미연결 상태가 60초 지속됨")
            }
            return
        }

        val unhealthySince = when {
            !watchNotificationsEnabled -> gattConnectedSinceMillis
            isWatchResponsive -> {
                connectionUnavailableSinceMillis = 0L
                return
            }
            else -> lastWatchPongAt
        }
        if (unhealthySince > 0L &&
            now - unhealthySince >= FULL_CONNECTION_RECOVERY_AFTER_MS
        ) {
            resetGattConnection("워치 응답/구독 이상이 60초 지속됨")
        }
    }

    private fun resetGattConnection(reason: String) {
        if (adapter?.isEnabled != true) return
        logDiagnostic("$reason → GATT 연결 및 서버를 초기화합니다")
        recordFailureLog("$reason; GATT 서버 전체 재초기화")

        stopHeartbeat()
        advertisingRecoveryWorkItem?.let(mainHandler::removeCallbacks)
        advertisingRecoveryWorkItem = null
        advertisingStartTimeoutWorkItem?.let(mainHandler::removeCallbacks)
        advertisingStartTimeoutWorkItem = null
        adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        val oldDevice = connectedDevice
        val oldServer = gattServer
        if (oldDevice != null && oldServer != null) {
            oldServer.cancelConnection(oldDevice)
        }
        oldServer?.close()

        connectedDevice = null
        gattServer = null
        notifyCharacteristic = null
        connectionUnavailableSinceMillis = System.currentTimeMillis()
        gattConnectedSinceMillis = 0L
        watchConnectedSinceMillis = null
        watchNotificationsEnabled = false
        watchHeartbeatResponded = false
        heartbeatDelayed = false
        pendingHeartbeatTokens.clear()
        outgoingFrames.clear()
        notificationInFlight = false
        notificationRetryCount = 0
        negotiatedMtu = 23
        isAdvertising = false
        advertisingStartPending = false
        gattServiceReady = false
        advertisingStatus = "GATT 재초기화 중"
        advertisingRecoveryAttempt = 0
        incomingFailureLogs.clear()
        completedFailureLogTransfers.clear()

        setupGattServer()
    }

    private fun setupGattServer() {
        if (gattServer != null) return
        gattServiceReady = false
        val server = bluetoothManager.openGattServer(appContext, gattServerCallback)
        if (server == null) {
            logDiagnostic("갤럭시 GATT 서버를 열지 못했습니다")
            recordFailureLog("GATT 서버 열기 실패")
            scheduleAdvertisingRecovery("GATT 서버 열기 실패")
            return
        }
        gattServer = server
        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        notifyCharacteristic = BluetoothGattCharacteristic(
            charUuid,
            BluetoothGattCharacteristic.PROPERTY_READ or
                    BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                    BluetoothGattCharacteristic.PROPERTY_INDICATE,
            BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        val cccdDescriptor = BluetoothGattDescriptor(
            cccdUuid,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        notifyCharacteristic?.addDescriptor(cccdDescriptor)

        service.addCharacteristic(notifyCharacteristic)
        val accepted = server.addService(service)
        if (accepted) {
            logDiagnostic("GATT 서비스 등록 요청 완료; Android 등록 콜백 대기")
        } else {
            server.close()
            gattServer = null
            logDiagnostic("갤럭시가 GATT 서비스 등록 요청을 거부했습니다")
            recordFailureLog("GATT 서비스 등록 요청 거부")
            scheduleAdvertisingRecovery("GATT 서비스 등록 요청 거부")
        }
    }

    private fun startAdvertising() {
        if (!gattServiceReady) {
            logDiagnostic("GATT 서비스 등록 전이라 BLE 광고를 시작하지 않았습니다")
            return
        }
        if (isAdvertising || advertisingStartPending) {
            return
        }
        val advertiser = adapter?.bluetoothLeAdvertiser
        if (advertiser == null) {
            isAdvertising = false
            advertisingStatus = "실패: BLE 광고기 사용 불가"
            logDiagnostic("갤럭시 BLE 광고기를 사용할 수 없습니다")
            recordFailureLog("BLE 광고기를 사용할 수 없습니다")
            scheduleAdvertisingRecovery("BLE 광고기 사용 불가")
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(serviceUuid))
            .build()

        advertisingStartPending = true
        advertisingStatus = "시작 요청 중"
        advertisingStartTimeoutWorkItem?.let(mainHandler::removeCallbacks)
        val startTimeout = Runnable {
            if (!advertisingStartPending) return@Runnable
            advertisingStartPending = false
            isAdvertising = false
            advertisingStatus = "실패: 광고 콜백 시간 초과"
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
            logDiagnostic("BLE 광고 시작 요청 후 10초간 결과 콜백이 없어 복구합니다")
            recordFailureLog("BLE 광고 시작 콜백 시간 초과")
            scheduleAdvertisingRecovery("광고 시작 콜백 시간 초과")
        }
        advertisingStartTimeoutWorkItem = startTimeout
        mainHandler.postDelayed(startTimeout, 10_000L)
        try {
            advertiser.startAdvertising(settings, data, advertiseCallback)
            logDiagnostic("BLE 광고 시작 요청; 실제 성공/실패 콜백 대기")
        } catch (e: SecurityException) {
            advertisingStartTimeoutWorkItem?.let(mainHandler::removeCallbacks)
            advertisingStartTimeoutWorkItem = null
            advertisingStartPending = false
            isAdvertising = false
            advertisingStatus = "실패: 광고 권한 거부"
            logDiagnostic("BLE 광고 권한 오류: ${e.message}")
            recordFailureLog("BLE 광고 권한 오류: ${e.message}")
            scheduleAdvertisingRecovery("광고 권한 오류")
        } catch (e: IllegalStateException) {
            advertisingStartTimeoutWorkItem?.let(mainHandler::removeCallbacks)
            advertisingStartTimeoutWorkItem = null
            advertisingStartPending = false
            isAdvertising = false
            advertisingStatus = "실패: Bluetooth 상태 오류"
            logDiagnostic("BLE 광고 시작 중 Bluetooth 상태 오류: ${e.message}")
            recordFailureLog("BLE 광고 시작 Bluetooth 오류: ${e.message}")
            scheduleAdvertisingRecovery("Bluetooth 상태 오류")
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            advertisingStartTimeoutWorkItem?.let(mainHandler::removeCallbacks)
            advertisingStartTimeoutWorkItem = null
            advertisingStartPending = false
            if (connectedDevice != null) {
                adapter?.bluetoothLeAdvertiser?.stopAdvertising(this)
                isAdvertising = false
                advertisingStatus = "연결됨"
                return
            }
            isAdvertising = true
            advertisingStatus = "성공"
            advertisingRecoveryAttempt = 0
            advertisingRecoveryWorkItem?.let(mainHandler::removeCallbacks)
            advertisingRecoveryWorkItem = null
            logDiagnostic("갤럭시 BLE 광고 시작 성공; 워치 연결 대기 중")
        }
        override fun onStartFailure(errorCode: Int) {
            advertisingStartTimeoutWorkItem?.let(mainHandler::removeCallbacks)
            advertisingStartTimeoutWorkItem = null
            advertisingStartPending = false
            if (errorCode == AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED) {
                if (connectedDevice != null) {
                    adapter?.bluetoothLeAdvertiser?.stopAdvertising(this)
                    isAdvertising = false
                    advertisingStatus = "워치 연결됨"
                    return
                }
                isAdvertising = true
                advertisingStatus = "성공: 기존 광고 유지"
                advertisingRecoveryAttempt = 0
                advertisingRecoveryWorkItem?.let(mainHandler::removeCallbacks)
                advertisingRecoveryWorkItem = null
                logDiagnostic("요청 광고는 중복이지만 기존 BLE 광고가 실행 중입니다")
                return
            }
            isAdvertising = false
            advertisingStatus = "실패: ${advertiseErrorName(errorCode)} ($errorCode)"
            logDiagnostic("갤럭시 BLE 광고 시작 실패: ${advertiseErrorName(errorCode)} ($errorCode)")
            recordFailureLog("BLE 광고 시작 실패: ${advertiseErrorName(errorCode)} ($errorCode)")
            scheduleAdvertisingRecovery("광고 시작 실패 ($errorCode)")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            gattServiceReady = status == BluetoothGatt.GATT_SUCCESS &&
                service?.uuid == serviceUuid
            if (gattServiceReady) {
                logDiagnostic("갤럭시 GATT 서비스 등록 성공")
                startAdvertising()
            } else {
                advertisingStatus = "대기: GATT 서비스 등록 실패 ($status)"
                logDiagnostic("갤럭시 GATT 서비스 등록 실패: ${gattStatusName(status)} ($status)")
                recordFailureLog("GATT 서비스 등록 실패: ${gattStatusName(status)} ($status)")
                gattServer?.close()
                gattServer = null
                notifyCharacteristic = null
                scheduleAdvertisingRecovery("GATT 서비스 등록 실패 ($status)")
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
            val stateName = when (newState) {
                BluetoothProfile.STATE_CONNECTED -> "연결됨"
                BluetoothProfile.STATE_CONNECTING -> "연결 중"
                BluetoothProfile.STATE_DISCONNECTING -> "연결 해제 중"
                BluetoothProfile.STATE_DISCONNECTED -> "연결 안 됨"
                else -> "알 수 없는 상태($newState)"
            }
            val event = "$stateName, GATT=${gattStatusName(status)}($status)"
            lastWatchConnectionEvent = event

            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                connectedDevice = device
                gattConnectedSinceMillis = System.currentTimeMillis()
                connectionUnavailableSinceMillis = 0L
                watchConnectedSinceMillis = null
                advertisingRecoveryWorkItem?.let(mainHandler::removeCallbacks)
                advertisingRecoveryWorkItem = null
                advertisingStartTimeoutWorkItem?.let(mainHandler::removeCallbacks)
                advertisingStartTimeoutWorkItem = null
                advertisingRecoveryAttempt = 0
                adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
                isAdvertising = false
                advertisingStartPending = false
                advertisingStatus = "워치 연결됨"
                negotiatedMtu = 23
                watchNotificationsEnabled = false
                watchHeartbeatResponded = false
                heartbeatDelayed = false
                lastWatchPongAt = System.currentTimeMillis()
                pendingHeartbeatTokens.clear()
                heartbeatHandshakeAckSent = false
                logDiagnostic("워치 GATT 연결 성공; 알림 구독 및 PING 확인 대기")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                logDiagnostic("워치 GATT 연결 해제 이벤트: ${gattStatusName(status)} ($status)")
                recordFailureLog("워치 GATT 연결 해제: ${gattStatusName(status)} ($status)")
                stopHeartbeat()
                connectedDevice = null
                gattConnectedSinceMillis = 0L
                connectionUnavailableSinceMillis = System.currentTimeMillis()
                watchConnectedSinceMillis = null
                watchNotificationsEnabled = false
                watchHeartbeatResponded = false
                heartbeatDelayed = false
                outgoingFrames.clear()
                notificationInFlight = false
                negotiatedMtu = 23
                scheduleAdvertisingRecovery("워치 GATT 연결 해제")
            } else if (status != BluetoothGatt.GATT_SUCCESS) {
                logDiagnostic("워치 GATT 연결 단계 오류: 상태=$stateName, ${gattStatusName(status)} ($status)")
                recordFailureLog("워치 GATT 연결 단계 오류: 상태=$stateName, ${gattStatusName(status)} ($status)")
            }

        }

        override fun onMtuChanged(device: BluetoothDevice?, mtu: Int) {
            if (device == connectedDevice && mtu >= 23) {
                negotiatedMtu = mtu
                Log.d(TAG, "BLE MTU 변경: $mtu")
            }
        }

        override fun onNotificationSent(device: BluetoothDevice?, status: Int) {
            mainHandler.post {
                if (device != connectedDevice) return@post
                notificationInFlight = false
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    if (outgoingFrames.isNotEmpty()) outgoingFrames.removeFirst()
                    notificationRetryCount = 0
                    sendNextFrame()
                } else {
                    notificationRetryCount++
                    Log.e(TAG, "BLE 프레임 전송 실패 status=$status ($notificationRetryCount/$MAX_FRAME_RETRIES)")
                    if (notificationRetryCount > MAX_FRAME_RETRIES) {
                        outgoingFrames.clear()
                        notificationRetryCount = 0
                        saveLog("⚠️ BLE 전송 실패; 다음 재전송 요청을 기다립니다")
                        recordFailureLog("BLE 알림 프레임 전송 실패: ${gattStatusName(status)} ($status)")
                    } else {
                        mainHandler.postDelayed({ sendNextFrame() }, 250L)
                    }
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }

            value ?: return
            if (isWatchFailureLogFrame(value)) {
                handleWatchFailureLogFrame(value)
                return
            }
            val msg = String(value, Charsets.UTF_8).trim()

            // ⚡ 워치 PING 수신 즉시 PING_ACK 1:1 맞응답 (대기시간 0ms)
            if (msg == "PING") {
                logDiagnostic("워치에서 PING 수신; 양방향 GATT 통신 정상")
                sendLatestIdAck()
                return
            }

            if (msg.startsWith("PING:")) {
                val token = msg.substringAfter("PING:").toLongOrNull()
                if (token != null) {
                    mainHandler.post {
                        enqueueRaw("PONG:$token".toByteArray(Charsets.UTF_8))
                        Log.d(TAG, "워치 하트비트 수신; PONG 전송 (id=$token)")
                        if (!heartbeatHandshakeAckSent) {
                            heartbeatHandshakeAckSent = true
                            sendLatestIdAck()
                        }
                    }
                }
            } else if (msg.startsWith("PONG:")) {
                val token = msg.substringAfter("PONG:").toLongOrNull()
                if (token != null) mainHandler.post { handleHeartbeatPong(token) }
            } else if (msg.startsWith("BATTERY:")) {
                val battery = msg.substringAfter("BATTERY:").toIntOrNull() ?: -1
                com.example.watchnotify.WatchNotifyWidget.updateBattery(appContext, battery)
            } else if (msg.startsWith("BAT:")) {
                val battery = msg.substringAfter("BAT:").toIntOrNull() ?: -1
                com.example.watchnotify.WatchNotifyWidget.updateBattery(appContext, battery)
            } else if (msg.startsWith("RESEND:")) {
                val lastId = msg.substringAfter("RESEND:").toLongOrNull() ?: 0L
                if (AppSettings.getMode(appContext) == AppSettings.MODE_BLE) {
                    resendPendingAfter(lastId)
                } else {
                    Log.d(TAG, "API 모드에서 BLE 재전송 요청 무시")
                }
            } else if (msg.startsWith("PING_ACK:")) {
                val acknowledgedId = msg.substringAfter("PING_ACK:").toLongOrNull()
                if (AppSettings.getMode(appContext) == AppSettings.MODE_BLE &&
                    acknowledgedId != null && acknowledgedId > 0) {
                    scope.launch {
                        try {
                            AppDatabase.getInstance(appContext)
                                .notificationDao()
                                .markAckedThrough(acknowledgedId.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
                        } catch (e: Exception) {
                            Log.e(TAG, "알림 확인 상태 저장 실패 id=$acknowledgedId", e)
                        }
                    }
                }
            } else {
                Log.d(TAG, "워치 데이터 수신: $msg")
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            descriptor: BluetoothGattDescriptor?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            val isCccd = descriptor?.uuid ==
                UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
            val notificationsEnabled = value?.contentEquals(
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            ) == true || value?.contentEquals(
                BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            ) == true
            val status = if (isCccd && offset == 0) {
                BluetoothGatt.GATT_SUCCESS
            } else {
                BluetoothGatt.GATT_FAILURE
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, status, offset, value)
            }
            if (status == BluetoothGatt.GATT_SUCCESS) {
                watchNotificationsEnabled = notificationsEnabled
                logDiagnostic(
                    if (notificationsEnabled) "워치 알림 구독(CCCD) 성공; 알림 전송 준비 완료"
                    else "워치가 알림 구독을 해제했습니다"
                )
                if (notificationsEnabled) {
                    mainHandler.post {
                        startHeartbeat()
                    }
                } else {
                    mainHandler.post {
                        stopHeartbeat()
                        watchHeartbeatResponded = false
                        heartbeatDelayed = false
                    }
                }
            } else {
                logDiagnostic("워치 CCCD 구독 설정 실패: 잘못된 디스크립터 또는 offset=$offset")
                recordFailureLog("워치 CCCD 구독 설정 실패: offset=$offset")
            }
        }
    }

    private fun startHeartbeat() {
        stopHeartbeat()
        watchHeartbeatResponded = false
        heartbeatDelayed = false
        lastWatchPongAt = System.currentTimeMillis()
        pendingHeartbeatTokens.clear()
        sendHeartbeatPing()

        val heartbeat = object : Runnable {
            override fun run() {
                heartbeatWorkItem = null
                val device = connectedDevice
                if (device == null || !watchNotificationsEnabled) return

                if (pendingHeartbeatTokens.isNotEmpty()) {
                    heartbeatDelayed = true
                    logDiagnostic("워치 하트비트 응답 누락; 즉시 재확인 핑을 전송합니다")
                    sendHeartbeatPing()
                    scheduleHeartbeatRetryTimeout(device)
                } else {
                    sendHeartbeatPing()
                }
                heartbeatWorkItem = this
                mainHandler.postDelayed(this, HEARTBEAT_INTERVAL_MS)
            }
        }
        heartbeatWorkItem = heartbeat
        mainHandler.postDelayed(heartbeat, HEARTBEAT_INTERVAL_MS)
    }

    private fun stopHeartbeat() {
        heartbeatWorkItem?.let(mainHandler::removeCallbacks)
        heartbeatWorkItem = null
        heartbeatRetryTimeoutWorkItem?.let(mainHandler::removeCallbacks)
        heartbeatRetryTimeoutWorkItem = null
        pendingHeartbeatTokens.clear()
        heartbeatDelayed = false
    }

    private fun scheduleHeartbeatRetryTimeout(device: BluetoothDevice) {
        heartbeatRetryTimeoutWorkItem?.let(mainHandler::removeCallbacks)
        val timeout = Runnable {
            heartbeatRetryTimeoutWorkItem = null
            if (connectedDevice != device || pendingHeartbeatTokens.isEmpty()) return@Runnable
            logDiagnostic(
                "워치 재확인 핑에도 응답 없음; GATT 링크는 유지하고 실제 연결 해제 이벤트를 기다립니다"
            )
            recordFailureLog("워치 하트비트 재확인 무응답; GATT 연결 해제 이벤트 대기")
            pendingHeartbeatTokens.clear()
        }
        heartbeatRetryTimeoutWorkItem = timeout
        mainHandler.postDelayed(timeout, HEARTBEAT_RETRY_GRACE_MS)
    }

    private fun sendHeartbeatPing() {
        if (connectedDevice == null || !watchNotificationsEnabled) return
        heartbeatSequence = if (heartbeatSequence >= Long.MAX_VALUE) 1L else heartbeatSequence + 1L
        pendingHeartbeatTokens.add(heartbeatSequence)
        enqueueRaw("PING:$heartbeatSequence".toByteArray(Charsets.UTF_8))
        Log.d(TAG, "워치 하트비트 PING 전송 (id=$heartbeatSequence)")
    }

    private fun handleHeartbeatPong(token: Long) {
        if (!pendingHeartbeatTokens.remove(token)) {
            Log.d(TAG, "이전/미요청 하트비트 PONG 무시 (id=$token)")
            return
        }
        pendingHeartbeatTokens.clear()
        heartbeatRetryTimeoutWorkItem?.let(mainHandler::removeCallbacks)
        heartbeatRetryTimeoutWorkItem = null
        heartbeatDelayed = false
        watchHeartbeatResponded = true
        lastWatchPongAt = System.currentTimeMillis()
        if (watchConnectedSinceMillis == null) {
            watchConnectedSinceMillis = lastWatchPongAt
        }
        Log.i(TAG, "워치 하트비트 응답 확인 (id=$token)")
    }

    private fun scheduleAdvertisingRecovery(reason: String) {
        if (connectedDevice != null || adapter?.isEnabled != true) return
        advertisingRecoveryWorkItem?.let(mainHandler::removeCallbacks)
        advertisingRecoveryAttempt++
        val delayMs = minOf(
            1_000L * (1 shl minOf(advertisingRecoveryAttempt - 1, 5)),
            30_000L
        )
        logDiagnostic("$reason → ${delayMs / 1_000}초 후 BLE 재시도 ($advertisingRecoveryAttempt)")
        val recovery = Runnable {
            advertisingRecoveryWorkItem = null
            ensureReady()
        }
        advertisingRecoveryWorkItem = recovery
        mainHandler.postDelayed(recovery, delayMs)
    }

    fun diagnosticSnapshot(): String {
        val bluetoothState = when {
            adapter == null -> "어댑터 없음"
            !adapter.isEnabled -> "꺼짐"
            else -> "켜짐"
        }
        val connection = if (connectedDevice != null) "연결됨" else "연결 안 됨"
        val advertisingReady = isAdvertising || advertisingStatus.startsWith("성공")
        val assessment = when {
            bluetoothState != "켜짐" -> "갤럭시 Bluetooth 상태 확인 필요"
            !gattServiceReady -> "갤럭시 GATT 서버/서비스 준비 실패 확인 필요"
            advertisingStartPending -> "갤럭시 BLE 광고 시작 콜백 대기 중; 아직 실패로 판정할 수 없음"
            !advertisingReady -> "갤럭시 BLE 광고 실패 확인 필요"
            connectedDevice != null && watchNotificationsEnabled ->
                "BLE 연결 및 워치 구독 정상; 알림 전달 경로 점검 가능"
            connectedDevice != null ->
                "갤럭시 GATT 연결은 됨; 워치 구독/초기화 단계 점검 필요"
            lastWatchConnectionEvent != "없음" ->
                "갤럭시 광고는 정상이나 마지막 연결 이벤트 이후 연결 해제됨; 상태 코드 확인 필요"
            else ->
                "갤럭시 GATT/광고는 정상이나 워치 연결 이벤트 없음; 워치 검색 또는 무선 도달 여부 확인 필요"
        }
        val heartbeat = when {
            connectedDevice == null -> "미연결"
            isWatchResponsive -> "응답 정상"
            watchHeartbeatResponded -> "응답 지연"
            else -> "응답 확인 대기"
        }
        return "진단: Bluetooth=$bluetoothState, GATT서비스=${if (gattServiceReady) "준비됨" else "준비 안 됨"}, " +
            "광고=$advertisingStatus${if (advertisingStartPending) " (콜백 대기)" else ""}, 워치=$connection, " +
            "하트비트=$heartbeat, 구독=${if (watchNotificationsEnabled) "완료" else "미확인"}, " +
            "마지막 연결 이벤트=$lastWatchConnectionEvent. " +
            "판정: $assessment"
    }

    fun logDiagnosticSnapshot() {
        logDiagnostic(diagnosticSnapshot())
    }

    fun recordFailureLog(message: String, source: String = "Galaxy") {
        Log.e(TAG, "실패 로그 [$source]: $message")
        scope.launch(Dispatchers.IO) {
            try {
                FailureLogFile.append(
                    appContext,
                    System.currentTimeMillis(),
                    source,
                    message
                )
            } catch (e: Exception) {
                Log.e(TAG, "실패 로그 파일 기록 오류", e)
            }
        }
    }

    private fun isWatchFailureLogFrame(value: ByteArray): Boolean {
        return value.size >= FAILURE_LOG_FRAME_HEADER_SIZE &&
            value[0] == FAILURE_LOG_FRAME_MAGIC[0] &&
            value[1] == FAILURE_LOG_FRAME_MAGIC[1]
    }

    private fun handleWatchFailureLogFrame(value: ByteArray) {
        val transferId = ((value[2].toInt() and 0xFF) shl 8) or (value[3].toInt() and 0xFF)
        val index = value[4].toInt() and 0xFF
        val total = value[5].toInt() and 0xFF
        if (total == 0 || index >= total) {
            recordFailureLog("워치 실패 로그 프레임 형식 오류")
            return
        }
        if (transferId in completedFailureLogTransfers) {
            acknowledgeWatchFailureLog(transferId)
            return
        }
        if (transferId !in incomingFailureLogs &&
            incomingFailureLogs.size >= MAX_INCOMING_FAILURE_LOG_TRANSFERS
        ) {
            val oldestTransferId = incomingFailureLogs.keys.first()
            incomingFailureLogs.remove(oldestTransferId)
            Log.w(TAG, "오래된 워치 실패 로그 조립 상태 제거: id=$oldestTransferId")
        }
        val assembly = incomingFailureLogs.getOrPut(transferId) {
            FailureLogAssembly(total)
        }
        if (assembly.total != total) {
            incomingFailureLogs.remove(transferId)
            recordFailureLog("워치 실패 로그 청크 수가 일치하지 않습니다 (id=$transferId)")
            return
        }
        assembly.chunks[index] = value.copyOfRange(FAILURE_LOG_FRAME_HEADER_SIZE, value.size)
        if (assembly.chunks.sumOf { it?.size ?: 0 } > MAX_FAILURE_LOG_TRANSFER_BYTES) {
            incomingFailureLogs.remove(transferId)
            recordFailureLog("워치 실패 로그가 최대 크기를 초과했습니다 (id=$transferId)")
            return
        }
        if (assembly.chunks.any { it == null }) return

        incomingFailureLogs.remove(transferId)
        val payload = ByteArrayOutputStream()
        assembly.chunks.filterNotNull().forEach { payload.write(it) }
        val json = payload.toByteArray().toString(Charsets.UTF_8)
        try {
            val record = JSONObject(json)
            val timestamp = record.getLong("timestamp")
            val recordId = record.getString("id")
            val source = record.getString("source")
            val message = record.getString("message")
            scope.launch(Dispatchers.IO) {
                try {
                    FailureLogFile.append(appContext, timestamp, source, message, recordId)
                    mainHandler.post {
                        completedFailureLogTransfers.add(transferId)
                        while (completedFailureLogTransfers.size > MAX_COMPLETED_FAILURE_LOG_TRANSFERS) {
                            completedFailureLogTransfers.remove(completedFailureLogTransfers.first())
                        }
                        acknowledgeWatchFailureLog(transferId)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "워치 실패 로그 저장 오류", e)
                }
            }
        } catch (e: Exception) {
            recordFailureLog("워치 실패 로그 JSON 파싱 실패: ${e.message}")
        }
    }

    private fun acknowledgeWatchFailureLog(transferId: Int) {
        val ack = byteArrayOf(
            FAILURE_LOG_ACK_MAGIC[0],
            FAILURE_LOG_ACK_MAGIC[1],
            (transferId shr 8).toByte(),
            transferId.toByte()
        )
        enqueueRaw(ack)
    }

    private fun logDiagnostic(message: String) {
        Log.i(TAG, message)
        saveLog("🔎 $message")
    }

    private fun advertiseErrorName(errorCode: Int): String = when (errorCode) {
        AdvertiseCallback.ADVERTISE_FAILED_DATA_TOO_LARGE -> "광고 데이터가 너무 큼"
        AdvertiseCallback.ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "광고기 사용 한도 초과"
        AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED -> "이미 광고 중"
        AdvertiseCallback.ADVERTISE_FAILED_INTERNAL_ERROR -> "Bluetooth 내부 오류"
        AdvertiseCallback.ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "광고 기능 미지원"
        else -> "알 수 없는 광고 오류"
    }

    private fun gattStatusName(status: Int): String = when (status) {
        BluetoothGatt.GATT_SUCCESS -> "성공"
        BluetoothGatt.GATT_FAILURE -> "일반 GATT 실패"
        BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION -> "인증 필요"
        BluetoothGatt.GATT_INSUFFICIENT_ENCRYPTION -> "암호화 필요"
        BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH -> "잘못된 데이터 길이"
        BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED -> "요청 미지원"
        else -> "기타 GATT 상태"
    }

    private fun sendLatestIdAck() {
        scope.launch {
            val latestId = try {
                AppDatabase.getInstance(appContext).notificationDao().getLatestId() ?: 0
            } catch (e: Exception) {
                Log.e(TAG, "최신 알림 ID 조회 실패", e)
                return@launch
            }
            mainHandler.post { enqueueRaw("PING_ACK:$latestId".toByteArray(Charsets.UTF_8)) }
        }
    }

    fun sendNotification(id: Long, pkg: String, title: String, body: String) {
        if (connectedDevice == null) {
            Log.w(TAG, "워치 미연결 상태 - 알림 전송 보류")
            saveLog("⚠️ 워치 미연결 상태 - 알림 전송 보류 ($title)")
            return
        }

        val json = JSONObject().apply {
            put("id", id)
            put("pkg", pkg)
            put("title", title)
            put("body", body)
        }

        val data = json.toString().toByteArray(Charsets.UTF_8)
        mainHandler.post {
            enqueuePayload(id, data)
            Log.d(TAG, "알림 전송 대기 id=$id $title")
        }
    }

    fun sendSignal(signal: String) {
        mainHandler.post { enqueueRaw(signal.toByteArray(Charsets.UTF_8)) }
    }

    private fun resendPendingAfter(lastId: Long) {
        val boundedId = lastId.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
        scope.launch {
            try {
                val pending = AppDatabase.getInstance(appContext)
                    .notificationDao()
                    .getPendingAfter(boundedId)
                mainHandler.post {
                    pending.forEach { notification ->
                        val separator = notification.event.indexOf(" | ")
                        if (separator <= 0) {
                            saveLog("⚠️ 저장된 알림 형식 오류 id=${notification.id}")
                        } else {
                            sendNotification(
                                notification.id.toLong(),
                                notification.event.substring(0, separator),
                                notification.event.substring(separator + 3),
                                notification.msg
                            )
                        }
                    }
                    Log.d(TAG, "재전송 요청 처리: ${pending.size}건 (lastId=$lastId)")
                }
            } catch (e: Exception) {
                Log.e(TAG, "미확인 알림 조회 실패", e)
            }
        }
    }

    private fun enqueuePayload(id: Long, data: ByteArray) {
        if (connectedDevice == null) return
        val payloadLimit = (negotiatedMtu - 3 - FRAME_HEADER_SIZE).coerceAtLeast(1)
        val total = (data.size + payloadLimit - 1) / payloadLimit
        if (total > 0xFFFF) {
            Log.e(TAG, "BLE 페이로드가 최대 조각 수를 초과했습니다: ${data.size} bytes")
            saveLog("⚠️ 알림 크기 초과로 BLE 전송 실패 id=$id")
            return
        }

        val transferId = nextTransferId.toInt()
        nextTransferId = if (nextTransferId >= 0xFFFF_FFFFL) 1L else nextTransferId + 1L
        var offset = 0
        repeat(total) { index ->
            val length = minOf(payloadLimit, data.size - offset)
            val frame = ByteBuffer.allocate(FRAME_HEADER_SIZE + length)
                .order(ByteOrder.BIG_ENDIAN)
                .put(FRAME_MAGIC)
                .putInt(transferId)
                .putShort(index.toShort())
                .putShort(total.toShort())
                .put(data, offset, length)
                .array()
            outgoingFrames.addLast(frame)
            offset += length
        }
        sendNextFrame()
    }

    private fun enqueueRaw(data: ByteArray) {
        if (connectedDevice == null) return
        if (data.size > negotiatedMtu - 3) {
            Log.e(TAG, "BLE 제어 패킷이 MTU를 초과했습니다: ${data.size} bytes")
            return
        }
        outgoingFrames.addLast(data)
        sendNextFrame()
    }

    @Suppress("DEPRECATION")
    private fun sendNextFrame() {
        if (notificationInFlight || outgoingFrames.isEmpty()) return
        val device = connectedDevice ?: return
        val characteristic = notifyCharacteristic ?: return
        val server = gattServer ?: return
        val data = outgoingFrames.first()
        notificationInFlight = true
        val accepted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, characteristic, false, data) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            characteristic.value = data
            server.notifyCharacteristicChanged(device, characteristic, false)
        }
        if (!accepted) {
            notificationInFlight = false
            notificationRetryCount++
            Log.e(TAG, "BLE 프레임 제출 실패 ($notificationRetryCount/$MAX_FRAME_RETRIES)")
            if (notificationRetryCount > MAX_FRAME_RETRIES) {
                outgoingFrames.clear()
                notificationRetryCount = 0
                saveLog("⚠️ BLE 전송 실패; 다음 재전송 요청을 기다립니다")
            } else {
                mainHandler.postDelayed({ sendNextFrame() }, 250L)
            }
        }
    }

    fun saveLog(msg: String) {
        scope.launch {
            try {
                val db = AppDatabase.getInstance(appContext)
                db.connectionLogDao().insert(ConnectionLogEntity(message = msg))
                db.connectionLogDao().trimOld()
            } catch (e: Exception) {
                Log.e(TAG, "로그 저장 오류: ${e.message}")
            }
        }
    }
}