import SwiftUI
import AppKit

@main
struct NDIPlaygroundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let lockNote = Notification.Name("uvscope.toggleCameraLock")
    private let gridNote = Notification.Name("uvscope.toggleFloorGrid")


    @StateObject private var helpPanel = HelpPanelController()

    var body: some Scene {
        WindowGroup {
            ContentView()
            // ✅ Force SwiftUI side to dark + unify accent/tint (kills macOS blue)
            .preferredColorScheme(.dark)
            .tint(AppTheme.tint)
            .accentColor(AppTheme.tint)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Camera") {
                Button("Toggle Camera Lock") {
                    NotificationCenter.default.post(name: lockNote, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }

            CommandMenu("View") {
                Button("Toggle Floor Grid") {
                    NotificationCenter.default.post(name: gridNote, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command])
            }


            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts…") {
                    helpPanel.show()
                }
            }
        }
    }
}

// MARK: - App Delegate (force Dark Aqua safely)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // ✅ Force dark appearance even if macOS is in Light mode
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

// MARK: - Custom Panel

final class HelpHUDPanel: NSPanel {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onClose?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Help Panel Controller

@MainActor
final class HelpPanelController: ObservableObject {
    private var panel: HelpHUDPanel?

    func show() {
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let p = HelpHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.moveToActiveSpace, .transient]

        p.onClose = { [weak self] in self?.close() }

        let root = KeyboardShortcutsCard {
            self.close()
        }

        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 380)
        host.autoresizingMask = [.width, .height]

        // ✅ FIX: remove any opaque hosting background (kills the "gray square")
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false

        p.contentView = host

        // extra safety: make contentView transparent too
        p.contentView?.wantsLayer = true
        p.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView?.layer?.isOpaque = false

        p.center()
        panel = p

        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(host)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Card View

private struct KeyboardShortcutsCard: View {
    let onClose: () -> Void
    @State private var okHover = false

    private let cardW: CGFloat = 285
    private let cardH: CGFloat = 360

    var body: some View {
        ZStack {
            // ✅ absolutely no background here (prevents any square)
            Color.clear



            VStack(spacing: 0) {
                Spacer().frame(height: 30) // top safe

                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 70, height: 70)
                        .cornerRadius(16)

                    Text("Keyboard Shortcuts")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))

                    VStack(spacing: 12) {
                        section("Camera Presets")
                        row("⌘ 0…9", "Save camera preset")
                        row("⌥ 0…9", "Recall camera preset")

                        Spacer().frame(height: 6)

                        section("Camera")
                        row("⌘ L", "Camera Lock")
                        row("⌘ G", "Grid")
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 18)

                // ✅ FIX: explicit space between last row and button
                Spacer().frame(height: 14)

                Button {
                    onClose()
                } label: {
                    Text("OK")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 110, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(okHover ? 0.18 : 0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(okHover ? 0.22 : 0.14), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .onHover { okHover = $0 }

                Spacer().frame(height: 30) // bottom safe
            }
            .frame(width: cardW, height: cardH)
            .background(cardBackground)
            .overlay(cardStroke)
            .shadow(color: .black.opacity(0.65), radius: 26, x: 0, y: 14)
        }
        .frame(width: 300, height: 380)
        .environment(\.colorScheme, .dark)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 26)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.20), Color(white: 0.13)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 26)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func row(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Text(keys)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .frame(width: 96, alignment: .trailing)

            Text(text)
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white.opacity(0.86))
    }
}
