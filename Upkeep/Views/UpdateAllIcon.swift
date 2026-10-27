import AppKit

/// The Update All toolbar icon while updates run: a solid arc for the finished part,
/// a dashed arc for the rest, and a down arrow inside. It is drawn as a template image
/// because the toolbar gives a custom view its own glass, which would split the button
/// from the group beside it.
enum UpdateAllIcon {
    static func image(fraction: Double, side: CGFloat = 17) -> NSImage {
        let progress = min(max(fraction, 0), 1)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lineWidth: CGFloat = 1.5
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = (min(rect.width, rect.height) - lineWidth) / 2
            // Clockwise from the top, the way progress fills.
            let start: CGFloat = 90
            let end = start - 360 * progress
            NSColor.black.setStroke()

            if progress < 1 {
                let remaining = NSBezierPath()
                remaining.appendArc(
                    withCenter: center, radius: radius, startAngle: end, endAngle: start - 360,
                    clockwise: true)
                remaining.lineWidth = lineWidth
                remaining.lineCapStyle = .round
                remaining.setLineDash([0.1, 2.6], count: 2, phase: 0)
                remaining.stroke()
            }
            if progress > 0 {
                let finished = NSBezierPath()
                finished.appendArc(
                    withCenter: center, radius: radius, startAngle: start, endAngle: end,
                    clockwise: true)
                finished.lineWidth = lineWidth
                finished.lineCapStyle = .round
                finished.stroke()
            }

            let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .semibold)
            if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            {
                let size = arrow.size
                arrow.draw(
                    in: NSRect(
                        x: center.x - size.width / 2, y: center.y - size.height / 2,
                        width: size.width, height: size.height))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
