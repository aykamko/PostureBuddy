//
//  ContentView.swift
//  Posture Buddy Watch Watch App
//
//  Created by Aleks Kamko on 4/21/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var receiver: WatchPostureReceiver

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.seated.side.right")
                .font(.largeTitle)
            Text("Posture Buddy")
                .font(.headline)
            Text("Last event: \(receiver.lastEvent ?? "—")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
