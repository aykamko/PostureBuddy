import SwiftUI
import Vision

struct PostureOverlayView: View {
    let detectedPose: DetectedPose?

    private static let connections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        // Head
        (.nose, .leftEye), (.nose, .rightEye),
        (.leftEye, .leftEar), (.rightEye, .rightEar),
        // Neck to head and shoulders
        (.neck, .nose),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        // Ears to shoulders (side profile spine line)
        (.leftEar, .leftShoulder), (.rightEar, .rightShoulder),
        // Torso
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .root), (.rightHip, .root),
        // Arms
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        // Legs
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    var body: some View {
        Canvas { context, size in
            guard let pose = detectedPose else { return }
            let kp = pose.keypoints
            let lineColor = pose.score.map { gradeColor($0.grade) } ?? .white.opacity(0.6)

            for (a, b) in Self.connections {
                guard let ptA = kp[a], let ptB = kp[b] else { continue }
                var path = Path()
                path.move(to: visionToCanvas(ptA, in: size))
                path.addLine(to: visionToCanvas(ptB, in: size))
                context.stroke(path, with: .color(lineColor), lineWidth: 3)
            }

            for (_, point) in kp {
                let center = visionToCanvas(point, in: size)
                let rect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: rect), with: .color(.white))
            }
        }
    }

    private func visionToCanvas(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: pt.x * size.width, y: (1.0 - pt.y) * size.height)
    }

    private func gradeColor(_ grade: PostureScore.Grade) -> Color {
        let c = grade.color
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}
