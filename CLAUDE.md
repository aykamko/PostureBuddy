# Posture Buddy

iOS app that monitors sitting posture in real time using the front camera. The user props their phone in **portrait** mode to the side of themselves while working at a desk; the app watches their side profile, scores posture, and vibrates/alerts after sustained poor posture.

## Core Design Decisions

### Pose estimation: 2D only
- Uses **`VNDetectHumanBodyPoseRequest`** (2D), not 3D.
- The **3D variant (`VNDetectHumanBodyPose3DRequest` / `DetectHumanBodyPose3DRequest`) is broken on iOS 26** — fails with `Error Domain=com.apple.Vision Code=9 "Unable to run HumanBodyPose3D pipeline"` and `Could not create mlImage buffer of type kCVPixelFormatType_32BGRA`. Both the `VN`-prefixed and Swift-native API fail. Do not reintroduce it without testing on a current iOS version.
  - This is likely broken because the camera will typically not capture all of the user's joints when propped up on the desk, since the desk occludes the bottom half of the body. In other words, we usually only see the top half of the body.

### Scoring: 3-position calibration + head-yaw-aware classification
- 2D pose can't separate "bad posture" from "weird camera angle" or "head turned". Rotating your head ~30° toward the screen shifts the ear's 2D position enough to tank the score even with perfect torso posture.
- Solution: guided calibration at **three head positions** — middle, left, right edge of screen — plus a fourth "lean forward" capture at the middle yaw (used only to derive `forwardSign`, see Asymmetric scoring). Each yaw baseline captures `earShoulderAngle` and a raw `YawTelemetry` (bundle of candidate yaw features). At the end of calibration we pick the two features that best separate the three yaw positions (see below).
- At runtime: the current frame's telemetry is projected into the selected feature pair (with EMA smoothing, see below), producing a `YawSignature`. That's matched to the **nearest** baseline by 2D Euclidean distance and scored against that baseline's angles. Scoring pauses only when there's no signature at all (no face detected, or the selected features aren't populated in the frame). The `classificationThreshold` still exists inside `YawCalibration` and is shown in frame logs as a `✓/✗` confidence indicator, but it **no longer gates scoring** — hard slouching pitches the head enough to drag the signature outside any baseline's tight threshold, and blocking scoring in exactly that case defeats the whole point. All three baselines are calibrated upright, so even a "wrong nearest" baseline produces a large ear-shoulder deviation when the user slouches, and the score correctly drops.
- Side-profile scoring uses **same-side ear + shoulder**. Hip was dropped entirely — the desk consistently occluded it in the target setup, and a partially-available signal was making scoring less reliable, not more. The skeleton rendering was likewise trimmed to upper-body-only (nose, eyes, ears, neck, shoulders); arms, hips, legs, and root aren't extracted or drawn.
- **Last-known keypoint fallback**: `PoseEstimator` caches the most recent confident location for **always-eligible joints** (`nose`, `leftEye`, `rightEye`, `neck`, `leftShoulder`, `rightShoulder`), plus — post-calibration — the **dominant ear** (the camera-side one). Frames that briefly drop one of these fall back to the cached location; `Keypoint.isStale = true` makes the overlay render those dots/connections **purple** (distinct from the grade-colored fresh skeleton and cyan face landmarks).
  - **Dominant-ear derivation**: `PoseEstimator` maintains running `earSightings` counters for left and right ears. At `calibrate()` commit, whichever side has more sightings is locked in as `dominantEar` and becomes stale-eligible. Both counters reset on `resetCalibration()`, so recalibrating after flipping the phone to the other side of the desk picks the new dominant ear correctly.
  - **Far-side ear is never stale-cached** because it can flicker in briefly at extreme head yaws and then look like a ghost after the user's head turns back. If the non-dominant ear is fresh this frame it still renders (white), it just never gets remembered.
  - **Pre-calibration**: neither ear is stale-eligible (dominantEar is nil), so ears only render when freshly detected.
  - Cache survives scene-phase changes; the first fresh frame after a gap overwrites it.
- **Asymmetric scoring (forward-only penalty).** `angleFromVertical` returns a *signed* angle (drop-in replaced the old `abs(dx)` formulation), so the ear-shoulder angle now lives in [-90°, +90°] with sign indicating which side of vertical the line tips toward. At calibration, we capture a "lean forward briefly" sample at the middle yaw (see Guided calibration flow), compute `forwardSign = sign(forwardLean.earShoulderAngle − middle.earShoulderAngle)`, and stash it on `PostureBaselines`. At scoring time, `PostureAnalyzer.forwardDeviation(current, baseline, sign)` computes `max(0, (current − baseline) × sign)` — positive only in the forward direction, zero for backward lean. If the user's lean sample wasn't decisive (|Δ| < 1°), `forwardSign` is nil and scoring falls back to the old symmetric `abs(current − baseline)` behavior. Net effect: leaning back into your chair doesn't ding the score; slouching forward does.
- **Brief classification pauses don't disturb downstream timers.** `ContentView.onChange` drops nil scores before forwarding to `PostureSoundCoach` / `NotificationManager`, so a single flickered frame can't cancel an in-flight slouch/recovery timer or reset the alert countdown. Long-horizon resets still happen via `pauseCapture` (scene phase change) and `calibration.start` — those call `reset()` / `update(score: nil)` explicitly. Without this filter the slouch and recovery sounds were effectively never firing because every ~200 ms pause interrupted them.
- **No phone haptics, anywhere.** The iPhone is typically balanced on books / a stand with the camera pointed at the user, and any buzz can knock it over mid-session. All iOS-side `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator` calls have been removed (previously in `CalibrationController` countdown + capture, and in `NotificationManager.triggerAlert`). Don't reintroduce them. Haptic feedback lives exclusively on the Watch companion (see Watch companion section) via `WatchBridge.shared.notify(.slouch | .recovery)` → `WKInterfaceDevice.play(...)` on the watch side. The system notification still posts from `NotificationManager.triggerAlert`, but that routes through iOS's notification UI without a direct haptic from our code.
- **Tunable timing constants** (currently set for active testing — bump back up before shipping):
  - `NotificationManager.alertDelay = 10s` (system-notification trigger after sustained poor posture; production target ~30s)
  - `PostureSoundCoach.slouchDelay = 6s`, `recoveryDelay = 3s` (audible coach cues for sustained fair/poor and good-after-alert states)
  - `PostureAnalyzer.maxDeviation = 20°` (degrees of deviation that drive the score to 0)
  - `PostureScore.init` grade thresholds: good ≥ 75, fair 60–75, poor < 60

### Head-yaw classification: adaptive 2-feature selection
Yaw in our side-profile setup isn't one-dimensional. A single scalar (any direction *or* frontality measure alone) collapses at least one pair of positions — e.g. "middle" and "left" often share the same median-line offset, while "middle" and "right" share the same face-contour width. Which failure mode hits depends on the camera angle + the user's anatomy, so we pick the feature pair adaptively instead of hardcoding one.

- **`YawTelemetry`** (in `PostureModels.swift`) is a per-frame bundle of candidate features, computed from the face observation + body observation. Populated in `PoseEstimator.captureOutput`, logged at each calibration capture for tuning. Currently included:
  - Direction candidates (bbox-local x-offset of a midline feature, range ~[-0.5, +0.5]): `medianLine`, `noseCrest`, `noseCentroid` (full `nose` region centroid).
  - Frontality candidates (how much of the face is visible): `eyeSepOverH` (leftEye↔rightEye centroid distance ÷ bbox height), `contourSpreadOverH` (faceContour x-spread ÷ bbox height), `allLandmarksSpreadLocal` (x-spread across every landmark, bbox-local).
  - A few ignored-but-still-logged fields for reference (bboxAspect, raw spreads, ear-confidence ratio) — see Gotchas for why they're dead.
- **`YawCalibration.make(...)`** runs at calibration commit. It tries every (DirectionFeature × FrontalityFeature) pair, computes the three baseline `YawSignature`s for that pair, and scores the pair by `min(d(middle,left), d(left,right), d(middle,right))` in raw (unnormalized) feature space. The winning pair is the one whose three baseline points have the largest minimum pairwise distance — i.e. the most reliably discriminative pair for this user + camera setup. The chosen `classificationThreshold = minPair * 0.5` gives each baseline a Voronoi-ish acceptance radius that can't overlap its neighbors.
- **`YawSelection.signature(from: telemetry)`** at runtime extracts the same two features from the current frame so it can be compared to the baselines. Returns nil if either feature is missing in the frame.
- **Signature EMA smoothing** before classification. `PoseEstimator` holds a smoothed `YawSignature` in an `OSAllocatedUnfairLock` and blends each fresh projection with `α = yawSignatureSmoothingAlpha` (currently 0.3 — ~450 ms to 80 % settle at 10 FPS). Without this, frames straddling a baseline boundary would thrash in and out of the acceptance radius (single-frame noise on `contourSpreadOverH` / `eyeSepOverH` is ±0.02 – ±0.04, larger than the tight thresholds minPair/2 produces near close-together baselines). `PostureAnalyzer.score` now takes a pre-computed `YawSignature` so the smoothed value is what's classified; raw per-frame sigs are only logged. Smoothed state is reset in `resetCalibration()`.
- **No normalization.** Features are compared in their raw units (all are bbox-width or bbox-height fractions, roughly comparable scales). Normalizing by spread would amplify noise on low-signal axes — don't do it without thinking.

### Head-yaw detection: VNDetectFaceLandmarksRequest
- Runs alongside `VNDetectHumanBodyPoseRequest` per frame. Face landmarks drive every direction candidate and most frontality candidates; body-pose observations only contribute the (mostly dead) ear-confidence ratio. All candidates are packed into a `YawTelemetry` in `PoseEstimator.captureOutput`.
- **Do NOT use `VNFaceObservation.yaw` directly.** Despite Apple's docs claiming revision 3+ gives continuous values, in practice `yaw` is still quantized to 45° buckets (-π/4, -π/2, etc.) for side-profile faces on iOS 26. Observed: "middle" and "right" calibration positions both returned exactly -0.785 rad (-45°), making them indistinguishable. The quantization makes `yaw` unusable for 3-position classification.
- Revision is still set to `currentRevision` for landmark detection itself; we just don't read the `yaw` property anymore.
- Face landmarks are also rendered on the overlay as **cyan** dots + bounding box for debugging — distinguishable from the white body keypoints (and from purple stale-keypoint markers). See `PostureOverlayView.swift`.
- Landmark points are in `VNFaceLandmarkRegion2D.normalizedPoints`, which are *bounding-box-local* (0-1 within the face rect). `extractFaceLandmarks(from:)` converts them to image-normalized coords so they share the skeleton's coordinate system (needed for drawing, not for yaw features which use bbox-local coords directly).

### Guided calibration flow
Owned by `CalibrationController` (a `@MainActor` `ObservableObject`). The controller publishes `instruction: String?` and `countdown: Int?`; `ContentView` observes those and renders `GuidedCalibrationOverlay`. All flow logic — voice prompts, marimba ticks, haptics, snapshot capture, cancellation — lives in the controller so `ContentView` only composes views.

- Triggered by **Set Baseline Posture** (or Recalibrate), which calls `calibration.start(poseEstimator:, soundCoach:, notificationManager:)`. Flow:
  1. Reset: discard existing baselines (`poseEstimator.resetCalibration()`), cancel slouch/recovery timers (`soundCoach.reset()`), and clear the pending-alert banner (`notificationManager.update(score: nil)`). This stops scoring + any in-flight coaching sounds so they can't fire mid-calibration. Consequence: cancelling calibration leaves the app uncalibrated — there's no "restore previous baselines" path.
  2. Audio pipeline prime (1s silent buffer) + "Get ready…" spinner
  3. Four capture positions, runtime order: **center** (`sit_straight_look_center.aiff` — fused intro+first-position prompt, labelled `middle` internally to match `CalibrationPosition.middle`) → **left** (`look_left.aiff`) → **right** (`look_right.aiff`) → **leanForward** (`lean_forward.aiff`; prompt says "Look at the center and lean forward"). Each position runs:
     - Voice prompt
     - 3-beat marimba countdown (3, 2, 1) with tick + capture sounds
     - **Burst-sample** 10 frames over ~1.25 s after count=1, then take the componentwise median (`PostureAngles.median(of:)`, which medians each `YawTelemetry` field independently). Single-frame capture was unreliable — jittery features like `contourSpreadOverH` frequently spiked high for one frame, placing the baseline outside the user's steady-state distribution and causing runtime frames to fall outside the classification threshold. Require ≥6 successful samples or the flow aborts with *"Couldn't detect your pose."*
     - The center + leanForward captures together feed the `forwardSign` derivation (see Asymmetric scoring); center/left/right feed `YawCalibration` for yaw classification. The leanForward sample is *only* used for the sign — it isn't a yaw baseline. `runFlow` maps `snapshots[0, 1, 2, 3]` to `calibrate(middle: snapshots[0], forwardLean: snapshots[3], left: snapshots[1], right: snapshots[2])`.
     - The three yaw captures come first as a natural "scan left-to-right" head motion; the lean-forward capture is last so the user only has to reset posture once (back to center, then lean).
  4. Voice: *"Calibration is complete."*
- Cancel button (the calibrate button goes red during calibration) calls `calibration.cancel()` — cancels the controller's task, stops voice, reverts UI. Baselines remain discarded (reset at step 1); user must re-run calibration before scoring resumes.
- If `snapshotCurrentAngles()` returns nil at any capture moment (no valid pose), the flow aborts with *"Couldn't detect your pose. Please try again."*
- The controller's run-flow uses `try Task.checkCancellation()` + `try await Task.sleep(for:)` with a single `do/catch cleanup()` wrapper. Don't add manual `if Task.isCancelled { … }` guards — the throwing path already handles them.

### Voice guidance — pre-recorded, not TTS
- Originally used `AVSpeechSynthesizer`, but iOS default TTS voices sound robotic and premium voices require per-user downloads from Settings → Accessibility. Apple also walls off Siri's voice from third-party apps entirely (Siri voice downloads are not exposed via `AVSpeechSynthesisVoice.speechVoices()` or the `say` command).
- Solution: ship **pre-recorded `.aiff` files** in the bundle, one per prompt. `VoiceGuide.shared.say(_: VoicePrompt)` plays the matching file via `AVAudioPlayer` (delegate callback resumes a `CheckedContinuation` when done).
- Recordings were generated with **ElevenLabs** (Clara voice). Raw clips are stored outside the bundle at `voice-samples/` (ignored by Xcode); the chopped segments live in `Posture Buddy/VoicePrompts/` and are auto-included via the file-system-synchronized group.
- `VoicePrompt` is a `String`-backed `CaseIterable` enum whose raw values match the filenames (e.g., `.lookMiddle` → `look_middle.aiff`).
- Players are lazily loaded and cached on first use; subsequent plays are instant.

### Re-recording the voice prompts
The script:
```
Starting calibration! Please sit up straight
  and look at the center of your screen.                    → sit_straight_look_center.aiff
Look at the left of your screen.                            → look_left.aiff
Look at the right of your screen.                           → look_right.aiff
Look back at the center and lean forward slightly.          → lean_forward.aiff
Calibration is complete.                                    → calibration_complete.aiff
Couldn't detect your pose. Please try again.                → pose_not_detected.aiff
```

Workflow:
1. Paste the script into ElevenLabs and export as one mp3 (or chop each line separately in ElevenLabs for better per-phrase intonation — the hand-chopped files ended up sounding more natural than auto-chopped).
2. If auto-chopping a single mp3: `ffmpeg -i in.mp3 -af silencedetect=noise=-35dB:d=0.4 -f null -` to find silence boundaries, then split with `ffmpeg -ss START -to END -i in.mp3 -c:a pcm_s16be out.aiff`.
3. Otherwise convert each mp3 to aiff: `ffmpeg -i in.mp3 -c:a pcm_s16be out.aiff`.
4. Replace files in `Posture Buddy/VoicePrompts/`. Filenames must match `VoicePrompt.rawValue` exactly.

### Battery: drop the video preview post-calibration
- Once `poseEstimator.isCalibrated` becomes true, `ContentView` waits 3 s, fades a black overlay over the preview in ~1 s, then *removes* the `CameraPreviewView` from the view hierarchy. That deallocates the `AVCaptureVideoPreviewLayer`, which is the main GPU consumer — the capture session and `PoseEstimator` keep running unchanged, so pose detection and scoring are unaffected. The skeleton (`PostureOverlayView`) renders above the dimmer and stays visible throughout.
- Reset path: when `isCalibrated` goes false (user taps Recalibrate), the preview is re-added to the hierarchy immediately and the dimmer fades off over 1 s so you can see yourself during the new calibration flow. Scene-phase changes (background/foreground) do **not** touch the fade state — returning from background on a calibrated session keeps the preview hidden.
- The dimmer sits between the camera preview and the skeleton layer in the `ZStack`, so slouching feedback stays crisp on top of a plain black background.

### Watch companion (haptic feedback)
- Separate watchOS target: **`Posture Buddy Watch App`**. Three files: `Posture_Buddy_WatchApp.swift` (`@main`), `ContentView.swift` (status view), `WatchPostureReceiver.swift` (`WCSession` delegate + haptic playback).
- iOS sends events via **`WatchBridge.shared.notify(_: Event)`** — a `WCSession` singleton that fires `sendMessage` (live-only, drops if watch unreachable). Two events: **`.slouch`** (from `PostureSoundCoach` when the slouch sound plays after sustained fair/poor) and **`.recovery`** (when the recovery sound plays after sustained good post-alert). The 30 s system notification path *intentionally does not* fire a separate watch event — it would arrive ~4 s after `.slouch` for the same condition and just feel like a double-buzz.
- The `WCSession` is activated in `Posture_BuddyApp.task` via `_ = WatchBridge.shared`. iOS-side delegate methods + reachability changes are logged under `[Watch]`.
- Watch side: `WatchPostureReceiver` plays `WKInterfaceDevice.current().play(.notification)` for slouch and `.success` for recovery; updates `lastEvent` for the status view.
- **Limitation we accepted**: `sendMessage` only delivers when the watch app is reachable (foreground or recently backgrounded). After a long wrist-down period the watch app is suspended and events are dropped — visible in the iOS log as `[Watch] skip slouch — watch not reachable`. Reliable always-on delivery would require an `HKWorkoutSession` extended-runtime path, deferred until the dropped-event rate becomes a real problem.
- We also briefly explored Apple's **notification-mirroring** path (Option A: rely on iOS local notifications mirroring to the watch). That doesn't work for us because the iPhone is foreground-active during a session (`isIdleTimerDisabled = true`), so iOS routes notifications to the phone and skips the mirror. WatchBridge is the workaround.

### Orientation: portrait + portrait-upside-down
- Supported orientations (Info.plist-equivalent in `project.pbxproj`): `UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown`.
- **iOS's native portrait-upside-down rotation is unreliable on iPhone.** Setting the `AppDelegate` `supportedInterfaceOrientationsFor:` returning both doesn't actually rotate the UI.
- Instead, we **manually flip the UI** with `.rotationEffect(.degrees(180))` when we detect `UIDeviceOrientation.portraitUpsideDown` (via `UIDevice.current.beginGeneratingDeviceOrientationNotifications()` + `orientationDidChangeNotification`).
- The **`CameraPreviewView` is NOT rotated** — `AVCaptureVideoPreviewLayer` handles its own orientation internally; double-rotating it shows the user upside-down in the preview.
- Vision orientation hint is flipped: front-camera-portrait = `.leftMirrored`, upside-down = `.rightMirrored`.
- **Native SwiftUI `.alert` uses the system interface orientation and won't respect manual rotation** — use the custom `AlertOverlay` component inside the rotated ZStack instead.

### Concurrency: MainActor default isolation
- Project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every class, struct, and extension is implicitly `@MainActor`.
- `AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput` MUST be marked `nonisolated` or frames get dispatched to main, defeating the background video queue and blocking the UI.
- Shared background state (orientation, last-processed-time, smoothed score, smoothed yaw signature, last-known keypoints cache, current angles, current telemetry, baselines, log-throttle stamps + state) is protected with `OSAllocatedUnfairLock`.
- Static `let` constants used from `nonisolated` methods must be explicitly `nonisolated static let`.
- **Types used from `captureOutput` must opt out of MainActor too.** `PostureAnalyzer`, `YawSignature`, and `YawTelemetry` are declared `nonisolated struct` so all their methods are callable on the video queue without per-method annotations. Same goes for extension methods intended for background use (e.g. the `OSAllocatedUnfairLock.shouldFire` throttle helper in `PoseEstimator.swift` is `nonisolated`).

### Audio: synthesized marimba-like tones
- No bundled sound files. `SoundEffects.swift` generates tones at runtime using `AVAudioEngine` + `AVAudioPCMBuffer` + a simple additive synthesis (fundamental + octave + fast-decaying inharmonic "clink").
- **Countdown melody**: F4 → G4 → A4 → B4 → C5 (top half of C major resolving on C5). 5 beats total; the 5th beat (at count=1 on screen) is the capture moment.
- Tone buffers are **pre-generated on a background queue at startup** — never synthesize on the main thread at play time.
- Before each countdown, we **prime the audio pipeline** with a 1-second silent buffer (showing a "Get ready…" spinner) so the render thread is hot before the first tone. An earlier approach of continuous silence loop was removed to save battery.
- Audio session: `.playback` category with `.mixWithOthers` — plays even when the silent switch is on; doesn't interrupt background audio.
- **Must set `AVCaptureSession.automaticallyConfiguresApplicationAudioSession = false`** in `CameraManager` — otherwise the camera session disrupts our audio session on start, causing first-tone glitches.
- Audio format matches the **hardware sample rate** (queried via `AVAudioSession.sharedInstance().sampleRate`, typically 48kHz) to avoid real-time resampling on the audio thread. Preferred IO buffer duration is 40ms (vs ~23ms default) for CPU-spike tolerance.

### ANE / pose-model resilience
- Apple's pose model (`cnn_human_pose.espresso.net`) ships with iOS but each new app process must re-load the weights from disk into the ANE. There's no way to persist the loaded model across app launches.
- **Do not run a "warmup" Vision inference concurrently with the camera pipeline.** Tried this with `Task.detached { poseEstimator.warmUp() }` that ran a dummy inference on a blank 256×256 buffer; result was the ANE serializing warmup and real-frame inferences, slowing the whole app to a crawl. Accept the ~1-2 second cold-start on first frame instead.
- Apple's pose model occasionally fails to load onto the Neural Engine with errors like `ANECF error: failed to load ANE model ... Cannot open additional blob file`. Usually fixed by restarting the iPhone or freeing storage.
- If no valid pose observation is received within **20 seconds** of the camera starting, the app shows an `AlertOverlay` telling the user to free space / reboot / force-quit.

## File Layout

```
Posture Buddy/                          (iOS target)
├── Posture_BuddyApp.swift              App entry. Creates NotificationManager, primes WatchBridge, configures audio session
├── ContentView.swift                   Orchestration shell: camera lifecycle, scene phase, layout, post-calibration video fade
├── CameraManager.swift                 AVCaptureSession owner (front camera, YUV420, no audio session touch)
├── CameraPreviewView.swift             UIViewRepresentable wrapping AVCaptureVideoPreviewLayer
├── PoseEstimator.swift                 Runs VNDetectHumanBodyPoseRequest on videoQueue; caches last-known keypoints; publishes DetectedPose
├── PostureAnalyzer.swift               Pure math: picks best side (ear+shoulder), computes signed ear-shoulder angle, asymmetric scoring vs baseline
├── PostureModels.swift                 Data types: DetectedPose, Keypoint, FaceLandmarks, PostureScore/Grade,
│                                       PostureAngles, YawTelemetry, YawSignature, DirectionFeature,
│                                       FrontalityFeature, YawSelection, YawCalibration, PostureBaselines (incl. forwardLean + forwardSign)
├── PostureGrade+UI.swift               SwiftUI-bridge: PostureScore.Grade.swiftUIColor
├── PostureOverlayView.swift            SwiftUI Canvas drawing skeleton + face landmarks (white=fresh, purple=stale, cyan=face)
├── CalibrationController.swift         @MainActor ObservableObject driving the 4-position guided-calibration flow
├── UIDeviceOrientation+Vision.swift    .visionOrientation mapping for front-camera buffers
├── NotificationManager.swift           Tracks poor-posture duration; fires haptic + local notification + WatchBridge slouch event
├── PostureSoundCoach.swift             Sustained-state grade-transition sounds (slouch=6s, recovery=3s); also fires WatchBridge events
├── VoiceGuide.swift                    Plays bundled .aiff prompts via AVAudioPlayer; keyed by VoicePrompt enum
├── SoundEffects.swift                  Synthesized marimba tones + beep pairs
├── WatchBridge.swift                   WCSession singleton; sends `.slouch` / `.recovery` haptic events to paired watch
├── Log.swift                           Timestamped print helper (HH:mm:ss.SSS); thread-safe DateFormatter under OSAllocatedUnfairLock
├── Views/                              Leaf SwiftUI views composed by ContentView
│   ├── ScoreHUDView.swift              108pt circle, color-coded score
│   ├── CalibrateButton.swift           Capsule button, flips to red "Cancel" while calibrating
│   ├── TrackingLoadingView.swift       Spinner + message while pose model is loading
│   ├── AlertOverlay.swift              Custom modal (native .alert doesn't respect manual rotation)
│   └── GuidedCalibrationOverlay.swift  Instruction text + big countdown number
└── VoicePrompts/                       Bundled pre-recorded calibration audio (ElevenLabs "Clara")
    ├── sit_straight_look_center.aiff
    ├── look_left.aiff
    ├── look_right.aiff
    ├── lean_forward.aiff
    ├── calibration_complete.aiff
    └── pose_not_detected.aiff

Posture Buddy Watch App/                (watchOS target)
├── Posture_Buddy_WatchApp.swift        @main App entry; owns WatchPostureReceiver as @StateObject
├── ContentView.swift                   Minimal status view — shows last-received event tag
└── WatchPostureReceiver.swift          WCSession delegate; plays WKInterfaceDevice haptics on incoming `slouch`/`recovery` events
```

## Data Flow

```
AVCaptureSession (front camera, YUV 420 BiPlanar)
    │  CMSampleBuffer on videoQueue
    ▼
PoseEstimator.captureOutput (nonisolated, 10 FPS throttled)
    │  VNDetectHumanBodyPoseRequest → VNHumanBodyPoseObservation (body keypoints)
    │  VNDetectFaceLandmarksRequest → VNFaceObservation (face landmarks, ignore .yaw)
    │  → YawTelemetry(all candidate direction + frontality features)
    │  → smoothed YawSignature (EMA α=0.3 in PoseEstimator)
    │  PostureAnalyzer.computeAngles(observation, yawTelemetry:) → PostureAngles
    │  PostureAnalyzer.score(current, baselines, yawSignature:) → (PostureScore, position)?
    │    classifies the *nearest* baseline (no threshold gating); applies forwardSign
    │    asymmetric scoring; returns nil only if no signature available.
    │  exponential smoothing on score (0.8*prev + 0.2*new)
    ▼  Task { @MainActor } publishes DetectedPose (keypoints w/ isStale + faceLandmarks + score)
ContentView
    ├── CameraPreviewView        (bottom layer, not rotated; faded out + removed 3 s after calibration)
    ├── PostureOverlayView       (Canvas, rotated with UI — fresh white, stale purple, face cyan)
    ├── ScoreHUDView             (108pt circle, color-coded score)
    ├── CalibrateButton / TrackingLoadingView / GuidedCalibrationOverlay / AlertOverlay
    └── onChange(score) → NotificationManager.update + PostureSoundCoach.update (skips nil scores)
                          → on alert / slouch / recovery: WatchBridge.shared.notify(...)
```

## Permissions & Build Settings

- **`INFOPLIST_KEY_NSCameraUsageDescription`** is set in both Debug and Release in `project.pbxproj`.
- **`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown"`**.
- **Bundle IDs**: iOS app `akamko.Posture-Buddy`; watch app `akamko.Posture-Buddy.watchkitapp` (`INFOPLIST_KEY_WKCompanionAppBundleIdentifier` on the watch target points back at the iOS app). Team: `ZC95DNC67Z`.
- **Deployment targets**: iOS 26.4, watchOS 26.4.

## Dev Workflow

- **Default end-of-change loop** (Claude should do this after every meaningful code change, not just when asked):
  1. Run `BuildProject` via the Xcode MCP — structured error output.
  2. If the build succeeds, run `./run.sh` from the project root — uses `osascript` to send Cmd+R to Xcode and launch on the connected device.
  3. If the build fails, fix the errors and repeat; don't call `run.sh` on a broken build.
- `run.sh` requires Accessibility permission for `osascript` (first run prompts; granted via System Settings → Privacy & Security → Accessibility). It's at the project root, chmod +x'd.
- Must test on a **physical device** — the Simulator has no camera.
- **SourceKit diagnostics frequently show stale false positives** (e.g., "No such module 'UIKit'", "'AVAudioSession' is unavailable in macOS", "Cannot find type X"). If `BuildProject` returns success, the build is good — ignore stale SourceKit errors.

## Gotchas Discovered

- **CMSampleBuffer race on startup**: `requestAccessAndSetup()` must await the `videoQueue.async` block (via `withCheckedContinuation`), otherwise `setSampleBufferDelegate` fires before `videoOutput` exists and frames are never delivered.
- **`FigCaptureSourceRemote err=-17281`** and similar Fig/VTEST/Espresso console errors on camera startup are usually benign — they fire during session negotiation and stop after the first valid frame.
- **"Frame received" spam**: log throttling (2-second interval) is important; pose estimation at 10 FPS can easily flood the console.
- **Tone pitch-shifting with `AVAudioPlayer.rate`** changes duration too — not used; we synthesize each pitch separately.
- **Idle timer**: `UIApplication.shared.isIdleTimerDisabled = true` when the scene is active, `false` when backgrounded, so the screen doesn't sleep during use.
- **`VNFaceObservation.yaw` is quantized to 45° even at revision 3+ in practice.** Despite Apple's docs. For continuous yaw on iOS 26, don't use the property — compute your own proxy from landmark geometry (`medianLine` offset within bbox is clean).
- **Single-axis yaw isn't enough** — but *which* axis fails depends on setup. In one camera angle "middle" and "left" collapse on direction (median-line offset) while "middle" and "right" stay separated; in another the opposite pair collapses on frontality. That's why classification uses an adaptive 2-feature pair selected from `YawTelemetry` at calibration time.
- **Ear-confidence ratio is mostly dead as a frontality signal.** The body-pose model typically only detects one ear when the phone is propped at the user's side (all three calibration positions are still substantially in profile), so `min/max` of the two ear confidences is ~0 across all positions. Kept in `YawTelemetry` for diagnostics, but `FrontalityFeature` doesn't include it.
- **`VNFaceObservation.boundingBox` aspect ratio is fixed** (observed ≈1.78 W/H in portrait, identical across all head positions). Vision sizes the bbox consistently regardless of how frontal the face is. Not a usable frontality proxy — don't try.
- **Face landmarks are in bounding-box-local coords**, not image-normalized. `VNFaceLandmarkRegion2D.normalizedPoints` ranges 0-1 within the face rect — you have to transform by `bbox.origin + p * bbox.size` to get image-space coordinates that match what the body pose model returns. For a yaw signal that's bbox-invariant, you can use normalized points directly without converting.
