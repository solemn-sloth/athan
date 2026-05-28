import AppKit
import QuartzCore

private let kAnimationDuration: TimeInterval = 0.35
private let kWindowWidth: CGFloat = 280
private let kWindowHeight: CGFloat = 52
private let kCornerRadius: CGFloat = 26  // true pill = height / 2

private final class PillWindow: NSPanel {
    private let targetY: CGFloat
    private var skipAction: (() -> Void)?

    init(prayer: String, screen: NSScreen, onSkip: @escaping () -> Void) {
        self.skipAction = onSkip
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - kWindowWidth / 2
        let yVisible = screenFrame.maxY - kWindowHeight - 8
        let yHidden = screenFrame.maxY + 10
        self.targetY = yVisible

        super.init(
            contentRect: NSRect(x: x, y: yHidden, width: kWindowWidth, height: kWindowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none

        let content = NSView(frame: NSRect(x: 0, y: 0, width: kWindowWidth, height: kWindowHeight))

        let vibrancy = NSVisualEffectView(frame: content.bounds)
        vibrancy.autoresizingMask = [.width, .height]
        vibrancy.material = .popover
        vibrancy.state = .active
        vibrancy.blendingMode = .behindWindow
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = kCornerRadius
        vibrancy.layer?.masksToBounds = true
        content.addSubview(vibrancy)

        // Mosque emoji
        let emoji = NSTextField(labelWithString: "🕌")
        emoji.font = NSFont.systemFont(ofSize: 22)
        emoji.frame = NSRect(x: 14, y: (kWindowHeight - 28) / 2, width: 30, height: 28)
        content.addSubview(emoji)

        // Prayer name
        let label = NSTextField(labelWithString: prayer)
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .labelColor
        label.frame = NSRect(x: 50, y: (kWindowHeight - 20) / 2, width: 140, height: 20)
        content.addSubview(label)

        // Skip button — tinted, no bezel, matches macOS notification action style
        let skip = NSButton(title: "Skip", target: self, action: #selector(didSkip))
        skip.bezelStyle = .roundRect
        skip.controlSize = .small
        skip.font = .preferredFont(forTextStyle: .caption1)
        skip.contentTintColor = .controlAccentColor
        skip.frame = NSRect(x: kWindowWidth - 58, y: (kWindowHeight - 22) / 2, width: 46, height: 22)
        content.addSubview(skip)

        self.contentView = content
    }

    @objc private func didSkip() {
        skipAction?()
        skipAction = nil
    }

    func showAnimated(duration: TimeInterval, completion: @escaping () -> Void) {
        orderFrontRegardless()
        alphaValue = 0

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = kAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(
                NSRect(x: frame.origin.x, y: targetY, width: kWindowWidth, height: kWindowHeight),
                display: true
            )
            animator().alphaValue = 1.0
        }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                self.dismiss(completion: completion)
            }
        }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = kAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }) {
            self.orderOut(nil)
            completion?()
        }
    }
}

// MARK: - Entry

var prayer = "Athan"
var afplayPid: Int32 = 0
var duration: TimeInterval = 30

var args = CommandLine.arguments.dropFirst()
var it = args.makeIterator()
while let arg = it.next() {
    switch arg {
    case "--prayer": prayer = it.next() ?? prayer
    case "--pid":    afplayPid = Int32(it.next() ?? "0") ?? 0
    case "--duration": duration = Double(it.next() ?? "30") ?? 30
    default: break
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

class Delegate: NSObject, NSApplicationDelegate {
    fileprivate var window: PillWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(0) }

        window = PillWindow(prayer: prayer, screen: screen) {
            // Skip: kill afplay, dismiss
            if afplayPid > 0 { kill(afplayPid, SIGTERM) }
            NSApp.terminate(nil)
        }
        window?.showAnimated(duration: duration) {
            NSApp.terminate(nil)
        }
    }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
