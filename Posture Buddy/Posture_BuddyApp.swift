//
//  Posture_BuddyApp.swift
//  Posture Buddy
//
//  Created by Aleks Kamko on 4/20/26.
//

import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        [.portrait, .portraitUpsideDown]
    }
}

@main
struct Posture_BuddyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var notificationManager = NotificationManager()

    init() {
        // Start orientation sampling as early as possible and spin briefly so
        // `UIDevice.current.orientation` is valid by the time ContentView renders.
        // Without this, the UI flashes in portrait before the first orientation
        // notification fires (~50-100ms later).
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let start = Date()
        while Date().timeIntervalSince(start) < 0.15 {
            let o = UIDevice.current.orientation
            if o == .portrait || o == .portraitUpsideDown { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notificationManager)
                .task {
                    SoundEffects.configureAudioSession()
                    await notificationManager.requestNotificationPermission()
                }
        }
    }
}
