import SwiftUI

extension PostureScore.Grade {
    var swiftUIColor: Color {
        let c = color
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}
