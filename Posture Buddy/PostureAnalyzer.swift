import Vision
import simd

struct PostureScore {
    let value: Float
    let grade: Grade

    enum Grade {
        case good, fair, poor

        var color: (red: Double, green: Double, blue: Double) {
            switch self {
            case .good: return (0.2, 0.8, 0.3)
            case .fair: return (1.0, 0.8, 0.0)
            case .poor: return (0.9, 0.2, 0.2)
            }
        }
    }

    nonisolated init(value: Float) {
        self.value = value
        switch value {
        case 80...: grade = .good
        case 60..<80: grade = .fair
        default: grade = .poor
        }
    }
}

struct PostureAnalyzer {
    // Degrees from the body's own up-axis at which score hits zero.
    // 3D positions are in true meters; 5-15° is typical forward-head, 20° is clearly poor.
    private nonisolated static let maxAngle: Float = 20.0

    nonisolated func analyze3D(_ observation: HumanBodyPose3DObservation) -> PostureScore? {
        func position(_ name: HumanBodyPose3DObservation.JointName) -> simd_float3 {
            let m = observation.cameraRelativePosition(for: name)
            return simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }

        let head = position(.centerHead)
        let leftShoulder = position(.leftShoulder)
        let rightShoulder = position(.rightShoulder)
        let root = position(.root)

        let shoulderMid = (leftShoulder + rightShoulder) * 0.5

        // Use the body's own axis (root → shoulders) as "up" instead of gravity — this makes
        // the measurement intrinsic to the body, so it doesn't matter how the camera is tilted.
        let bodyUp = simd_normalize(shoulderMid - root)
        let headOffset = head - shoulderMid

        // Decompose headOffset into a component along bodyUp and a perpendicular component.
        // A perfectly-stacked posture has a large positive upComponent and near-zero perpComponent.
        let upComponent = simd_dot(headOffset, bodyUp)
        let perp = headOffset - bodyUp * upComponent
        let perpMag = simd_length(perp)

        // If the head is below shoulders (upComponent <= 0), posture is collapsed — score 0.
        guard upComponent > 0 else { return PostureScore(value: 0) }

        let angle = atan2(perpMag, upComponent) * 180 / .pi
        let score = max(0, 1.0 - angle / Self.maxAngle) * 100
        return PostureScore(value: score)
    }
}
