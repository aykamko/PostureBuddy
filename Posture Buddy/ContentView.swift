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

    /// Toggles the main on-screen visual between the friendly figure caricature
    /// (false, default) and the live skeleton overlay (true, debug).
    @State private var showDebugOverlay: Bool = false

    /// Hide every UI chrome element (HUD, buttons, camera preview, overlays)
    /// to inspect just the 3D rig. Bottom-left toggle; useful for camera /
    /// pose / bone diagnosis via finger-orbit on the SCNView.
    @State private var hideUI: Bool = false

    /// Show the debug bone markers overlaid on the 3D mascot. Off by default
    /// now that the rig is working — kept behind a toggle for future rig
    /// debugging.
    @State private var showBones: Bool = false

    // Debug transform state driven by AxisKnob + pan/pinch gestures when
    // `hideUI` is on. `PostureBuddy3DView` only applies these when
    // `debugEnabled` is true, so toggling `hideUI` off snaps the model back
    // to its normal position without losing the values.
    // Seeded with the same isometric default the non-debug path uses so
    // entering Hide-UI doesn't change the view — knobs just start there.
    @State private var modelYaw: Double = PostureBuddy3DView.defaultYawDeg
    @State private var modelPitch: Double = PostureBuddy3DView.defaultPitchDeg
    @State private var modelRoll: Double = PostureBuddy3DView.defaultRollDeg
    @State private var modelScale: Double = 1.0
    @State private var modelScaleAtStart: Double = 1.0
    @State private var modelOffset: CGSize = .zero
    @State private var modelOffsetAtStart: CGSize = .zero

    private let trackingTimeoutSeconds: Double = 45
    private let videoFadeStartDelay: Duration = .seconds(3)
    private let videoFadeDuration: Double = 1.0

    /// Dark slate backdrop shown behind the buddy once the camera preview
    /// fades out. Slightly warmer than pure black so the white mascot has a
    /// little tonal separation from the backdrop.
    private static let backdropSlate = Color(red: 36/255, green: 37/255, blue: 43/255)

    var body: some View {
        mainContent
            .animation(.easeInOut(duration: 0.3), value: isUpsideDown)
            .animation(.easeInOut(duration: 0.2), value: calibration.countdown)
            .animation(.easeInOut(duration: 0.2), value: calibration.instruction)
            .animation(.easeInOut(duration: 0.2), value: showTrackingFailedAlert)
            .animation(.easeInOut(duration: videoFadeDuration), value: videoFadeOpacity)
            // Drives PostureBuddyView's head pivot. 0.4s feels natural for body
            // motion (slower than the snappy 0.2s state changes).
            .animation(.easeInOut(duration: 0.4), value: poseEstimator.currentPose?.score?.value)
            .animation(.easeInOut(duration: 0.2), value: showDebugOverlay)
            // Snap mirroring (don't animate the buddy "flipping" through its
            // mid-flip transparent state when calibration commits).
            .animation(nil, value: poseEstimator.dominantEar)
            .task {
                poseEstimator.updateOrientation(UIDevice.current.orientation.visionOrientation)
                await cameraManager.requestAccessAndSetup()
                cameraManager.setSampleBufferDelegate(poseEstimator)
                resumeCapture()
            }
            .onChange(of: poseEstimator.isTrackingReady) { _, ready in
                if ready {
                    trackingTimeoutTask?.cancel()
                    trackingTimeoutTask = nil
                }
            }
            .onChange(of: poseEstimator.isCalibrated) { _, calibrated in
                if calibrated {
                    hideVideo(afterDelay: videoFadeStartDelay)
                } else {
                    // Recalibration or reset — bring the preview back for the
                    // upcoming calibration flow.
                    showVideo()
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
            Self.backdropSlate.ignoresSafeArea()

            if !videoHidden && !hideUI {
                CameraPreviewView(session: cameraManager.session)
                    .ignoresSafeArea()
            }

            // Slate dimmer between the camera preview and the skeleton.
            // Animated via the body-level `.animation(value: videoFadeOpacity)`
            // modifier, so we just set the target opacity from the fade Task.
            // Suppressed in Hide-UI mode — the root slate already covers it.
            if !hideUI {
                Self.backdropSlate
                    .opacity(videoFadeOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            // Default visual is the Posture Buddy mascot; Debug toggle (under
            // CalibrateButton) swaps it for the raw skeleton overlay.
            if showDebugOverlay {
                PostureOverlayView(detectedPose: poseEstimator.currentPose)
                    .ignoresSafeArea()
                    .rotatedIfUpsideDown(isUpsideDown)
            } else {
                PostureBuddy3DView(
                    score: poseEstimator.currentPose?.score,
                    dominantEar: poseEstimator.dominantEar,
                    debugEnabled: hideUI,
                    yawDeg: modelYaw,
                    pitchDeg: modelPitch,
                    rollDeg: modelRoll,
                    scale: modelScale,
                    translation: modelOffset,
                    showBones: showBones
                )
                .ignoresSafeArea()
                .rotatedIfUpsideDown(isUpsideDown)
                .gesture(modelDragGesture, including: hideUI ? .gesture : .none)
                .simultaneousGesture(modelPinchGesture, including: hideUI ? .gesture : .none)
            }

            if !hideUI {
            VStack {
                HStack {
                    ScoreHUDView(score: poseEstimator.currentPose?.score,
                                 isCalibrated: poseEstimator.isCalibrated)
                        .padding()
                    Spacer()
                    // Toggle camera preview visibility. Drives the same fade state
                    // the post-calibration auto-fade uses, so tapping here mid-fade
                    // cancels the auto-fade task and reverses direction.
                    Button {
                        if isVideoHiddenOrHiding {
                            showVideo()
                        } else {
                            hideVideo(afterDelay: .zero)
                        }
                    } label: {
                        Image(systemName: isVideoHiddenOrHiding ? "video.slash.fill" : "video.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.white)
                            .padding(20)
                            .background(Circle().fill(.black.opacity(0.4)))
                    }
                    .padding()
                }
                Spacer()

                Group {
                    if poseEstimator.isTrackingReady {
                        CalibrateButton(
                            isCalibrated: poseEstimator.isCalibrated,
                            hasSavedBaselines: poseEstimator.hasSavedBaselines,
                            isActive: calibration.isActive
                        ) {
                            if calibration.isActive {
                                calibration.cancel()
                            } else if poseEstimator.hasSavedBaselines && !poseEstimator.isCalibrated {
                                // "Start Tracking" — restored baselines from disk; flip
                                // tracking on without re-running calibration.
                                poseEstimator.startTracking()
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
                // Small gap below the calibrate button before the Debug toggle.
                // The Debug button itself carries the rest of the bottom-clearance
                // (so the prop / bezel doesn't occlude either button).
                .padding(.bottom, 12)

                // Debug toggles — outside the `isTrackingReady` Group so
                // they're always available (useful for previewing the figure
                // before pose tracking has warmed up).
                HStack(spacing: 10) {
                    Button { showDebugOverlay.toggle() } label: {
                        Text(showDebugOverlay ? "Hide Debug" : "Debug")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                    Button { showBones.toggle() } label: {
                        Text(showBones ? "Hide Bones" : "Bones")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                }
                .padding(.bottom, 100)
            }
            .rotatedIfUpsideDown(isUpsideDown)
            }

            if calibration.isActive && !hideUI {
                GuidedCalibrationOverlay(
                    instruction: calibration.instruction,
                    countdown: calibration.countdown
                )
                .rotatedIfUpsideDown(isUpsideDown)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if showTrackingFailedAlert && !hideUI {
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

            // Always-visible Hide/Show UI toggle. Stays on top so we can get
            // the chrome back when we're done inspecting the rig.
            VStack {
                Spacer()
                HStack {
                    Button { hideUI.toggle() } label: {
                        Text(hideUI ? "Show UI" : "Hide UI")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.black.opacity(0.4)))
                            .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                    .padding(.leading, 20)
                    .padding(.bottom, 100)
                    Spacer()
                }
            }
            .rotatedIfUpsideDown(isUpsideDown)

            // Debug axis knobs shown in Hide-UI mode. Press-and-drag each knob
            // vertically to spin that axis; Reset zeroes all five transforms.
            if hideUI {
                VStack {
                    Spacer()
                    HStack(spacing: 14) {
                        Spacer()
                        AxisKnob(label: "Y", value: $modelYaw,   accent: .cyan)
                        AxisKnob(label: "P", value: $modelPitch, accent: .yellow)
                        AxisKnob(label: "R", value: $modelRoll,  accent: .pink)
                        Button {
                            modelYaw = PostureBuddy3DView.defaultYawDeg
                            modelPitch = PostureBuddy3DView.defaultPitchDeg
                            modelRoll = PostureBuddy3DView.defaultRollDeg
                            modelScale = 1.0; modelScaleAtStart = 1.0
                            modelOffset = .zero; modelOffsetAtStart = .zero
                        } label: {
                            Text("Reset")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(.black.opacity(0.55)))
                                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                        }
                        .padding(.trailing, 20)
                    }
                    .padding(.bottom, 100)
                }
                .rotatedIfUpsideDown(isUpsideDown)
            }
        }
    }

    /// One-finger drag on the 3D view translates the model in screen X/Y while
    /// `hideUI` is on. Captures the offset at drag-start so repeated strokes
    /// accumulate instead of snapping back.
    private var modelDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                modelOffset = CGSize(
                    width:  modelOffsetAtStart.width  + g.translation.width,
                    height: modelOffsetAtStart.height + g.translation.height
                )
            }
            .onEnded { _ in modelOffsetAtStart = modelOffset }
    }

    /// Pinch-to-scale the model while `hideUI` is on. Multiplied against the
    /// start value for continuous scaling across multiple pinches.
    private var modelPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { m in modelScale = max(0.2, modelScaleAtStart * m) }
            .onEnded   { _ in modelScaleAtStart = modelScale }
    }

    /// `true` once the fade-to-black has passed its midpoint or the preview has
    /// been fully removed. Drives the camera-toggle button's icon and direction
    /// (tap while "hiding-or-hidden" reverses to show).
    private var isVideoHiddenOrHiding: Bool {
        videoHidden || videoFadeOpacity > 0.5
    }

    /// Fades the dimmer over the preview and, once fully opaque, removes the
    /// `CameraPreviewView` from the hierarchy (saves GPU). `afterDelay` = 0 for
    /// manual toggle; the post-calibration auto-fade uses `videoFadeStartDelay`.
    private func hideVideo(afterDelay: Duration) {
        videoFadeTask?.cancel()
        videoFadeTask = Task { @MainActor in
            if afterDelay > .zero {
                try? await Task.sleep(for: afterDelay)
                if Task.isCancelled { return }
            }
            videoFadeOpacity = 1.0
            try? await Task.sleep(for: .seconds(videoFadeDuration))
            if Task.isCancelled { return }
            videoHidden = true
        }
    }

    /// Re-adds the preview (if removed) and animates the dimmer back to transparent.
    private func showVideo() {
        videoFadeTask?.cancel()
        videoHidden = false
        videoFadeOpacity = 0
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
