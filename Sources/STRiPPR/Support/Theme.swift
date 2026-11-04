import SwiftUI

enum Theme {
    static let cyan = Color(red: 0.12, green: 0.91, blue: 0.96)
    static let pink = Color(red: 1, green: 0.23, blue: 0.65)
    static let green = Color(red: 0.38, green: 0.93, blue: 0.65)
    static let amber = Color(red: 1, green: 0.72, blue: 0.24)
    static let background = Color(red: 0.045, green: 0.052, blue: 0.075)
    static let surface = Color(red: 0.075, green: 0.084, blue: 0.11)
    static let border = Color.white.opacity(0.11)
}

struct ThinProgress: View {
    var value: Double
    var color: Color = Theme.cyan
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
