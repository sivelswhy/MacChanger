import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    // macOS masque l'adresse MAC aux applications (02:00:00:00:00:00) : on ne l'affiche qu'après un changement.
    let macLabel = NSTextField(labelWithString: "—")
    let statusLabel = NSTextField(labelWithString: "")
    let button = NSButton(title: "Changer l'adresse MAC", target: nil, action: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        macLabel.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        macLabel.isSelectable = true
        statusLabel.textColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(change)
        button.controlSize = .large
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [NSTextField(labelWithString: "Adresse MAC Wi-Fi (en0)"), macLabel, button, statusLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        window.title = "MacChanger"
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func change() {
        let newMAC = randomMAC()
        // Le Wi-Fi doit être déconnecté pour accepter une nouvelle adresse :
        // on l'applique Wi-Fi éteint, sinon juste après le rallumage, avant qu'il ne se reconnecte.
        // On attend ensuite la reconnexion, puis on renvoie l'adresse finale (lisible seulement en root).
        let script = """
        networksetup -setairportpower en0 off; ifconfig en0 ether \(newMAC) 2>/dev/null; \
        networksetup -setairportpower en0 on; sleep 1; \
        if ! ifconfig en0 | grep -qi 'ether \(newMAC)'; then \
        networksetup -setairportpower en0 off; networksetup -setairportpower en0 on; \
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do \
        ifconfig en0 ether \(newMAC) 2>/dev/null; \
        ifconfig en0 | grep -qi 'ether \(newMAC)' && break; sleep 0.2; done; fi; \
        sleep 12; ifconfig en0 | awk '/ether/{print $2}'
        """
        button.isEnabled = false
        statusLabel.stringValue = "Changement en cours…"

        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(script)\" with administrator privileges"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try? p.run()
            p.waitUntilExit()
            let finalMAC = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

            DispatchQueue.main.async { [self] in
                button.isEnabled = true
                if p.terminationStatus != 0 {
                    statusLabel.stringValue = "Échec : \(error.trimmingCharacters(in: .whitespacesAndNewlines))"
                    return
                }
                macLabel.stringValue = finalMAC
                statusLabel.stringValue = finalMAC == newMAC
                    ? "Adresse changée ✓"
                    : "macOS a imposé son adresse privée (à désactiver dans les réglages Wi-Fi)"
            }
        }
    }
}

func randomMAC() -> String {
    var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
    bytes[0] = (bytes[0] & 0xFC) | 0x02 // adresse unicast, administrée localement
    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
