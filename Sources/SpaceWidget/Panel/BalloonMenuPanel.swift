import AppKit
import SwiftUI

final class BalloonMenuPanel: NSPanel {
    private let visualEffect = NSVisualEffectView()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let arrowHeight: CGFloat = 10
    private static let arrowWidth: CGFloat = 20
    private static let cornerRadius: CGFloat = 10
    private static let menuWidth: CGFloat = 200

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true

        visualEffect.material = .menu
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        contentView = visualEffect
    }

    func show<V: View>(content: V, anchorScreenPoint: NSPoint) {
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.frame = NSRect(x: 0, y: 0, width: Self.menuWidth, height: 0)
        let contentHeight = hosting.fittingSize.height

        let panelWidth = Self.menuWidth
        let panelHeight = contentHeight + Self.arrowHeight

        // Arrow sits at the left edge of the body; menu extends to the right (Dock-style)
        let arrowOffsetFromLeft: CGFloat = Self.cornerRadius + Self.arrowWidth / 2
        let origin = NSPoint(
            x: anchorScreenPoint.x - arrowOffsetFromLeft,
            y: anchorScreenPoint.y + 2
        )

        // Clamp to screen bounds
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            var clampedOrigin = origin
            if clampedOrigin.x < visibleFrame.minX { clampedOrigin.x = visibleFrame.minX }
            if clampedOrigin.x + panelWidth > visibleFrame.maxX { clampedOrigin.x = visibleFrame.maxX - panelWidth }
            setFrame(NSRect(origin: clampedOrigin, size: NSSize(width: panelWidth, height: panelHeight)), display: false)
        } else {
            setFrame(NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)), display: false)
        }

        // Apply balloon mask image (drawn at Retina scale for smooth anti-aliased edges)
        visualEffect.frame = NSRect(origin: .zero, size: NSSize(width: panelWidth, height: panelHeight))
        visualEffect.maskImage = Self.makeBalloonMaskImage(
            size: NSSize(width: panelWidth, height: panelHeight),
            arrowCenterX: arrowOffsetFromLeft
        )

        // Host content above arrow
        hosting.frame = NSRect(x: 0, y: Self.arrowHeight, width: panelWidth, height: contentHeight)
        visualEffect.subviews.forEach { $0.removeFromSuperview() }
        visualEffect.addSubview(hosting)

        orderFrontRegardless()
        installDismissMonitors()
    }

    func dismiss() {
        orderOut(nil)
        removeMonitors()
    }

    private static func makeBalloonMaskImage(size: NSSize, arrowCenterX: CGFloat) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelW = Int(size.width * scale)
        let pixelH = Int(size.height * scale)

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size  // point size — establishes 2x mapping

        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = true
        ctx.imageInterpolation = .high

        // Draw balloon path in point coordinates
        let r = cornerRadius
        let ah = arrowHeight
        let aw = arrowWidth / 2
        let cx = arrowCenterX
        let w = size.width
        let h = size.height

        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: ah + r))
        path.appendArc(from: NSPoint(x: 0, y: ah), to: NSPoint(x: r, y: ah), radius: r)
        path.line(to: NSPoint(x: cx - aw, y: ah))
        path.line(to: NSPoint(x: cx, y: 0))
        path.line(to: NSPoint(x: cx + aw, y: ah))
        path.line(to: NSPoint(x: w - r, y: ah))
        path.appendArc(from: NSPoint(x: w, y: ah), to: NSPoint(x: w, y: ah + r), radius: r)
        path.line(to: NSPoint(x: w, y: h - r))
        path.appendArc(from: NSPoint(x: w, y: h), to: NSPoint(x: w - r, y: h), radius: r)
        path.line(to: NSPoint(x: r, y: h))
        path.appendArc(from: NSPoint(x: 0, y: h), to: NSPoint(x: 0, y: h - r), radius: r)
        path.close()

        NSColor.white.setFill()
        path.fill()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private func installDismissMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.window !== self { self.dismiss() }
            return event
        }
    }

    private func removeMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}

// MARK: - Balloon menu content

struct BalloonMenuContent: View {
    let itemName: String
    let canNewWindow: Bool
    let onNewWindow: () -> Void
    let onCloseFromSpace: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BalloonMenuItem(title: "New Window", enabled: canNewWindow, action: onNewWindow)
            Divider().padding(.horizontal, 8)
            BalloonMenuItem(title: "Close from this Space", action: onCloseFromSpace)
            Divider().padding(.horizontal, 8)
            BalloonMenuItem(title: "Quit \(itemName)", action: onQuit)
        }
        .padding(.vertical, 4)
    }
}

private struct BalloonMenuItem: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(enabled ? .white : .white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered && enabled ? Color.accentColor : Color.clear)
                        .padding(.horizontal, 4)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { isHovered = $0 }
    }
}
