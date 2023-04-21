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

/// Extended Runtime delegate.  Don't really use it for anything.
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

/// Track workout state
enum ArmState {
  case idle, active, end
}

/// A round of the workout
struct ArmRound : Hashable {
  /// When round started
  let startTime : TimeInterval
  /// Duration, calculated at end of round
  var duration : TimeInterval = 0
  /// Accumulated acceleration during the round.  0 -> 1
  var motion = 0.0

  mutating func move(by amount: Double) {
    motion += amount
  }
  mutating func stop(at: Date) {
    duration = at.timeIntervalSince1970 - startTime
  }
}

/**
Workout View Model
 
Subclass of NSObject so we can be an HKWorkoutSession delegate.
*/
final class ArmViewModel : NSObject, ObservableObject {
  @Published private(set) var state : ArmState = .idle
  @Published private(set) var heartRate: Double = 0
  @Published private(set) var activeEnergy: Double = 0

  private(set) var rounds = [ArmRound]()
  private(set) var round = 0
  private var timer : Timer?
  /// For driving the workout in the simulator, where there's no motion.
  private var ttimer : Timer?
  @Published private(set) var roundTime : TimeInterval = 0

  private let healthStore = HKHealthStore()
  private var session: HKWorkoutSession?
  private var builder: HKLiveWorkoutBuilder?
  private let configuration = HKWorkoutConfiguration()

  /// Extended Runtime to keep the app active
  private var rts = WKExtendedRuntimeSession()
  private let swrt = SWRuntime()
  private var motionManager = CMMotionManager()

  override init() {
    motionManager.accelerometerUpdateInterval = 0.1
    rts.delegate = swrt
    super.init()
  }
  
  /// Request authorization to access HealthKit.
  func requestAuthorization() {
    /// The quantity type to write to the health store.
    let typesToShare: Set = [
      HKQuantityType.workoutType()
    ]
    
    /// The quantity types to read from the health store.
    let typesToRead: Set = [
      HKQuantityType.quantityType(forIdentifier: .heartRate)!,
      HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!, // Not used in the app
      HKObjectType.activitySummaryType()
    ]
    
    // Request authorization for those quantity types.
    healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { (success, error) in
      // Handle error.
    }
  }
  
  /// Receive statistics from the workout builder, and extract what we need.
  func updateForStatistics(_ statistics: HKStatistics?) {
    guard let statistics = statistics else { return }
    
    DispatchQueue.main.async {
      switch statistics.quantityType {
      case HKQuantityType.quantityType(forIdentifier: .heartRate):
        let heartRateUnit = HKUnit.count().unitDivided(by: HKUnit.minute()) // Beats per minute
        self.heartRate = statistics.mostRecentQuantity()?.doubleValue(for: heartRateUnit) ?? 0
      case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
        let energyUnit = HKUnit.kilocalorie()
        self.activeEnergy = statistics.sumQuantity()?.doubleValue(for: energyUnit) ?? 0
      default:
        return
      }
    }
  }
  

  /// Current motion value
  var motion : Double {
    rounds.last?.motion ?? 0.0
  }

  /// Reset info to start new workout
  func reset() {
    state = .idle
    round = 0
    rounds = []
    roundTime = 0
  }

  /// Start the workout
  func start() {
    if state == .active { return }  // Already active
    if state == .end { reset() }  // Reset to start a new workout
    state = .active
    round = 0
    rounds.append(ArmRound(startTime: Date().timeIntervalSince1970))

    // Start our extended runtime
    if rts.state == .notStarted {
      rts.start()
    } else if rts.state == .invalid {
      rts = WKExtendedRuntimeSession()
      rts.start()
    }

    // Configure / setup the workout
    configuration.activityType = .other // No HKActivityType matches holding your arm still

    // Create the workout session
    session = try? HKWorkoutSession(healthStore: healthStore, configuration: configuration)
    // Grab a reference to the workout builder
    builder = session?.associatedWorkoutBuilder()
    // Connect the builder to the HealthKit storage
    builder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                  workoutConfiguration: configuration)

    session?.delegate = self  // Track session state so we can act when it ends
    builder?.delegate = self  // Watch for new sensor data (i.e. heart rate)

    // Enable collection of heart rate data
    builder?.dataSource?.enableCollection(for: HKQuantityType(.heartRate), predicate: nil)

    // Timer to measure round duration
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
      self.roundTime = Date().timeIntervalSince1970 - self.rounds[self.round].startTime
    }

    let startDate = Date()
    // Start the workout session
    session?.startActivity(with: startDate)
    // Start the first workout activity
    session?.beginNewActivity(configuration: configuration, date: startDate, metadata: nil)
    Task {
      // Start collection of data and begin building the workout
      try? await builder?.beginCollection(at: startDate)
    }

    // Create a timer to drive the workout in the simulator, where there's no actual motion
#if targetEnvironment(simulator)
    ttimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
      self.rounds[self.round].move(by: 0.05)
      self.objectWillChange.send()
      if self.rounds[self.round].motion >= 1.0 {
        self.end()
      }
    }
#else
    // Start monitoring the device's accelerometer
    motionManager.startAccelerometerUpdates(to: OperationQueue.current!) { (data, error) in
      if let data {
        // Calculate acceleration magnitude.  Remove gravity, which has a constant 1.0 acceleration.
        let mag = abs(sqrt(data.acceleration.x.magnitudeSquared + data.acceleration.y.magnitudeSquared + data.acceleration.z.magnitudeSquared) - 1.0)
        let val = min(mag,0.1)  // clamp magnitude, so large motions don't immediately end workout
        let oldMotion = self.rounds[self.round].motion
        self.rounds[self.round].move(by: val)
        let newMotion = self.rounds[self.round].motion
        // Just using old and new motion values to monitor what's happening - don't need this for the app
        if Int(newMotion * 10) > Int(oldMotion * 10) {
          print("motion = \(newMotion)")
        }
        // End the round when accumulated acceleration reaches 1.0
        if newMotion >= 1.0 {
          self.end()
        }
        self.objectWillChange.send()
      }
    }
#endif

  }
  
  /// End the round / workout activity
  func end() {
    if state != .active { return }

    // Do 3 rounds / activities for the workout
    if round < 2 {
      let dt = Date()
      rounds[round].stop(at: dt)  // End the existing round
      // Start the next round
      rounds.append(ArmRound(startTime: dt.timeIntervalSince1970))
      round += 1
      // End the existing workout activity and start a new one
      session?.beginNewActivity(configuration: configuration, date: dt, metadata: nil)

    } else {
      // End the workout, stop collecting data
      timer?.invalidate()
      ttimer?.invalidate()
      motionManager.stopAccelerometerUpdates()
      if rts.state == .running {
        rts.invalidate()
      }
      state = .end
      let dt = Date()
      rounds[round].stop(at: dt)
      // End the current workout activity
      session?.endCurrentActivity(on: dt)
      // End the workout session - triggers a session state change
      session?.end()
    }
  }

}

extension ArmViewModel: HKWorkoutSessionDelegate {
  func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                      from fromState: HKWorkoutSessionState, date: Date) {

    print("Workout Session State", String(describing: toState))
    
    // Wait for the session to transition states before ending the builder.
    if toState == .ended {
      print("Workout Session Ended")
      
      Task { @MainActor in
        do {
          let d = session?.currentActivity.endDate ?? Date()
          try await builder?.endCollection(at: d) // Stop collecting data and building the workout
          let hkworkout = try await builder?.finishWorkout()  // Create workout and save to HealthKit
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
      // Received new sensor data from workout builder
      let statistics = workoutBuilder.statistics(for: quantityType)
      
      // Update the published values.
      updateForStatistics(statistics)
    }
  }
}

// Convience vars to create a time string
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
