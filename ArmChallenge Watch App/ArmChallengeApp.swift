//
//  ArmChallengeApp.swift
//  ArmChallenge Watch App
//
//  Created by Edward Arenberg on 4/18/23.
//

import SwiftUI
import HealthKit

@main
struct ArmChallenge_Watch_AppApp: App {
  @StateObject var armModel = ArmViewModel()
  
  var body: some Scene {
    WindowGroup {
      ContentView(armVM: armModel)
        .onAppear {
          armModel.requestAuthorization()
        }
    }
  }
}
