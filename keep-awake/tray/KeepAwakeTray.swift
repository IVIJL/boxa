import AppKit
import Foundation

struct Holder: Decodable {
    let agent: String
    let session: String?
    let remainingTTLSeconds: Int
}

struct KeepAwakeStatus: Decodable {
    let activeHolders: [Holder]
    let isInhibited: Bool
}

final class TrayDelegate: NSObject, NSApplicationDelegate {
    private let port: Int
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?

    override init() {
        if CommandLine.arguments.count > 1, let value = Int(CommandLine.arguments[1]) {
            port = value
        } else {
            port = 17777
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.menu = menu
        render(status: nil)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        guard let url = URL(string: "http://localhost:\(port)/v1/status") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let status = data.flatMap { try? JSONDecoder().decode(KeepAwakeStatus.self, from: $0) }
            DispatchQueue.main.async { self?.render(status: status) }
        }.resume()
    }

    private func render(status: KeepAwakeStatus?) {
        let busy = status?.isInhibited == true
        let color = busy ? NSColor.systemGreen : NSColor.systemGray
        statusItem.button?.attributedTitle = NSAttributedString(
            string: "●",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 16)]
        )
        statusItem.button?.toolTip = tooltip(status: status)

        menu.removeAllItems()
        if let status = status, busy {
            for holder in status.activeHolders {
                let session = holder.session.map { "/\($0)" } ?? ""
                let item = NSMenuItem(
                    title: "\(holder.agent)\(session) — \(holder.remainingTTLSeconds)s",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        } else {
            let title = status == nil ? "Daemon unavailable" : "Idle"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func tooltip(status: KeepAwakeStatus?) -> String {
        guard let status = status else { return "Boxa keep-awake: daemon unavailable" }
        guard status.isInhibited else { return "Boxa keep-awake: idle" }
        let holders = status.activeHolders.map { holder -> String in
            let session = holder.session.map { "/\($0)" } ?? ""
            return "\(holder.agent)\(session) (\(holder.remainingTTLSeconds)s)"
        }
        return "Boxa keep-awake: busy — " + holders.joined(separator: ", ")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = TrayDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
