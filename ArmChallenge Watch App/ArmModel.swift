//
//  ArmModel.swift
//  ArmChallenge Watch App
//
//  Created by Edward Arenberg on 4/18/23.
//

import Foundation
import WatchKit
import HealthKit
import CoreMotion

class SWRuntime : NSObject, WKExtendedRuntimeSessionDelegate {
  
  func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
      // Track when your session starts.
    print("Start Extended")
  }

  func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
      // Finish and clean up any tasks before the session ends.
    print("Expire Extended")
  }
      
  func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
      // Track when your session ends.
      // Also handle errors here.
    print("Invalidate Extended")
  }
}


enum ArmState {
  case idle, active, end
}

struct ArmRound : Hashable {
  static var maxMotion = 1.0
  let startTime : TimeInterval
  var duration : TimeInterval = 0
  var motion = 0.0
  var over : Bool { motion > ArmRound.maxMotion }

  mutating func move(by amount: Double) {
    motion += amount
  }
  mutating func stop(at: Date) {
    duration = at.timeIntervalSince1970 - startTime
  }
}

final class ArmViewModel : NSObject, ObservableObject {
  @Published private(set) var state : ArmState = .idle
  @Published private(set) var heartRate: Double = 0
  @Published private(set) var activeEnergy: Double = 0

  private(set) var rounds = [ArmRound]()
  private(set) var round = 0
  private var timer : Timer?
  private var ttimer : Timer?
  private var roundStart : TimeInterval = 0
  @Published private(set) var roundTime : TimeInterval = 0

  private let healthStore = HKHealthStore()
  private var session: HKWorkoutSession?
  private var builder: HKLiveWorkoutBuilder?
  private let configuration = HKWorkoutConfiguration()

  private var rts = WKExtendedRuntimeSession()
  private let swrt = SWRuntime()
  private var motionManager = CMMotionManager()

  override init() {
    motionManager.accelerometerUpdateInterval = 0.1
    rts.delegate = swrt
    super.init()
  }
  
  // Request authorization to access HealthKit.
  func requestAuthorization() {
    // The quantity type to write to the health store.
    let typesToShare: Set = [
      HKQuantityType.workoutType()
    ]
    
    // The quantity types to read from the health store.
    let typesToRead: Set = [
      HKQuantityType.quantityType(forIdentifier: .heartRate)!,
      HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
      HKObjectType.activitySummaryType()
    ]
    
    // Request authorization for those quantity types.
    healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { (success, error) in
      // Handle error.
    }
  }
  
  func updateForStatistics(_ statistics: HKStatistics?) {
    guard let statistics = statistics else { return }
    
    DispatchQueue.main.async {
      switch statistics.quantityType {
      case HKQuantityType.quantityType(forIdentifier: .heartRate):
        let heartRateUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        self.heartRate = statistics.mostRecentQuantity()?.doubleValue(for: heartRateUnit) ?? 0
      case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
        let energyUnit = HKUnit.kilocalorie()
        self.activeEnergy = statistics.sumQuantity()?.doubleValue(for: energyUnit) ?? 0
      default:
        return
      }
    }
  }
  

  
  var motion : Double {
    rounds.last?.motion ?? 0.0
  }

  
  func reset() {
    state = .idle
    round = 0
    rounds = []
    roundTime = 0
  }
  
  func start() {
    if state == .active { return }
    if state == .end { reset() }
    state = .active
    round = 0
    roundStart = Date().timeIntervalSince1970
    rounds.append(ArmRound(startTime: roundStart))

    if rts.state == .notStarted {
      rts.start()
    } else if rts.state == .invalid {
      rts = WKExtendedRuntimeSession()
      rts.start()
    }

    configuration.activityType = .other

    session = try? HKWorkoutSession(healthStore: healthStore, configuration: configuration)
    builder = session?.associatedWorkoutBuilder()
    builder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                  workoutConfiguration: configuration)

    session?.delegate = self
    builder?.delegate = self
    
    builder?.dataSource?.enableCollection(for: HKQuantityType(.heartRate), predicate: nil)

    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
      self.roundTime = Date().timeIntervalSince1970 - self.rounds[self.round].startTime
    }

    let startDate = Date()
    session?.startActivity(with: startDate)
    session?.beginNewActivity(configuration: configuration, date: startDate, metadata: nil)
    Task {
      try? await builder?.beginCollection(at: startDate)
    }

#if targetEnvironment(simulator)
    ttimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
      self.rounds[self.round].move(by: 0.05)
      self.objectWillChange.send()
      if self.rounds[self.round].motion >= 1.0 {
        self.end()
      }
    }
#else
    motionManager.startAccelerometerUpdates(to: OperationQueue.current!) { (data, error) in
      if let data {
        let mag = abs(sqrt(data.acceleration.x.magnitudeSquared + data.acceleration.y.magnitudeSquared + data.acceleration.z.magnitudeSquared) - 1.0)
        let val = min(mag,0.1)  // clamp magnitude
        let oldMotion = self.rounds[self.round].motion
        self.rounds[self.round].move(by: val)
        let newMotion = self.rounds[self.round].motion
        if Int(newMotion * 10) > Int(oldMotion * 10) {
          print("motion = \(newMotion)")
        }
        if newMotion >= 1.0 {
          self.end()
        }
        self.objectWillChange.send()
      }
    }
#endif

  }
  
  func end() {
    if round < 2 {
      let dt = Date()
      rounds[round].stop(at: dt)
      rounds.append(ArmRound(startTime: dt.timeIntervalSince1970))
      round += 1
      session?.beginNewActivity(configuration: configuration, date: dt, metadata: nil)

    } else {
      if state != .active { return }
      timer?.invalidate()
      ttimer?.invalidate()
      motionManager.stopAccelerometerUpdates()
      if rts.state == .running {
        rts.invalidate()
      }
      state = .end
      let dt = Date()
      rounds[round].stop(at: dt)
      session?.endCurrentActivity(on: dt)
      session?.end()
    }
  }

}

extension ArmViewModel: HKWorkoutSessionDelegate {
  func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                      from fromState: HKWorkoutSessionState, date: Date) {
//    DispatchQueue.main.async {
//      self.running = toState == .running
//    }
    
    print("Workout Session State", String(describing: toState))
    
    // Wait for the session to transition states before ending the builder.
    if toState == .ended {
      print("Workout Session Ended")
      
      Task { @MainActor in
        do {
          let d = session?.currentActivity.endDate ?? Date()
          try await builder?.endCollection(at: d)
          let hkworkout = try await builder?.finishWorkout()
          print(hkworkout!)
          
          print("Saved to HealthKit")
        } catch {
          print("End Error", error.localizedDescription)
        }
      }
    }
  }
  func workoutSession(_ workoutSession: HKWorkoutSession, didBeginActivityWith workoutConfiguration: HKWorkoutConfiguration, date: Date) {
    print("Activity Start: \(workoutConfiguration.debugDescription) \(date.formatted())")
  }
  func workoutSession(_ workoutSession: HKWorkoutSession, didEndActivityWith workoutConfiguration: HKWorkoutConfiguration, date: Date) {
    print("Activity End: \(workoutConfiguration.debugDescription) \(date.formatted())")
  }
  
  func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
    
  }
}

extension ArmViewModel : HKLiveWorkoutBuilderDelegate {
  func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
    
  }
  
  func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
    for type in collectedTypes {
      guard let quantityType = type as? HKQuantityType else {
        return // Nothing to do.
      }
      
      let statistics = workoutBuilder.statistics(for: quantityType)
      
      // Update the published values.
      updateForStatistics(statistics)
    }
  }
}

extension Double {
  var hmss : (hours: Int, minutes: Int, seconds: Int) {
    if self.isNaN || self.isInfinite { return (-1, -1, -1) }
    let secs = Int(floor(self))
    let hours = secs / 3600
    let minutes = (secs % 3600) / 60
    let seconds = (secs % 3600) % 60
    return (hours, minutes, seconds)
  }
  var timeStringMS : String {
    let t = self.hmss
    var s = ""
    if t.hours > 0 { s = String(format: "%02d:%02d", t.1, t.2) }
    else { s = String(format: "%d:%02d", t.1, t.2) }
    return s
  }
}
