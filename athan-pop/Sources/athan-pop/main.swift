import AppKit
import QuartzCore

private let kAnimationDuration: TimeInterval = 0.35
private let kWindowHeight: CGFloat = 44
private let kCornerRadius: CGFloat = 22  // true pill = height / 2

private final class PillWindow: NSPanel {
    private let targetY: CGFloat
    private var skipAction: (() -> Void)?

    init(prayer: String, screen: NSScreen, onSkip: @escaping () -> Void) {
        self.skipAction = onSkip

        // Measure label width so the pill hugs the content
        let labelFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let labelWidth = (prayer as NSString).size(withAttributes: [.font: labelFont]).width.rounded(.up) + 6
        let kPad: CGFloat = 18
        let kGap: CGFloat = 14
        let kEmojiW: CGFloat = 26
        let kCloseW: CGFloat = 20    // circular x button
        let windowWidth = kPad + kEmojiW + kGap + labelWidth + kGap + kCloseW + kPad

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - windowWidth / 2
        let yVisible = screenFrame.maxY - kWindowHeight - 8
        let yHidden = screenFrame.maxY + 10
        self.targetY = yVisible

        super.init(
            contentRect: NSRect(x: x, y: yHidden, width: windowWidth, height: kWindowHeight),
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

        // Use NSVisualEffectView directly as contentView — required for blur to work in borderless panels
        let vibrancy = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: kWindowHeight))
        vibrancy.material = .menu
        vibrancy.state = .active
        vibrancy.blendingMode = .behindWindow
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = kCornerRadius
        vibrancy.layer?.masksToBounds = true

        // Mosque emoji
        let emoji = NSTextField(labelWithString: "🕌")
        emoji.font = NSFont.systemFont(ofSize: 20)
        emoji.frame = NSRect(x: kPad, y: (kWindowHeight - 24) / 2, width: kEmojiW, height: 24)
        vibrancy.addSubview(emoji)

        // Prayer name
        let label = NSTextField(labelWithString: prayer)
        label.font = labelFont
        label.textColor = .labelColor
        label.frame = NSRect(x: kPad + kEmojiW + kGap, y: (kWindowHeight - 18) / 2, width: labelWidth, height: 18)
        vibrancy.addSubview(label)

        // Circular × close button using SF Symbol
        let closeX = kPad + kEmojiW + kGap + labelWidth + kGap
        let close = NSButton(frame: NSRect(x: closeX, y: (kWindowHeight - kCloseW) / 2, width: kCloseW, height: kCloseW))
        close.bezelStyle = .circular
        close.isBordered = false
        let xImage = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        close.image = xImage
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        close.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        close.target = self
        close.action = #selector(didSkip)
        vibrancy.addSubview(close)

        self.contentView = vibrancy
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
                NSRect(x: frame.origin.x, y: targetY, width: frame.width, height: kWindowHeight),
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
