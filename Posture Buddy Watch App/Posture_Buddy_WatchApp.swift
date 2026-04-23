//
//  Posture_Buddy_WatchApp.swift
//  Posture Buddy Watch App
//
//  Created by Aleks Kamko on 4/21/26.
//

import SwiftUI

@main
struct Posture_Buddy_WatchApp: App {
    @StateObject private var receiver = WatchPostureReceiver()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(receiver)
        }
    }
}
