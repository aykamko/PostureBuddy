//
//  ContentView.swift
//  Posture Buddy
//
//  Created by Aleks Kamko on 4/20/26.
//

import SwiftUI
import UIKit
import AudioToolbox

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var poseEstimator = PoseEstimator()
    @StateObject private var soundCoach = PostureSoundCoach()
    @EnvironmentObject private var notificationManager: NotificationManager

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUpsideDown: Bool = UIDevice.current.orientation == .portraitUpsideDown
    @State private var countdown: Int? = nil
    @State private var isPriming = false
    @State private var countdownTask: Task<Void, Never>? = nil
    @State private var trackingTimeoutTask: Task<Void, Never>? = nil
    @State private var showTrackingFailedAlert = false

    private let countdownDuration = 5
    private let trackingTimeoutSeconds: Double = 45

    var body: some View {
        mainContent
        .animation(.easeInOut(duration: 0.3), value: isUpsideDown)
        .animation(.easeInOut(duration: 0.2), value: countdown)
        .animation(.easeInOut(duration: 0.2), value: isPriming)
        .animation(.easeInOut(duration: 0.2), value: showTrackingFailedAlert)
        .task {
            poseEstimator.updateOrientation(visionOrientation(for: UIDevice.current.orientation))
            UIApplication.shared.isIdleTimerDisabled = true
            await cameraManager.requestAccessAndSetup()
            cameraManager.setSampleBufferDelegate(poseEstimator)
            cameraManager.start()
            startTrackingTimeout()
        }
        .onChange(of: poseEstimator.isTrackingReady) { _, ready in
            if ready {
                trackingTimeoutTask?.cancel()
                trackingTimeoutTask = nil
            }
        }
        .onChange(of: poseEstimator.currentPose?.score?.value) {
            guard poseEstimator.isCalibrated else { return }
            let score = poseEstimator.currentPose?.score
            notificationManager.update(score: score)
            soundCoach.update(score: score)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let deviceOrientation = UIDevice.current.orientation
            let flipped = deviceOrientation == .portraitUpsideDown
            isUpsideDown = flipped
            poseEstimator.updateOrientation(visionOrientation(for: deviceOrientation))
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                cameraManager.start()
                startTrackingTimeout()
            case .background, .inactive:
                UIApplication.shared.isIdleTimerDisabled = false
                cameraManager.stop()
                cancelCountdown()
                trackingTimeoutTask?.cancel()
                notificationManager.update(score: nil)
                soundCoach.reset()
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: cameraManager.session)
                .ignoresSafeArea()

            PostureOverlayView(detectedPose: poseEstimator.currentPose)
                .ignoresSafeArea()
                .rotationEffect(isUpsideDown ? .degrees(180) : .zero)

            VStack {
                HStack {
                    ScoreHUDView(score: poseEstimator.currentPose?.score,
                                 isCalibrated: poseEstimator.isCalibrated)
                        .padding()
                    Spacer()
                }
                Spacer()

                if poseEstimator.isCalibrated,
                   countdown == nil,
                   case .warning(let seconds) = notificationManager.alertState {
                    Text("Poor posture — alert in \(seconds)s")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 12)
                }

                Group {
                    if poseEstimator.isTrackingReady {
                        CalibrateButton(isCalibrated: poseEstimator.isCalibrated,
                                        isActive: isPriming || countdown != nil) {
                            if isPriming || countdown != nil {
                                cancelCountdown()
                            } else {
                                startCountdown()
                            }
                        }
                    } else {
                        TrackingLoadingView(message: "Initializing pose tracking…")
                    }
                }
                .padding(.bottom, 30)
            }
            .rotationEffect(isUpsideDown ? .degrees(180) : .zero)

            if isPriming {
                PrimingOverlay()
                    .rotationEffect(isUpsideDown ? .degrees(180) : .zero)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if let countdown {
                CountdownOverlay(value: countdown)
                    .rotationEffect(isUpsideDown ? .degrees(180) : .zero)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if showTrackingFailedAlert {
                AlertOverlay(
                    title: "Pose Tracking Unavailable",
                    message: "Apple's pose-detection model couldn't load on this device. Try:\n\n• Free up storage space on your iPhone\n• Force-quit and relaunch Posture Buddy\n• Restart your iPhone",
                    buttonTitle: "OK"
                ) {
                    showTrackingFailedAlert = false
                }
                .rotationEffect(isUpsideDown ? .degrees(180) : .zero)
                .transition(.opacity)
            }
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        // Phase 1: prime the audio pipeline. Show spinner, no haptic/sound yet.
        isPriming = true
        SoundEffects.prime()
        countdownTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(SoundEffects.primeDuration))
            if Task.isCancelled { isPriming = false; return }
            isPriming = false

            // Phase 2: actual countdown. Beat 1 — "5" on screen, lowest pitch.
            countdown = countdownDuration
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            SoundEffects.playTick(index: 0)

            // Beats 2-4 — ticks at count 4, 3, 2
            for remaining in stride(from: countdownDuration - 1, through: 2, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdown = remaining
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                SoundEffects.playTick(index: countdownDuration - remaining)
            }
            // Beat 5 — "1" on screen, capture note (A), calibrate
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            countdown = 1
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            SoundEffects.playCapture()
            poseEstimator.calibrate()
            soundCoach.reset()
            // Hold "1" briefly so the capture moment is visible, then dismiss
            try? await Task.sleep(for: .seconds(0.6))
            if !Task.isCancelled { countdown = nil }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        isPriming = false
    }

    private func startTrackingTimeout() {
        trackingTimeoutTask?.cancel()
        guard !poseEstimator.isTrackingReady else { return }
        trackingTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(trackingTimeoutSeconds))
            if Task.isCancelled { return }
            if !poseEstimator.isTrackingReady {
                showTrackingFailedAlert = true
            }
        }
    }
}

private func visionOrientation(for deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
    deviceOrientation == .portraitUpsideDown ? .rightMirrored : .leftMirrored
}

struct ScoreHUDView: View {
    let score: PostureScore?
    let isCalibrated: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(gradeColor, lineWidth: 7)
                .frame(width: 108, height: 108)
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                Text(isCalibrated ? "score" : "ready")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .background(.black.opacity(0.4), in: Circle())
    }

    private var label: String {
        if let score { return "\(Int(score.value))" }
        return isCalibrated ? "--" : "·"
    }

    private var gradeColor: Color {
        guard let c = score?.grade.color else { return .gray }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

struct CalibrateButton: View {
    let isCalibrated: Bool
    let isActive: Bool   // true during audio-prime or countdown phases
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label).font(.title2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .background(Capsule().fill(background))
        }
    }

    private var icon: String {
        if isActive { return "xmark.circle.fill" }
        return isCalibrated ? "arrow.clockwise.circle.fill" : "scope"
    }

    private var label: String {
        if isActive { return "Cancel" }
        return isCalibrated ? "Recalibrate" : "Set Baseline Posture"
    }

    private var background: Color {
        if isActive { return .red.opacity(0.8) }
        return isCalibrated ? Color.white.opacity(0.2) : Color.accentColor
    }
}

struct TrackingLoadingView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Capsule().fill(Color.white.opacity(0.18)))
    }
}

struct AlertOverlay: View {
    let title: String
    let message: String
    let buttonTitle: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.leading)
                Button(action: onDismiss) {
                    Text(buttonTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(white: 0.15))
            )
            .padding(24)
        }
    }
}

struct PrimingOverlay: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .controlSize(.large)
            Text("Get ready…")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(40)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.35))
    }
}

struct CountdownOverlay: View {
    let value: Int

    var body: some View {
        VStack(spacing: 12) {
            Text("\(value)")
                .font(.system(size: 160, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .id(value)
            Text("Hold your best posture")
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(40)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.35))
        .animation(.easeInOut(duration: 0.25), value: value)
    }
}

#Preview {
    ContentView()
        .environmentObject(NotificationManager())
}
