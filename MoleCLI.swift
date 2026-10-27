import AppKit
import CryptoKit
import Darwin

// Moteur Mole : la CLI open source de tw93 (https://github.com/tw93/Mole, GPL-3.0), lancée comme
// programme séparé. Hippocampe s'en sert pour l'état du Mac, l'analyse du disque, la liste des
// apps et leurs fichiers, le plan de nettoyage et l'optimisation, et lit ses sorties. Sans la CLI,
// chaque onglet retombe sur les fonctions intégrées d'Hippocampe.

let molePath: String? = ["/opt/homebrew/bin/mo", "/usr/local/bin/mo"].first { FileManager.default.isExecutableFile(atPath: $0) }

func stripANSI(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
}

final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private(set) var all = ""

    func feed(_ chunk: String, _ onLine: (String) -> Void) {
        lock.lock()
        pending += chunk
        all += chunk
        var lines = pending.components(separatedBy: .newlines)
        pending = lines.removeLast()
        lock.unlock()
        for line in lines { onLine(line) }
    }
}

// Lance mo sans terminal (stdin fermé : Mole passe en mode non interactif) et transmet chaque
// ligne au fil de l'eau ; la dernière ligne utile s'affiche en direct sous le bouton.
func runMole(_ arguments: [String], onLine: @escaping @Sendable (String) -> Void = { _ in }) -> (status: Int32, out: String) {
    guard let mo = molePath else { return (127, "") }
    return runLive(mo, arguments, label: "Mole", onLine: onLine)
}

// Lance un outil en ligne de commande et affiche en direct sa dernière ligne utile.
func runLive(_ tool: String, _ arguments: [String], label: String,
             onLine: @escaping @Sendable (String) -> Void = { _ in }) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["NO_COLOR"] = "1"
    env["TERM"] = "dumb"
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    let buffer = LineBuffer()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        buffer.feed(String(decoding: data, as: UTF8.self)) { raw in
            let line = stripANSI(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return }
            onLine(line)
            if !line.hasPrefix("{") && !line.hasPrefix("[") && !line.hasPrefix("\"") && !line.hasPrefix("}") {
                LiveStatus.shared.set(label + " · " + line)
            }
        }
    }
    do { try p.run() } catch { return (1, error.localizedDescription) }
    p.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
    buffer.feed(String(decoding: rest, as: UTF8.self) + "\n") { _ in }
    return (p.terminationStatus, stripANSI(buffer.all))
}

func moleVersion() -> String? {
    guard molePath != nil else { return nil }
    return runMole(["--version"]).out.components(separatedBy: .newlines)
        .first { $0.contains("version") }?.replacingOccurrences(of: "Mole version ", with: "")
}

// « 71.3MB », « 4.5 GB », « 0B » → octets (Mole compte en puissances de 1024).
func parseMoleSize(_ text: String) -> Int64? {
    guard let r = text.range(of: "([0-9]+(?:[.,][0-9]+)?)\\s*([KMGT]?B)", options: .regularExpression) else { return nil }
    let match = String(text[r])
    let number = Double(match.prefix { "0123456789.,".contains($0) }.replacingOccurrences(of: ",", with: ".")) ?? 0
    let unit = match.drop { "0123456789., ".contains($0) }
    let power: Double = ["B": 0, "KB": 1, "MB": 2, "GB": 3, "TB": 4][String(unit)] ?? 0
    return Int64(number * pow(1024, power))
}

func expandTilde(_ path: String) -> URL {
    URL(fileURLWithPath: path.hasPrefix("~") ? home.path + path.dropFirst() : path)
}

// Noms des sections de Mole, en français.
let moleSectionNames: [String: String] = [
    "User essentials": "Essentiels de la session", "App caches": "Caches des apps", "Browsers": "Navigateurs",
    "Cloud & Office": "Cloud et bureautique", "Developer tools": "Outils de développement",
    "Apps & utilities": "Apps et utilitaires", "Application Support": "Données d'apps (Application Support)",
    "App leftovers": "Restes d'apps supprimées", "Large files": "Gros fichiers à gérer séparément",
    "Project artifacts": "Artefacts de projets", "Time Machine": "Time Machine", "System": "Système",
    "Finder Cache Refresh": "Caches du Finder", "App State Cleanup": "États des apps",
    "Broken Config Repair": "Réglages corrompus", "Network Cache Refresh": "Cache réseau",
    "Database Optimization": "Bases de données", "Prevent Finder .DS_Store": "Fichiers .DS_Store",
    "Legacy Overrides": "Anciens réglages forcés", "Network Stack Refresh": "Pile réseau",
    "Permission Repair": "Autorisations", "Spotlight Optimization": "Spotlight",
    "Spotlight Orphan Rules": "Règles Spotlight orphelines", "Periodic Maintenance": "Maintenance périodique",
    "Shared File Lists": "Listes Récents et barre latérale", "Disk Health": "Santé du disque",
    "Login Items": "Éléments d'ouverture", "Quarantine Database Cleanup": "Historique de quarantaine",
    "Launch Agents Cleanup": "Services d'arrière-plan", "Memory": "Mémoire", "Disk Image": "Images disque",
]

func frenchSection(_ name: String) -> String { moleSectionNames[name] ?? name }

// MARK: - État (mo status --json)

struct MoleStatus: Decodable {
    struct Hardware: Decodable { var model: String?; var cpuModel: String?; var totalRam: String?; var osVersion: String? }
    struct CPU: Decodable { var usage: Double?; var load1: Double?; var coreCount: Int?; var perCore: [Double]? }
    struct GPU: Decodable { var name: String?; var usage: Double? }
    struct Memory: Decodable { var used: Int64?; var total: Int64?; var swapUsed: Int64?; var pressure: String? }
    struct Disk: Decodable { var mount: String?; var used: Int64?; var total: Int64?; var purgeable: Int64? }
    struct Net: Decodable { var name: String?; var rxRateMbs: Double?; var txRateMbs: Double?; var ip: String? }
    struct Battery: Decodable { var percent: Int?; var status: String?; var timeLeft: String?; var health: String?; var cycleCount: Int?; var capacity: Int? }
    struct Thermal: Decodable { var cpuTemp: Double?; var gpuTemp: Double?; var batteryTemp: Double? }
    struct Proc: Decodable { var pid: Int?; var name: String?; var cpu: Double?; var memoryBytes: Int64? }

    var healthScore: Int?
    var healthScoreMsg: String?
    var uptimeSeconds: Double?
    var procs: Int?
    var hardware: Hardware?
    var cpu: CPU?
    var gpu: [GPU]?
    var memory: Memory?
    var disks: [Disk]?
    var network: [Net]?
    var batteries: [Battery]?
    var thermal: Thermal?
    var topProcesses: [Proc]?

    static func fetch() -> MoleStatus? {
        let r = runMole(["status", "--json"])
        guard r.status == 0, let start = r.out.firstIndex(of: "{") else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(MoleStatus.self, from: Data(r.out[start...].utf8))
    }
}

// MARK: - Analyse (mo analyze --json)

struct MoleAnalysis: Decodable {
    struct Entry: Decodable { var name: String; var path: String; var size: Int64; var isDir: Bool? }
    struct LargeFile: Decodable { var name: String; var path: String; var size: Int64 }
    var entries: [Entry]?
    var largeFiles: [LargeFile]?
    var totalSize: Int64?

    static func fetch(_ url: URL) -> MoleAnalysis? {
        let r = runMole(["analyze", "--json", url.path])
        guard r.status == 0, let start = r.out.firstIndex(of: "{") else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(MoleAnalysis.self, from: Data(r.out[start...].utf8))
    }
}

// MARK: - Nettoyage (mo clean --dry-run, puis ~/.config/mole/clean-list.txt)

struct MoleCleanPlan {
    var sections: [(title: String, items: [(URL, Int64)])] = []
    var review: [(name: String, url: URL, size: Int64)] = []
}

func moleCleanPlan() -> MoleCleanPlan? {
    let r = runMole(["clean", "--dry-run"])
    // « ⊙ Docker Desktop data · 32.63GB · ~/Library/Containers/… » : à gérer à part, Mole n'y touche pas.
    var review: [(String, URL, Int64)] = []
    for raw in r.out.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("⊙ ") else { continue }
        let parts = line.dropFirst(2).components(separatedBy: " · ")
        guard parts.count >= 3, let path = parts.last, path.hasPrefix("/") || path.hasPrefix("~") else { continue }
        review.append((parts[0], expandTilde(path), parseMoleSize(parts[1]) ?? 0))
    }
    guard r.status == 0,
          let list = try? String(contentsOf: home.appending(path: ".config/mole/clean-list.txt"), encoding: .utf8) else { return nil }
    var plan = MoleCleanPlan()
    for line in list.components(separatedBy: .newlines) {
        if line.hasPrefix("=== "), line.hasSuffix(" ===") {
            plan.sections.append((String(line.dropFirst(4).dropLast(4)), []))
            continue
        }
        // Les fichiers « counted under » un dossier déjà listé seraient comptés deux fois.
        guard !line.hasPrefix("#"), let mark = line.range(of: "  # "), !plan.sections.isEmpty,
              !line.contains("counted under") else { continue }
        let path = String(line[..<mark.lowerBound])
        let size = parseMoleSize(String(line[mark.upperBound...])) ?? 0
        plan.sections[plan.sections.count - 1].items.append((URL(fileURLWithPath: path), size))
    }
    plan.review = review
    return plan
}

// MARK: - Apps (mo uninstall --list, mo uninstall --dry-run)

struct MoleApp: Decodable {
    var name: String
    var bundleId: String?
    var source: String?
    var uninstallName: String
    var path: String
    var size: String?
}

func moleApps() -> [MoleApp]? {
    let r = runMole(["uninstall", "--list"])
    guard r.status == 0, let start = r.out.firstIndex(of: "[") else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode([MoleApp].self, from: Data(r.out[start...].utf8))
}

func leftoverKind(_ url: URL) -> String {
    let p = url.path
    let rules: [(String, String)] = [
        (".app", "Application"), ("/var/folders/", "Cache temporaire"), ("/Library/Caches/", "Cache"),
        ("/Library/Preferences/", "Réglages"), ("/Library/Group Containers/", "Conteneur partagé"),
        ("/Library/Containers/", "Conteneur"), ("/Library/Application Scripts/", "Scripts d'app"),
        ("/Library/HTTPStorages/", "Stockage HTTP"), ("/Library/WebKit/", "WebKit"), ("/Library/Logs/", "Journaux"),
        ("/Library/Saved Application State/", "État des fenêtres"), ("LaunchAgents/", "Agent de démarrage"),
        ("LaunchDaemons/", "Service système"), ("ApplicationRecentDocuments", "Documents récents"),
        ("/Library/Cookies/", "Cookies"), ("/Library/Application Support/", "Données de l'app"),
    ]
    if p.hasSuffix(".binarycookies") { return "Cookies" }
    return rules.first { p.hasSuffix($0.0) || p.contains($0.0) }?.1 ?? "Fichier"
}

// Plan de Mole pour une app : ce qu'il supprime d'office, et les données personnelles qu'il garde.
func moleUninstallPlan(_ moleName: String) -> [Leftover]? {
    let r = runMole(["uninstall", "--dry-run", moleName])
    guard r.out.contains("Files to be removed") else { return nil }
    var found: [Leftover] = []
    var section = ""
    for raw in r.out.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Files to be removed") { section = "remove"; continue }
        if line.hasPrefix("Personal data to remove") { section = "remove"; continue }
        if line.hasPrefix("Personal data kept") { section = "kept"; continue }
        guard line.hasPrefix("✓ ") || line.hasPrefix("⊙ ") else { continue }
        let body = String(line.dropFirst(2))
        let parts = body.components(separatedBy: " , ")
        let url = expandTilde(parts[0])
        guard !url.path.hasSuffix(".app") || section == "kept" else { continue }
        let size = parts.count > 1 ? parseMoleSize(parts[1]) ?? allocatedSize(url) : allocatedSize(url)
        // Données personnelles (documents, réglages de compte) : Mole les garde par défaut.
        let kind = section == "kept" ? "Donnée perso · " + leftoverKind(url) : leftoverKind(url)
        found.append(Leftover(url: url, kind: kind, size: size, selected: section == "remove"))
    }
    return found
}

// MARK: - Optimisation (mo optimize)

struct MoleOptimizeLine: Identifiable {
    let id = UUID()
    let symbol: String
    let text: String
}

struct MoleOptimizeSection: Identifiable {
    let id = UUID()
    let title: String
    var lines: [MoleOptimizeLine]
}

func parseOptimize(_ output: String) -> [MoleOptimizeSection] {
    var sections: [MoleOptimizeSection] = []
    for raw in output.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("➤ ") {
            sections.append(MoleOptimizeSection(title: frenchSection(String(line.dropFirst(2))), lines: []))
        } else if !sections.isEmpty, let first = line.first, "→✓◎-⚠✗".contains(first) {
            sections[sections.count - 1].lines.append(MoleOptimizeLine(symbol: String(first),
                                                                      text: line.dropFirst().trimmingCharacters(in: .whitespaces)))
        }
    }
    return sections
}

// MARK: - Doublons (Hippocampe : Mole n'a pas cette fonction)

struct DuplicateFile: Identifiable {
    var id: URL { url }
    let url: URL
    let modified: Date
    // Octets que sa suppression libère vraiment : moins que sa taille si c'est un clone APFS.
    let privateSize: Int64
    var remove: Bool
}

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let size: Int64
    var files: [DuplicateFile]
    var reclaimable: Int64 { files.filter(\.remove).reduce(0) { $0 + $1.privateSize } }
    var cloned: Bool { files.contains { $0.privateSize < size / 2 } }
}

// Espace propre à un fichier sur APFS (non partagé avec ses clones).
func privateSize(_ path: String) -> Int64? {
    var attrs = attrlist()
    attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    attrs.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    var buffer = [UInt8](repeating: 0, count: 32)
    guard getattrlist(path, &attrs, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED)) == 0 else { return nil }
    return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
}

func digest(_ url: URL, limit: Int?) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    var read = 0
    while true {
        if Task.isCancelled { return nil }
        let chunk = handle.readData(ofLength: limit.map { min(1 << 20, $0 - read) } ?? 1 << 20)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
        read += chunk.count
        if let limit, read >= limit { break }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// Même taille, puis même début (64 Ko), puis même contenu complet (SHA-256).
// ~/Library, les dossiers cachés et l'intérieur des apps et paquets sont ignorés.
func findDuplicates(under root: URL, minimum: Int = 1_000_000) -> [DuplicateGroup] {
    let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey, .fileResourceIdentifierKey]
    guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                    errorHandler: { _, _ in true }) else { return [] }
    let library = home.appending(path: "Library").path
    var bySize: [Int: [URL]] = [:]
    var seen = Set<String>()
    var count = 0
    while let file = walk.nextObject() as? URL {
        if Task.isCancelled { return [] }
        if file.path == library { walk.skipDescendants(); continue }
        count += 1
        if count % 300 == 0 { LiveStatus.shared.set(file.path) }
        guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
              let size = v.fileSize, size >= minimum else { continue }
        // Liens physiques : un seul fichier sous deux noms, pas un doublon.
        if let id = v.fileResourceIdentifier.map({ "\($0)" }) {
            guard seen.insert(id).inserted else { continue }
        }
        bySize[size, default: []].append(file)
    }
    var groups: [DuplicateGroup] = []
    for (size, urls) in bySize where urls.count > 1 {
        let byHead = Dictionary(grouping: urls) { digest($0, limit: 65_536) ?? UUID().uuidString }
        for (_, same) in byHead where same.count > 1 {
            for u in same { LiveStatus.shared.set(u.path) }
            let byFull = Dictionary(grouping: same) { digest($0, limit: nil) ?? UUID().uuidString }
            for (_, identical) in byFull where identical.count > 1 {
                let files = identical.map { url in
                    DuplicateFile(url: url,
                                  modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast,
                                  privateSize: privateSize(url.path) ?? Int64(size), remove: true)
                }
                // On garde le plus ancien : c'est en général l'original.
                var sorted = files.sorted { $0.modified < $1.modified }
                sorted[0].remove = false
                groups.append(DuplicateGroup(size: Int64(size), files: sorted))
            }
        }
    }
    return groups.sorted { $0.reclaimable > $1.reclaimable }
}
