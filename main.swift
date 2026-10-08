import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    // macOS masque l'adresse MAC aux applications (02:00:00:00:00:00) : on ne l'affiche qu'après un changement.
    let macLabel = NSTextField(labelWithString: "—")
    let statusLabel = NSTextField(labelWithString: "")
    let button = NSButton(title: "Changer l'adresse MAC", target: nil, action: nil)
    let monitorBox = NSButton(checkboxWithTitle: "Surveiller les crédits (NormandieTrainConnecte)", target: nil, action: nil)
    let creditsLabel = NSTextField(labelWithString: "")
    // Crédits restants affichés dans la barre des menus.
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    // Surveillance : quand les crédits du portail tombent à 0, on change d'adresse pour repartir à 100 %.
    let portal = URL(string: "http://wifi.normandie.fr")!
    let captive = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    var timer: Timer?
    var checking = false
    var lastChange = Date.distantPast
    // Le portail est une application JavaScript : on le charge dans un navigateur invisible
    // pour lire les crédits et accepter les CGU comme le ferait un humain.
    let web: WKWebView = {
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        w.alphaValue = 0.01
        return w
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        macLabel.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        macLabel.isSelectable = true
        statusLabel.textColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(change)
        button.controlSize = .large
        button.keyEquivalent = "\r"
        monitorBox.target = self
        monitorBox.action = #selector(toggleMonitor)
        creditsLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [NSTextField(labelWithString: "Adresse MAC Wi-Fi (en0)"), macLabel, button, statusLabel,
                                        monitorBox, creditsLabel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        setupStatusItem()

        window.title = "MacChanger"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        stack.addSubview(web, positioned: .below, relativeTo: nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // L'app reste active dans la barre des menus quand la fenêtre est fermée.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func setupStatusItem() {
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusItem.button?.toolTip = "MacChanger — crédits Wi-Fi restants"
        showCredits(nil)
        let menu = NSMenu()
        menu.addItem(withTitle: "Afficher MacChanger", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "Changer l'adresse MAC", action: #selector(change), keyEquivalent: "")
        menu.addItem(withTitle: "Vérifier les crédits maintenant", action: #selector(checkNow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    // Nombre de crédits restants dans la barre des menus, « – » s'il est inconnu.
    func showCredits(_ credits: Int?, text: String? = nil) {
        statusItem.button?.title = text ?? credits.map { "\($0) %" } ?? "–"
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func checkNow() {
        if monitorBox.state != .on {
            monitorBox.state = .on
            toggleMonitor()
        } else {
            tick()
        }
    }

    @objc func change() { changeMAC(completion: nil) }

    func changeMAC(completion: ((Bool) -> Void)?) {
        let newMAC = randomMAC()
        button.isEnabled = false
        statusLabel.stringValue = "Changement en cours…"
        let installed = (try? String(contentsOfFile: helperPath, encoding: .utf8)) == helperScript

        DispatchQueue.global().async {
            // Sans mot de passe une fois l'outil installé ; sinon une seule demande pour l'installer.
            var result = installed ? run("/usr/bin/sudo", ["-n", helperPath, newMAC]) : nil
            if result?.status != 0, let installer = prepareHelper() {
                result = run("/usr/bin/osascript",
                             ["-e", "do shell script \"\(installer) && \(helperPath) \(newMAC)\" with administrator privileges"])
            }
            let (status, finalMAC, error) = result ?? (1, "", "installation impossible")

            DispatchQueue.main.async { [self] in
                button.isEnabled = true
                log("changement d'adresse → \(status == 0 ? finalMAC : error)")
                completion?(status == 0)
                if status != 0 {
                    statusLabel.stringValue = "Échec : \(error)"
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

let helperPath = "/Library/PrivilegedHelperTools/local.macchanger.rotate"

// Outil installé en root : change l'adresse MAC Wi-Fi puis rejoint le même réseau. Une règle sudo
// permet à l'utilisateur de le lancer sans mot de passe, pour que la rotation soit automatique.
let helperScript = #"""
#!/bin/sh
# Installé par MacChanger. Usage : sudo local.macchanger.rotate aa:bb:cc:dd:ee:ff
IFACE=en0
MAC="$1"
echo "$MAC" | grep -Eq '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || { echo "adresse invalide" >&2; exit 2; }
SSID=$(ipconfig getsummary $IFACE 2>/dev/null | awk -F' : ' '/ SSID : /{print $2; exit}')
has_mac() { ifconfig $IFACE | grep -qi "ether $MAC"; }
has_ip() { ipconfig getifaddr $IFACE >/dev/null 2>&1; }

# Le Wi-Fi doit être déconnecté pour accepter une nouvelle adresse : on l'applique Wi-Fi éteint,
# sinon juste après le rallumage, avant qu'il ne se reconnecte.
networksetup -setairportpower $IFACE off
ifconfig $IFACE ether "$MAC" 2>/dev/null
networksetup -setairportpower $IFACE on
sleep 1
if ! has_mac; then
    networksetup -setairportpower $IFACE off
    networksetup -setairportpower $IFACE on
    for i in $(seq 20); do
        ifconfig $IFACE ether "$MAC" 2>/dev/null
        has_mac && break
        sleep 0.2
    done
fi

# Attend une adresse IP ; si macOS ne rejoint pas le réseau tout seul, on le rejoint explicitement.
for i in $(seq 15); do has_ip && break; sleep 1; done
if ! has_ip && [ -n "$SSID" ]; then
    networksetup -setairportnetwork $IFACE "$SSID" >/dev/null 2>&1
    for i in $(seq 20); do has_ip && break; sleep 1; done
fi
ifconfig $IFACE | awk '/ether/{print $2}'
"""#

// Prépare l'outil et sa règle sudo dans un dossier temporaire privé, et renvoie
// la commande (à lancer en administrateur) qui les installe.
func prepareHelper() -> String? {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macchanger-\(UUID().uuidString)")
    let helper = dir.appendingPathComponent("helper"), sudoers = dir.appendingPathComponent("sudoers")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try helperScript.write(to: helper, atomically: true, encoding: .utf8)
        try "\(NSUserName()) ALL=(root) NOPASSWD: \(helperPath)\n".write(to: sudoers, atomically: true, encoding: .utf8)
    } catch { return nil }
    return "install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools"
        + " && install -o root -g wheel -m 755 '\(helper.path)' \(helperPath)"
        + " && visudo -cf '\(sudoers.path)' && install -o root -g wheel -m 440 '\(sudoers.path)' /etc/sudoers.d/macchanger"
        + " && rm -rf '\(dir.path)'"
}

// Lance une commande et renvoie son code de sortie, sa sortie et ses erreurs.
func run(_ tool: String, _ arguments: [String]) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return (1, "", error.localizedDescription) }
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

extension AppDelegate {
    @objc func toggleMonitor() {
        timer?.invalidate()
        timer = nil
        guard monitorBox.state == .on else {
            creditsLabel.stringValue = ""
            showCredits(nil)
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func tick() {
        guard !checking, button.isEnabled else { return }
        checking = true
        Task {
            defer { checking = false }
            // wifi.normandie.fr n'existe que sur le réseau du train ; sinon le portail
            // se reconnaît à la page qu'il renvoie à la place de celle d'Apple.
            let check = await fetch(captive)
            let online = check?.contains("Success") == true
            let intercepted = online ? false : check?.localizedCaseInsensitiveContains("normandie") == true
            guard await fetch(portal) != nil || intercepted else {
                creditsLabel.stringValue = "Pas connecté au Wi-Fi du train"
                showCredits(nil)
                return
            }
            let status = await readCredits()
            let credits = status.percent
            let time = Date().formatted(date: .omitted, time: .shortened)
            let shown = status.description
            showCredits(credits)

            switch status {
            case .noGrant:
                // Aucun forfait pour cette adresse : il suffit d'accepter les CGU pour en obtenir un.
                creditsLabel.stringValue = "\(time) — aucun forfait actif, acceptation des CGU…"
                creditsLabel.stringValue = await acceptPortal()
                    ? "\(time) — conditions acceptées ✓"
                    : "\(time) — accepte les CGU du portail"
            case .left(percent: 0, _):
                await rotate()
            case .left:
                // Forfait actif mais Internet coupé : simple coupure du réseau du train (tunnel…).
                creditsLabel.stringValue = online
                    ? "\(time) — en ligne, crédits : \(shown)"
                    : "\(time) — réseau du train coupé, crédits : \(shown)"
            case .unknown:
                if online {
                    creditsLabel.stringValue = "\(time) — en ligne, crédits inconnus"
                } else {
                    creditsLabel.stringValue = await acceptPortal()
                        ? "\(time) — conditions acceptées ✓"
                        : "\(time) — hors ligne : accepte les CGU du portail"
                }
            }
        }
    }

    func rotate() async {
        // Évite d'enchaîner les changements pendant que le portail se met à jour.
        guard Date().timeIntervalSince(lastChange) > 120 else { return }
        lastChange = Date()
        creditsLabel.stringValue = "Crédits épuisés → nouvelle adresse MAC…"
        showCredits(nil, text: "…")
        let ok = await withCheckedContinuation { c in changeMAC { c.resume(returning: $0) } }
        guard ok else { return }
        creditsLabel.stringValue = "Acceptation des conditions du portail…"
        if await acceptPortal() {
            creditsLabel.stringValue = "Nouvelle adresse, conditions acceptées ✓"
            showCredits(await fetchStatus()?.percent ?? 100)
        } else {
            creditsLabel.stringValue = "Accepte les conditions du portail pour retrouver 100 %"
            showCredits(nil, text: "!")
            NSWorkspace.shared.open(portal)
            NSApp.requestUserAttention(.criticalRequest)
        }
    }

    // Coche « J'accepte les CGU » puis clique « Se connecter » (et accepte les cookies s'ils sont demandés).
    func acceptPortal() async -> Bool {
        await load(portal.appending(path: "fr/home"))
        var noForm = 0
        for _ in 0..<20 {
            let state = await js("""
                (() => {
                  const accept = [...document.querySelectorAll('button, a')]
                    .find(b => /accepter|accept/i.test(b.textContent) && !b.closest('.SignUpModalContent'));
                  if (accept) accept.click();
                  const cgu = document.getElementById('cgu');
                  if (!cgu) return 'no-form';
                  if (!cgu.checked) { cgu.click(); return 'checked'; }
                  const submit = document.querySelector('.SignUpModalContent button[type=submit]');
                  if (!submit || submit.disabled) return 'waiting';
                  submit.click();
                  return 'submitted';
                })()
                """) as? String ?? "error"
            log("portail : \(state)")
            switch state {
            case "submitted":
                // Le forfait peut mettre une vingtaine de secondes à apparaître.
                if await waitForCredits(seconds: 25) { return true }
            case "no-form":
                // Formulaire absent : soit c'est déjà bon, soit la page est restée sur un autre écran.
                if await waitForCredits(seconds: 2) { return true }
                noForm += 1
                if noForm % 3 == 0 { await load(portal.appending(path: "fr/home")) }
            default:
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    // Attend que l'API annonce un forfait avec des crédits.
    func waitForCredits(seconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        repeat {
            if let p = await fetchStatus()?.percent, p > 0 { return true }
            try? await Task.sleep(for: .seconds(2))
        } while Date() < deadline
        return false
    }

    // État du forfait d'après l'API du portail, qui reconnaît l'appareil à son adresse IP.
    func fetchStatus() async -> Credits? {
        guard let body = await fetch(portal.appending(path: "router/api/connection/status")) else { return nil }
        let credits = parseStatus(body)
        if let credits { saveText("API → \(credits.description)\n\n\(body)") }
        return credits
    }

    // Lit le pourcentage de crédits affiché dans l'en-tête du portail. La page reste ouverte
    // entre deux lectures : le portail met l'indicateur à jour tout seul.
    func readCredits() async -> Credits {
        // L'API reconnaît l'appareil à son adresse IP : un appel direct suffit, sans charger la page.
        if let credits = await fetchStatus() { return credits }
        if web.url?.host?.contains("normandie") != true || web.url?.path.hasPrefix("/fr/home") != true {
            await load(portal.appending(path: "fr/home"))
        }
        // Source principale : l'API que la page interroge elle-même.
        var raw: [String] = []
        if let body = await api("/router/api/connection/status") {
            raw.append("/router/api/connection/status\n\(body)")
            if let credits = parseStatus(body) {
                saveText("API → \(credits.description)\n\n\(body)")
                return credits
            }
            if let c = creditsFromJSON([body]) {
                saveText("API → \(c) %\n\n\(body)")
                return .left(percent: c, megabytes: nil)
            }
        }
        log("API sans pourcentage reconnu : \(raw.joined(separator: " | ").prefix(500))")
        for _ in 0..<5 {
            let indicator = await js("""
                (() => {
                  const p = [...document.querySelectorAll('.HeaderIndicators p')]
                    .find(p => /cr\\S{0,2}dit|restant/i.test(p.textContent));
                  return p ? p.textContent : null;
                })()
                """) as? String
            if let c = indicator.flatMap(firstNumber) {
                saveText("Indicateur : \(indicator ?? "")")
                return .left(percent: c, megabytes: nil)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // Indicateur absent : on garde de quoi comprendre comment le portail le charge.
        let diagnostic = await js("""
            JSON.stringify({
              url: location.href,
              header: document.querySelector('.HeaderIndicators')?.outerHTML ?? null,
              requests: performance.getEntriesByType('resource').map(e => e.name).filter(n => !/\\.(png|svg|jpg|css|woff2?)$/.test(n)),
              localStorage: Object.fromEntries(Object.keys(localStorage).map(k => [k, localStorage.getItem(k)])),
              cookies: document.cookie
            }, null, 2)
            """) as? String
        saveText("Indicateur introuvable\n\n" + raw.joined(separator: "\n\n") + "\n\n\(diagnostic ?? "diagnostic impossible")")
        // Au prochain passage, on repart d'une page fraîche.
        web.load(URLRequest(url: URL(string: "about:blank")!))
        return .unknown
    }

    func load(_ url: URL) async {
        web.load(URLRequest(url: url))
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(500))
            if !web.isLoading { break }
        }
    }

    // Appelle l'API du portail depuis la page, avec ses cookies.
    func api(_ path: String) async -> String? {
        do {
            return try await web.callAsyncJavaScript(
                "const r = await fetch(path, {cache: 'no-store'}); return r.status + ' ' + await r.text();",
                arguments: ["path": path], contentWorld: .page) as? String
        } catch {
            log("api \(path) → \(error.localizedDescription)")
            return nil
        }
    }

    func js(_ script: String) async -> Any? {
        do {
            return try await web.evaluateJavaScript(script)
        } catch {
            log("js → \(error.localizedDescription)")
            return nil
        }
    }

    func fetch(_ url: URL) async -> String? {
        do {
            let (data, response) = try await session.data(from: url)
            log("\(url) → \((response as? HTTPURLResponse)?.statusCode ?? 0) \(response.url?.absoluteString ?? "")")
            return String(decoding: data, as: UTF8.self)
        } catch {
            log("\(url) → \(error.localizedDescription)")
            return nil
        }
    }

    var logDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacChanger") }

    // Texte de la page « Le Wifi », pour pouvoir affiner la lecture des crédits.
    func saveText(_ text: String) {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try? text.write(to: logDir.appendingPathComponent("wifi.txt"), atomically: true, encoding: .utf8)
    }

    func log(_ line: String) {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let file = logDir.appendingPathComponent("monitor.log")
        let entry = Data("[\(Date().formatted(date: .omitted, time: .standard))] \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(entry)
            try? h.close()
        } else {
            try? entry.write(to: file)
        }
    }
}

enum Credits: CustomStringConvertible {
    case left(percent: Int, megabytes: Int?)
    case noGrant
    case unknown

    var percent: Int? {
        if case .left(let percent, _) = self { return percent }
        return nil
    }

    var description: String {
        switch self {
        case .left(let percent, let mb?): "\(percent) % (\(mb) Mo)"
        case .left(let percent, nil): "\(percent) %"
        case .noGrant: "aucun forfait actif"
        case .unknown: "inconnus"
        }
    }
}

// Réponse de /router/api/connection/status, précédée de son code HTTP. Le forfait vaut
// remaining_data + consumed_data (en Kio, 150 Mio par connexion) ; sans forfait, l'API répond
// « … does not have any active grants ».
func parseStatus(_ response: String) -> Credits? {
    let json = response.drop(while: { $0 != "{" })
    guard let data = json.data(using: .utf8),
          let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if (status["status_description"] as? String)?.contains("does not have any") == true { return .noGrant }
    guard let remaining = (status["remaining_data"] as? NSNumber)?.doubleValue,
          let consumed = (status["consumed_data"] as? NSNumber)?.doubleValue,
          remaining + consumed > 0 else { return nil }
    // 0 % seulement quand il ne reste vraiment plus rien.
    let percent = remaining <= 0 ? 0 : min(100, max(1, Int((remaining / (remaining + consumed) * 100).rounded())))
    return .left(percent: percent, megabytes: Int(max(0, remaining) / 1024))
}

// Pourcentage de crédit restant dans les réponses JSON de l'API, quel que soit le nom exact des champs.
func creditsFromJSON(_ bodies: [String]) -> Int? {
    var values: [(key: String, value: Double)] = []
    func walk(_ node: Any, _ path: String) {
        if let dict = node as? [String: Any] {
            for (k, v) in dict { walk(v, path + "." + k.lowercased()) }
        } else if let array = node as? [Any] {
            for (i, v) in array.enumerated() { walk(v, path + "[\(i)]") }
        } else if let n = node as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            values.append((path, n.doubleValue))
        }
    }
    for body in bodies {
        let json = body.drop(while: { $0 != "{" && $0 != "[" })
        if let data = json.data(using: .utf8), let node = try? JSONSerialization.jsonObject(with: data) { walk(node, "") }
    }
    func find(_ pattern: String, excluding: String? = nil) -> Double? {
        values.first { entry in
            entry.key.range(of: pattern, options: .regularExpression) != nil
                && excluding.map { entry.key.range(of: $0, options: .regularExpression) == nil } ?? true
        }?.value
    }
    let percent: Double?
    if let p = find("(percent|pourcent|ratio).*(remain|left|restant|credit)|(remain|left|restant|credit).*(percent|pourcent|ratio)") {
        percent = p <= 1 ? p * 100 : p
    } else if let p = find("(percent|pourcent)", excluding: "(used|consum)") {
        percent = p <= 1 ? p * 100 : p
    } else if let p = find("(used|consum).*(percent|pourcent)|(percent|pourcent).*(used|consum)") {
        percent = 100 - (p <= 1 ? p * 100 : p)
    } else if let total = find("(total|quota|limit|max|allowed|initial)"), total > 0 {
        if let left = find("(remain|left|restant|available)", excluding: "(total|quota|limit|max)") {
            percent = left / total * 100
        } else if let used = find("(used|consum)", excluding: "(total|quota|limit|max)") {
            percent = 100 - used / total * 100
        } else { percent = nil }
    } else { percent = nil }
    return percent.map { Int(min(100, max(0, $0)).rounded()) }
}

func firstNumber(_ text: String) -> Int? {
    text.range(of: "[0-9]{1,3}", options: .regularExpression).flatMap { Int(text[$0]) }
}

// Pourcentage affiché après le mot « crédit » dans la page du portail (HTML ou texte), ou nil s'il est introuvable.
func parseCredits(_ html: String) -> Int? {
    let text = html
        .replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    guard let word = text.range(of: "cr(é|e|&eacute;|&#233;)dit", options: [.regularExpression, .caseInsensitive]) else { return nil }
    let near = text[word.lowerBound...].prefix(300)
    guard let n = near.range(of: "[0-9]{1,3}(?=([.,][0-9]+)?\\s*%)", options: .regularExpression) else { return nil }
    return Int(near[n])
}

func randomMAC() -> String {
    var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
    bytes[0] = (bytes[0] & 0xFC) | 0x02 // adresse unicast, administrée localement
    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
