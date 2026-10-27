import AppKit

// Onglet Apps : mises à jour (Homebrew, App Store, Sparkle, site de l'éditeur) et éléments lancés
// au démarrage. La CLI Mole n'a pas ces fonctions : elles sont propres à Hippocampe.

let brewPath: String? = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }

// « 3.10.2 » est plus récent que « 3.9 » : comparaison nombre par nombre.
func versionIsNewer(_ a: String, than b: String) -> Bool {
    let x = a.split { !$0.isNumber }.compactMap { Int($0) }
    let y = b.split { !$0.isNumber }.compactMap { Int($0) }
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

func plainText(fromHTML html: String) -> String {
    var text = html.replacingOccurrences(of: "<(br|/p|/li|/h[1-6])[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "<li[^>]*>", with: "• ", options: [.regularExpression, .caseInsensitive])
    text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
        text = text.replacingOccurrences(of: entity, with: char)
    }
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return String(lines.joined(separator: "\n").prefix(1500))
}

// MARK: - Mises à jour

enum UpdateSource: String {
    case homebrew = "Homebrew"
    case appStore = "App Store"
    case sparkle = "Sparkle"
    case website = "Site de l'éditeur"
}

enum UpdateState {
    case outdated
    case current
    case unknown(String)
}

struct AppUpdate: Identifiable {
    var id: URL { app.url }
    let app: AppEntry
    let source: UpdateSource
    let installed: String
    var latest: String?
    var state: UpdateState
    var notes: String?
    var notesURL: URL?
    // Où récupérer la nouvelle version : page App Store, fichier Sparkle ou site.
    var actionURL: URL?
    var cask: String?

    var isOutdated: Bool { if case .outdated = state { true } else { false } }
    var isCurrent: Bool { if case .current = state { true } else { false } }
}

struct SparkleRelease {
    var short = ""
    var build = ""
    var url: URL?
    var notes = ""
    var notesLink: URL?
}

// Lecture d'un flux Sparkle (appcast) : version, fichier à télécharger et notes de chaque version.
final class AppcastParser: NSObject, XMLParserDelegate {
    var releases: [SparkleRelease] = []
    private var current: SparkleRelease?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = SparkleRelease() }
        if name == "enclosure" {
            current?.url = attributes["url"].flatMap(URL.init(string:))
            if let v = attributes["sparkle:shortVersionString"] { current?.short = v }
            if let v = attributes["sparkle:version"] { current?.build = v }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "sparkle:shortVersionString": current?.short = value
        case "sparkle:version": current?.build = value
        case "description": current?.notes = value
        case "sparkle:releaseNotesLink", "sparkle:fullReleaseNotesLink":
            if current?.notesLink == nil { current?.notesLink = URL(string: value) }
        case "item":
            if let c = current { releases.append(c) }
            current = nil
        default: break
        }
    }
}

func fetchData(_ url: URL) async -> Data? {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue("Hippocampe", forHTTPHeaderField: "User-Agent")
    return try? await URLSession.shared.data(for: request).0
}

func checkSparkle(_ app: AppEntry, feed: URL, short: String, build: String) async -> AppUpdate {
    var result = AppUpdate(app: app, source: .sparkle, installed: short, state: .unknown("Flux de mise à jour illisible"))
    guard let data = await fetchData(feed) else {
        result.state = .unknown("Flux de mise à jour injoignable")
        return result
    }
    let parser = XMLParser(data: data)
    let delegate = AppcastParser()
    parser.delegate = delegate
    parser.parse()
    let best = delegate.releases.max { a, b in
        versionIsNewer(b.build.isEmpty ? b.short : b.build, than: a.build.isEmpty ? a.short : a.build)
    }
    guard let best else { return result }
    result.latest = best.short.isEmpty ? best.build : best.short
    let newer = !best.build.isEmpty && !build.isEmpty ? versionIsNewer(best.build, than: build) : versionIsNewer(best.short, than: short)
    result.state = newer ? .outdated : .current
    result.notes = best.notes.isEmpty ? nil : plainText(fromHTML: best.notes)
    result.notesURL = best.notesLink
    result.actionURL = best.url
    return result
}

func checkAppStore(_ app: AppEntry, short: String) async -> AppUpdate {
    var result = AppUpdate(app: app, source: .appStore, installed: short, state: .unknown("Introuvable sur l'App Store"))
    let query = "https://itunes.apple.com/lookup?bundleId=\(app.bundleID)&country=fr&entity=macSoftware"
    guard let url = URL(string: query), let data = await fetchData(url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let first = (json["results"] as? [[String: Any]])?.first,
          let version = first["version"] as? String else { return result }
    result.latest = version
    result.state = versionIsNewer(version, than: short) ? .outdated : .current
    result.notes = (first["releaseNotes"] as? String).map(plainText(fromHTML:))
    if let id = first["trackId"] as? Int { result.actionURL = URL(string: "macappstore://apps.apple.com/app/id\(id)") }
    return result
}

// Casks Homebrew pour lesquels une version plus récente existe : nom → version proposée.
func brewOutdated() -> [String: String] {
    guard let brew = brewPath else { return [:] }
    let r = runLive(brew, ["outdated", "--cask", "--greedy", "--json=v2"], label: "Homebrew")
    guard let start = r.out.firstIndex(of: "{"),
          let json = try? JSONSerialization.jsonObject(with: Data(r.out[start...].utf8)) as? [String: Any],
          let casks = json["casks"] as? [[String: Any]] else { return [:] }
    var result: [String: String] = [:]
    for cask in casks {
        guard let name = cask["name"] as? String, let version = cask["current_version"] as? String else { continue }
        result[name] = version.components(separatedBy: ",")[0]
    }
    return result
}

func checkUpdate(_ app: AppEntry, outdatedCasks: [String: String]) async -> AppUpdate {
    let bundle = Bundle(url: app.url)
    let short = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? app.version
    let build = bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    if app.source == "Homebrew", let cask = app.moleName {
        var result = AppUpdate(app: app, source: .homebrew, installed: short, state: .current, cask: cask)
        // Homebrew croit vieilles les apps qui se mettent à jour toutes seules : on compare à la version réellement installée.
        if let latest = outdatedCasks[cask] {
            result.latest = latest
            result.state = versionIsNewer(latest, than: short) ? .outdated : .current
        }
        return result
    }
    if FileManager.default.fileExists(atPath: app.url.appending(path: "Contents/_MASReceipt/receipt").path) {
        return await checkAppStore(app, short: short)
    }
    if let feed = (bundle?.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:)) {
        return await checkSparkle(app, feed: feed, short: short, build: build)
    }
    return AppUpdate(app: app, source: .website, installed: short,
                     state: .unknown("L'app se met à jour elle-même ou via le site de son éditeur"))
}

enum UpdateFilter: String, CaseIterable {
    case all = "Toutes"
    case outdated = "Obsolètes"
    case current = "À jour"
    case homebrew = "Homebrew"
    case external = "Externes"
    case unknown = "Inconnues"
}

@MainActor
final class UpdatesModel: ObservableObject {
    static let shared = UpdatesModel()

    @Published var items: [AppUpdate] = []
    @Published var checking = false
    @Published var checked = false
    @Published var filter: UpdateFilter = .all
    @Published var working: Set<URL> = []
    @Published var message = ""
    @Published var expanded: Set<URL> = []
    // Versions ignorées : identifiant de l'app → version qu'on ne veut pas installer.
    @Published var ignored: [String: String] = UserDefaults.standard.dictionary(forKey: "ignoredUpdates") as? [String: String] ?? [:]

    func isIgnored(_ u: AppUpdate) -> Bool { u.latest != nil && ignored[u.app.bundleID] == u.latest }

    func matches(_ u: AppUpdate) -> Bool {
        switch filter {
        case .all: true
        case .outdated: u.isOutdated && !isIgnored(u)
        case .current: u.isCurrent || isIgnored(u)
        case .homebrew: u.source == .homebrew
        case .external: u.source == .sparkle || u.source == .website
        case .unknown: !u.isOutdated && !u.isCurrent
        }
    }

    var outdatedCount: Int { items.filter { $0.isOutdated && !isIgnored($0) }.count }
    // Les apps mises à jour par le site de leur éditeur ne peuvent pas être vérifiées : elles ne comptent pas.
    var verifiedCount: Int { items.filter { $0.source != .website }.count }

    func check(_ apps: [AppEntry]) {
        guard !checking else { return }
        checking = true
        message = ""
        LiveStatus.shared.set("Recherche des mises à jour…")
        Task {
            let casks = await Task.detached { brewOutdated() }.value
            var found: [AppUpdate] = []
            await withTaskGroup(of: AppUpdate.self) { group in
                for app in apps {
                    group.addTask {
                        LiveStatus.shared.set("Mises à jour · " + app.name)
                        return await checkUpdate(app, outdatedCasks: casks)
                    }
                }
                for await result in group { found.append(result) }
            }
            items = found
            checking = false
            checked = true
        }
    }

    func ignore(_ u: AppUpdate) {
        guard let latest = u.latest else { return }
        ignored[u.app.bundleID] = latest
        UserDefaults.standard.set(ignored, forKey: "ignoredUpdates")
    }

    func unignore(_ u: AppUpdate) {
        ignored[u.app.bundleID] = nil
        UserDefaults.standard.set(ignored, forKey: "ignoredUpdates")
    }

    // Homebrew : mise à jour sur place ; App Store : page de l'app ; Sparkle : téléchargement de la nouvelle version.
    func update(_ u: AppUpdate) {
        switch u.source {
        case .homebrew:
            guard let brew = brewPath, let cask = u.cask else { return }
            working.insert(u.id)
            Task {
                let r = await Task.detached { runLive(brew, ["upgrade", "--cask", cask], label: "Homebrew") }.value
                working.remove(u.id)
                if r.status == 0, let i = items.firstIndex(where: { $0.id == u.id }) {
                    items[i].state = .current
                    message = "\(u.app.name) mis à jour par Homebrew"
                } else {
                    message = "Échec de la mise à jour de \(u.app.name) : " + (r.out.components(separatedBy: .newlines).last { !$0.isEmpty } ?? "")
                }
            }
        case .appStore, .sparkle:
            if let url = u.actionURL { NSWorkspace.shared.open(url) }
        case .website:
            NSWorkspace.shared.open(u.app.url)
        }
    }
}

// MARK: - Démarrage

struct LoginEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    var enabled: Bool
}

struct BackgroundEntry: Identifiable {
    var id: String { label + url.path }
    let label: String
    let url: URL
    let program: String
    // user : vos agents, allUsers : agents de tous les comptes, system : services root, embedded : intégré à une app.
    let scope: String
    var enabled: Bool
    var editable: Bool { scope != "embedded" }

    var appURL: URL? {
        let path = scope == "embedded" ? url.path : program
        guard let range = path.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
    }

    var scopeText: String {
        switch scope {
        case "user": "Agent de votre session"
        case "allUsers": "Agent pour tous les comptes"
        case "system": "Service système"
        default: "Intégré à l'app, à gérer dans Réglages Système › Ouverture"
        }
    }
}

func disabledLabels(_ domain: String) -> Set<String> {
    var result = Set<String>()
    for line in run("/bin/launchctl", ["print-disabled", domain]).out.components(separatedBy: .newlines) {
        guard line.contains("=> disabled") || line.contains("=> true"),
              let start = line.firstIndex(of: "\""), let end = line.lastIndex(of: "\""), start < end else { continue }
        result.insert(String(line[line.index(after: start)..<end]))
    }
    return result
}

func loginEntries() -> [LoginEntry] {
    let script = "JSON.stringify(Application('System Events').loginItems().map(i => ({name: i.name(), path: i.path()})))"
    let r = run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script])
    guard let data = r.out.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
    return list.compactMap { item in
        guard let name = item["name"], let path = item["path"] else { return nil }
        return LoginEntry(name: name, path: path, enabled: true)
    }
}

func backgroundEntries() -> [BackgroundEntry] {
    let uid = getuid()
    let userOff = disabledLabels("gui/\(uid)"), systemOff = disabledLabels("system")
    var items: [BackgroundEntry] = []
    for (dir, scope) in [(home.appending(path: "Library/LaunchAgents"), "user"),
                         (URL(fileURLWithPath: "/Library/LaunchAgents"), "allUsers"),
                         (URL(fileURLWithPath: "/Library/LaunchDaemons"), "system")] {
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "plist" {
            let plist = NSDictionary(contentsOf: url)
            let label = plist?["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
            let program = plist?["Program"] as? String ?? (plist?["ProgramArguments"] as? [String])?.first ?? ""
            let off = scope == "system" ? systemOff.contains(label) : userOff.contains(label)
            items.append(BackgroundEntry(label: label, url: url, program: program, scope: scope, enabled: !off))
        }
    }
    // Agents déclarés à l'intérieur des apps (SMAppService) : affichés pour information.
    for dir in ["/Applications", home.appending(path: "Applications").path] {
        for app in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where app.hasSuffix(".app") {
            let agents = URL(fileURLWithPath: dir).appending(path: app).appending(path: "Contents/Library/LaunchAgents")
            for url in (try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "plist" {
                let label = NSDictionary(contentsOf: url)?["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                items.append(BackgroundEntry(label: label, url: url, program: "", scope: "embedded", enabled: !userOff.contains(label)))
            }
        }
    }
    return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
}

@MainActor
final class StartupModel: ObservableObject {
    static let shared = StartupModel()

    @Published var logins: [LoginEntry] = []
    @Published var background: [BackgroundEntry] = []
    @Published var loading = false
    @Published var message = ""
    // Éléments de connexion retirés depuis Hippocampe, pour pouvoir les remettre.
    private var removed: [String: String] = UserDefaults.standard.dictionary(forKey: "removedLoginItems") as? [String: String] ?? [:]

    func load() {
        loading = true
        Task {
            let (active, bg) = await Task.detached { (loginEntries(), backgroundEntries()) }.value
            let activePaths = Set(active.map(\.path))
            logins = active + removed.filter { !activePaths.contains($0.value) }.map { LoginEntry(name: $0.key, path: $0.value, enabled: false) }
            background = bg
            loading = false
        }
    }

    func setLogin(_ item: LoginEntry, _ on: Bool) {
        let name = item.name.replacingOccurrences(of: "'", with: "\\'")
        let path = item.path.replacingOccurrences(of: "'", with: "\\'")
        let script = on
            ? "var se = Application('System Events'); se.loginItems.push(se.LoginItem({path: '\(path)', hidden: false}))"
            : "Application('System Events').loginItems.byName('\(name)').delete()"
        Task {
            let r = await Task.detached { run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script]) }.value
            guard r.status == 0 else { return message = "Échec : \(r.err)" }
            if on { removed[item.name] = nil } else { removed[item.name] = item.path }
            UserDefaults.standard.set(removed, forKey: "removedLoginItems")
            if let i = logins.firstIndex(where: { $0.id == item.id }) { logins[i].enabled = on }
        }
    }

    // Agents : launchctl dans votre session, sans mot de passe. Services système : via l'outil administrateur.
    func setBackground(_ item: BackgroundEntry, _ on: Bool) {
        let uid = getuid()
        Task {
            let r = await Task.detached { () -> (status: Int32, out: String, err: String) in
                if item.scope == "system" {
                    return runHelper([on ? "daemon-on" : "daemon-off", item.label, item.url.lastPathComponent])
                }
                let target = "gui/\(uid)/\(item.label)"
                if on {
                    let r = run("/bin/launchctl", ["enable", target])
                    _ = run("/bin/launchctl", ["bootstrap", "gui/\(uid)", item.url.path])
                    return r
                }
                let r = run("/bin/launchctl", ["disable", target])
                _ = run("/bin/launchctl", ["bootout", target])
                return r
            }.value
            guard r.status == 0 else { return message = "Échec pour \(item.label) : \(r.err)" }
            if let i = background.firstIndex(where: { $0.id == item.id }) { background[i].enabled = on }
        }
    }
}
