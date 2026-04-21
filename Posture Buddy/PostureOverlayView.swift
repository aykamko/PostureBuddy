import SwiftUI
import Vision

struct PostureOverlayView: View {
    let detectedPose: DetectedPose?

    private static let connections: [(HumanBodyPose3DObservation.JointName, HumanBodyPose3DObservation.JointName)] = [
        // Head / spine
        (.topHead, .centerHead),
        (.centerHead, .spine),
        (.spine, .root),
        // Shoulders
        (.centerHead, .leftShoulder), (.centerHead, .rightShoulder),
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .spine), (.rightShoulder, .spine),
        // Hips
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
            let lineColor = gradeColor(pose.score.grade)

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
