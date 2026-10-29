// BLECentralManager.swift
// WatchNotify 안드로이드 BLE 프로토콜 연동 규격 최적화 코드

import Foundation
import CoreBluetooth
import UserNotifications
import WatchKit
import SwiftData
import WidgetKit
import HealthKit

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
class BLECentralManager: NSObject, HKWorkoutSessionDelegate {

    // MARK: - 상수
    private enum Constants {
        static let reconnectTimerSec: TimeInterval = 45    // 주기적 재스캔 간격 (오프라인일 때)
        static let scanTimeoutSec: TimeInterval = 15       // 스캔 타임아웃
        static let pingIntervalSec: TimeInterval = 60      // 하트비트 PING 간격 (연결 중일 때)
        static let maxRetryCount: Int = 3                  // 연속 재시도 실패 한도
    }

    // MARK: - Public State
    var connectionState: ConnectionState = .offline
    var lastMessage = "대기 중..."
    var statusLog: [String] = []
    var lastReceivedTime: Date? = nil
    var lastPingTime: Date? = nil
    var disconnectReason: String = "연결 대기 중"
    var lastDisconnectReason: String = ""
    var isScanning = false

    var isConnected: Bool {
        connectionState == .connected || connectionState == .operational
    }

    var isFullyOperational: Bool {
        connectionState == .operational
    }

    // MARK: - HealthKit 백그라운드 세션
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?

    // MARK: - Private
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?

    private var reconnectTimer: Timer?
    private var scanTimeoutTimer: Timer?
    private var pingTimer: Timer?
    private var retryWorkItem: DispatchWorkItem?
    private var currentMTU: Int = 20

    private var chunkBuffers: [String: [Int: [UInt8]]] = [:]
    private var chunkTotals: [String: Int] = [:]
    private var lastCallPayload: NotificationPayload?
    private var lastReceivedId: Int64 = 0
    private var lastConnectedTime: Date? = nil
    private var retryCount: Int = 0
    private var isConnecting = false

    // 최근 수신된 알림 기록 (단시간 동일 알림 중복 방지용)
    private struct RecentNotification {
        let pkg: String
        let title: String
        let body: String
        let timestamp: Date
    }
    private var recentNotifications: [RecentNotification] = []

    // MARK: - SwiftData
    var modelContext: ModelContext?

    // MARK: - CBUUID 상수 (프로토콜 명세서 2번)
    let serviceUUID = CBUUID(string: "0000180D-0000-1000-8000-00805f9b34fb")
    let characteristicUUID = CBUUID(string: "00002A37-0000-1000-8000-00805f9b34fb")
    private let callNotificationId = "incoming_call"

    // MARK: - Init
    override init() {
        super.init()

        // 1. 마지막 수신 ID 복원 (13자리 타임스탬프 형식만 신뢰, 고정 sbn.id 값은 0으로 리셋)
        let rawLastId = UserDefaults.standard.object(forKey: "lastReceivedId")
        var savedId: Int64 = 0
        if let num = rawLastId as? NSNumber {
            savedId = num.int64Value
        } else if let intVal = rawLastId as? Int64 {
            savedId = intVal
        }
        if savedId > 1_000_000_000_000 {
            lastReceivedId = savedId
        } else {
            lastReceivedId = 0
            UserDefaults.standard.set(0, forKey: "lastReceivedId")
        }

        // 2. 배터리 모니터링 활성화
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true

        // 3. 백그라운드 상주를 위한 HealthKit 권한 요청
        requestHealthAuthorization()

        // 4. CoreBluetooth 초기화
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.kang.watchnotify.central",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )

        addLog("BLE 초기화 완료 lastId=\(lastReceivedId)")
        startReconnectTimer()
    }

    // MARK: - HealthKit 백그라운드 세션 로직

    private func requestHealthAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let typesToShare: Set = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: typesToShare, read: nil) { success, error in
            if success {
                DispatchQueue.main.async {
                    self.startBackgroundWorkoutSession()
                }
            } else if let error = error {
                self.addLog("⚠️ HealthKit 권한 실패: \(error.localizedDescription)")
            }
        }
    }

    func startBackgroundWorkoutSession() {
        if let session = workoutSession, session.state == .running {
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .indoor

        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            workoutSession?.delegate = self
            workoutSession?.startActivity(with: Date())
            addLog("⚡ 백그라운드 상주 세션 가동 완료!")
        } catch {
            addLog("⚠️ 백그라운드 세션 생성 실패: \(error.localizedDescription)")
        }
    }

    // MARK: - 상태 업데이트

    private func updateConnectionState(_ state: ConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = state
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

    // MARK: - 타이머 관리

    private func startReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.reconnectTimerSec,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            guard connectionState == .offline,
                  centralManager.state == .poweredOn,
                  !isScanning,
                  connectedPeripheral == nil else { return }
            addLog("타이머 재스캔")
            startScan()
        }
    }

    private func startScanTimeout() {
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.scanTimeoutSec,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            if isScanning {
                addLog("스캔 타임아웃 → 중단")
                stopScan()
            }
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.pingIntervalSec,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            guard self.isConnected else { return }
            self.sendPing()
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func scheduleScan(after delay: TimeInterval, reason: String) {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard centralManager.state == .poweredOn else { return }
            guard connectionState == .offline else { return }
            guard connectedPeripheral == nil else { return }
            guard !isScanning, !isConnecting else { return }
            addLog("🔍 재스캔 시작: \(reason)")
            startScan()
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - 공개 메서드

    func handleAppActive() {
        addLog("🟢 앱 활성화")
        if connectionState == .offline {
            startScan()
        } else if isConnected {
            sendPing()
            sendBatteryStatus()
        }
    }

    func reset() {
        addLog("전체 초기화")
        retryWorkItem?.cancel()
        scanTimeoutTimer?.invalidate()
        reconnectTimer?.invalidate()
        stopPingTimer()

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
            self.connectionState = .offline
            self.isScanning = false
            self.disconnectReason = "초기화 중..."
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
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
        guard !isScanning, !isConnecting, connectedPeripheral == nil else { return }

        isScanning = true
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        startScanTimeout()
        addLog("스캔 시작")
    }

    func stopScan() {
        scanTimeoutTimer?.invalidate()
        centralManager.stopScan()
        isScanning = false
    }

    func disconnect() {
        retryWorkItem?.cancel()
        reconnectTimer?.invalidate()
        scanTimeoutTimer?.invalidate()
        stopPingTimer()
        isConnecting = false
        if let peripheral = connectedPeripheral,
           centralManager.state == .poweredOn {
            centralManager.cancelPeripheralConnection(peripheral)
        }
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

        // 명세서 2번/5번: Write 지원 시 withResponse 우선 사용
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    /// 1. PING 전송 (워치 → 안드로이드)
    func sendPing() {
        sendWriteCommand("PING")
        addLog("📤 PING 전송")
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
        updateConnectionState(.operational)
        DispatchQueue.main.async { self.disconnectReason = "" }
        addLog("✅ PING_ACK 수신 (Android lastId=\(androidLastId), Watch lastId=\(lastReceivedId))")

        // 1. 배터리 상태 전송
        sendBatteryStatus()

        // 2. 주기적 PING 타이머 가동
        startPingTimer()

        // 3. 누락 알림 확인 및 재전송 요청 (13자리 타임스탬프인 경우에만 누락 재전송 판단)
        if androidLastId > 1_000_000_000_000 && androidLastId > lastReceivedId {
            addLog("🔄 누락 알림 감지 (\(lastReceivedId) < \(androidLastId)) → RESEND 요청")
            requestResend(lastId: lastReceivedId)
        }
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
        cancelCallNotifications()
        for i in 0..<10 {
            let content = UNMutableNotificationContent()
            content.title = "📞 전화"
            content.body = "\(payload.title): 수신 전화"
            content.sound = .defaultCritical
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: Double(i) * 3.0 + 0.1,
                repeats: false
            )
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "\(callNotificationId)_\(i)",
                    content: content,
                    trigger: trigger
                )
            )
        }
        WKInterfaceDevice.current().play(.notification)
        addLog("수신 전화 알림 예약")
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
        let ids = (0..<10).map { "\(callNotificationId)_\($0)" }
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
        case "CALL_ANSWERED":
            addLog("📞 통화 연결됨 (알림 중단)")
            cancelCallNotifications()
        case "CANCEL_CALL":
            addLog("📞 통화 종료됨")
            cancelCallNotifications()
        case "MISSED_CALL":
            addLog("📞 부재중 전화 발생")
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
        default:
            break
        }
    }

    // MARK: - DB 저장 (실제 앱 메시지만 저장)

    private func saveMessage(payload: NotificationPayload) {
        if payload.pkg == "com.test" || payload.pkg == "com.watchnotify.system" || payload.pkg == "com.watchnotify.log" {
            return
        }

        DispatchQueue.main.async {
            guard let context = self.modelContext else { return }

            // 13자리 타임스탬프 ID인 경우에만 DB 상 고유 ID 중복 체크 (RESEND 재전송 대비)
            if payload.id > 1_000_000_000_000 {
                let id = payload.id
                let duplicateCheck = FetchDescriptor<WatchMessage>(
                    predicate: #Predicate { $0.id == id }
                )
                if let existing = try? context.fetch(duplicateCheck), !existing.isEmpty {
                    self.addLog("중복 저장 방지 id=\(id)")
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
                if payload.id > 1_000_000_000_000 && payload.id > self.lastReceivedId {
                    self.lastReceivedId = payload.id
                    UserDefaults.standard.set(payload.id, forKey: "lastReceivedId")
                }
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

    private func reinitializeCentralManager() {
        addLog("CBCentralManager 재초기화")
        centralManager.delegate = nil
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "com.kang.watchnotify.central",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
        )
        retryCount = 0
        isConnecting = false
        connectedPeripheral = nil
        notifyCharacteristic = nil
    }

    // MARK: - HKWorkoutSessionDelegate (백그라운드 유지 전용)

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended || toState == .stopped || toState == .paused {
            self.workoutSession = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.startBackgroundWorkoutSession()
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        self.workoutSession = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.startBackgroundWorkoutSession()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentralManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            addLog("블루투스 켜짐")
            DispatchQueue.main.async { self.disconnectReason = "갤럭시 검색 중..." }
            if let peripheral = connectedPeripheral,
               peripheral.state == .connected {
                updateConnectionState(.connected)
                peripheral.delegate = self
                peripheral.discoverServices([serviceUUID])
                addLog("복원 peripheral 재발견 시도")
            } else {
                startScan()
            }
        case .poweredOff:
            addLog("블루투스 꺼짐")
            stopPingTimer()
            updateConnectionState(.offline)
            DispatchQueue.main.async { self.disconnectReason = "블루투스 꺼짐" }
        case .unauthorized:
            addLog("블루투스 권한 없음")
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
                notifyCharacteristic = nil
                if peripheral.state == .connected {
                    updateConnectionState(.connected)
                    addLog("복원 peripheral 보관")
                } else if central.state == .poweredOn {
                    central.connect(peripheral, options: nil)
                    addLog("복원 peripheral 재연결 시도")
                }
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        stopScan()
        guard !isConnecting else { return }
        if let existing = connectedPeripheral, existing != peripheral {
            central.cancelPeripheralConnection(existing)
        }
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self
        isConnecting = true
        central.connect(peripheral, options: nil)
        DispatchQueue.main.async { self.disconnectReason = "갤럭시 발견 - 연결 중..." }
        addLog("발견 RSSI=\(RSSI) → 연결 시도")
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        retryWorkItem?.cancel()
        isConnecting = false
        retryCount = 0
        lastConnectedTime = Date()
        updateConnectionState(.connected)
        DispatchQueue.main.async { self.disconnectReason = "서비스 검색 중..." }

        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        currentMTU = mtu
        addLog("연결 성공 MTU: \(mtu)바이트 → 서비스 검색")

        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnecting = false
        stopPingTimer()
        updateConnectionState(.offline)
        let reason = "연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류")"
        DispatchQueue.main.async {
            self.disconnectReason = reason
            self.lastDisconnectReason = reason
        }
        addLog("연결 실패: \(error?.localizedDescription ?? "")")

        retryCount += 1

        if retryCount >= Constants.maxRetryCount {
            addLog("\(Constants.maxRetryCount)회 실패 → 재초기화")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.reinitializeCentralManager()
                self.retryCount = 0
            }
        } else {
            let delay = pow(2.0, Double(retryCount))
            addLog("재시도 \(retryCount)회 → \(Int(delay))초 후")
            scheduleScan(after: delay, reason: "연결 실패 후 재스캔")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        notifyCharacteristic = nil
        isConnecting = false
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
            reason = "정상종료 (갤럭시가끊음)"
        }

        DispatchQueue.main.async {
            self.disconnectReason = reason
            self.lastDisconnectReason = reason
            WKInterfaceDevice.current().play(.failure)
        }

        lastConnectedTime = nil
        lastPingTime = nil
        addLog("연결 끊김: \(reason)")

        retryWorkItem?.cancel()
        connectedPeripheral = nil

        DispatchQueue.main.async { self.disconnectReason = "재연결 중..." }
        scheduleScan(after: 2.0, reason: "끊김 후 재스캔")
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentralManager: CBPeripheralDelegate {

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error {
            addLog("서비스 발견 실패: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            addLog("특성 발견 실패: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == characteristicUUID {
            notifyCharacteristic = characteristic

            let supportsIndicate = characteristic.properties.contains(.indicate)
            let supportsNotify = characteristic.properties.contains(.notify)

            if supportsIndicate || supportsNotify {
                peripheral.setNotifyValue(true, for: characteristic)
                addLog("구독 신청 (\(supportsIndicate ? "Indicate" : "Notify"))")
            } else {
                addLog("⚠️ Notify/Indicate 미지원")
            }

            // 연결 및 특성 발견 즉시 PING 전송 (명세서 5번 샘플 코드 준수)
            sendPing()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            addLog("구독 상태 갱신 실패: \(error.localizedDescription)")
            return
        }
        addLog("구독 활성 상태: \(characteristic.isNotifying)")
        if characteristic.isNotifying {
            // 구독 상태 확정 후 PING 전송 (핸드셰이크 보장)
            sendPing()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        addLog("서비스 변경 → 재발견")
        notifyCharacteristic = nil
        peripheral.discoverServices([serviceUUID])
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

        // 수신 데이터 텍스트 파싱
        if let rawText = String(data: data, encoding: .utf8) {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

            // ① 전화 및 신호 처리 (명세서 3-②)
            if text == "CALL_ANSWERED" || text == "CANCEL_CALL" || text == "MISSED_CALL" {
                handleSignal(text)
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
                updateConnectionState(.operational)
                lastPingTime = Date()
                return
            } else if rawText.hasPrefix("CHUNK:") || rawText.hasPrefix("CHUNK_END:") {
                handleChunk(data: data)
                return
            }
        }

        // ② 일반 앱 알림 (JSON 문자열) 처리 (명세서 3-①)
        handlePayloadData(data)
    }

    // MARK: - 청크 재조립 (대용량 패킷 호환)

    private func handleChunk(data: Data) {
        guard let signal = String(data: data, encoding: .utf8) else { return }

        let isLast = signal.hasPrefix("CHUNK_END:")
        let prefix = isLast ? "CHUNK_END:" : "CHUNK:"
        let body = String(signal.dropFirst(prefix.count))

        let parts = body.components(separatedBy: ":")
        guard parts.count >= 4,
              let index = Int(parts[1]),
              let total = Int(parts[2]) else {
            addLog("청크 헤더 파싱 실패: \(body.prefix(30))")
            return
        }

        let id = parts[0]

        let headerStr = "\(prefix)\(id):\(parts[1]):\(parts[2]):"
        guard let headerData = headerStr.data(using: .utf8) else { return }
        let chunkData = data.dropFirst(headerData.count)

        if chunkBuffers[id] == nil {
            chunkBuffers[id] = [:]
            chunkTotals[id] = total
        }
        chunkBuffers[id]?[index] = Array(chunkData)

        addLog("청크 수신 \(index + 1)/\(total) id=\(id)")

        if isLast {
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

        // 중복 수신 방지 처리
        let now = Date()
        recentNotifications.removeAll { now.timeIntervalSince($0.timestamp) > 3.0 }

        // 1) 최근 3초 내 동일한 내용(pkg, title, body)이 수신된 경우 BLE 중복 패킷으로 간주하여 무시
        if recentNotifications.contains(where: { $0.pkg == payload.pkg && $0.title == payload.title && $0.body == payload.body }) {
            addLog("중복 패킷 무시 (3초 내 동일): [\(payload.pkg)] \(payload.title)")
            return
        }

        // 2) 13자리 타임스탬프 ID인 경우에만 ID 순서 기반 중복 검사 (안드로이드 sbn.id 고정값 예: 19077은 무시하지 않음)
        if payload.id > 1_000_000_000_000 && payload.id <= lastReceivedId {
            addLog("타임스탬프 중복 무시 id=\(payload.id)")
            return
        }

        // 최근 수신 목록에 등록
        recentNotifications.append(RecentNotification(pkg: payload.pkg, title: payload.title, body: payload.body, timestamp: now))

        updateConnectionState(.operational)
        lastPingTime = Date()

        DispatchQueue.main.async {
            self.lastMessage = "\(payload.title): \(payload.body)"
        }
        addLog("📥 알림 [\(payload.pkg)]: \(payload.title) - \(payload.body) (ID: \(payload.id))")

        // 시스템/테스트 패키지가 아닐 때 저장 및 알림 발생
        if payload.pkg != "com.test" && payload.pkg != "com.watchnotify.system" && payload.pkg != "com.watchnotify.log" {
            saveMessage(payload: payload)
            let isCallPkg = payload.pkg == "com.lguplus.aicallagent" || payload.pkg == "com.uplus.ubizai"
            if isCallPkg && payload.body.contains("수신 전화") {
                lastCallPayload = payload
                sendIncomingCallNotification(payload: payload)
            } else {
                sendLocalNotification(payload: payload)
            }
        } else if payload.id > 1_000_000_000_000 && payload.id > lastReceivedId {
            lastReceivedId = payload.id
            UserDefaults.standard.set(payload.id, forKey: "lastReceivedId")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            addLog("쓰기 완료 오류: \(error.localizedDescription)")
        }
    }
}
