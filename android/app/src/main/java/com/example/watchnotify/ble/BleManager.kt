package com.example.watchnotify.ble

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import com.example.watchnotify.db.AppDatabase
import com.example.watchnotify.db.ConnectionLogEntity
import kotlinx.coroutines.*
import org.json.JSONObject
import java.util.*

@SuppressLint("MissingPermission")
class BleManager private constructor(context: Context) {

    enum class ConnectionState { CONNECTED, OFFLINE }

    private val appContext = context.applicationContext
    private val bluetoothManager = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val adapter = bluetoothManager.adapter
    private var gattServer: BluetoothGattServer? = null
    private var connectedDevice: BluetoothDevice? = null
    private var notifyCharacteristic: BluetoothGattCharacteristic? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var lastSentId: Long = 0

    var isAdvertising: Boolean = false
        private set

    var watchBatteryLevel: Int = -1

    val connectionState: ConnectionState
        get() = if (connectedDevice != null) ConnectionState.CONNECTED else ConnectionState.OFFLINE

    private val serviceUuid = UUID.fromString("0000180D-0000-1000-8000-00805f9b34fb")
    private val charUuid = UUID.fromString("00002A37-0000-1000-8000-00805f9b34fb")

    companion object {
        private const val TAG = "BleManager"
        @Volatile private var instance: BleManager? = null

        fun getInstance(context: Context): BleManager {
            return instance ?: synchronized(this) {
                instance ?: BleManager(context.applicationContext).also { instance = it }
            }
        }
    }

    fun startGattServer() {
        if (adapter == null || !adapter.isEnabled) {
            Log.e(TAG, "블루투스 비활성화 상태")
            return
        }
        setupGattServer()
        startAdvertising()
    }

    fun restartAdvertising() {
        try {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        } catch (e: Exception) { }
        startAdvertising()
    }

    fun disconnect() {
        try {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
            gattServer?.close()
            gattServer = null
            connectedDevice = null
            isAdvertising = false
            Log.d(TAG, "BLE 서비스 정지")
        } catch (e: Exception) {
            Log.e(TAG, "BLE 정지 오류: ${e.message}")
        }
    }

    private fun setupGattServer() {
        if (gattServer != null) return
        gattServer = bluetoothManager.openGattServer(appContext, gattServerCallback)
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
        gattServer?.addService(service)
        Log.d(TAG, "GATT 서버 및 서비스 생성 완료")
    }

    private fun startAdvertising() {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
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

        advertiser.startAdvertising(settings, data, advertiseCallback)
        isAdvertising = true
        Log.d(TAG, "BLE 어드버타이징 시작")
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            isAdvertising = true
            Log.d(TAG, "어드버타이징 성공")
        }
        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            Log.e(TAG, "어드버타이징 실패 code=$errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedDevice = device
                Log.d(TAG, "워치 연결됨: ${device?.address}")
                saveLog("🟢 워치 연결됨")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.d(TAG, "워치 연결 끊김")
                saveLog("🔴 워치 연결 끊김")
                connectedDevice = null
                startAdvertising()
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
            val msg = String(value, Charsets.UTF_8).trim()

            // ⚡ 워치 PING 수신 즉시 PING_ACK 1:1 맞응답 (대기시간 0ms)
            if (msg == "PING") {
                sendDirectAck("PING_ACK:$lastSentId")
                return
            }

            if (msg.startsWith("BATTERY:")) {
                watchBatteryLevel = msg.substringAfter("BATTERY:").toIntOrNull() ?: -1
                com.example.watchnotify.WatchNotifyWidget.updateAllWidgets(appContext)
            } else if (msg.startsWith("BAT:")) {
                watchBatteryLevel = msg.substringAfter("BAT:").toIntOrNull() ?: -1
                com.example.watchnotify.WatchNotifyWidget.updateAllWidgets(appContext)
            } else if (msg.startsWith("RESEND:")) {
                val lastId = msg.substringAfter("RESEND:").toLongOrNull() ?: 0L
                Log.d(TAG, "워치 RESEND 요청 lastId=$lastId")
            } else if (msg.startsWith("PING_ACK:")) {
                Log.d(TAG, "워치 PING_ACK 수신 확인")
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
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
            Log.d(TAG, "CCCD 디스크립터 Write 수신 (Notify 구독 성공)")
        }
    }

    @Suppress("DEPRECATION")
    private fun sendDirectAck(ackText: String) {
        val device = connectedDevice ?: return
        val characteristic = notifyCharacteristic ?: return
        val data = ackText.toByteArray(Charsets.UTF_8)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gattServer?.notifyCharacteristicChanged(device, characteristic, false, data)
        } else {
            characteristic.value = data
            gattServer?.notifyCharacteristicChanged(device, characteristic, false)
        }
    }

    @Suppress("DEPRECATION")
    fun sendNotification(id: Long, pkg: String, title: String, body: String) {
        val device = connectedDevice ?: run {
            Log.w(TAG, "워치 미연결 상태 - 알림 전송 보류")
            saveLog("⚠️ 워치 미연결 상태 - 알림 전송 보류 ($title)")
            return
        }
        val characteristic = notifyCharacteristic ?: return

        lastSentId = id
        val json = JSONObject().apply {
            put("id", id)
            put("pkg", pkg)
            put("title", title)
            put("body", body)
        }

        val data = json.toString().toByteArray(Charsets.UTF_8)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gattServer?.notifyCharacteristicChanged(device, characteristic, false, data)
        } else {
            characteristic.value = data
            gattServer?.notifyCharacteristicChanged(device, characteristic, false)
        }
        Log.d(TAG, "알림 전송 완료 id=$id $title")
        saveLog("📤 BLE 알림 전송 완료: $title")
    }

    @Suppress("DEPRECATION")
    fun sendSignal(signal: String) {
        val device = connectedDevice ?: return
        val characteristic = notifyCharacteristic ?: return

        val data = signal.toByteArray(Charsets.UTF_8)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gattServer?.notifyCharacteristicChanged(device, characteristic, false, data)
        } else {
            characteristic.value = data
            gattServer?.notifyCharacteristicChanged(device, characteristic, false)
        }
        Log.d(TAG, "신호 전송 완료: $signal")
    }

    fun saveLog(msg: String) {
        scope.launch {
            try {
                val db = AppDatabase.getInstance(appContext)
                db.connectionLogDao().insert(ConnectionLogEntity(System.currentTimeMillis(), msg))
            } catch (e: Exception) {
                Log.e(TAG, "로그 저장 오류: ${e.message}")
            }
        }
    }
}