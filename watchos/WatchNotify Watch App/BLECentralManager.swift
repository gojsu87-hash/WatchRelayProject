// BLECentralManager.swift
// WatchNotify 안드로이드 BLE 프로토콜 연동 규격 최적화 코드

import Foundation
import CoreBluetooth
import UserNotifications
import WatchKit
import SwiftData
import WidgetKit

// MARK: - Models

struct NotificationPayload: Codable {
    let id: Int64
    let pkg: String
    let title: String
    let body: String

    enum CodingKeys: String, CodingKey {
        case id, pkg, title, body
    }

    init(id: Int64, pkg: String, title: String, body: String) {
        self.id = id
        self.pkg = pkg
        self.title = title
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        self.pkg = try container.decodeIfPresent(String.self, forKey: .pkg) ?? ""
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }
}

nonisolated enum ConnectionState: Sendable {
    case offline
    case connected
    case operational
}

extension ConnectionState: Equatable {
    nonisolated static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.offline, .offline), (.connected, .connected), (.operational, .operational):
            return true
        default:
            return false
        }
    }
}

// MARK: - BLECentralManager

@Observable
class BLECentralManager: NSObject {

    // MARK: - 상수
    private enum Constants {
        static let reconnectTimerSec: TimeInterval = 45    // 주기적 재스캔 간격 (오프라인일 때)
        static let scanTimeoutSec: TimeInterval = 15       // 스캔 타임아웃
        static let connectionTimeoutSec: TimeInterval = 20
        static let maxServiceDiscoveryRetries = 3
        static let pingIntervalSec: TimeInterval = 15      // 하트비트 PING 간격 (연결 중일 때)
        static let pingRetryGraceSec: TimeInterval = 3
        static let activationCallbackDebounceSec: TimeInterval = 1
        static let maxReconnectDelaySec: TimeInterval = 60
        static let stableConnectionSec: TimeInterval = 60
    }

    // MARK: - Public State
    var connectionState: ConnectionState = .offline
    var lastMessage = "대기 중..."
    var statusLog: [String] = []
    var lastReceivedTime: Date? = nil
    var lastPingTime: Date? = nil
    var lastHeartbeatResponseAt: Date? = nil
    var disconnectReason: String = "연결 대기 중"
    var lastDisconnectReason: String = ""
    var isScanning = false
    var connectionProgress = "연결 대기 중"
    var heartbeatDelayed = false
    var connectionEstablishedAt: Date?
    var retryStartedAt: Date?
    var nextReconnectAt: Date?

    var isConnected: Bool {
        connectionState == .connected || connectionState == .operational
    }

    var isFullyOperational: Bool {
        connectionState == .operational
    }

    // MARK: - Private
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?

    private var reconnectTimer: Timer?
    private var scanTimeoutTimer: Timer?
    private var pingTimer: Timer?
    private var heartbeatRetryWorkItem: DispatchWorkItem?
    private var heartbeatSequence: UInt64 = 0
    private var pendingHeartbeatTokens = Set<UInt64>()
    private var lastAppActiveHandledAt: Date?
    private var retryWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var serviceDiscoveryRetryWorkItem: DispatchWorkItem?
    private var connectionStabilityWorkItem: DispatchWorkItem?
    private var serviceDiscoveryRetryCount = 0
    private var timedOutPeripheralID: UUID?
    private var requestedDisconnectReasons: [UUID: String] = [:]
    private var failureLogFrames: [Data] = []
    private var currentFailureLogRecordId: String?
    private var currentFailureLogTransferId: UInt16?
    private var failureLogWriteInFlight = false
    private var controlWriteInFlight = false
    private var failureLogAckTimeoutWorkItem: DispatchWorkItem?
    private var failureLogRetryCount = 0
    private var failureLogTransferSequence: UInt16 = 0
    private var pendingControlWrites: [String] = []
    private var resetScanWorkItem: DispatchWorkItem?
    private var isResettingConnection = false
    private var ignoredResetPeripheralID: UUID?
    private var chunkBuffers: [String: [Int: [UInt8]]] = [:]
    private var chunkTotals: [String: Int] = [:]
    private var lastCallPayload: NotificationPayload?
    private var lastReceivedId: Int64 = 0
    private var retryCount: Int = 0
    private var isConnecting = false
    private var isAppInBackground = false
    private var isManuallyDisconnecting = false

    private let knownPeripheralIdKey = "knownAndroidPeripheralId"
    private var incomingCallAlertActive = false
    private let incomingCallNotificationCount = 20
    private let incomingCallRepeatInterval: TimeInterval = 3

    // MARK: - SwiftData
    var modelContext: ModelContext?

    // MARK: - CBUUID 상수 (프로토콜 명세서 2번)
    let serviceUUID = CBUUID(string: "0000180D-0000-1000-8000-00805f9b34fb")
    let characteristicUUID = CBUUID(string: "00002A37-0000-1000-8000-00805f9b34fb")
    private let callNotificationId = "incoming_call"
    private var activeCallRecordID: Int64?

    // MARK: - Init
    override init() {
        super.init()

        // Android Room 알림 ID는 Int 범위의 자동 증가값이다.
        let rawLastId = UserDefaults.standard.object(forKey: "lastReceivedId")
        var savedId: Int64 = 0
        if let num = rawLastId as? NSNumber {
            savedId = num.int64Value
        } else if let intVal = rawLastId as? Int64 {
            savedId = intVal
        }
        if savedId > 0 && savedId <= Int64(Int32.max) {
            lastReceivedId = savedId
        } else {
            lastReceivedId = 0
            UserDefaults.standard.set(0, forKey: "lastReceivedId")
        }

        // 2. 배터리 모니터링 활성화
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true

        // CoreBluetooth 상태 복원으로 백그라운드 연결 및 재연결을 유지한다.
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.kang.watchnotify.central",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )

        addLog("BLE 초기화 완료 lastId=\(lastReceivedId)")
        if savedId > Int64(Int32.max) {
            addLog("저장된 알림 ID가 Android 범위를 넘어 초기화했습니다")
        }
        startReconnectTimer()
    }

    // MARK: - 상태 업데이트

    private func updateConnectionState(_ state: ConnectionState) {
        DispatchQueue.main.async {
            let wasOperational = self.connectionState == .operational
            self.connectionState = state
            if state == .operational {
                if !wasOperational || self.connectionEstablishedAt == nil {
                    self.connectionEstablishedAt = Date()
                }
                self.connectionProgress = "연결 완료"
                self.retryStartedAt = nil
                self.nextReconnectAt = nil
            } else {
                self.connectionEstablishedAt = nil
            }
        }
    }

    func addLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm:ss"
        let time = formatter.string(from: Date())
        print("[WatchNotify][\(time)] \(message)")
        DispatchQueue.main.async {
            self.statusLog.insert("[\(time)] \(message)", at: 0)
            if self.statusLog.count > 50 {
                self.statusLog.removeLast()
            }
        }
    }

    func addFailureLog(_ message: String) {
        addLog("❌ \(message)")
        do {
            try WatchFailureLogStore.append(source: "Watch", message: message)
            if isConnected, notifyCharacteristic != nil {
                sendPendingFailureLog()
            }
        } catch {
            addLog("실패 로그 파일 기록 오류: \(error.localizedDescription)")
        }
    }

    // MARK: - 타이머 관리

    private func startReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.reconnectTimerSec,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            guard !isAppInBackground,
                  connectionState == .offline,
                  centralManager.state == .poweredOn,
                  !isScanning,
                  !isConnecting,
                  retryWorkItem == nil else { return }
            addLog("타이머 재연결 확인")
            if resumeConnectedPeripheralIfAvailable(reason: "주기적 재연결 확인") {
                return
            }
            beginFreshScan(reason: "주기적 재연결")
        }
    }

    private func startScanTimeout() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.scanTimeoutSec,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            if isScanning && !isAppInBackground {
                addLog("스캔 타임아웃 → 중단")
                addFailureLog("Galaxy 광고 검색 시간 초과")
                stopScan()
                scheduleReconnectAfterDisconnect(reason: "Galaxy 검색 시간 초과")
            }
        }
    }

    private func startPingTimer() {
        guard !isAppInBackground else { return }
        pingTimer?.invalidate()
        heartbeatRetryWorkItem?.cancel()
        heartbeatRetryWorkItem = nil
        pendingHeartbeatTokens.removeAll()
        heartbeatDelayed = false
        sendPing()
        pingTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.pingIntervalSec,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            guard self.isConnected else { return }
            if !self.pendingHeartbeatTokens.isEmpty {
                self.heartbeatDelayed = true
                self.connectionProgress = "응답 지연 · 재확인 중"
                self.addLog("⏱️ 하트비트 응답 누락 → 즉시 재확인 전송")
                self.sendPing()
                self.sendBatteryStatus()
                self.scheduleHeartbeatRetryTimeout()
            } else {
                self.sendPing()
                self.sendBatteryStatus()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
        heartbeatRetryWorkItem?.cancel()
        heartbeatRetryWorkItem = nil
        pendingHeartbeatTokens.removeAll()
    }

    private func scheduleHeartbeatRetryTimeout() {
        heartbeatRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.pendingHeartbeatTokens.isEmpty else { return }
            self.pendingHeartbeatTokens.removeAll()
            self.heartbeatRetryWorkItem = nil
            self.heartbeatDelayed = true
            self.connectionProgress = "응답 없음 · BLE 링크 상태 확인 중"
            self.addLog("재확인 PING에도 응답 없음; 실제 BLE 해제 콜백 대기")
            self.addFailureLog("Galaxy 하트비트 재확인 응답 없음")
        }
        heartbeatRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.pingRetryGraceSec,
            execute: workItem
        )
    }

    private func scheduleScan(after delay: TimeInterval, reason: String) {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.nextReconnectAt = nil
            guard centralManager.state == .poweredOn else { return }
            guard connectionState == .offline else { return }
            guard !isScanning, !isConnecting else { return }
            if resumeConnectedPeripheralIfAvailable(reason: reason) {
                return
            }
            addLog("🔄 재연결 시도: \(reason)")
            beginFreshScan(reason: reason)
        }
        retryWorkItem = workItem
        nextReconnectAt = Date().addingTimeInterval(delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resumeConnectedPeripheralIfAvailable(reason: String) -> Bool {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected else { return false }

        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        isConnecting = false
        peripheral.delegate = self
        updateConnectionState(.connected)

        if notifyCharacteristic == nil {
            connectionProgress = "기존 BLE 연결의 서비스 확인 중"
            peripheral.discoverServices([serviceUUID])
            addLog("\(reason): CoreBluetooth 연결 유지 확인 → 서비스 재검색")
        } else {
            connectionProgress = "기존 BLE 연결 응답 확인 중"
            startPingTimer()
            addLog("\(reason): CoreBluetooth 연결 유지 확인 → 재연결 없이 PING")
        }
        return true
    }

    private func scheduleReconnectAfterDisconnect(reason: String) {
        if retryStartedAt == nil {
            retryStartedAt = Date()
        }
        retryCount += 1
        let delay = min(
            pow(2.0, Double(min(retryCount, 6))),
            Constants.maxReconnectDelaySec
        )
        connectionProgress = "재연결 대기 · \(Int(delay))초 후 새 검색"
        DispatchQueue.main.async {
            self.disconnectReason = "\(Int(delay))초 후 자동 재연결 시도"
        }
        addLog("자동 재연결 \(retryCount)회차: \(reason) → \(Int(delay))초 대기")
        scheduleScan(after: delay, reason: reason)
    }

    private func scheduleConnectionStabilityCheck(for peripheral: CBPeripheral) {
        connectionStabilityWorkItem?.cancel()
        let peripheralID = peripheral.identifier
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  peripheral.state == .connected,
                  self.connectedPeripheral?.identifier == peripheralID,
                  self.connectionState == .operational else { return }
            self.retryCount = 0
            self.retryStartedAt = nil
            self.nextReconnectAt = nil
            self.addLog("연결이 \(Int(Constants.stableConnectionSec))초 안정 유지됨; 재연결 대기시간 초기화")
        }
        connectionStabilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.stableConnectionSec,
            execute: workItem
        )
    }

    // MARK: - 공개 메서드

    func handleAppActive() {
        isAppInBackground = false
        let now = Date()
        if let lastHandled = lastAppActiveHandledAt,
           now.timeIntervalSince(lastHandled) < Constants.activationCallbackDebounceSec {
            return
        }
        lastAppActiveHandledAt = now
        addLog("🟢 앱 활성화")
        if connectionState == .offline {
            if !resumeConnectedPeripheralIfAvailable(reason: "앱 활성화") {
                addLog("앱 활성화 시 BLE 연결이 실제로 끊긴 것을 확인 → 재연결 시작")
                reconnectNow()
            }
            if notifyCharacteristic != nil {
                sendBatteryStatus()
            }
        } else if isConnected {
            startPingTimer()
            sendBatteryStatus()
        }
    }

    func reconnectNow() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        nextReconnectAt = nil
        connectionTimeoutWorkItem?.cancel()
        serviceDiscoveryRetryWorkItem?.cancel()
        serviceDiscoveryRetryCount = 0
        retryCount = 0

        guard centralManager.state == .poweredOn else {
            let reason = centralManager.state == .unauthorized
                ? "블루투스 권한 필요"
                : "블루투스를 켜주세요"
            DispatchQueue.main.async { self.disconnectReason = reason }
            addLog("수동 재연결 불가: \(reason)")
            return
        }

        guard !isManuallyDisconnecting else {
            addLog("수동 재연결 무시: 연결 초기화 중")
            return
        }

        retryStartedAt = Date()
        addLog("수동 재연결: 기존 세션을 정리하고 새 검색을 시작합니다")
        beginFreshScan(reason: "사용자 재연결")
    }

    private func beginFreshScan(reason: String) {
        guard centralManager.state == .poweredOn,
              !isManuallyDisconnecting else { return }

        retryWorkItem?.cancel()
        retryWorkItem = nil
        nextReconnectAt = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        serviceDiscoveryRetryWorkItem?.cancel()
        serviceDiscoveryRetryWorkItem = nil
        serviceDiscoveryRetryCount = 0
        stopScan()

        let peripheral = connectedPeripheral
        let needsDisconnect = peripheral?.state == .connected || peripheral?.state == .connecting
        if let peripheral, needsDisconnect {
            requestedDisconnectReasons[peripheral.identifier] = reason
        }
        isManuallyDisconnecting = needsDisconnect
        isConnecting = false
        connectedPeripheral = nil
        notifyCharacteristic = nil
        updateConnectionState(.offline)
        connectionProgress = needsDisconnect ? "기존 연결 정리 중" : "새 Galaxy 검색 준비 중"
        DispatchQueue.main.async {
            self.disconnectReason = needsDisconnect ? "기존 연결 취소 중..." : "갤럭시 새로 검색 중..."
        }

        if let peripheral, needsDisconnect {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        let scanDelay: TimeInterval = needsDisconnect ? 1.0 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + scanDelay) {
            self.isManuallyDisconnecting = false
            guard self.centralManager.state == .poweredOn else {
                self.connectionProgress = "Bluetooth 연결 대기 중"
                return
            }
            self.connectionProgress = "갤럭시 검색 중"
            self.addLog("\(reason): 새 Galaxy 광고 검색 시작")
            self.startScan()
        }
    }

    func resetBluetoothConnection() {
        guard centralManager.state == .poweredOn else {
            let reason = centralManager.state == .unauthorized
                ? "블루투스 권한 필요"
                : "블루투스를 켜주세요"
            DispatchQueue.main.async { self.disconnectReason = reason }
            addLog("BLE 연결 초기화 불가: \(reason)")
            return
        }

        guard !isResettingConnection else {
            addLog("BLE 연결 초기화가 이미 진행 중입니다")
            return
        }

        retryWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        serviceDiscoveryRetryWorkItem?.cancel()
        serviceDiscoveryRetryCount = 0
        resetScanWorkItem?.cancel()
        stopScan()
        stopPingTimer()
        timedOutPeripheralID = nil
        retryCount = 0

        let peripheral = connectedPeripheral
        if let peripheral {
            requestedDisconnectReasons[peripheral.identifier] = "사용자 BLE 연결 초기화"
        }
        ignoredResetPeripheralID = peripheral?.identifier
        isResettingConnection = true
        isManuallyDisconnecting = true
        isConnecting = false
        connectedPeripheral = nil
        notifyCharacteristic = nil
        UserDefaults.standard.removeObject(forKey: knownPeripheralIdKey)
        updateConnectionState(.offline)
        DispatchQueue.main.async {
            self.disconnectReason = "BLE 연결 초기화 중..."
        }
        addLog("BLE 연결 초기화: 저장된 Galaxy 식별자와 현재 연결 세션을 지우고 새로 검색합니다")

        if let peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.finishConnectionReset()
        }
        resetScanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (peripheral == nil ? 0.5 : 2.0), execute: workItem)
    }

    private func finishConnectionReset() {
        guard isResettingConnection else { return }
        if let peripheralID = ignoredResetPeripheralID {
            requestedDisconnectReasons.removeValue(forKey: peripheralID)
        }
        isResettingConnection = false
        isManuallyDisconnecting = false
        resetScanWorkItem = nil

        guard centralManager.state == .poweredOn else {
            addLog("BLE 연결 초기화 완료; Bluetooth가 꺼져 있어 검색을 시작하지 못했습니다")
            return
        }

        DispatchQueue.main.async {
            self.disconnectReason = "Galaxy BLE 새로 검색 중..."
        }
        addLog("BLE 세션 초기화 완료 → 새 광고 검색 시작")
        startScan()
    }

    func handleAppBackground() {
        isAppInBackground = true
        addLog("⚫ 백그라운드 BLE 연결 유지")
        stopPingTimer()
        if centralManager.state == .poweredOn && !isConnected && !isConnecting {
            reconnectToKnownPeripheralOrScan()
        }
    }

    func reset() {
        addLog("전체 초기화")
        retryWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        timedOutPeripheralID = nil
        scanTimeoutTimer?.invalidate()
        reconnectTimer?.invalidate()
        stopPingTimer()
        isManuallyDisconnecting = true
        UserDefaults.standard.removeObject(forKey: knownPeripheralIdKey)

        if let peripheral = connectedPeripheral,
           centralManager.state == .poweredOn {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        connectedPeripheral = nil
        notifyCharacteristic = nil
        isConnecting = false
        retryCount = 0

        if centralManager.state == .poweredOn {
            centralManager.stopScan()
        }

        DispatchQueue.main.async {
            self.updateConnectionState(.offline)
            self.isScanning = false
            self.disconnectReason = "초기화 중..."
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isManuallyDisconnecting = false
            self.startReconnectTimer()
            if self.centralManager.state == .poweredOn {
                self.scheduleScan(after: 0.0, reason: "초기화 후 재스캔")
            }
            self.addLog("초기화 완료")
        }
    }

    func startScan() {
        guard centralManager.state == .poweredOn else {
            DispatchQueue.main.async { self.disconnectReason = "블루투스 비활성" }
            return
        }
        guard !isScanning, !isConnecting else { return }

        isScanning = true
        connectionProgress = "갤럭시 검색 중"
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: !isAppInBackground]
        )
        if !isAppInBackground {
            startScanTimeout()
        } else {
            scanTimeoutTimer?.invalidate()
        }
        addLog(isAppInBackground ? "백그라운드 BLE 스캔 시작" : "스캔 시작")
    }

    func stopScan() {
        scanTimeoutTimer?.invalidate()
        centralManager.stopScan()
        isScanning = false
    }

    func disconnect() {
        retryWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        timedOutPeripheralID = nil
        reconnectTimer?.invalidate()
        scanTimeoutTimer?.invalidate()
        stopPingTimer()
        isManuallyDisconnecting = true
        UserDefaults.standard.removeObject(forKey: knownPeripheralIdKey)
        isConnecting = false
        if let peripheral = connectedPeripheral,
           centralManager.state == .poweredOn {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    private func reconnectToKnownPeripheralOrScan() {
        guard centralManager.state == .poweredOn,
              !isManuallyDisconnecting,
              !isConnecting else { return }

        if let peripheral = connectedPeripheral {
            connect(to: peripheral)
            return
        }

        let savedIdentifier = (UserDefaults.standard.string(forKey: knownPeripheralIdKey))
            .flatMap(UUID.init(uuidString:))
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [serviceUUID])
        let peripheral = savedIdentifier.flatMap { identifier in
            centralManager.retrievePeripherals(withIdentifiers: [identifier]).first
                ?? connectedPeripherals.first(where: { $0.identifier == identifier })
        } ?? connectedPeripherals.first

        if let peripheral {
            connect(to: peripheral)
        } else {
            startScan()
        }
    }

    private func connect(to peripheral: CBPeripheral) {
        guard centralManager.state == .poweredOn,
              !isManuallyDisconnecting,
              !isConnecting else { return }

        stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: knownPeripheralIdKey)

        if peripheral.state == .connected {
            updateConnectionState(.connected)
            connectionProgress = "BLE 서비스 확인 중"
            peripheral.discoverServices([serviceUUID])
            addLog("저장된 Galaxy BLE 연결을 복원합니다")
            return
        }
        if peripheral.state == .connecting {
            isConnecting = true
            connectionProgress = "Galaxy 연결 요청 중"
            addLog("Galaxy BLE 연결 요청이 진행 중입니다")
            scheduleConnectionTimeout(for: peripheral)
            return
        }

        isConnecting = true
        connectionProgress = "Galaxy 연결 요청 중"
        centralManager.connect(peripheral, options: nil)
        addLog("Galaxy BLE 연결 요청 전송; 최대 \(Int(Constants.connectionTimeoutSec))초 응답 대기")
        scheduleConnectionTimeout(for: peripheral)
    }

    private func scheduleConnectionTimeout(for peripheral: CBPeripheral) {
        connectionTimeoutWorkItem?.cancel()
        let peripheralID = peripheral.identifier
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isConnecting,
                  self.connectedPeripheral?.identifier == peripheralID,
                  peripheral.state != .connected else { return }

            self.isConnecting = false
            self.timedOutPeripheralID = peripheralID
            self.updateConnectionState(.offline)
            if self.retryStartedAt == nil {
                self.retryStartedAt = Date()
            }
            DispatchQueue.main.async {
                self.disconnectReason = "갤럭시 연결 응답 시간 초과"
            }
            self.addLog("⏱️ 연결 요청 후 \(Int(Constants.connectionTimeoutSec))초간 응답 없음; 연결 취소 후 재시도")
            self.addFailureLog("Galaxy BLE 연결 요청 시간 초과")
            self.centralManager.cancelPeripheralConnection(peripheral)
            self.retryCount += 1
            let delay = min(
                pow(2.0, Double(min(self.retryCount, 6))),
                Constants.maxReconnectDelaySec
            )
            self.nextReconnectAt = Date().addingTimeInterval(delay)
            self.connectionProgress = "연결 응답 시간 초과 · \(Int(delay))초 후 새 검색"
            self.scheduleScan(after: delay, reason: "연결 응답 시간 초과")
        }
        connectionTimeoutWorkItem = workItem
        connectionProgress = "Galaxy 연결 응답 대기 중"
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.connectionTimeoutSec,
            execute: workItem
        )
    }

    // MARK: - GATT Write 송신 (프로토콜 명세서 4번 & 5번)

    func sendWriteCommand(_ command: String) {
        guard let peripheral = connectedPeripheral,
              let characteristic = notifyCharacteristic,
              peripheral.state == .connected,
              let data = command.data(using: .utf8) else {
            addLog("⚠️ 쓰기 실패: 연결 미준비 (\(command))")
            return
        }
        guard !failureLogWriteInFlight, !controlWriteInFlight else {
            pendingControlWrites.append(command)
            return
        }

        // 명세서 2번/5번: Write 지원 시 withResponse 우선 사용
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        controlWriteInFlight = writeType == .withResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    private func sendPendingFailureLog() {
        guard isConnected,
              pendingControlWrites.isEmpty,
              !controlWriteInFlight,
              !failureLogWriteInFlight,
              currentFailureLogRecordId == nil,
              let peripheral = connectedPeripheral,
              let characteristic = notifyCharacteristic,
              peripheral.state == .connected else { return }

        do {
            guard let record = try WatchFailureLogStore.pendingRecords().first else { return }
            let payload = try JSONEncoder().encode(record)
            let writeType: CBCharacteristicWriteType =
                characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            let maxChunkSize = peripheral.maximumWriteValueLength(for: writeType) - 6
            guard maxChunkSize > 0 else {
                addLog("실패 로그 전송 불가: BLE 쓰기 MTU가 헤더보다 작습니다")
                return
            }
            let total = (payload.count + maxChunkSize - 1) / maxChunkSize
            guard total > 0, total <= Int(UInt8.max) else {
                addLog("실패 로그 전송 보류: 기록 크기가 BLE 한도를 초과했습니다")
                return
            }

            failureLogTransferSequence = failureLogTransferSequence == UInt16.max
                ? 1
                : failureLogTransferSequence + 1
            currentFailureLogRecordId = record.id
            currentFailureLogTransferId = failureLogTransferSequence
            failureLogFrames = (0..<total).map { index in
                let start = index * maxChunkSize
                let end = min(start + maxChunkSize, payload.count)
                return Data([
                    0x57,
                    0x46,
                    UInt8((failureLogTransferSequence >> 8) & 0xFF),
                    UInt8(failureLogTransferSequence & 0xFF),
                    UInt8(index),
                    UInt8(total)
                ]) + payload.subdata(in: start..<end)
            }
            sendNextFailureLogFrame()
        } catch {
            addLog("실패 로그 전송 준비 오류: \(error.localizedDescription)")
        }
    }

    private func sendNextFailureLogFrame() {
        guard !controlWriteInFlight,
              !failureLogWriteInFlight,
              let frame = failureLogFrames.first,
              let peripheral = connectedPeripheral,
              let characteristic = notifyCharacteristic,
              peripheral.state == .connected else {
            if failureLogFrames.isEmpty, currentFailureLogRecordId != nil {
                scheduleFailureLogAckTimeout()
            }
            return
        }

        let writeType: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
            return
        }
        failureLogFrames.removeFirst()
        failureLogWriteInFlight = writeType == .withResponse
        peripheral.writeValue(frame, for: characteristic, type: writeType)
        if writeType == .withoutResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.sendNextFailureLogFrame()
            }
        }
    }

    private func scheduleFailureLogAckTimeout() {
        guard failureLogAckTimeoutWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.currentFailureLogRecordId != nil else { return }
            self.failureLogAckTimeoutWorkItem = nil
            self.failureLogFrames.removeAll()
            self.currentFailureLogRecordId = nil
            self.currentFailureLogTransferId = nil
            self.failureLogRetryCount += 1
            self.addLog("실패 로그 저장 확인 시간 초과 (\(self.failureLogRetryCount)회)")
            self.sendQueuedControlWrites()
            if self.failureLogRetryCount < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.sendPendingFailureLog()
                }
            }
        }
        failureLogAckTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func handleFailureLogAcknowledgement(_ data: Data) -> Bool {
        guard data.count == 4,
              data[data.startIndex] == 0x57,
              data[data.startIndex + 1] == 0x41 else { return false }
        let transferId =
            (UInt16(data[data.startIndex + 2]) << 8) |
            UInt16(data[data.startIndex + 3])
        guard transferId == currentFailureLogTransferId,
              let recordId = currentFailureLogRecordId else {
            addLog("이전/미요청 실패 로그 확인 응답 무시")
            return true
        }

        failureLogAckTimeoutWorkItem?.cancel()
        failureLogAckTimeoutWorkItem = nil
        do {
            try WatchFailureLogStore.remove(id: recordId)
            addLog("실패 로그가 Galaxy 파일에 저장됨")
        } catch {
            addLog("전송 완료 로그 정리 실패: \(error.localizedDescription)")
        }
        currentFailureLogRecordId = nil
        currentFailureLogTransferId = nil
        failureLogFrames.removeAll()
        failureLogRetryCount = 0
        sendQueuedControlWrites()
        sendPendingFailureLog()
        return true
    }

    private func sendQueuedControlWrites() {
        guard !failureLogWriteInFlight, !controlWriteInFlight else { return }
        guard !pendingControlWrites.isEmpty else { return }
        let nextCommand = pendingControlWrites.removeFirst()
        sendWriteCommand(nextCommand)
    }

    /// 1. PING 전송 (워치 → 안드로이드)
    @discardableResult
    func sendPing() -> UInt64 {
        heartbeatSequence = heartbeatSequence == UInt64.max ? 1 : heartbeatSequence + 1
        pendingHeartbeatTokens.insert(heartbeatSequence)
        sendWriteCommand("PING:\(heartbeatSequence)")
        addLog("📤 하트비트 PING 전송 (id=\(heartbeatSequence))")
        return heartbeatSequence
    }

    private func handleHeartbeatPong(_ token: UInt64) {
        guard pendingHeartbeatTokens.contains(token) else {
            addLog("이전/미요청 하트비트 PONG 무시 (id=\(token))")
            return
        }
        pendingHeartbeatTokens.removeAll()
        heartbeatRetryWorkItem?.cancel()
        heartbeatRetryWorkItem = nil
        heartbeatDelayed = false
        connectionProgress = "연결 완료"
        lastPingTime = Date()
        lastHeartbeatResponseAt = Date()
        updateConnectionState(.operational)
        addLog("✅ Galaxy 하트비트 응답 확인 (id=\(token))")
        sendPendingFailureLog()
    }

    /// 2. 재전송 요청 (워치 → 안드로이드)
    func requestResend(lastId: Int64) {
        sendWriteCommand("RESEND:\(lastId)")
        addLog("📤 RESEND:\(lastId) 요청")
    }

    /// 3. 배터리 잔량 전송 (워치 → 안드로이드)
    func sendBatteryStatus(level: Int? = nil) {
        let batteryLevel: Int
        if let level {
            batteryLevel = level
        } else {
            let device = WKInterfaceDevice.current()
            device.isBatteryMonitoringEnabled = true
            let rawLevel = device.batteryLevel
            guard rawLevel >= 0 else { return }
            batteryLevel = Int(round(rawLevel * 100))
        }
        sendWriteCommand("BATTERY:\(batteryLevel)")
        addLog("🔋 BATTERY:\(batteryLevel) 전송")
    }

    // MARK: - PING_ACK 수신 처리 (안드로이드 → 워치)

    private func handlePingAck(androidLastId: Int64) {
        lastPingTime = Date()
        lastHeartbeatResponseAt = Date()
        heartbeatDelayed = false
        pendingHeartbeatTokens.removeAll()
        heartbeatRetryWorkItem?.cancel()
        heartbeatRetryWorkItem = nil
        updateConnectionState(.operational)
        DispatchQueue.main.async { self.disconnectReason = "" }
        if androidLastId < lastReceivedId {
            addLog("Android 알림 ID가 초기화됨 (\(lastReceivedId) → \(androidLastId))")
            lastReceivedId = androidLastId
            UserDefaults.standard.set(androidLastId, forKey: "lastReceivedId")
        }
        addLog("✅ PING_ACK 수신 (Android lastId=\(androidLastId), Watch lastId=\(lastReceivedId))")

        // 1. 배터리 상태 전송
        sendBatteryStatus()

        // 2. 주기적 PING 타이머 가동
        startPingTimer()

        // 3. 누락 알림 확인 및 재전송 요청
        if androidLastId > lastReceivedId {
            addLog("🔄 누락 알림 감지 (\(lastReceivedId) < \(androidLastId)) → RESEND 요청")
            requestResend(lastId: lastReceivedId)
        }
        sendPendingFailureLog()
    }

    // MARK: - 로컬 알림 및 햅틱

    private func sendLocalNotification(payload: NotificationPayload) {
        let content = UNMutableNotificationContent()
        content.title = appName(for: payload.pkg)
        content.body = "\(payload.title): \(payload.body)"
        content.sound = .default

        WKInterfaceDevice.current().play(.notification)

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    private func sendIncomingCallNotification(payload: NotificationPayload) {
        scheduleIncomingCallNotifications(caller: payload.title)
    }

    private func sendIncomingCallNotification() {
        scheduleIncomingCallNotifications(caller: nil)
    }

    private func scheduleIncomingCallNotifications(caller: String?) {
        if incomingCallAlertActive {
            return
        }
        cancelCallNotifications()
        incomingCallAlertActive = true
        for i in 0..<incomingCallNotificationCount {
            let content = UNMutableNotificationContent()
            content.title = "전화"
            content.body = caller.map { "\($0): 수신 전화" } ?? "수신 전화가 왔습니다"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
            let trigger = i == 0 ? nil : UNTimeIntervalNotificationTrigger(
                timeInterval: Double(i) * incomingCallRepeatInterval,
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "\(callNotificationId)_\(i)",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request) { [weak self] error in
                if let error {
                    self?.addLog("수신 전화 알림 등록 실패: \(error.localizedDescription)")
                }
            }
        }
        addLog("수신 전화 즉시 알림 및 반복 알림 시작")
    }

    private func sendMissedCallNotification(payload: NotificationPayload) {
        cancelCallNotifications()
        let content = UNMutableNotificationContent()
        content.title = "📞 부재중 전화"
        content.body = payload.title
        content.sound = .default
        WKInterfaceDevice.current().play(.notification)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "missed_call_\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
        )
        addLog("부재중 전화 알림")
    }

    private func cancelCallNotifications() {
        incomingCallAlertActive = false
        let ids = (0..<incomingCallNotificationCount).map { "\(callNotificationId)_\($0)" }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func appName(for pkg: String) -> String {
        switch pkg {
        case "com.kakao.talk": return "카카오톡"
        case "com.lguplus.aicallagent", "com.uplus.ubizai": return "전화"
        case "com.samsung.android.messaging", "com.android.mms": return "문자"
        case "com.towneers.www": return "당근"
        case "com.nhn.android.search": return "네이버"
        case "gov.gyeonggi.ggcard": return "경기지역화폐"
        case "com.kbstar.kbbank",
             "com.kbcard.cxh.appcard": return "국민은행"
        case "com.microsoft.teams": return "Teams"
        default: return "알림"
        }
    }

    // MARK: - 신호 처리 (명세서 3-②)

    private func handleSignal(_ signal: String) {
        switch signal {
        case "CALL_RINGING":
            addLog("📞 수신 전화 벨 울림")
            recordCallEvent(status: "수신 전화", caller: lastCallPayload?.title)
            if let payload = lastCallPayload {
                sendIncomingCallNotification(payload: payload)
            } else {
                sendIncomingCallNotification()
            }
        case "CALL_ANSWERED":
            addLog("📞 통화 연결됨 (알림 중단)")
            recordCallEvent(status: "통화 연결됨", caller: lastCallPayload?.title)
            cancelCallNotifications()
        case "CANCEL_CALL":
            addLog("📞 통화 종료됨")
            recordCallEvent(status: "통화 종료", caller: lastCallPayload?.title)
            cancelCallNotifications()
            lastCallPayload = nil
            activeCallRecordID = nil
        case "MISSED_CALL":
            addLog("📞 부재중 전화 발생")
            recordCallEvent(status: "부재중 전화", caller: lastCallPayload?.title)
            if let payload = lastCallPayload {
                sendMissedCallNotification(payload: payload)
            } else {
                cancelCallNotifications()
                let content = UNMutableNotificationContent()
                content.title = "📞 부재중 전화"
                content.body = "부재중 전화가 있습니다"
                content.sound = .default
                WKInterfaceDevice.current().play(.notification)
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(
                        identifier: "missed_call_\(Date().timeIntervalSince1970)",
                        content: content,
                        trigger: nil
                    )
                )
            }
            lastCallPayload = nil
            activeCallRecordID = nil
        default:
            break
        }
    }

    private func recordCallEvent(status: String, caller: String?) {
        if activeCallRecordID == nil {
            let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
            let sequenceKey = "callRecordSequence"
            let sequence = UserDefaults.standard.integer(forKey: sequenceKey) + 1
            UserDefaults.standard.set(sequence, forKey: sequenceKey)
            activeCallRecordID = -(timestamp * 1_000 + Int64(sequence))
        }
        guard let recordID = activeCallRecordID else { return }

        DispatchQueue.main.async {
            guard let context = self.modelContext else {
                self.addLog("통화 기록 저장 실패: SwiftData 컨텍스트가 준비되지 않았습니다")
                return
            }

            let descriptor = FetchDescriptor<WatchMessage>(
                predicate: #Predicate { $0.id == recordID }
            )
            let existingRecord = try? context.fetch(descriptor).first
            if let existingRecord {
                if let caller, !caller.isEmpty {
                    existingRecord.title = caller
                }
                existingRecord.body = status
                existingRecord.createdAt = Date()
                existingRecord.isRead = false
            } else {
                let callTitle = caller.flatMap { $0.isEmpty ? nil : $0 } ?? "전화"
                context.insert(
                    WatchMessage(
                        id: recordID,
                        pkg: "com.lguplus.aicallagent",
                        title: callTitle,
                        body: status
                    )
                )
            }

            do {
                try context.save()
                self.addLog("통화 기록 저장: \(status)")
                let phonePackage = "com.lguplus.aicallagent"
                let descriptor = FetchDescriptor<WatchMessage>(
                    predicate: #Predicate { $0.pkg == phonePackage },
                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                )
                if let records = try? context.fetch(descriptor), records.count > 50 {
                    records.dropFirst(50).forEach(context.delete)
                    try context.save()
                }
            } catch {
                self.addLog("통화 기록 저장 오류: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - DB 저장 (실제 앱 메시지만 저장)

    private func saveMessage(payload: NotificationPayload) {
        if payload.pkg == "com.test" || payload.pkg == "com.watchnotify.system" || payload.pkg == "com.watchnotify.log" {
            return
        }

        DispatchQueue.main.async {
            guard let context = self.modelContext else {
                self.addLog("저장 실패: SwiftData 컨텍스트가 준비되지 않았습니다")
                return
            }

            if payload.id > 0 {
                let id = payload.id
                let duplicateCheck = FetchDescriptor<WatchMessage>(
                    predicate: #Predicate { $0.id == id }
                )
                do {
                    let existing = try context.fetch(duplicateCheck)
                    if !existing.isEmpty {
                        self.addLog("중복 저장 방지 id=\(id)")
                        self.acknowledgeReceived(id)
                        return
                    }
                } catch {
                    self.addLog("중복 확인 실패 id=\(id): \(error.localizedDescription)")
                    return
                }
            }

            let message = WatchMessage(
                id: payload.id,
                pkg: payload.pkg,
                title: payload.title,
                body: payload.body
            )
            context.insert(message)
            do {
                try context.save()
                self.acknowledgeReceived(payload.id)
                self.lastReceivedTime = Date()
                self.addLog("저장 완료 [\(payload.pkg)] id=\(payload.id)")

                let pkg = payload.pkg
                let fetchDescriptor = FetchDescriptor<WatchMessage>(
                    predicate: #Predicate { $0.pkg == pkg },
                    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
                )
                if let all = try? context.fetch(fetchDescriptor), all.count > 50 {
                    all.dropFirst(50).forEach { context.delete($0) }
                    try? context.save()
                }
            } catch {
                self.addLog("저장 실패: \(error.localizedDescription)")
            }
        }
    }

    private func acknowledgeReceived(_ id: Int64) {
        guard id > 0 else { return }
        if id > lastReceivedId {
            lastReceivedId = id
            UserDefaults.standard.set(id, forKey: "lastReceivedId")
        }
        sendWriteCommand("PING_ACK:\(lastReceivedId)")
    }

}

// MARK: - CBCentralManagerDelegate

extension BLECentralManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            addLog("블루투스 켜짐")
            DispatchQueue.main.async { self.disconnectReason = "갤럭시 검색 중..." }
            if connectedPeripheral?.state == .connecting {
                isConnecting = true
            } else {
                reconnectToKnownPeripheralOrScan()
            }
        case .poweredOff:
            addLog("블루투스 꺼짐")
            addFailureLog("워치 Bluetooth가 꺼짐")
            stopPingTimer()
            isConnecting = false
            isScanning = false
            updateConnectionState(.offline)
            DispatchQueue.main.async { self.disconnectReason = "블루투스 꺼짐" }
        case .unauthorized:
            addLog("블루투스 권한 없음")
            addFailureLog("워치 Bluetooth 권한 없음")
            stopPingTimer()
            DispatchQueue.main.async { self.disconnectReason = "블루투스 권한 필요" }
        case .resetting:
            DispatchQueue.main.async { self.disconnectReason = "블루투스 재시작 중..." }
        default:
            DispatchQueue.main.async { self.disconnectReason = "블루투스 초기화 중..." }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        addLog("BLE 상태 복원")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                connectedPeripheral = peripheral
                connectedPeripheral?.delegate = self
                UserDefaults.standard.set(
                    peripheral.identifier.uuidString,
                    forKey: knownPeripheralIdKey
                )
                notifyCharacteristic = nil
                if peripheral.state == .connected {
                    updateConnectionState(.connected)
                    peripheral.discoverServices([serviceUUID])
                    addLog("복원 peripheral 서비스 검색")
                } else if central.state == .poweredOn {
                    connect(to: peripheral)
                }
            }
        } else if central.state == .poweredOn {
            reconnectToKnownPeripheralOrScan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard !isResettingConnection else { return }
        guard !isConnecting else { return }
        if ignoredResetPeripheralID == peripheral.identifier {
            ignoredResetPeripheralID = nil
        }
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: knownPeripheralIdKey)
        connect(to: peripheral)
        connectionProgress = "Galaxy 발견 · 연결 중"
        DispatchQueue.main.async { self.disconnectReason = "갤럭시 발견 - 연결 중..." }
        addLog("발견 RSSI=\(RSSI) → 연결 시도")
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        if isResettingConnection {
            ignoredResetPeripheralID = peripheral.identifier
            addLog("연결 초기화 중 이전 연결이 완료됨; 즉시 해제합니다")
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        connectionStabilityWorkItem?.cancel()
        connectionStabilityWorkItem = nil
        serviceDiscoveryRetryWorkItem?.cancel()
        serviceDiscoveryRetryWorkItem = nil
        serviceDiscoveryRetryCount = 0
        timedOutPeripheralID = nil
        requestedDisconnectReasons.removeValue(forKey: peripheral.identifier)
        retryWorkItem?.cancel()
        isConnecting = false
        updateConnectionState(.connected)
        connectionProgress = "BLE 서비스 확인 중"
        scheduleConnectionStabilityCheck(for: peripheral)
        DispatchQueue.main.async { self.disconnectReason = "서비스 검색 중..." }

        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        addLog("연결 성공 MTU: \(mtu)바이트 → 서비스 검색")

        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        if isResettingConnection {
            addLog("연결 초기화 중 이전 연결 실패 콜백 수신")
            finishConnectionReset()
            return
        }
        if ignoredResetPeripheralID == peripheral.identifier {
            addLog("초기화한 이전 연결의 지연 실패 콜백 무시")
            return
        }
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        connectionStabilityWorkItem?.cancel()
        connectionStabilityWorkItem = nil
        serviceDiscoveryRetryWorkItem?.cancel()
        serviceDiscoveryRetryWorkItem = nil
        serviceDiscoveryRetryCount = 0
        if timedOutPeripheralID == peripheral.identifier {
            timedOutPeripheralID = nil
        }
        requestedDisconnectReasons.removeValue(forKey: peripheral.identifier)
        isConnecting = false
        stopPingTimer()
        updateConnectionState(.offline)
        if isManuallyDisconnecting {
            addLog("취소한 연결 시도의 실패 콜백 수신; 수동 검색을 계속합니다")
            return
        }
        let reason = "연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류")"
        DispatchQueue.main.async {
            self.disconnectReason = reason
            self.lastDisconnectReason = reason
        }
        addLog("연결 실패: \(error?.localizedDescription ?? "")")
        addFailureLog("Galaxy BLE 연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류")")

        retryCount += 1
        if retryStartedAt == nil {
            retryStartedAt = Date()
        }
        let delay = min(pow(2.0, Double(min(retryCount, 6))), Constants.maxReconnectDelaySec)
        addLog("연결 실패 \(retryCount)회 → \(Int(delay))초 후 동일 기기에 재연결")
        connectionProgress = "연결 실패 · \(Int(delay))초 후 새 검색"
        nextReconnectAt = Date().addingTimeInterval(delay)
        DispatchQueue.main.async {
            self.disconnectReason = "\(Int(delay))초 후 재연결 시도"
        }
        scheduleScan(after: delay, reason: "연결 실패")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if isResettingConnection {
            addLog("연결 초기화: 기존 Galaxy 연결 해제 확인")
            finishConnectionReset()
            return
        }
        if ignoredResetPeripheralID == peripheral.identifier {
            addLog("초기화한 이전 연결의 지연 해제 콜백 무시")
            return
        }
        let requestedDisconnectReason = requestedDisconnectReasons.removeValue(
            forKey: peripheral.identifier
        )
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        connectionStabilityWorkItem?.cancel()
        connectionStabilityWorkItem = nil
        serviceDiscoveryRetryWorkItem?.cancel()
        serviceDiscoveryRetryWorkItem = nil
        serviceDiscoveryRetryCount = 0
        notifyCharacteristic = nil
        isConnecting = false
        failureLogAckTimeoutWorkItem?.cancel()
        failureLogAckTimeoutWorkItem = nil
        failureLogFrames.removeAll()
        currentFailureLogRecordId = nil
        currentFailureLogTransferId = nil
        failureLogWriteInFlight = false
        controlWriteInFlight = false
        pendingControlWrites.removeAll()
        stopPingTimer()
        updateConnectionState(.offline)

        let reason: String
        if let error {
            let code = (error as NSError).code
            switch code {
            case 6:  reason = "code=6 (갤럭시앱종료)"
            case 7:  reason = "code=7 (연결타임아웃)"
            case 10: reason = "code=10 (범위벗어남)"
            case 14: reason = "code=14 (연결파라미터오류)"
            default:
                let desc = error.localizedDescription
                if desc.contains("timeout") { reason = "code=\(code) (타임아웃)" }
                else if desc.contains("sleep") { reason = "code=\(code) (절전모드)" }
                else if desc.contains("range") { reason = "code=\(code) (범위벗어남)" }
                else if desc.contains("terminated") { reason = "code=\(code) (강제종료)" }
                else { reason = "code=\(code) (\(desc))" }
            }
        } else {
            reason = requestedDisconnectReason.map {
                "앱이 연결 해제 요청 (\($0))"
            } ?? "정상 종료 (해제 요청 주체 확인 불가)"
        }

        DispatchQueue.main.async {
            self.disconnectReason = reason
            self.lastDisconnectReason = reason
            WKInterfaceDevice.current().play(.failure)
        }

        lastPingTime = nil
        addLog("연결 끊김: \(reason)")
        addFailureLog("BLE 연결 해제: \(reason)")

        retryWorkItem?.cancel()
        guard !isManuallyDisconnecting else {
            connectedPeripheral = nil
            return
        }

        connectedPeripheral = peripheral
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: knownPeripheralIdKey)
        if timedOutPeripheralID == peripheral.identifier {
            timedOutPeripheralID = nil
            addLog("연결 시간 초과에 따른 연결 해제 확인; 예약된 재시도 유지")
            return
        }
        connectedPeripheral = peripheral
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: knownPeripheralIdKey)
        scheduleReconnectAfterDisconnect(reason: "연결 해제 후")
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentralManager: CBPeripheralDelegate {

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error {
            scheduleServiceDiscoveryRetry(
                peripheral,
                reason: "서비스 발견 오류: \(error.localizedDescription)"
            )
            return
        }
        guard let services = peripheral.services else {
            scheduleServiceDiscoveryRetry(peripheral, reason: "Galaxy BLE 서비스 목록이 비어 있습니다")
            return
        }
        var foundService = false
        for service in services where service.uuid == serviceUUID {
            foundService = true
            serviceDiscoveryRetryWorkItem?.cancel()
            serviceDiscoveryRetryWorkItem = nil
            addLog("Galaxy BLE 서비스 UUID 확인: \(service.uuid.uuidString)")
            connectionProgress = "BLE 알림 채널 확인 중"
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
        if !foundService {
            let discoveredUUIDs = services.map { $0.uuid.uuidString }.joined(separator: ", ")
            scheduleServiceDiscoveryRetry(
                peripheral,
                reason: "Galaxy BLE 서비스 UUID \(serviceUUID.uuidString)를 찾지 못했습니다 (발견: \(discoveredUUIDs.isEmpty ? "없음" : discoveredUUIDs))"
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            scheduleServiceDiscoveryRetry(
                peripheral,
                reason: "특성 발견 오류: \(error.localizedDescription)"
            )
            return
        }
        guard let characteristics = service.characteristics else {
            scheduleServiceDiscoveryRetry(peripheral, reason: "Galaxy BLE 특성 목록이 비어 있습니다")
            return
        }
        var foundCharacteristic = false
        for characteristic in characteristics where characteristic.uuid == characteristicUUID {
            foundCharacteristic = true
            serviceDiscoveryRetryWorkItem?.cancel()
            serviceDiscoveryRetryWorkItem = nil
            serviceDiscoveryRetryCount = 0
            notifyCharacteristic = characteristic

            let supportsIndicate = characteristic.properties.contains(.indicate)
            let supportsNotify = characteristic.properties.contains(.notify)

            if supportsIndicate || supportsNotify {
                connectionProgress = "워치 알림 채널 구독 중"
                peripheral.setNotifyValue(true, for: characteristic)
                addLog("구독 신청 (\(supportsIndicate ? "Indicate" : "Notify"))")
            } else {
                retryConnectionAfterSetupFailure(
                    peripheral,
                    reason: "Galaxy BLE 특성이 Notify/Indicate를 지원하지 않습니다"
                )
                return
            }

            // 연결 및 특성 발견 즉시 PING 전송 (명세서 5번 샘플 코드 준수)
            sendPing()
        }
        if !foundCharacteristic {
            scheduleServiceDiscoveryRetry(peripheral, reason: "Galaxy BLE 특성을 찾지 못했습니다")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            retryConnectionAfterSetupFailure(peripheral, reason: "알림 구독 실패: \(error.localizedDescription)")
            return
        }
        addLog("구독 활성 상태: \(characteristic.isNotifying)")
        if characteristic.isNotifying {
            // 구독 상태 확정 후 PING 전송 (핸드셰이크 보장)
            connectionProgress = "Galaxy 응답 확인 중"
            sendPing()
        } else {
            retryConnectionAfterSetupFailure(peripheral, reason: "알림 구독이 활성화되지 않았습니다")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        let invalidatedUUIDs = invalidatedServices
            .map { $0.uuid.uuidString }
            .joined(separator: ", ")
        addLog("서비스 변경 알림: 무효화된 UUID=\(invalidatedUUIDs.isEmpty ? "목록 없음" : invalidatedUUIDs)")
        notifyCharacteristic = nil
        scheduleServiceDiscoveryRetry(peripheral, reason: "서비스 변경 후 UUID 재검색")
    }

    private func scheduleServiceDiscoveryRetry(_ peripheral: CBPeripheral, reason: String) {
        guard peripheral.state == .connected,
              connectedPeripheral?.identifier == peripheral.identifier else {
            retryConnectionAfterSetupFailure(peripheral, reason: "\(reason); 연결이 이미 끊겼습니다")
            return
        }

        guard serviceDiscoveryRetryCount < Constants.maxServiceDiscoveryRetries else {
            retryConnectionAfterSetupFailure(
                peripheral,
                reason: "\(reason); \(Constants.maxServiceDiscoveryRetries)회 재검색 후에도 서비스/특성을 찾지 못했습니다"
            )
            return
        }

        serviceDiscoveryRetryCount += 1
        let attempt = serviceDiscoveryRetryCount
        let delay = TimeInterval(attempt)
        connectionProgress = "BLE 서비스 재검색 \(attempt)/\(Constants.maxServiceDiscoveryRetries)"
        serviceDiscoveryRetryWorkItem?.cancel()
        addLog("\(reason) → 연결 유지, \(Int(delay))초 후 서비스 재검색 (\(attempt)/\(Constants.maxServiceDiscoveryRetries))")

        let peripheralID = peripheral.identifier
        let workItem = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  peripheral.state == .connected,
                  self.connectedPeripheral?.identifier == peripheralID else {
                return
            }
            self.addLog("Galaxy BLE 서비스 재검색 시작 (\(attempt)/\(Constants.maxServiceDiscoveryRetries))")
            peripheral.discoverServices([self.serviceUUID])
        }
        serviceDiscoveryRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func retryConnectionAfterSetupFailure(_ peripheral: CBPeripheral, reason: String) {
        addLog("\(reason) → 연결을 다시 시도합니다")
        connectionProgress = "\(reason) · 새 연결 준비 중"
        if retryStartedAt == nil {
            retryStartedAt = Date()
        }
        requestedDisconnectReasons[peripheral.identifier] = reason
        notifyCharacteristic = nil
        updateConnectionState(.offline)
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            addLog("수신 실패: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        if handleFailureLogAcknowledgement(data) {
            return
        }

        // 수신 데이터 텍스트 파싱
        if let rawText = String(data: data, encoding: .utf8) {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

            // ① 전화 및 신호 처리 (명세서 3-②)
            if text == "CALL_RINGING" ||
                text == "CALL_ANSWERED" ||
                text == "CANCEL_CALL" ||
                text == "MISSED_CALL" {
                handleSignal(text)
                return
            } else if text.hasPrefix("PONG:") {
                let tokenText = text.replacingOccurrences(of: "PONG:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let token = UInt64(tokenText) {
                    handleHeartbeatPong(token)
                }
                return
            } else if text.hasPrefix("PING:") {
                let tokenText = text.replacingOccurrences(of: "PING:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let token = UInt64(tokenText) {
                    addLog("📥 Galaxy 하트비트 수신 → PONG 전송 (id=\(token))")
                    sendWriteCommand("PONG:\(token)")
                    lastPingTime = Date()
                    updateConnectionState(.operational)
                }
                return
            } else if text.hasPrefix("PING_ACK:") {
                let lastIdStr = text.replacingOccurrences(of: "PING_ACK:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                let androidLastId = Int64(lastIdStr) ?? 0
                handlePingAck(androidLastId: androidLastId)
                return
            } else if text == "PING" {
                // 안드로이드가 PING을 보낸 경우 맞응답 전송 (상호 호환성)
                addLog("📥 Android PING 수신 → PING_ACK 전송")
                sendWriteCommand("PING_ACK:\(lastReceivedId)")
                sendBatteryStatus()
                updateConnectionState(.operational)
                lastPingTime = Date()
                return
            }
        }

        if data.count >= 10 && data[data.startIndex] == 0x57 && data[data.startIndex + 1] == 0x4E {
            handleChunk(data: data)
            return
        }

        // ② 일반 앱 알림 (JSON 문자열) 처리 (명세서 3-①)
        handlePayloadData(data)
    }

    // MARK: - 청크 재조립 (대용량 패킷 호환)

    private func handleChunk(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 10,
              bytes[0] == 0x57,
              bytes[1] == 0x4E else {
            addLog("BLE 청크 헤더가 올바르지 않습니다")
            return
        }

        let transferId =
            (UInt32(bytes[2]) << 24) |
            (UInt32(bytes[3]) << 16) |
            (UInt32(bytes[4]) << 8) |
            UInt32(bytes[5])
        let index = (Int(bytes[6]) << 8) | Int(bytes[7])
        let total = (Int(bytes[8]) << 8) | Int(bytes[9])
        guard total > 0, index < total else {
            addLog("BLE 청크 인덱스가 올바르지 않습니다")
            return
        }
        let id = String(transferId)

        if chunkBuffers[id] == nil || chunkTotals[id] != total {
            if chunkBuffers[id] == nil && chunkBuffers.count >= 32,
               let staleId = chunkBuffers.keys.first {
                chunkBuffers.removeValue(forKey: staleId)
                chunkTotals.removeValue(forKey: staleId)
            }
            chunkBuffers[id] = [:]
            chunkTotals[id] = total
        }
        chunkBuffers[id]?[index] = Array(bytes.dropFirst(10))

        addLog("청크 수신 \(index + 1)/\(total) id=\(id)")

        if chunkBuffers[id]?.count == total {
            reassembleChunks(id: id, total: total)
        }
    }

    private func reassembleChunks(id: String, total: Int) {
        guard let chunks = chunkBuffers[id],
              chunks.count == total else {
            addLog("청크 미완성 \(chunkBuffers[id]?.count ?? 0)/\(total)")
            return
        }

        var assembled = [UInt8]()
        for i in 0..<total {
            guard let chunk = chunks[i] else {
                addLog("청크 \(i) 누락")
                chunkBuffers.removeValue(forKey: id)
                chunkTotals.removeValue(forKey: id)
                return
            }
            assembled.append(contentsOf: chunk)
        }

        chunkBuffers.removeValue(forKey: id)
        chunkTotals.removeValue(forKey: id)

        addLog("청크 재조립 완료 id=\(id) 크기=\(assembled.count)바이트")

        handlePayloadData(Data(assembled))
    }

    // MARK: - 수신 페이로드 파싱 (JSON)

    private func handlePayloadData(_ data: Data) {
        var parsedPayload: NotificationPayload?

        // 1. JSONDecoder 시도
        if let payload = try? JSONDecoder().decode(NotificationPayload.self, from: data) {
            parsedPayload = payload
        }
        // 2. 유연한 JSONSerialization 시도 (필드 누락/형태 변형 대비)
        else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let id = (json["id"] as? NSNumber)?.int64Value ?? Int64(json["id"] as? Int ?? 0)
            let pkg = json["pkg"] as? String ?? ""
            let title = json["title"] as? String ?? ""
            let body = json["body"] as? String ?? ""
            if id != 0 || !pkg.isEmpty || !title.isEmpty || !body.isEmpty {
                parsedPayload = NotificationPayload(id: id, pkg: pkg, title: title, body: body)
            }
        }

        guard let payload = parsedPayload else {
            if let text = String(data: data, encoding: .utf8) {
                addLog("⚠️ 미확인 데이터: \(text.prefix(40))")
            }
            return
        }

        if payload.id > 0 && payload.id <= lastReceivedId {
            addLog("중복 알림 ID 무시 id=\(payload.id)")
            acknowledgeReceived(lastReceivedId)
            return
        }

        updateConnectionState(.operational)
        lastPingTime = Date()

        DispatchQueue.main.async {
            self.lastMessage = "\(payload.title): \(payload.body)"
        }
        addLog("📥 알림 [\(payload.pkg)]: \(payload.title) - \(payload.body) (ID: \(payload.id))")

        // 시스템/테스트 패키지가 아닐 때 저장 및 알림 발생
        if payload.pkg != "com.test" && payload.pkg != "com.watchnotify.system" && payload.pkg != "com.watchnotify.log" {
            let isCallPkg = payload.pkg == "com.lguplus.aicallagent" || payload.pkg == "com.uplus.ubizai"
            if isCallPkg && payload.body.contains("수신 전화") {
                lastCallPayload = payload
                recordCallEvent(status: "수신 전화", caller: payload.title)
                acknowledgeReceived(payload.id)
                sendIncomingCallNotification(payload: payload)
            } else {
                if payload.id > 0 {
                    saveMessage(payload: payload)
                } else {
                    addLog("DB ID가 없는 테스트/임시 알림; 알림만 표시")
                }
                sendLocalNotification(payload: payload)
            }
        } else {
            acknowledgeReceived(payload.id)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == characteristicUUID else { return }
        if failureLogWriteInFlight {
            failureLogWriteInFlight = false
            if let error {
                addLog("실패 로그 BLE 프레임 전송 오류: \(error.localizedDescription)")
                failureLogFrames.removeAll()
                currentFailureLogRecordId = nil
                currentFailureLogTransferId = nil
                failureLogRetryCount += 1
                sendQueuedControlWrites()
                if failureLogRetryCount < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.sendPendingFailureLog()
                    }
                }
            } else {
                sendNextFailureLogFrame()
            }
            return
        }

        guard controlWriteInFlight else {
            if let error {
                addFailureLog("BLE 쓰기 완료 오류: \(error.localizedDescription)")
            }
            return
        }
        controlWriteInFlight = false
        if let error {
            addFailureLog("BLE 제어 명령 쓰기 오류: \(error.localizedDescription)")
        }
        sendQueuedControlWrites()
        sendPendingFailureLog()
    }
}
