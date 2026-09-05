import SwiftUI
import AppKit

/// Custom view for the NSStatusItem button showing the 6-digit TOTP token
/// and a thin color-coded progress bar indicating time remaining.
///
/// Layout:
/// - Top: 6-digit token in monospaced font
/// - Bottom: 2px-tall progress bar that fills left-to-right proportional
///   to remaining seconds. Color thresholds: green > 10s, orange > 5s, red <= 5s.
struct StatusItemView: View {
    let code: String
    let secondsRemaining: Int
    let period: Int

    /// Progress bar color based on time remaining thresholds.
    var progressColor: Color {
        if secondsRemaining > 10 {
            return .green
        } else if secondsRemaining > 5 {
            return .orange
        } else {
            return .red
        }
    }

    /// Fraction of the period remaining, from 0.0 to 1.0.
    var progressFraction: CGFloat {
        guard period > 0 else { return 0 }
        return CGFloat(secondsRemaining) / CGFloat(period)
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)

            GeometryReader { geometry in
                Rectangle()
                    .fill(progressColor)
                    .frame(width: geometry.size.width * progressFraction, height: 2)
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 4)
    }
}
