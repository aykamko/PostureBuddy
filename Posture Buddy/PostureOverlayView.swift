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
            let lineColor = pose.score?.grade.swiftUIColor ?? .white.opacity(0.6)

            // Body skeleton
            for (a, b) in Self.connections {
                guard let ptA = kp[a], let ptB = kp[b] else { continue }
                var path = Path()
                path.move(to: visionToCanvas(ptA.location, in: size))
                path.addLine(to: visionToCanvas(ptB.location, in: size))
                context.stroke(path, with: .color(lineColor), lineWidth: 3)
            }
            for (_, keypoint) in kp {
                drawDot(at: visionToCanvas(keypoint.location, in: size), radius: 5, color: .white, in: &context)
            }

            // Face landmarks (debug overlay — cyan to stand out from the white body dots)
            if let face = pose.faceLandmarks {
                // Bounding box
                let bb = face.boundingBox
                let topLeft = visionToCanvas(CGPoint(x: bb.minX, y: bb.maxY), in: size)
                let bottomRight = visionToCanvas(CGPoint(x: bb.maxX, y: bb.minY), in: size)
                var boxPath = Path()
                boxPath.addRect(CGRect(
                    x: topLeft.x,
                    y: topLeft.y,
                    width: bottomRight.x - topLeft.x,
                    height: bottomRight.y - topLeft.y
                ))
                context.stroke(boxPath, with: .color(.cyan.opacity(0.6)), lineWidth: 1)

                for point in face.points {
                    drawDot(at: visionToCanvas(point, in: size), radius: 1.5, color: .cyan, in: &context)
                }
            }
        }
    }

    private func drawDot(at center: CGPoint, radius: CGFloat, color: Color, in context: inout GraphicsContext) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    private func visionToCanvas(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: pt.x * size.width, y: (1.0 - pt.y) * size.height)
    }
}
