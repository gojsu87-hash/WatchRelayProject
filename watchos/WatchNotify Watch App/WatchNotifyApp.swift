// WatchNotifyApp.swift
// init() 시점 즉시 싱글톤 및 ModelContext 주입 보완 코드

import SwiftUI
import SwiftData
import UserNotifications
#if os(watchOS)
import WatchKit
#endif

@main
struct WatchNotifyApp: App {

    #if os(watchOS)
    @WKApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    private let bleManager: BLECentralManager
    private let sharedModelContainer: ModelContainer

    init() {
        // 1. ModelContainer 생성
        let schema = Schema([WatchMessage.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            self.sharedModelContainer = container
        } catch {
            fatalError("ModelContainer 생성 실패: \(error)")
        }

        // 2. BLECentralManager 생성 및 즉시 싱글톤/Context 주입 (onAppear를 기다리지 않음)
        let manager = BLECentralManager()
        manager.modelContext = self.sharedModelContainer.mainContext
        BLEManagerStore.shared.manager = manager
        self.bleManager = manager
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bleManager)
                .onAppear {
                    // 알림 권한 요청
                    UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound, .badge]
                    ) { granted, _ in
                        print("[WatchNotify] 알림 권한: \(granted)")
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {

    private var bleManager: BLECentralManager? {
        return BLEManagerStore.shared.manager
    }

    // MARK: - 앱 생명주기

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        bleManager?.addLog("📱 앱 시작")
        scheduleNextBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        bleManager?.addLog("🟢 포그라운드 활성화")
        bleManager?.handleAppActive()
    }

    func applicationWillResignActive() {
        bleManager?.addLog("🟡 포그라운드 비활성화")
    }

    func applicationDidEnterBackground() {
        bleManager?.addLog("⚫ 백그라운드 진입")
        scheduleNextBackgroundRefresh()
    }

    // 포그라운드 상태에서도 로컬 알림 배너 및 소리 출력
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Background Tasks

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refreshTask as WKApplicationRefreshBackgroundTask:
                bleManager?.addLog("🔄 Background Refresh 실행")
                scheduleNextBackgroundRefresh()
                if let manager = bleManager {
                    if manager.connectionState == .offline {
                        bleManager?.addLog("🔄 Background Refresh - 재연결 시도")
                        manager.startScan()
                    } else {
                        bleManager?.addLog("🔄 Background Refresh - 연결 정상")
                        manager.sendPing()
                        manager.sendBatteryStatus()
                    }
                }
                refreshTask.setTaskCompletedWithSnapshot(false)

            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                bleManager?.addLog("📸 Snapshot Refresh 실행")
                if let manager = bleManager, manager.connectionState == .offline {
                    manager.startScan()
                }
                snapshotTask.setTaskCompletedWithSnapshot(true)

            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    // MARK: - Background Refresh 예약

    private func scheduleNextBackgroundRefresh() {
        let targetDate = Date().addingTimeInterval(12 * 60)
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: targetDate,
            userInfo: nil
        ) { error in
            if let error {
                self.bleManager?.addLog("❌ Background Refresh 예약 실패: \(error)")
            }
        }
    }
}

// MARK: - BLEManagerStore

class BLEManagerStore {
    static let shared = BLEManagerStore()
    var manager: BLECentralManager?
    private init() {}
}
