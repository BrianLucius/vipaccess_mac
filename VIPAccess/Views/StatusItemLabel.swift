import SwiftUI
import AppKit

/// A compact label for the `MenuBarExtra` that renders the 6-digit token
/// with a 2px color-coded progress bar beneath it as a rendered image.
///
/// macOS clips `VStack` content inside `MenuBarExtra` labels to a single line,
/// so we use `ImageRenderer` to composite the text and bar into an `NSImage`.
///
/// Color thresholds: green > 10s, orange > 5s, red <= 5s.
struct StatusItemLabel: View {
    let code: String
    let secondsRemaining: Int
    let period: Int

    var body: some View {
        // Render the composite view (text + bar) as an image
        // because MenuBarExtra clips VStack content
        Image(nsImage: renderLabel())
    }

    @MainActor
    private func renderLabel() -> NSImage {
        let progressColor: Color = {
            if secondsRemaining > 10 { return .green }
            else if secondsRemaining > 5 { return .orange }
            else { return .red }
        }()

        let fraction: CGFloat = {
            guard period > 0 else { return 0 }
            return min(max(CGFloat(secondsRemaining) / CGFloat(period), 0), 1)
        }()

        let barWidth: CGFloat = 52

        let content = VStack(spacing: 1) {
            Text(code)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            Rectangle()
                .fill(progressColor)
                .frame(width: barWidth * fraction, height: 2)
                .frame(width: barWidth, height: 2, alignment: .leading)
        }
        .frame(width: barWidth + 8, height: 18)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0

        guard let cgImage = renderer.cgImage else {
            return NSImage()
        }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: barWidth + 8, height: 18))
        nsImage.isTemplate = false  // Keep colored progress bar, not template tinting
        return nsImage
    }
}
