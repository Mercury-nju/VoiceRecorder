import SwiftUI

// A restrained, native macOS visual language: calm surfaces, clear hierarchy, one accent.
enum VoiceColors {
    static let ink = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let paper = Color.white
    static let coral = Color(red: 0.96, green: 0.30, blue: 0.25)
    static let softCoral = Color(red: 1, green: 0.91, blue: 0.89)
    static let violet = Color(red: 0.38, green: 0.42, blue: 0.96)
    static let cyan = Color(red: 0.25, green: 0.48, blue: 0.56)
    static let lime = Color(red: 0.12, green: 0.65, blue: 0.38)
    static let line = Color(red: 0.89, green: 0.90, blue: 0.92)
}

struct AmbientBackdrop: View {
    var body: some View {
        ZStack { VoiceColors.paper }
        .ignoresSafeArea()
    }
}

struct GlassSurface<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(padding: CGFloat = 16, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(VoiceColors.line, lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.025), radius: 5, y: 1)
    }
}

struct GlassPill<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.045), in: Capsule())
            .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.6))
    }
}

struct AccentButtonStyle: ButtonStyle {
    var tint: Color = VoiceColors.coral

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 0.6))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

struct LiveDot: View {
    var active = true

    var body: some View {
        Circle()
            .fill(active ? VoiceColors.coral : Color.secondary.opacity(0.5))
            .frame(width: 7, height: 7)
    }
}
