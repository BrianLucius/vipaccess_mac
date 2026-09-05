import SwiftUI

// MARK: - 3D Copy Button Style

/// Replicates the Python tkinter 3D raised/pressed button effect with
/// gradient fills and directional border highlights/shadows.
struct CopyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let isActive = configuration.isPressed
        configuration.label
            .background(
                LinearGradient(
                    colors: isActive
                        ? [Color(white: 0.30), Color(white: 0.36)] // pressed: darker top, lighter bottom
                        : [Color(white: 0.37), Color(white: 0.26)], // normal: lighter top, darker bottom
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                // 3D border: highlight on top-left, shadow on bottom-right (inverted when pressed)
                Rectangle()
                    .strokeBorder(
                        LinearGradient(
                            colors: isActive
                                ? [Color(white: 0.18), Color(white: 0.40)] // pressed: dark top-left, light bottom-right
                                : [Color(white: 0.54), Color(white: 0.18)], // normal: light top-left, dark bottom-right
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            // Shift content on press to reinforce 3D inset effect
            .offset(x: isActive ? 1 : 0, y: isActive ? 1 : 0)
    }
}

/// The floating window that displays the current TOTP token prominently,
/// matching the original Python VIP Access GUI design with a dark theme
/// and card-based layout.
struct TokenWindowView: View {
    @ObservedObject var viewModel: TokenViewModel
    @State private var isPinned: Bool = false

    // Colors from Python DARK_THEME
    private let bgGradTop = Color(red: 0.165, green: 0.165, blue: 0.165) // #2a2a2a
    private let bgGradBottom = Color(red: 0.078, green: 0.078, blue: 0.078) // #141414
    private let sectionBg = Color(red: 0.176, green: 0.176, blue: 0.176) // #2d2d2d
    private let headerBg = Color(red: 0.227, green: 0.227, blue: 0.227) // #3a3a3a
    private let headerFg = Color(red: 0.878, green: 0.878, blue: 0.878) // #e0e0e0
    private let valueBg = Color(red: 0.102, green: 0.102, blue: 0.102) // #1a1a1a
    private let valueFg = Color(red: 0.816, green: 0.816, blue: 0.816) // #d0d0d0
    private let countdownFg = Color(red: 0.667, green: 0.667, blue: 0.667) // #aaaaaa
    private let statusFg = Color(red: 0.533, green: 0.533, blue: 0.533) // #888888
    private let progressBg = Color(red: 0.227, green: 0.227, blue: 0.227) // #3a3a3a
    private let btnBg = Color(red: 0.29, green: 0.29, blue: 0.29) // #4a4a4a
    private let btnFg = Color(red: 0.878, green: 0.878, blue: 0.878) // #e0e0e0

    var body: some View {
        VStack(spacing: 0) {
            // --- Credential ID Section ---
            sectionCard(
                headerText: "Credential ID",
                headerExtra: nil,
                valueHeight: 32,
                copyAction: { copyToClipboard(viewModel.credentialID) }
            ) {
                Text(viewModel.credentialID)
                    .font(.custom("Helvetica", size: 21).bold())
                    .foregroundColor(valueFg)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 6)
            .padding(.bottom, 4)

            // --- Security Code Section ---
            sectionCard(
                headerText: "Security Code",
                headerExtra: "\u{23F1} \(String(format: "%02d", viewModel.secondsRemaining))",
                valueHeight: 71,
                copyAction: { copyToClipboard(viewModel.currentCode) }
            ) {
                GeometryReader { geo in
                    ZStack {
                        // Current code centered at 35% height
                        Text(viewModel.currentCode)
                            .font(.custom("Helvetica-Bold", size: 43))
                            .foregroundColor(valueFg)
                            .position(x: geo.size.width / 2, y: 68 * 0.35)

                        // Next code centered at 82% height
                        Text(viewModel.nextCode)
                            .font(.custom("Helvetica", size: 19))
                            .foregroundColor(countdownFg)
                            .position(x: geo.size.width / 2, y: 68 * 0.82)
                    }
                    .contentShape(Rectangle()) // Make entire area tappable
                    .onTapGesture {
                        NSApp.activate(ignoringOtherApps: true)
                        copyToClipboard(viewModel.currentCode)
                    }
                }
            }
            .padding(.vertical, 4)

            // --- Progress Bar ---
            progressBar
                .padding(.top, 2)

            Spacer(minLength: 0)

            // --- Footer ---
            footer
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 6)
        .background(
            LinearGradient(
                colors: [bgGradTop, bgGradBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .frame(width: 250, height: 195)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let window = NSApp.windows.first(where: {
                    $0.title == "VIP Access" || $0.identifier?.rawValue == "token-window"
                }) {
                    window.isMovableByWindowBackground = true
                    window.acceptsMouseMovedEvents = true
                }
            }
        }
    }

    // MARK: - Section Card Builder

    @ViewBuilder
    private func sectionCard(
        headerText: String,
        headerExtra: String?,
        valueHeight: CGFloat,
        copyAction: @escaping () -> Void,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 0) {
            // Content area (header + value)
            VStack(spacing: 0) {
                // Header bar (20px)
                HStack {
                    Text(headerText)
                        .font(.custom("Helvetica", size: 15).bold())
                        .foregroundColor(headerFg)
                    Spacer()
                    if let extra = headerExtra {
                        Text(extra)
                            .font(.custom("Helvetica", size: 13))
                            .foregroundColor(countdownFg)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(
                    LinearGradient(
                        colors: [Color(white: 0.29), Color(white: 0.20)], // #4a4a4a → #333333
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Value area
                content()
                    .frame(maxWidth: .infinity)
                    .frame(height: valueHeight)
                    .background(
                        LinearGradient(
                            colors: [Color(white: 0.165), Color(white: 0.102)], // #2a2a2a → #1a1a1a
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .padding(.leading, 1)
                    .padding(.top, 0)
                    .padding(.bottom, 0)
            }

            // Copy button (48px wide, full height) with 3D raised/pressed effect
            Button(action: copyAction) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 18))
                    .foregroundColor(btnFg)
                    .frame(width: 36)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(CopyButtonStyle())
        }
        .background(sectionBg)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(
            Rectangle()
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
    }

    // MARK: - Progress Bar (no rounded corners, 7px tall)

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(progressBg)
                    .frame(height: 5)

                Rectangle()
                    .fill(progressColor)
                    .frame(width: geo.size.width * progressFraction, height: 5)
            }
        }
        .frame(height: 5)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Token Active")
                .font(.custom("Helvetica", size: 12))
                .foregroundColor(statusFg)

            Spacer()

            Button(action: { togglePin() }) {
                pinIcon
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pin Icon

    @ViewBuilder
    private var pinIcon: some View {
        let name = isPinned ? "pin_color" : "pin_grey"
        if let url = resourceBundle?.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 15))
                .foregroundColor(isPinned ? .red : statusFg)
        }
    }

    /// Safely locate the resource bundle without crashing if not found.
    private var resourceBundle: Bundle? {
        let bundleName = "VIPAccess_VIPAccess"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
        ]
        for candidate in candidates {
            if let bundlePath = candidate?.appendingPathComponent(bundleName + ".bundle"),
               let bundle = Bundle(url: bundlePath) {
                return bundle
            }
        }
        return nil
    }

    // MARK: - Helpers

    private var progressColor: Color {
        if viewModel.secondsRemaining > 10 {
            return Color(red: 0.298, green: 0.686, blue: 0.314) // #4CAF50
        } else if viewModel.secondsRemaining > 5 {
            return Color(red: 1.0, green: 0.596, blue: 0.0) // #FF9800
        } else {
            return Color(red: 0.957, green: 0.263, blue: 0.212) // #F44336
        }
    }

    private var progressFraction: CGFloat {
        guard viewModel.secondsRemaining > 0 else { return 0 }
        return min(CGFloat(viewModel.secondsRemaining) / 30.0, 1.0)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func togglePin() {
        isPinned.toggle()
        guard let window = NSApp.windows.first(where: {
            $0.title == "VIP Access" || $0.identifier?.rawValue == "token-window"
        }) else { return }
        window.level = isPinned ? .floating : .normal
    }
}
