//
//  ContentView.swift
//  Posture Buddy
//
//  Created by Aleks Kamko on 4/20/26.
//

import SwiftUI
import UIKit

private extension View {
    func rotatedIfUpsideDown(_ flipped: Bool) -> some View {
        rotationEffect(flipped ? .degrees(180) : .zero)
    }
}

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var poseEstimator = PoseEstimator()
    @StateObject private var soundCoach = PostureSoundCoach()
    @StateObject private var calibration = CalibrationController()
    @EnvironmentObject private var notificationManager: NotificationManager

    @Environment(\.scenePhase) private var scenePhase
    @State private var isUpsideDown: Bool = UIDevice.current.orientation == .portraitUpsideDown
    @State private var trackingTimeoutTask: Task<Void, Never>?
    @State private var showTrackingFailedAlert = false

    // Once calibration completes, fade the live preview to black over 1s and then
    // drop the CameraPreviewView from the hierarchy so `AVCaptureVideoPreviewLayer`
    // stops compositing frames — saves GPU power while the capture session keeps
    // feeding PoseEstimator.
    @State private var videoHidden: Bool = false
    @State private var videoFadeOpacity: Double = 0
    @State private var videoFadeTask: Task<Void, Never>?

    private let trackingTimeoutSeconds: Double = 45
    private let videoFadeStartDelay: Duration = .seconds(3)
    private let videoFadeDuration: Double = 1.0

    var body: some View {
        mainContent
            .animation(.easeInOut(duration: 0.3), value: isUpsideDown)
            .animation(.easeInOut(duration: 0.2), value: calibration.countdown)
            .animation(.easeInOut(duration: 0.2), value: calibration.instruction)
            .animation(.easeInOut(duration: 0.2), value: showTrackingFailedAlert)
            .animation(.easeInOut(duration: videoFadeDuration), value: videoFadeOpacity)
            .task {
                poseEstimator.updateOrientation(UIDevice.current.orientation.visionOrientation)
                await cameraManager.requestAccessAndSetup()
                cameraManager.setFrameDelegate(poseEstimator)
                resumeCapture()
            }
            .onChange(of: poseEstimator.isTrackingReady) { _, ready in
                if ready {
                    trackingTimeoutTask?.cancel()
                    trackingTimeoutTask = nil
                }
            }
            .onChange(of: poseEstimator.isCalibrated) { _, calibrated in
                videoFadeTask?.cancel()
                guard calibrated else {
                    // Recalibration or reset — bring the preview back immediately
                    // and fade the dimmer off.
                    videoHidden = false
                    videoFadeOpacity = 0
                    return
                }
                videoFadeTask = Task { @MainActor in
                    try? await Task.sleep(for: videoFadeStartDelay)
                    if Task.isCancelled { return }
                    videoFadeOpacity = 1.0
                    try? await Task.sleep(for: .seconds(videoFadeDuration))
                    if Task.isCancelled { return }
                    videoHidden = true
                }
            }
            .onChange(of: poseEstimator.currentPose?.score?.value) {
                guard poseEstimator.isCalibrated else { return }
                // Drop nil scores: the classifier regularly pauses for single frames
                // (face landmarks flicker, yaw crosses the threshold). Forwarding those
                // nils would reset in-flight slouch/recovery timers on every blip,
                // preventing them from ever firing. Long-horizon resets happen
                // explicitly via pauseCapture + calibration.start.
                guard let score = poseEstimator.currentPose?.score else { return }
                notificationManager.update(score: score)
                soundCoach.update(score: score)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                let deviceOrientation = UIDevice.current.orientation
                isUpsideDown = deviceOrientation == .portraitUpsideDown
                poseEstimator.updateOrientation(deviceOrientation.visionOrientation)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    resumeCapture()
                case .background, .inactive:
                    pauseCapture()
                @unknown default:
                    break
                }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !videoHidden {
                CameraPreviewView(session: cameraManager.session)
                    .ignoresSafeArea()
            }

            // Debug: TrueDepth map jet-colormapped over the video. Magenta = IR hole.
            // Wrapped in a GeometryReader + explicit frame + clipped so the image's
            // intrinsic size doesn't feed back into ZStack layout (it was shifting
            // the rest of the UI horizontally when the image was wider than the
            // screen after aspect-fill).
            if let depthImage = poseEstimator.depthVisualization {
                GeometryReader { proxy in
                    Image(decorative: depthImage, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
                .opacity(0.45)
                .allowsHitTesting(false)
            }

            // Black dimmer between the camera preview and the skeleton. Animated via
            // the body-level `.animation(value: videoFadeOpacity)` modifier, so we
            // just set the target opacity from the fade Task.
            Color.black
                .opacity(videoFadeOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            PostureOverlayView(detectedPose: poseEstimator.currentPose)
                .ignoresSafeArea()
                .rotatedIfUpsideDown(isUpsideDown)

            VStack {
                HStack {
                    ScoreHUDView(score: poseEstimator.currentPose?.score,
                                 isCalibrated: poseEstimator.isCalibrated)
                        .padding()
                    Spacer()
                }
                Spacer()

                if poseEstimator.isCalibrated,
                   calibration.countdown == nil,
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
                                        isActive: calibration.isActive) {
                            if calibration.isActive {
                                calibration.cancel()
                            } else {
                                calibration.start(
                                    poseEstimator: poseEstimator,
                                    soundCoach: soundCoach,
                                    notificationManager: notificationManager
                                )
                            }
                        }
                    } else {
                        TrackingLoadingView(message: "Initializing pose tracking…")
                    }
                }
                .padding(.bottom, 30)
            }
            .rotatedIfUpsideDown(isUpsideDown)

            if calibration.isActive {
                GuidedCalibrationOverlay(
                    instruction: calibration.instruction,
                    countdown: calibration.countdown
                )
                .rotatedIfUpsideDown(isUpsideDown)
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
                .rotatedIfUpsideDown(isUpsideDown)
                .transition(.opacity)
            }
        }
    }

    /// Resumes or starts camera capture: keeps the screen awake, starts the capture
    /// session, and arms the tracking-load timeout.
    private func resumeCapture() {
        UIApplication.shared.isIdleTimerDisabled = true
        cameraManager.start()
        startTrackingTimeout()
    }

    /// Mirror of `resumeCapture` for when the app backgrounds: stops capture and
    /// unwinds any in-progress coaching / calibration state.
    private func pauseCapture() {
        UIApplication.shared.isIdleTimerDisabled = false
        cameraManager.stop()
        calibration.cancel()
        trackingTimeoutTask?.cancel()
        notificationManager.update(score: nil)
        soundCoach.reset()
    }

    private func startTrackingTimeout() {
        trackingTimeoutTask?.cancel()
        guard !poseEstimator.isTrackingReady else { return }
        trackingTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(trackingTimeoutSeconds))
            } catch {
                return  // cancelled before timeout elapsed
            }
            if !poseEstimator.isTrackingReady {
                showTrackingFailedAlert = true
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(NotificationManager())
}
