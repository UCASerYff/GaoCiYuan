import SwiftUI
import AppKit

/// The floating panel uses Claude's bundled native white flower. Keep the
/// original pixels and alpha; treating this image as a template would tint it
/// with quota or appearance colors. Other providers retain their shared mark.
private enum PanelClaudeIcon {
    static let image: NSImage? = {
        let image = TokenBundle.bundle.url(forResource: "claude-native-white-flower", withExtension: "png", subdirectory: "PanelIcons")
            .flatMap { NSImage(contentsOf: $0) }
        image?.isTemplate = false
        return image
    }()
}

struct PanelProviderMark: View {
    let provider: Provider
    var size: CGFloat = 18

    var body: some View {
        if provider == .claude, let image = PanelClaudeIcon.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
                // The rail is translucent in both appearances. A neutral dark
                // backing keeps the native white petals legible on light glass.
                .background(Color.black.opacity(0.72), in: Circle())
        } else {
            ProviderMark(provider: provider, size: size)
        }
    }
}
