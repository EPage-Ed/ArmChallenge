//
//  ContentView.swift
//  ArmChallenge Watch App
//
//  Created by Edward Arenberg on 4/18/23.
//

import SwiftUI

struct ContentView: View {
  @ObservedObject var armVM : ArmViewModel
  
  var body: some View {
    if armVM.state == .end {
      VStack {
        ForEach(armVM.rounds, id:\.self) { round in
          Text(round.duration.timeStringMS)
            .monospaced()
        }
        .font(.title)
        Button("Again") {
          armVM.reset()
        }
        .buttonStyle(.bordered)
      }
    } else {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack {
          HStack {
            HStack(spacing: 0) {
              Image(systemName: "heart")
              Text(armVM.heartRate.formatted())
            }
            Divider().frame(height: 30)
            Spacer()
            Text("\(armVM.round + 1)")
            Spacer()
            Divider().frame(height: 30)
            Text(armVM.roundTime.timeStringMS)
              .monospaced()
          }
          .font(.title2)
          
          GeometryReader { geo in
            // Scale circle inside our space.  0 <= motion <= 1
            let s = (min(geo.size.width, geo.size.height) - 10) * armVM.motion + 10
            // Hue goes from green (0.333) to red (0.0)
            let hue = 0.333 - armVM.motion * 0.333
            Circle()
              .fill(Color(hue: hue, saturation: 1, brightness: 1))
              .frame(width: s, height: s)
              .position(x: geo.size.width / 2, y: geo.size.height / 2)
              .clipped()
              .animation(.linear, value: armVM.motion)
              .overlay {
                Text(armVM.state == .idle ? "Tap to Start" : "")
                  .font(.largeTitle)
                  .foregroundColor(.orange)
              }
          }
        }
      }
      .contentShape(Rectangle())  // Allow tap anywhere
      .onTapGesture {
        armVM.start()
      }
    }
  }
}

struct ContentView_Previews: PreviewProvider {
  static var previews: some View {
    ContentView(armVM: ArmViewModel())
  }
}
