#if DEBUG
import Foundation
@preconcurrency import HealthKit

@MainActor
final class WorkoutSessionManager: NSObject {
    private let healthStore = HKHealthStore()
    private weak var bleManager: BLECentralManager?
    private var workoutSession: HKWorkoutSession?

    init(bleManager: BLECentralManager?) {
        self.bleManager = bleManager
        super.init()
    }

    func startIfNeeded() {
        guard HKHealthStore.isHealthDataAvailable() else {
            bleManager?.addFailureLog("테스트 운동 세션 시작 실패: HealthKit을 사용할 수 없음")
            return
        }
        guard workoutSession == nil else { return }
        beginWorkoutSession()
    }

    func endSession() {
        workoutSession?.end()
        bleManager?.addLog("🏃 테스트 운동 세션 종료 요청")
    }

    private func beginWorkoutSession() {
        guard workoutSession == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            session.delegate = self
            workoutSession = session
            bleManager?.addLog("🏃 운동 데이터 수집/저장 없이 테스트 운동 세션 시작 요청")
            session.startActivity(with: Date())
        } catch {
            bleManager?.addFailureLog("테스트 운동 세션 생성 실패: \(error.localizedDescription)")
        }
    }
}

extension WorkoutSessionManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.bleManager?.addLog("🏃 운동 세션 상태 변경: \(fromState.rawValue) → \(toState.rawValue)")
            if toState == .ended {
                self.workoutSession = nil
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.bleManager?.addFailureLog("운동 세션 실패: \(message)")
            self?.workoutSession = nil
        }
    }
}
#endif
