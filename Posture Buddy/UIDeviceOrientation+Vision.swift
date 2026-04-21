import ImageIO
import UIKit

extension UIDeviceOrientation {
    /// Vision image orientation hint for a front-camera sample buffer captured with
    /// this device orientation. Portrait-upside-down needs the mirrored-right flip;
    /// everything else (including face-up/down/unknown) maps to the portrait default.
    var visionOrientation: CGImagePropertyOrientation {
        self == .portraitUpsideDown ? .rightMirrored : .leftMirrored
    }
}
