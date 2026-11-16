import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var volume: Float = 0
    @Published var muted = false
    @Published var deviceName = ""
}

/// Small on-screen volume indicator, shown on the screen under the mouse pointer.
final class VolumeHUD {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(volume: Float, muted: Bool, deviceName: String) {
        model.volume = volume
        model.muted = muted
        model.deviceName = deviceName

        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        // A zero-length animation cancels any fade-out still in flight.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 90))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    private var level: CGFloat { model.muted ? 0 : CGFloat(model.volume) }

    private var icon: String {
        if model.muted || model.volume <= 0 { return "speaker.slash.fill" }
        if model.volume < 0.34 { return "speaker.wave.1.fill" }
        if model.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.15))
                        Capsule().fill(Color.primary).frame(width: geo.size.width * level)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 280, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
