import AppKit

/// A small overlay showing the external display's brightness after a key press,
/// since macOS shows nothing when the lid is closed.
final class BrightnessHUD {
    private let panel: NSPanel
    private let bar = LevelBar(frame: NSRect(x: 46, y: 21, width: 156, height: 6))
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 48),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 48))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 14, y: 12, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Brightness")
        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        icon.contentTintColor = .labelColor

        background.addSubview(icon)
        background.addSubview(bar)
        panel.contentView = background
    }

    /// Shows the overlay at `fraction` (0...1) on the external display, then fades it out.
    func show(_ fraction: Double) {
        bar.fraction = fraction
        let screen = NSScreen.screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return id.map { CGDisplayIsBuiltin($0) == 0 } ?? false
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 16))

        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                self?.panel.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

private final class LevelBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        var filled = bounds
        filled.size.width = bounds.width * min(max(fraction, 0), 1)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
