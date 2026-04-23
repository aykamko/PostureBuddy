import CoreGraphics
import Vision

// MARK: - Pose frame data

struct DetectedPose {
    let keypoints: [VNHumanBodyPoseObservation.JointName: Keypoint]
    let faceLandmarks: FaceLandmarks?  // nil if no face detected
    let score: PostureScore?           // nil until user calibrates
}

/// 2D keypoint with a freshness flag. `isStale == true` means the live frame didn't
/// contain this joint at sufficient confidence and we're falling back to the last
/// known position from a recent frame. Surfaced visually so the user can tell when
/// the overlay is partially extrapolated.
struct Keypoint {
    let location: CGPoint
    let isStale: Bool
}

// Face landmarks in Vision's image-normalized coordinates (0-1, y-up from bottom).
// Points are already transformed out of the bounding box's local space.
struct FaceLandmarks {
    let points: [CGPoint]        // all face landmarks (eye outlines, nose, lips, contour, etc.)
    let boundingBox: CGRect      // image-normalized face box
}

// MARK: - Posture score

struct PostureScore {
    let value: Float
    let grade: Grade

    enum Grade {
        case good, fair, poor

        nonisolated var color: (red: Double, green: Double, blue: Double) {
            switch self {
            case .good: return (0.2, 0.8, 0.3)
            case .fair: return (1.0, 0.8, 0.0)
            case .poor: return (0.9, 0.2, 0.2)
            }
        }

        nonisolated var label: String {
            switch self {
            case .good: return "good"
            case .fair: return "fair"
            case .poor: return "poor"
            }
        }
    }

    nonisolated init(value: Float) {
        self.value = value
        switch value {
        case 75...: grade = .good
        case 60..<75: grade = .fair
        default: grade = .poor
        }
    }
}

// MARK: - Angles and baselines

// A snapshot of the side-profile angle + raw yaw telemetry for one frame.
// Baseline = same struct captured during calibration at one head position.
// Hip/shoulder-hip angle was dropped — the desk consistently occluded the hip in
// this camera setup, so scoring it made the app less reliable, not more.
struct PostureAngles {
    let earShoulderAngle: Float       // degrees from image-vertical
    // Raw candidate features for yaw classification. Nil if face wasn't detected.
    // The analyzer projects this into a `YawSignature` at scoring time using the
    // feature pair chosen during calibration (see YawCalibration).
    let yawTelemetry: YawTelemetry?
}

// A 2D point in the feature space chosen by calibration. Comparable across frames
// because both sides of any comparison use the same YawSelection extractor.
nonisolated struct YawSignature {
    let direction: Float
    let frontality: Float

    var debugString: String {
        String(format: "dir=%+.3f front=%.3f", direction, frontality)
    }

    func distance(to other: YawSignature) -> Float {
        let dd = direction - other.direction
        let df = frontality - other.frontality
        return sqrtf(dd * dd + df * df)
    }
}

// Debug-only bundle of candidate yaw features computed per frame. We don't use these
// for classification yet — the goal is to log them across middle/left/right during
// calibration and see which pair of axes actually separates the three positions in
// practice. Once we pick a pair, we can replace `YawSignature` and drop this struct.
nonisolated struct YawTelemetry {
    let medianX: Float?                // current direction signal (medianLine x-offset, bbox-local)
    let noseCrestX: Float?             // alt direction: nose-bridge centerline centroid offset
    let noseCentroidX: Float?          // alt direction: full `nose` region centroid offset
    let bboxAspectWH: Float            // face bbox width / height (profile → narrow, frontal → wide)
    let contourSpreadLocal: Float?     // faceContour x-spread, bbox-local (0-1)
    let contourSpreadOverH: Float?     // same, normalized by bbox height (yaw-invariant)
    let eyeSepLocal: Float?            // leftEye↔rightEye centroid distance, bbox-local
    let eyeSepOverH: Float?            // same, normalized by bbox height
    let allLandmarksSpreadLocal: Float?  // x-spread across all landmarks, bbox-local
    let earConfRatio: Float            // current frontality signal

    var debugString: String {
        func f3(_ v: Float?) -> String { v.map { String(format: "%+.3f", $0) } ?? "n/a" }
        func f2(_ v: Float?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
        return """
        med=\(f3(medianX)) crest=\(f3(noseCrestX)) nose=\(f3(noseCentroidX)) \
        aspect=\(f2(bboxAspectWH)) \
        contourW=\(f2(contourSpreadLocal)) contourW/H=\(f2(contourSpreadOverH)) \
        eyeSep=\(f2(eyeSepLocal)) eyeSep/H=\(f2(eyeSepOverH)) \
        allSpread=\(f2(allLandmarksSpreadLocal)) earRatio=\(f2(earConfRatio))
        """
    }

    static func from(
        face: VNFaceObservation?,
        body: VNHumanBodyPoseObservation
    ) -> YawTelemetry? {
        guard let face else { return nil }
        let bbox = face.boundingBox
        let aspectWH = bbox.height > 0 ? Float(bbox.width / bbox.height) : 0
        let wOverH: Float = bbox.height > 0 ? Float(bbox.width / bbox.height) : 0

        let landmarks = face.landmarks
        let medianX = centroidX(of: landmarks?.medianLine).map { $0 - 0.5 }
        let noseCrestX = centroidX(of: landmarks?.noseCrest).map { $0 - 0.5 }
        let noseCentroidX = centroidX(of: landmarks?.nose).map { $0 - 0.5 }

        let contourLocal = xSpread(of: landmarks?.faceContour)
        let contourOverH = contourLocal.map { $0 * wOverH }

        let leftEyeX = centroidX(of: landmarks?.leftEye)
        let rightEyeX = centroidX(of: landmarks?.rightEye)
        let eyeLocal: Float? = {
            guard let l = leftEyeX, let r = rightEyeX else { return nil }
            return abs(r - l)
        }()
        let eyeOverH = eyeLocal.map { $0 * wOverH }

        let allSpreadLocal = xSpread(of: landmarks?.allPoints)

        let leftEar = (try? body.recognizedPoint(.leftEar))?.confidence ?? 0
        let rightEar = (try? body.recognizedPoint(.rightEar))?.confidence ?? 0
        let maxEar = max(leftEar, rightEar)
        let earRatio = maxEar > 0 ? min(leftEar, rightEar) / maxEar : 0

        return YawTelemetry(
            medianX: medianX,
            noseCrestX: noseCrestX,
            noseCentroidX: noseCentroidX,
            bboxAspectWH: aspectWH,
            contourSpreadLocal: contourLocal,
            contourSpreadOverH: contourOverH,
            eyeSepLocal: eyeLocal,
            eyeSepOverH: eyeOverH,
            allLandmarksSpreadLocal: allSpreadLocal,
            earConfRatio: earRatio
        )
    }

    private static func centroidX(of region: VNFaceLandmarkRegion2D?) -> Float? {
        guard let pts = region?.normalizedPoints, !pts.isEmpty else { return nil }
        return pts.reduce(Float(0)) { $0 + Float($1.x) } / Float(pts.count)
    }

    private static func xSpread(of region: VNFaceLandmarkRegion2D?) -> Float? {
        guard let pts = region?.normalizedPoints, !pts.isEmpty else { return nil }
        let xs = pts.map { Float($0.x) }
        guard let lo = xs.min(), let hi = xs.max() else { return nil }
        return hi - lo
    }
}

// MARK: - Adaptive yaw feature selection

/// One of several candidate signals for left/right head rotation. The right one depends
/// on camera angle / user anatomy — we pick the best via calibration.
enum DirectionFeature: String, CaseIterable {
    case medianLine
    case noseCrest
    case noseCentroid

    func extract(_ t: YawTelemetry) -> Float? {
        switch self {
        case .medianLine: return t.medianX
        case .noseCrest: return t.noseCrestX
        case .noseCentroid: return t.noseCentroidX
        }
    }
}

/// Candidate signals for how frontal the face is (distinguishing "deep profile" from
/// "3/4 view toward camera"). Picked adaptively at calibration.
enum FrontalityFeature: String, CaseIterable {
    case eyeSeparationOverHeight
    case contourSpreadOverHeight
    case allLandmarksSpread

    func extract(_ t: YawTelemetry) -> Float? {
        switch self {
        case .eyeSeparationOverHeight: return t.eyeSepOverH
        case .contourSpreadOverHeight: return t.contourSpreadOverH
        case .allLandmarksSpread: return t.allLandmarksSpreadLocal
        }
    }
}

/// The chosen pair of features. Projects a raw YawTelemetry into a 2D YawSignature.
struct YawSelection {
    let direction: DirectionFeature
    let frontality: FrontalityFeature

    func signature(from t: YawTelemetry) -> YawSignature? {
        guard let d = direction.extract(t), let f = frontality.extract(t) else { return nil }
        return YawSignature(direction: d, frontality: f)
    }
}

/// Everything yaw-related produced by a successful calibration: which features to use,
/// the three baseline signatures, and a data-derived classification threshold. The
/// threshold is half the minimum pairwise distance among the three baselines, so each
/// baseline gets a Voronoi-ish acceptance radius that never overlaps its neighbors.
struct YawCalibration {
    let selection: YawSelection
    let middle: YawSignature
    let left: YawSignature
    let right: YawSignature
    let classificationThreshold: Float
    let minPairwiseDistance: Float   // kept for logging / diagnostics

    /// Picks the (direction, frontality) pair whose three baseline points have the
    /// largest minimum pairwise distance — i.e. the pair that most reliably tells the
    /// three positions apart for this particular user + camera setup.
    static func make(
        middle mT: YawTelemetry,
        left lT: YawTelemetry,
        right rT: YawTelemetry
    ) -> YawCalibration? {
        var best: YawCalibration?
        for dir in DirectionFeature.allCases {
            for front in FrontalityFeature.allCases {
                let sel = YawSelection(direction: dir, frontality: front)
                guard
                    let m = sel.signature(from: mT),
                    let l = sel.signature(from: lT),
                    let r = sel.signature(from: rT)
                else { continue }
                let dML = m.distance(to: l)
                let dLR = l.distance(to: r)
                let dMR = m.distance(to: r)
                let minDist = min(dML, dLR, dMR)
                // Require non-trivial separation — otherwise this pair is useless.
                guard minDist > 0.01 else { continue }
                let candidate = YawCalibration(
                    selection: sel,
                    middle: m,
                    left: l,
                    right: r,
                    classificationThreshold: minDist * 0.5,
                    minPairwiseDistance: minDist
                )
                if best == nil || minDist > best!.minPairwiseDistance {
                    best = candidate
                }
            }
        }
        return best
    }

    /// Diagnostic classification: distances to every baseline, which one is closest,
    /// the threshold, and whether the frame was accepted. Analyzer uses
    /// `.acceptedPosition`; logs consume the rest.
    func classify(_ sig: YawSignature) -> YawClassification {
        let dM = sig.distance(to: middle)
        let dL = sig.distance(to: left)
        let dR = sig.distance(to: right)
        let pairs: [(CalibrationPosition, Float)] = [(.middle, dM), (.left, dL), (.right, dR)]
        let best = pairs.min { $0.1 < $1.1 }!
        return YawClassification(
            middleDistance: dM,
            leftDistance: dL,
            rightDistance: dR,
            closest: best.0,
            closestDistance: best.1,
            threshold: classificationThreshold
        )
    }
}

struct YawClassification {
    let middleDistance: Float
    let leftDistance: Float
    let rightDistance: Float
    let closest: CalibrationPosition
    let closestDistance: Float
    let threshold: Float

    // Informational — whether the nearest baseline is within the calibration-derived
    // acceptance radius. Surfaced in logs as ✓/✗ for quick scanning; no longer gates scoring.
    var isHighConfidence: Bool { closestDistance <= threshold }

    var debugString: String {
        String(
            format: "m=%.3f l=%.3f r=%.3f → %@ %@",
            middleDistance, leftDistance, rightDistance,
            closest.rawValue, isHighConfidence ? "✓" : "✗"
        )
    }
}

// Calibrated baselines + the adaptive yaw calibration derived from them.
// `forwardLean` is captured at the same yaw as `middle` but with the user intentionally
// slouching; `forwardSign` is the sign that (current − baseline) takes when the user
// leans forward (derived from forwardLean − middle). Nil if the user's lean-forward
// gesture didn't produce a confident enough delta — scoring falls back to symmetric.
struct PostureBaselines {
    let middle: PostureAngles
    let forwardLean: PostureAngles
    let left: PostureAngles
    let right: PostureAngles
    let yaw: YawCalibration
    let forwardSign: Float?
}

enum CalibrationPosition: String {
    case middle, left, right
}

// MARK: - Median helpers

/// Componentwise median across a burst of per-frame snapshots. Single-frame calibration
/// captures were getting skewed by detector jitter (e.g. `contourSpreadOverH` spiking
/// high for one frame); taking the median of 6–10 snapshots gives a baseline that's
/// actually representative of the user's steady-state position.
extension PostureAngles {
    static func median(of samples: [PostureAngles]) -> PostureAngles? {
        guard !samples.isEmpty else { return nil }
        let ear = Self.median(samples.map { $0.earShoulderAngle })!
        let telemetries = samples.compactMap { $0.yawTelemetry }
        return PostureAngles(
            earShoulderAngle: ear,
            yawTelemetry: telemetries.isEmpty ? nil : YawTelemetry.median(of: telemetries)
        )
    }

    fileprivate static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

extension YawTelemetry {
    static func median(of samples: [YawTelemetry]) -> YawTelemetry {
        func medOpt(_ key: KeyPath<YawTelemetry, Float?>) -> Float? {
            PostureAngles.median(samples.compactMap { $0[keyPath: key] })
        }
        func med(_ key: KeyPath<YawTelemetry, Float>) -> Float {
            PostureAngles.median(samples.map { $0[keyPath: key] }) ?? 0
        }
        return YawTelemetry(
            medianX: medOpt(\.medianX),
            noseCrestX: medOpt(\.noseCrestX),
            noseCentroidX: medOpt(\.noseCentroidX),
            bboxAspectWH: med(\.bboxAspectWH),
            contourSpreadLocal: medOpt(\.contourSpreadLocal),
            contourSpreadOverH: medOpt(\.contourSpreadOverH),
            eyeSepLocal: medOpt(\.eyeSepLocal),
            eyeSepOverH: medOpt(\.eyeSepOverH),
            allLandmarksSpreadLocal: medOpt(\.allLandmarksSpreadLocal),
            earConfRatio: med(\.earConfRatio)
        )
    }
}
