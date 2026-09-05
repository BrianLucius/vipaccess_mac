import SwiftUI

/// A horizontal progress bar that fills proportionally to seconds remaining in the
/// current TOTP period. Color transitions from green → orange → red as time runs out.
struct ProgressBarView: View {
    let secondsRemaining: Int
    let period: Int

    var progressColor: Color {
        if secondsRemaining > 10 { return .green }
        else if secondsRemaining > 5 { return .orange }
        else { return .red }
    }

    var progressFraction: CGFloat {
        guard period > 0 else { return 0 }
        return CGFloat(secondsRemaining) / CGFloat(period)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 8)
                    .cornerRadius(4)

                Rectangle()
                    .fill(progressColor)
                    .frame(width: geometry.size.width * progressFraction, height: 8)
                    .cornerRadius(4)
                    .animation(.linear(duration: 1), value: secondsRemaining)
            }
        }
        .frame(height: 8)
    }
}
