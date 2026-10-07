import AppKit

enum TokenMenuBarIcon {
    static func image(hasAlert: Bool = false) -> NSImage {
        let width: CGFloat = 18
        let height: CGFloat = 18
        let size = NSSize(width: width, height: height)
        let img = NSImage(size: size, flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: 13, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let str = NSAttributedString(string: "搞", attributes: attrs)
            let strSize = str.size()
            let strRect = NSRect(
                x: (width - strSize.width) / 2.0,
                y: (height - strSize.height) / 2.0 - 0.5,
                width: strSize.width,
                height: strSize.height
            )
            str.draw(in: strRect)

            if hasAlert {
                let dotRect = NSRect(x: width - 5, y: height - 5, width: 4.5, height: 4.5)
                let dotPath = NSBezierPath(ovalIn: dotRect)
                NSColor.black.setFill()
                dotPath.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
