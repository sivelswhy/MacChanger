import AppKit
import Darwin
import IOKit
import IOKit.ps

// Outils système inspirés de Mole : état de la machine, nettoyage, apps, analyse du disque
// et optimisations. Les opérations root passent par runHelper (main.swift).

let home = FileManager.default.homeDirectoryForCurrentUser

func formatBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false // « 0 KB » plutôt que « Zero KB »
    return f.string(fromByteCount: bytes)
}

func tildePath(_ url: URL) -> String { url.path.replacingOccurrences(of: home.path, with: "~") }

func relativeDate(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "fr_FR")
    f.unitsStyle = .full
    return f.localizedString(for: date, relativeTo: Date())
}

// Ce que l'app est en train de faire (chemin parcouru, étape en cours), lu par l'interface
// pour l'afficher en direct sous le bouton principal.
final class LiveStatus: @unchecked Sendable {
    static let shared = LiveStatus()
    private let lock = NSLock()
    private var value = ""

    func set(_ text: String) {
        lock.lock()
        value = text
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// Espace réellement occupé sur le disque, sans suivre les liens symboliques.
// S'arrête dès que la tâche appelante est annulée.
func allocatedSize(_ url: URL) -> Int64 {
    guard let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]),
          v.isSymbolicLink != true else { return 0 }
    guard v.isDirectory == true else { return Int64(v.totalFileAllocatedSize ?? 0) }
    guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                    options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total: Int64 = 0, count = 0
    LiveStatus.shared.set(url.path)
    while let file = walk.nextObject() as? URL {
        if Task.isCancelled { break }
        count += 1
        if count % 200 == 0 { LiveStatus.shared.set(file.path) }
        total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    return total
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

// MARK: - État

struct BatteryInfo {
    var percent: Int
    var charging: Bool
    var health: Int?
    var cycles: Int?
}

struct ProcessRow: Identifiable {
    let id: Int
    let name: String
    let cpu: Double
    let memory: Int64
}

func cpuTicks() -> (busy: UInt64, total: UInt64)? {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
    let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
    return (user + system + nice, user + system + idle + nice)
}

// Mémoire utilisée comme dans le Moniteur d'activité : mémoire des apps, câblée et compressée.
func currentMemoryUsed() -> Int64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let pages = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))
        + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
    return pages * Int64(getpagesize())
}

// 1 : normale, 2 : tendue, 4 : critique.
func memoryPressure() -> Int32 {
    var level: Int32 = 1
    var size = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
    return level
}

func swapUsed() -> Int64 {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
    return Int64(usage.xsu_used)
}

func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    getloadavg(&loads, 3)
    return loads[0]
}

// Octets reçus et envoyés par interface (compteurs 32 bits, qui repartent de zéro).
func interfaceBytes() -> [String: (rx: UInt32, tx: UInt32)] {
    var result: [String: (rx: UInt32, tx: UInt32)] = [:]
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return result }
    defer { freeifaddrs(list) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let a = entry.pointee
        guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data else { continue }
        let name = String(cString: a.ifa_name)
        if name.hasPrefix("lo") { continue }
        let d = data.assumingMemoryBound(to: if_data.self).pointee
        result[name] = (d.ifi_ibytes, d.ifi_obytes)
    }
    return result
}

func batteryInfo() -> BatteryInfo? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              d["Type"] as? String == "InternalBattery",
              let current = d["Current Capacity"] as? Int, let maximum = d["Max Capacity"] as? Int, maximum > 0 else { continue }
        var info = BatteryInfo(percent: current * 100 / maximum, charging: d["Is Charging"] as? Bool ?? false)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func value(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            info.cycles = value("CycleCount")
            if let full = value("AppleRawMaxCapacity") ?? value("NominalChargeCapacity"), let design = value("DesignCapacity"), design > 0 {
                info.health = min(100, full * 100 / design)
            }
        }
        return info
    }
    return nil
}

// Processus triés par mémoire, et leur nombre total.
func processList() -> (count: Int, top: [ProcessRow]) {
    let lines = run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm=", "-m"]).out.split(separator: "\n")
    let top = lines.prefix(14).compactMap { line -> ProcessRow? in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        // ps suit la langue du système : « 0,4 » en français.
        guard parts.count == 4, let pid = Int(parts[0]), let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
              let rss = Int64(parts[2]) else { return nil }
        return ProcessRow(id: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024)
    }
    return (lines.count, top)
}

func processPath(_ pid: Int) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
}

@MainActor
final class StatusModel: ObservableObject {
    static let shared = StatusModel()

    @Published var cpu = 0.0
    @Published var memoryUsed: Int64 = 0
    @Published var memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
    @Published var purgeable: Int64 = 0
    @Published var gpuUsage: Double?
    @Published var temperature: Double?
    @Published var healthMessage = ""
    // Mesures fournies par « mo status --json » quand la CLI Mole est installée.
    @Published var fromMole = false
    private var fetching = false
    @Published var pressure: Int32 = 1
    @Published var swap: Int64 = 0
    @Published var load = 0.0
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var download = 0.0
    @Published var upload = 0.0
    @Published var battery: BatteryInfo?
    @Published var processes: [ProcessRow] = []
    @Published var processCount = 0
    @Published var score = 100
    @Published var factors: [String] = []
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var downloadHistory: [Double] = []

    let model = sysctlString("hw.model") ?? "Mac"
    let chip = sysctlString("machdep.cpu.brand_string") ?? ""
    let system: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()

    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastSample = Date()
    private var timer: Timer?
    private var users = 0

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var thermal: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
    var memoryFraction: Double { Double(memoryUsed) / Double(max(1, memoryTotal)) }

    var verdict: String {
        switch score {
        case 90...: "Excellent"
        case 75..<90: "Bon"
        case 50..<75: "Correct"
        default: "À surveiller"
        }
    }

    var thermalText: String {
        switch thermal {
        case .nominal: "Normal"
        case .fair: "Tiède"
        case .serious: "Chaud"
        case .critical: "Critique"
        @unknown default: "Inconnu"
        }
    }

    var uptimeText: String {
        let s = Int(uptime)
        return s >= 86400 ? "\(s / 86400) j \(s % 86400 / 3600) h" : "\(s / 3600) h \(s % 3600 / 60) min"
    }

    // Plusieurs vues peuvent afficher l'état : l'échantillonnage tourne tant qu'une d'elles est visible.
    func start() {
        users += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func push(_ value: Double, _ history: inout [Double]) {
        history.append(value)
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }

    func sample() {
        guard molePath != nil else { return sampleOwn() }
        guard !fetching else { return }
        fetching = true
        Task {
            let snapshot = await Task.detached { MoleStatus.fetch() }.value
            fetching = false
            if let snapshot { apply(snapshot) } else { sampleOwn() }
        }
    }

    private func apply(_ s: MoleStatus) {
        fromMole = true
        cpu = (s.cpu?.usage ?? 0) / 100
        load = s.cpu?.load1 ?? 0
        memoryUsed = s.memory?.used ?? 0
        if let total = s.memory?.total, total > 0 { memoryTotal = total }
        swap = s.memory?.swapUsed ?? 0
        switch s.memory?.pressure?.lowercased() ?? "" {
        case let p where p.contains("crit"): pressure = 4
        case let p where p.contains("warn"): pressure = 2
        default: pressure = memoryPressure()
        }
        if let disk = s.disks?.first(where: { $0.mount == "/" }) ?? s.disks?.first, let total = disk.total {
            diskTotal = total
            diskFree = total - (disk.used ?? 0)
            purgeable = disk.purgeable ?? 0
        }
        download = (s.network ?? []).reduce(0) { $0 + ($1.rxRateMbs ?? 0) } * 1_048_576
        upload = (s.network ?? []).reduce(0) { $0 + ($1.txRateMbs ?? 0) } * 1_048_576
        if let b = s.batteries?.first, let percent = b.percent {
            let status = (b.status ?? "").lowercased()
            battery = BatteryInfo(percent: percent, charging: status.contains("charg") && !status.contains("dis"),
                                  health: b.capacity, cycles: b.cycleCount)
        } else {
            battery = nil
        }
        processes = (s.topProcesses ?? []).map {
            ProcessRow(id: $0.pid ?? 0, name: $0.name ?? "?", cpu: $0.cpu ?? 0, memory: $0.memoryBytes ?? 0)
        }
        processCount = s.procs ?? processCount
        score = s.healthScore ?? score
        healthMessage = s.healthScoreMsg ?? ""
        factors = []
        gpuUsage = s.gpu?.first?.usage.flatMap { $0 >= 0 ? $0 / 100 : nil }
        temperature = s.thermal?.cpuTemp.flatMap { $0 > 0 ? $0 : nil }
        push(cpu, &cpuHistory)
        push(memoryFraction, &memoryHistory)
        push(download, &downloadHistory)
    }

    private func sampleOwn() {
        fromMole = false
        let now = Date()
        let elapsed = max(0.5, now.timeIntervalSince(lastSample))
        lastSample = now

        if let ticks = cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
            } else if ticks.total > 0 {
                cpu = Double(ticks.busy) / Double(ticks.total)
            }
            lastTicks = ticks
        }
        memoryUsed = currentMemoryUsed()
        pressure = memoryPressure()
        swap = swapUsed()
        load = loadAverage()
        (diskFree, diskTotal) = diskSpace()

        let net = interfaceBytes()
        if !lastNet.isEmpty {
            var rx: UInt64 = 0, tx: UInt64 = 0
            for (name, bytes) in net {
                guard let last = lastNet[name] else { continue }
                rx += UInt64(bytes.rx &- last.rx)
                tx += UInt64(bytes.tx &- last.tx)
            }
            download = Double(rx) / elapsed
            upload = Double(tx) / elapsed
        }
        lastNet = net

        push(cpu, &cpuHistory)
        push(memoryFraction, &memoryHistory)
        push(download, &downloadHistory)

        battery = batteryInfo()
        (processCount, processes) = processList()
        scoreHealth()
    }

    // Score sur 100 : chaque signal inquiétant retire des points.
    private func scoreHealth() {
        var penalties: [(String, Int)] = []
        if cpu > 0.85 { penalties.append(("Processeur très sollicité", 15)) } else if cpu > 0.6 { penalties.append(("Processeur chargé", 5)) }
        if pressure >= 4 { penalties.append(("Mémoire saturée", 25)) } else if pressure >= 2 { penalties.append(("Pression mémoire", 10)) }
        if diskTotal > 0 {
            let free = Double(diskFree) / Double(diskTotal)
            if free < 0.1 { penalties.append(("Disque presque plein", 20)) } else if free < 0.2 { penalties.append(("Peu d'espace disque", 10)) }
        }
        switch thermal {
        case .critical: penalties.append(("Surchauffe", 30))
        case .serious: penalties.append(("Mac très chaud", 15))
        case .fair: penalties.append(("Mac tiède", 5))
        default: break
        }
        if let health = battery?.health, health < 80 { penalties.append(("Batterie usée (\(health) %)", 10)) }
        if let cycles = battery?.cycles, cycles > 1000 { penalties.append(("\(cycles) cycles de charge", 5)) }
        if uptime > 7 * 86400 { penalties.append(("Pas redémarré depuis \(Int(uptime / 86400)) jours", 5)) }
        score = max(0, 100 - penalties.reduce(0) { $0 + $1.1 })
        factors = penalties.map { "\($0.0), −\($0.1) pts" }
    }

    // Rapport de diagnostic, par section, à afficher ou à copier.
    func report() -> [(String, [(String, String)])] {
        let screens = NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @ \(Int($0.backingScaleFactor))x" }
        let environment = [
            ("macOS", system), ("Puce", chip), ("Modèle", model),
            ("Architecture", sysctlString("hw.machine") ?? ""), ("Langue", Locale.current.identifier),
            ("Écrans", "\(screens.count) · " + screens.joined(separator: ", ")),
        ]
        var machine = [
            ("Processeur", "\(Int(cpu * 100)) %"),
            ("Charge moyenne", String(format: "%.2f (%d cœurs)", load, ProcessInfo.processInfo.activeProcessorCount)),
            ("Mémoire", "\(formatBytes(memoryUsed)) / \(formatBytes(memoryTotal)) (\(Int(memoryFraction * 100)) %)"),
            ("Pression mémoire", pressure >= 4 ? "critique" : pressure >= 2 ? "élevée" : "normale"),
            ("Swap", formatBytes(swap)),
            ("Température", thermalText.lowercased()),
            ("Disque /", "\(formatBytes(diskTotal - diskFree)) / \(formatBytes(diskTotal))"),
        ]
        if let b = battery {
            machine.append(("Batterie", "\(b.percent) %" + (b.charging ? " · en charge" : "") + (b.health.map { " · santé \($0) %" } ?? "")))
        }
        machine += [
            ("Économie d'énergie", ProcessInfo.processInfo.isLowPowerModeEnabled ? "activée" : "désactivée"),
            ("Allumé depuis", uptimeText),
            ("Score de santé", "\(score)/100"),
        ]
        let wifi = [
            ("Moteur", moleVersionText.map { "CLI Mole \($0) (\(molePath ?? ""))" } ?? "intégré (CLI Mole absente)"),
            ("Outil administrateur", helperTrusted() ? "installé et vérifié" : "non installé"),
            ("Wi-Fi faible latence", OptimizeModel.shared.lowLatency ? "actif" : "inactif"),
        ]
        return [("ENVIRONNEMENT", environment), ("SYSTÈME", machine), ("HIPPOCAMPE", wifi)]
    }
}

// MARK: - Nettoyage

struct CleanItem: Identifiable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let recommended: Bool
    let inUse: Bool
    var selected: Bool
    // Protégé par le bouclier : jamais coché ni supprimé, d'une analyse à l'autre.
    var kept = false
    // Pourquoi l'élément n'est pas coché d'office (affiché au survol de « À vérifier »).
    var note = ""
    // Signalé par Mole sans être nettoyé (données Docker, émulateurs…) : affiché, jamais supprimé.
    var reviewOnly = false
}

// Une source : soit chaque élément d'un dossier, soit le dossier entier.
struct CleanSource {
    let root: URL
    var wholeFolder = false
    var recommended: @Sendable (String) -> Bool = { _ in true }
    var note: @Sendable (String) -> String = { _ in "" }
}

// Caches d'outils connus pour contenir des données longues à récupérer.
func toolCacheNote(_ name: String) -> String {
    switch name.lowercased() {
    case "huggingface": "Modèles d'IA téléchargés (Hugging Face) : ils seront retéléchargés, souvent plusieurs Go, au prochain usage."
    case "torch", "whisper", "lm-studio", "ollama": "Modèles d'IA téléchargés : ils seront retéléchargés au prochain usage, ce qui peut être long."
    case "gh": "Cache de GitHub CLI : petit et recréé tout seul, mais il garde aussi des extensions installées."
    case "pkg": "Cache d'un gestionnaire de paquets : recréé au besoin, mais les prochaines installations seront plus lentes."
    default: "Cache d'un outil qu'Hippocampe ne connaît pas : il peut contenir des données longues à refaire (modèles, téléchargements, sessions). Regardez son contenu avant de le supprimer."
    }
}

struct CleanGroup: Identifiable {
    let id: String
    let title: String
    let detail: String
    let sources: [CleanSource]
    var items: [CleanItem] = []
    var scanned = false
    var readable = true
    var expanded = false
    // Corbeille illisible sans accès complet au disque : elle est vidée par le Finder si cochée.
    var finderEmpty = true

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
    var allSelected: Bool {
        readable ? !items.isEmpty && items.allSatisfy { $0.selected || $0.inUse || $0.kept || $0.reviewOnly } : finderEmpty
    }
    var noneSelected: Bool { readable ? !items.contains { $0.selected } : !finderEmpty }
}

// Dossiers système que le nettoyage ne touche jamais : réglages, centre de contrôle,
// autorisations (TCC), éléments d'ouverture, audio, iCloud.
func isProtected(_ name: String) -> Bool {
    let n = name.lowercased()
    return ["systemsettings", "systempreferences", "controlcenter", "com.apple.settings", "backgroundtaskmanagement",
            "loginitems", "sharedfilelist", "tcc", "coreaudio", "com.apple.audio", "cloudkit", "com.apple.bird", "macchanger"]
        .contains { n.contains($0) }
}

// Éléments directement sous la racine qui peuvent être supprimés ; nil si le dossier est illisible.
func cleanableChildren(_ root: URL) -> [URL]? {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
    return items.filter { !isProtected($0.lastPathComponent) && $0.lastPathComponent != ".DS_Store" }
}

// Un cache est « actif » quand il porte l'identifiant d'une app ouverte : il est laissé de côté.
@MainActor
func runningIdentifiers() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
}

func scanGroup(_ group: CleanGroup, running: Set<String>, kept: Set<String>) -> CleanGroup {
    var g = group
    g.items = []
    g.readable = true
    for source in group.sources {
        if source.wholeFolder {
            guard FileManager.default.fileExists(atPath: source.root.path) else { continue }
            let size = allocatedSize(source.root)
            let keep = kept.contains(source.root.path)
            if size > 0 { g.items.append(CleanItem(url: source.root, size: size, recommended: !keep, inUse: false, selected: !keep, kept: keep)) }
            continue
        }
        guard let children = cleanableChildren(source.root) else {
            g.readable = false
            continue
        }
        for child in children {
            let size = allocatedSize(child)
            guard size > 0 else { continue }
            let name = child.lastPathComponent.lowercased()
            let inUse = running.contains(name) || running.contains { !$0.isEmpty && name.hasPrefix($0 + ".") }
            let keep = kept.contains(child.path)
            let recommended = source.recommended(child.lastPathComponent) && !inUse && !keep
            g.items.append(CleanItem(url: child, size: size, recommended: recommended, inUse: inUse, selected: recommended, kept: keep,
                                     note: source.note(child.lastPathComponent)))
        }
    }
    g.items.sort { $0.size > $1.size }
    g.scanned = true
    return g
}

@MainActor
final class CleanModel: ObservableObject {
    static let shared = CleanModel()

    @Published var groups: [CleanGroup] = [
        .init(id: "apps", title: "Caches et journaux des apps",
              detail: "Caches des apps et navigateurs, anciens journaux. Réglages, comptes et historiques restent en place",
              sources: [.init(root: home.appending(path: "Library/Caches")), .init(root: home.appending(path: "Library/Logs"))]),
        .init(id: "dev", title: "Outils de développement",
              detail: "Xcode, simulateurs, npm et autres caches d'outils. La prochaine compilation sera un peu plus longue",
              sources: [
                  .init(root: home.appending(path: "Library/Developer/Xcode/DerivedData")),
                  .init(root: home.appending(path: "Library/Developer/CoreSimulator/Caches"), wholeFolder: true),
                  .init(root: home.appending(path: "Library/Developer/Xcode/iOS DeviceSupport"), recommended: { _ in false },
                        note: { _ in "Symboles de débogage d'une version d'iOS : Xcode les recopie depuis l'iPhone au prochain branchement, ce qui prend plusieurs minutes. Sans risque si vous ne déboguez plus d'app sur cette version." }),
                  .init(root: home.appending(path: ".npm/_cacache"), wholeFolder: true),
                  .init(root: home.appending(path: ".cache"),
                        recommended: { ["uv", "pip", "puppeteer", "pre-commit", "node-gyp", "yarn", "prisma"].contains($0) },
                        note: toolCacheNote),
              ]),
        .init(id: "trash", title: "Corbeille", detail: "Vidée définitivement",
              sources: [.init(root: home.appending(path: ".Trash"))]),
    ]
    @Published var scanning = false
    @Published var cleaning = false
    @Published var confirming = false
    @Published var lastFreed: Int64?
    @Published var message = ""
    // Plan établi par « mo clean --dry-run » plutôt que par l'analyse intégrée.
    @Published var fromMole = false
    // Chemins protégés par le bouclier, gardés entre les lancements.
    @Published var kept: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "cleanKept") ?? [])

    var total: Int64 { groups.reduce(0) { $0 + $1.total } }
    var selectedSize: Int64 { groups.reduce(0) { $0 + $1.selectedSize } }
    var selectedCount: Int { groups.reduce(0) { $0 + $1.items.filter(\.selected).count } }
    var scanned: Bool { groups.allSatisfy(\.scanned) }

    func scan() {
        guard !scanning, !cleaning else { return }
        if molePath != nil { return scanWithMole() }
        scanOwn()
    }

    private func scanWithMole() {
        scanning = true
        LiveStatus.shared.set("Mole · préparation du plan de nettoyage…")
        let kept = kept
        let expanded = Set(groups.filter(\.expanded).map(\.id))
        Task {
            let plan = await Task.detached { moleCleanPlan() }.value
            guard let plan else {
                scanning = false
                return scanOwn()
            }
            var result = plan.sections.filter { !$0.items.isEmpty }.map { section in
                CleanGroup(id: "mole-" + section.title, title: frenchSection(section.title),
                           detail: "Repéré par Mole · \(section.items.count) éléments", sources: [],
                           items: section.items.map { url, size in
                               let keep = kept.contains(url.path)
                               return CleanItem(url: url, size: size, recommended: !keep, inUse: false, selected: !keep, kept: keep)
                           }.sorted { $0.size > $1.size },
                           scanned: true)
            }
            if !plan.review.isEmpty {
                result.append(CleanGroup(id: "mole-review", title: "À gérer séparément",
                                         detail: "Espace occupé seulement : Mole ne le nettoie pas. Gérez-le dans l'app concernée ou les Réglages Système",
                                         sources: [],
                                         items: plan.review.map {
                                             CleanItem(url: $0.url, size: $0.size, recommended: false, inUse: false, selected: false,
                                                       note: $0.name, reviewOnly: true)
                                         },
                                         scanned: true))
            }
            for i in result.indices where expanded.contains(result[i].id) { result[i].expanded = true }
            groups = result
            fromMole = true
            scanning = false
        }
    }

    private func scanOwn() {
        fromMole = false
        scanning = true
        let current = groups
        let running = runningIdentifiers()
        let kept = kept
        Task {
            await withTaskGroup(of: CleanGroup.self) { tasks in
                for group in current { tasks.addTask { scanGroup(group, running: running, kept: kept) } }
                for await done in tasks {
                    guard let i = groups.firstIndex(where: { $0.id == done.id }) else { continue }
                    var updated = done
                    updated.expanded = groups[i].expanded
                    groups[i] = updated
                }
            }
            scanning = false
        }
    }

    func toggleGroup(_ id: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let select = !groups[i].allSelected
        if groups[i].readable {
            for j in groups[i].items.indices where !groups[i].items[j].inUse && !groups[i].items[j].kept && !groups[i].items[j].reviewOnly {
                groups[i].items[j].selected = select
            }
        } else {
            groups[i].finderEmpty = select
        }
    }

    func select(all: Bool? = nil) {
        for i in groups.indices {
            for j in groups[i].items.indices {
                let item = groups[i].items[j]
                groups[i].items[j].selected = !item.inUse && !item.kept && !item.reviewOnly && (all ?? item.recommended)
            }
            groups[i].finderEmpty = all ?? true
        }
    }

    // Bouclier : protège un élément (ou le libère) pour toutes les analyses suivantes.
    func toggleKept(_ url: URL) {
        let keep = !kept.contains(url.path)
        if keep { kept.insert(url.path) } else { kept.remove(url.path) }
        UserDefaults.standard.set(Array(kept), forKey: "cleanKept")
        for i in groups.indices {
            for j in groups[i].items.indices where groups[i].items[j].url == url {
                groups[i].items[j].kept = keep
                groups[i].items[j].selected = !keep && groups[i].items[j].recommended
            }
        }
    }

    func clearKept() {
        for path in kept { toggleKept(URL(fileURLWithPath: path)) }
    }

    func clean() {
        // Plan de Mole accepté tel quel : c'est Mole qui nettoie, avec ses propres garde-fous.
        let cleanable = groups.flatMap { $0.items.filter { !$0.reviewOnly } }
        if fromMole && !cleanable.isEmpty && cleanable.allSatisfy(\.selected) {
            let planned = selectedSize
            cleaning = true
            Task {
                let r = await Task.detached { runMole(["clean"]) }.value
                cleaning = false
                lastFreed = planned
                message = r.status == 0 ? "Nettoyé par Mole" : "Mole s'est arrêté (code \(r.status))"
                scan()
            }
            return
        }
        let chosen = groups.flatMap { $0.items.filter(\.selected).map(\.url) }
        let emptyWithFinder = groups.contains { $0.id == "trash" && !$0.readable && $0.finderEmpty }
        cleaning = true
        Task {
            let (freed, failed) = await Task.detached { () -> (Int64, Int) in
                var freed: Int64 = 0, failed = 0
                for item in chosen {
                    let size = allocatedSize(item)
                    do {
                        try FileManager.default.removeItem(at: item)
                        freed += size
                    } catch {
                        // Supprimé en partie seulement : on ne compte que ce qui a disparu.
                        freed += max(0, size - allocatedSize(item))
                        failed += 1
                    }
                }
                if emptyWithFinder { _ = run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"]) }
                return (freed, failed)
            }.value
            cleaning = false
            lastFreed = freed
            message = failed > 0 ? "\(failed) éléments en cours d'utilisation conservés" : ""
            scan()
        }
    }
}

// MARK: - Apps

struct AppEntry: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let lastUsed: Date?
    var size: Int64?
    // Nom accepté par « mo uninstall » et origine (Homebrew, App Store, téléchargement).
    var moleName: String?
    var source = ""
    var dateAdded: Date?
}

struct Leftover: Identifiable {
    var id: URL { url }
    let url: URL
    let kind: String
    let size: Int64
    var selected = true
}

struct StartupItem: Identifiable {
    var id: URL { url }
    let url: URL
    let label: String
    let program: String
    let scope: String
    var appURL: URL? {
        guard let range = program.range(of: ".app/") else { return nil }
        return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
    }
}

// Applications installées par l'utilisateur ; celles d'Apple sont laissées de côté.
func installedApps() -> [AppEntry] {
    var apps: [AppEntry] = []
    for dir in [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")] {
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "app" {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !id.hasPrefix("com.apple."), id != Bundle.main.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let lastUsed = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
            apps.append(AppEntry(url: url, name: name, bundleID: id, version: version, lastUsed: lastUsed,
                                 dateAdded: NSMetadataItem(url: url)?.value(forAttribute: "kMDItemDateAdded") as? Date))
        }
    }
    return apps
}

func darwinDirectory(_ name: Int32) -> URL? {
    var buffer = [CChar](repeating: 0, count: 1024)
    guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer))
}

// Tout ce qu'une app laisse derrière elle : ~/Library (réglages, caches, conteneurs, cookies…),
// caches temporaires de /private/var/folders et liste de ses documents récents.
func findLeftovers(of app: AppEntry) -> [Leftover] {
    let id = app.bundleID.lowercased()
    let names = Set([app.name.lowercased(), app.url.deletingPathExtension().lastPathComponent.lowercased()].filter { $0.count >= 3 })
    let library = home.appending(path: "Library")
    var places: [(URL, String)] = [
        (library.appending(path: "Application Support"), "Données de l'app"),
        (library.appending(path: "Caches"), "Cache"),
        (library.appending(path: "Preferences"), "Réglages"),
        (library.appending(path: "Preferences/ByHost"), "Réglages"),
        (library.appending(path: "Containers"), "Conteneur"),
        (library.appending(path: "Group Containers"), "Conteneur partagé"),
        (library.appending(path: "Logs"), "Journaux"),
        (library.appending(path: "Saved Application State"), "État des fenêtres"),
        (library.appending(path: "HTTPStorages"), "Stockage HTTP"),
        (library.appending(path: "WebKit"), "WebKit"),
        (library.appending(path: "LaunchAgents"), "Agent de démarrage"),
        (library.appending(path: "Application Scripts"), "Scripts d'app"),
        (library.appending(path: "Cookies"), "Cookies"),
        (library.appending(path: "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"),
         "Documents récents"),
    ]
    if let cache = darwinDirectory(_CS_DARWIN_USER_CACHE_DIR) { places.append((cache, "Cache temporaire")) }
    if let temp = darwinDirectory(_CS_DARWIN_USER_TEMP_DIR) { places.append((temp, "Fichiers temporaires")) }

    var found: [Leftover] = []
    for (dir, kind) in places {
        for item in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let file = item.lastPathComponent.lowercased()
            let stem = (file as NSString).deletingPathExtension
            let matches = stem == id || file.hasPrefix(id + ".") || file.hasSuffix("." + id) || file.hasSuffix("+" + id)
                || names.contains(file) || names.contains(stem)
            guard matches else { continue }
            let label = file.hasSuffix(".binarycookies") ? "Cookies" : kind
            found.append(Leftover(url: item, kind: label, size: allocatedSize(item)))
        }
    }
    return found.sorted { $0.size > $1.size }
}

// Tâches lancées au démarrage par launchd, pour l'utilisateur et pour tout le Mac.
func startupItems() -> [StartupItem] {
    let places = [(home.appending(path: "Library/LaunchAgents"), "Agent de votre session"),
                  (URL(fileURLWithPath: "/Library/LaunchAgents"), "Agent pour tous les comptes"),
                  (URL(fileURLWithPath: "/Library/LaunchDaemons"), "Service système")]
    var items: [StartupItem] = []
    for (dir, scope) in places {
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "plist" {
            let plist = NSDictionary(contentsOf: url)
            let label = plist?["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
            let program = plist?["Program"] as? String ?? (plist?["ProgramArguments"] as? [String])?.first ?? ""
            items.append(StartupItem(url: url, label: label, program: program, scope: scope))
        }
    }
    return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
}

enum AppSort: String, CaseIterable {
    case name = "Nom"
    case size = "Taille"
    case lastUsed = "Dernière utilisation"
    case added = "Ajoutée"
}

@MainActor
final class UninstallModel: ObservableObject {
    static let shared = UninstallModel()

    @Published var apps: [AppEntry] = []
    @Published var selection: Set<URL> = []
    @Published var sort: AppSort = .lastUsed
    @Published var ascending = true
    @Published var filter = ""
    @Published var searching = false
    @Published var section = 0
    @Published var startup: [StartupItem] = []
    @Published var confirming = false
    @Published var working = false
    @Published var message = ""
    @Published var loaded = false
    @Published var expanded: Set<URL> = []
    @Published var details: [URL: [Leftover]] = [:]
    // Apps dont la liste de fichiers vient du plan de Mole, et celles où vous avez décoché des fichiers.
    @Published var molePlanned: Set<URL> = []
    private var edited: Set<URL> = []
    private var sizing: Task<Void, Never>?
    private var preloading: Task<Void, Never>?

    // Les fichiers de chaque app sont prêts avant qu'on la déplie : d'abord la recherche intégrée,
    // instantanée, puis le plan de Mole (quelques secondes par app), trois apps à la fois.
    func preloadDetails() {
        preloading?.cancel()
        let list = apps
        preloading = Task {
            let quick = await Task.detached { list.map { ($0.url, findLeftovers(of: $0)) } }.value
            for (url, files) in quick where details[url] == nil { details[url] = files }
            guard molePath != nil else { return }
            for start in stride(from: 0, to: list.count, by: 3) {
                if Task.isCancelled { return }
                let chunk = Array(list[start..<min(start + 3, list.count)])
                await withTaskGroup(of: (URL, [Leftover]?).self) { group in
                    for app in chunk { group.addTask { (app.url, app.moleName.flatMap(moleUninstallPlan)) } }
                    for await (url, plan) in group {
                        guard let plan, !edited.contains(url) else { continue }
                        details[url] = plan
                        molePlanned.insert(url)
                    }
                }
            }
        }
    }

    func toggleFile(_ app: AppEntry, _ file: Leftover) {
        guard let i = details[app.url]?.firstIndex(where: { $0.id == file.id }) else { return }
        details[app.url]?[i].selected.toggle()
        edited.insert(app.url)
    }

    // Déplie une app pour voir chaque fichier qui partira avec elle.
    func toggleExpanded(_ app: AppEntry) {
        if expanded.contains(app.url) {
            expanded.remove(app.url)
            return
        }
        expanded.insert(app.url)
        guard details[app.url] == nil else { return }
        Task {
            let found = await Task.detached { app.moleName.flatMap(moleUninstallPlan) ?? findLeftovers(of: app) }.value
            details[app.url] = found
        }
    }

    func leftoverSize(_ app: AppEntry) -> Int64 {
        (details[app.url] ?? []).filter(\.selected).reduce(0) { $0 + $1.size }
    }

    var visibleApps: [AppEntry] {
        let shown = filter.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        return shown.sorted(by: before)
    }

    // Ordre choisi en haut de la liste (aussi utilisé par les mises à jour).
    func before(_ a: AppEntry, _ b: AppEntry) -> Bool {
        let ordered: Bool
        switch sort {
        case .name: ordered = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case .size: ordered = (a.size ?? 0) > (b.size ?? 0)
        case .lastUsed: ordered = (a.lastUsed ?? .distantPast) < (b.lastUsed ?? .distantPast)
        case .added: ordered = (a.dateAdded ?? .distantPast) > (b.dateAdded ?? .distantPast)
        }
        return ascending ? ordered : !ordered
    }

    var totalSize: Int64 { apps.compactMap(\.size).reduce(0, +) }
    var selectedApps: [AppEntry] { apps.filter { selection.contains($0.url) } }

    func setSort(_ s: AppSort) {
        if sort == s { ascending.toggle() } else { sort = s; ascending = true }
    }

    func load() {
        sizing?.cancel()
        Task {
            if molePath != nil, let listed = await Task.detached(operation: { moleApps() }).value {
                apps = listed.compactMap { m in
                    let url = URL(fileURLWithPath: m.path)
                    guard m.bundleId != Bundle.main.bundleIdentifier else { return nil }
                    let bundle = Bundle(url: url)
                    return AppEntry(url: url, name: m.name, bundleID: m.bundleId ?? "",
                                    version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                    lastUsed: NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date,
                                    size: m.size.flatMap(parseMoleSize), moleName: m.uninstallName, source: m.source ?? "",
                                    dateAdded: NSMetadataItem(url: url)?.value(forAttribute: "kMDItemDateAdded") as? Date)
                }
                loaded = true
                preloadDetails()
                return
            }
            apps = await Task.detached { installedApps() }.value
            loaded = true
            preloadDetails()
            let urls = apps.map(\.url)
            sizing = Task {
                for url in urls {
                    let size = await Task.detached { allocatedSize(url) }.value
                    if Task.isCancelled { return }
                    if let i = apps.firstIndex(where: { $0.url == url }) { apps[i].size = size }
                }
            }
        }
    }

    func loadStartup() {
        Task { startup = await Task.detached { startupItems() }.value }
    }

    func toggle(_ app: AppEntry) {
        if selection.contains(app.url) { selection.remove(app.url) } else { selection.insert(app.url) }
    }

    // Quitte les apps ouvertes, puis met les apps et leurs restes à la Corbeille (récupérables).
    func uninstall() {
        let chosen = selectedApps
        guard !chosen.isEmpty else { return }
        working = true
        message = ""
        Task {
            for app in chosen {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) { running.terminate() }
            }
            try? await Task.sleep(for: .seconds(1))
            // Restes déjà affichés : seulement ceux qui sont cochés ; sinon tous ceux qui sont trouvés.
            let known = details
            let leftovers = await Task.detached {
                chosen.flatMap { app in (known[app.url] ?? findLeftovers(of: app)).filter(\.selected) }
            }.value
            let total = chosen.compactMap(\.size).reduce(0, +) + leftovers.reduce(0) { $0 + $1.size }
            do {
                _ = try await NSWorkspace.shared.recycle(chosen.map(\.url) + leftovers.map(\.url))
                message = "\(chosen.count) app\(chosen.count > 1 ? "s" : "") et \(leftovers.count) restes mis à la Corbeille, \(formatBytes(total))"
                apps.removeAll { selection.contains($0.url) }
                for app in chosen { details[app.url] = nil; expanded.remove(app.url) }
                selection = []
            } catch {
                message = "Échec : \(error.localizedDescription)"
            }
            working = false
        }
    }
}

// MARK: - Analyse du disque

func diskSpace() -> (free: Int64, total: Int64) {
    let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
    return (v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeTotalCapacity ?? 0))
}

struct DiskItem: Identifiable {
    var id: URL { url }
    let url: URL
    let isDirectory: Bool
    var size: Int64?
}

// Les plus gros fichiers sous un dossier (au moins 50 Mo), du plus gros au plus petit.
func largestFiles(under root: URL, limit: Int = 40) -> [DiskItem] {
    guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                                    options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else { return [] }
    var found: [DiskItem] = []
    var count = 0
    while let file = walk.nextObject() as? URL {
        if Task.isCancelled { break }
        count += 1
        if count % 200 == 0 { LiveStatus.shared.set(file.path) }
        guard let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]), v.isRegularFile == true,
              let size = v.totalFileAllocatedSize, size >= 50_000_000 else { continue }
        found.append(DiskItem(url: file, isDirectory: false, size: Int64(size)))
    }
    return Array(found.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(limit))
}

// Carte « treemap » : chaque élément reçoit un rectangle proportionnel à sa taille, le plus carré possible.
func treemap(_ sizes: [Double], in bounds: CGRect) -> [CGRect] {
    func worst(_ row: [Double], _ side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let big = row.max(), let small = row.min(), small > 0, side > 0 else { return .infinity }
        return max(side * side * big / (sum * sum), sum * sum / (side * side * small))
    }
    var result: [CGRect] = []
    var rect = bounds
    var remaining = ArraySlice(sizes)
    var total = sizes.reduce(0, +)
    while !remaining.isEmpty {
        guard total > 0, rect.width > 1, rect.height > 1 else {
            result += Array(repeating: .zero, count: remaining.count)
            break
        }
        let scale = Double(rect.width * rect.height) / total
        let side = Double(min(rect.width, rect.height))
        var row: [Double] = []
        for value in remaining {
            let candidate = row + [value * scale]
            if row.isEmpty || worst(candidate, side) <= worst(row, side) { row = candidate } else { break }
        }
        let thickness = row.reduce(0, +) / side
        var offset = 0.0
        for area in row {
            let length = area / thickness
            if rect.width >= rect.height {
                result.append(CGRect(x: rect.minX, y: rect.minY + offset, width: thickness, height: length))
            } else {
                result.append(CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: thickness))
            }
            offset += length
        }
        if rect.width >= rect.height {
            rect = CGRect(x: rect.minX + thickness, y: rect.minY, width: rect.width - thickness, height: rect.height)
        } else {
            rect = CGRect(x: rect.minX, y: rect.minY + thickness, width: rect.width, height: rect.height - thickness)
        }
        total -= row.reduce(0, +) / scale
        remaining = remaining.dropFirst(row.count)
    }
    return result
}

@MainActor
final class AnalyzeModel: ObservableObject {
    static let shared = AnalyzeModel()

    @Published var current = home
    @Published var items: [DiskItem] = []
    @Published var pending = 0
    @Published var started = false
    @Published var showLarge = false
    @Published var largeFiles: [DiskItem] = []
    @Published var scanningLarge = false
    @Published var toTrash: DiskItem?
    @Published var message = ""
    @Published var showDuplicates = false
    @Published var duplicates: [DuplicateGroup] = []
    @Published var scanningDuplicates = false
    @Published var duplicatesDone = false
    private var task: Task<Void, Never>?
    private var largeTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?

    var duplicateSavings: Int64 { duplicates.reduce(0) { $0 + $1.reclaimable } }

    func findDuplicatesHere() {
        duplicateTask?.cancel()
        scanningDuplicates = true
        duplicatesDone = false
        duplicates = []
        let root = current
        LiveStatus.shared.set(root.path)
        duplicateTask = Task {
            let found = await Task.detached { findDuplicates(under: root) }.value
            guard !Task.isCancelled else { return }
            duplicates = found
            scanningDuplicates = false
            duplicatesDone = true
        }
    }

    // Met à la Corbeille les copies cochées ; l'exemplaire gardé reste en place.
    func trashDuplicates() {
        let urls = duplicates.flatMap { $0.files.filter(\.remove).map(\.url) }
        let saved = duplicateSavings
        Task {
            do {
                _ = try await NSWorkspace.shared.recycle(urls)
                duplicates = duplicates.compactMap { group in
                    var g = group
                    g.files.removeAll(where: \.remove)
                    return g.files.count > 1 ? g : nil
                }
                message = "\(urls.count) doublons mis à la Corbeille, \(formatBytes(saved)) libérés"
            } catch {
                message = "Échec : \(error.localizedDescription)"
            }
        }
    }

    var total: Int64 { items.compactMap(\.size).reduce(0, +) }

    func open(_ url: URL) {
        task?.cancel()
        started = true
        current = url
        message = ""
        duplicates = []
        duplicatesDone = false
        guard molePath != nil else { return openOwn(url) }
        items = []
        pending = 1
        LiveStatus.shared.set("Mole · analyse de " + tildePath(url) + "…")
        task = Task {
            let result = await Task.detached { MoleAnalysis.fetch(url) }.value
            if Task.isCancelled { return }
            guard let result else {
                pending = 0
                return openOwn(url)
            }
            items = (result.entries ?? []).map {
                DiskItem(url: URL(fileURLWithPath: $0.path), isDirectory: $0.isDir ?? false, size: $0.size)
            }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
            largeFiles = (result.largeFiles ?? []).map { DiskItem(url: URL(fileURLWithPath: $0.path), isDirectory: false, size: $0.size) }
            scanningLarge = false
            pending = 0
            if showDuplicates { findDuplicatesHere() }
        }
    }

    private func openOwn(_ url: URL) {
        let children = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        items = children.map { DiskItem(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
        pending = items.count
        task = Task {
            await withTaskGroup(of: (URL, Int64).self) { group in
                for child in children { group.addTask { (child, allocatedSize(child)) } }
                for await (child, size) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    if let i = items.firstIndex(where: { $0.url == child }) { items[i].size = size }
                    items.sort { ($0.size ?? -1) > ($1.size ?? -1) }
                    pending -= 1
                }
            }
        }
        if showLarge { findLarge() }
    }

    func findLarge() {
        // Avec Mole, les gros fichiers arrivent avec l'analyse du dossier.
        guard molePath == nil || largeFiles.isEmpty && pending == 0 && !started else { return }
        largeTask?.cancel()
        scanningLarge = true
        largeFiles = []
        let root = current
        largeTask = Task {
            let found = await Task.detached { largestFiles(under: root) }.value
            guard !Task.isCancelled else { return }
            largeFiles = found
            scanningLarge = false
        }
    }

    func up() {
        guard current.path != "/" else { return }
        open(current.deletingLastPathComponent())
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = current
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func trash(_ item: DiskItem) {
        Task {
            do {
                _ = try await NSWorkspace.shared.recycle([item.url])
                items.removeAll { $0.id == item.id }
                largeFiles.removeAll { $0.id == item.id }
                message = "\(item.url.lastPathComponent) mis à la Corbeille"
            } catch {
                message = "Échec : \(error.localizedDescription)"
            }
        }
    }
}

// Version de la CLI Mole, lue une fois au lancement.
let moleVersionText = moleVersion()

// MARK: - Optimisation

enum StepOutcome: Sendable {
    case done(String)
    case skipped(String)
    case attention(String)
    case failed(String)

    var text: String {
        switch self {
        case .done(let t), .skipped(let t), .attention(let t), .failed(let t): t
        }
    }
}

// Une étape d'optimisation vérifie d'abord si elle est utile : sinon elle est ignorée, avec la raison.
struct OptimizeStep: Identifiable, Sendable {
    let id: String
    let section: String
    let title: String
    let run: @Sendable () -> StepOutcome
}

func restartAgent(_ name: String) -> StepOutcome {
    run("/usr/bin/killall", [name]).status == 0 ? .done("Actualisé") : .skipped("Non lancé")
}

func helperOutcome(_ r: (status: Int32, out: String, err: String), _ success: String) -> StepOutcome {
    r.status == 0 ? .done(success) : .failed(r.err.isEmpty ? "Échec" : r.err)
}

// États de fenêtre d'apps qui ne sont plus installées.
func staleWindowStates() -> StepOutcome {
    let dir = home.appending(path: "Library/Saved Application State")
    let stale = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { url in
        let id = url.deletingPathExtension().lastPathComponent
        return url.pathExtension == "savedState" && NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil
    }
    guard !stale.isEmpty else { return .skipped("Aucun état obsolète") }
    let removed = stale.filter { (try? FileManager.default.removeItem(at: $0)) != nil }.count
    return .done("\(removed) effacés")
}

func quarantineHistory() -> StepOutcome {
    let db = home.appending(path: "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2").path
    guard FileManager.default.fileExists(atPath: db) else { return .skipped("Historique vide") }
    let count = Int(run("/usr/bin/sqlite3", [db, "SELECT COUNT(*) FROM LSQuarantineEvent"]).out) ?? 0
    guard count > 500 else { return .skipped("\(count) entrées, rien à faire") }
    let r = run("/usr/bin/sqlite3", [db, "DELETE FROM LSQuarantineEvent; VACUUM;"])
    return r.status == 0 ? .done("\(count) entrées effacées") : .failed(r.err)
}

func brokenStartupItems() -> StepOutcome {
    let broken = startupItems().filter { $0.scope == "Agent de votre session" && !$0.program.isEmpty
        && $0.program.hasPrefix("/") && !FileManager.default.fileExists(atPath: $0.program) }
    return broken.isEmpty ? .skipped("Tous valides") : .attention("\(broken.count) pointent vers un programme absent (Apps › Démarrage)")
}

func unreadablePreferences() -> StepOutcome {
    let dir = home.appending(path: "Library/Preferences")
    let bad = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "plist" }
        .filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
        }
    return bad.isEmpty ? .skipped("Toutes lisibles") : .attention("\(bad.count) illisibles : " + bad.prefix(3).map(\.lastPathComponent).joined(separator: ", "))
}

func orphanCommands() -> StepOutcome {
    var broken: [String] = []
    for dir in ["/usr/local/bin", "/opt/homebrew/bin"] {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            let path = dir + "/" + name
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                let resolved = target.hasPrefix("/") ? target : dir + "/" + target
                if !FileManager.default.fileExists(atPath: resolved) { broken.append(name) }
            }
        }
    }
    return broken.isEmpty ? .skipped("Aucune") : .attention("Commandes sans app : " + broken.prefix(4).joined(separator: ", "))
}

func mountedImages() -> StepOutcome {
    let count = run("/usr/bin/hdiutil", ["info"]).out.components(separatedBy: "image-path").count - 1
    return count == 0 ? .skipped("Aucune") : .attention("\(count) montées, à éjecter dans le Finder si inutiles")
}

let optimizeSteps: [OptimizeStep] = [
    .init(id: "input", section: "Corrections", title: "Changement de saisie") { restartAgent("TextInputMenuAgent") },
    .init(id: "spotlight", section: "Corrections", title: "Spotlight") {
        run("/usr/bin/mdutil", ["-s", "/"]).out.contains("enabled") ? .skipped("Normal") : .attention("Indexation désactivée")
    },
    .init(id: "notifications", section: "Corrections", title: "Centre de notifications") { restartAgent("NotificationCenter") },
    .init(id: "pasteboard", section: "Corrections", title: "Presse-papiers universel") { restartAgent("pboard") },
    .init(id: "quicklook", section: "Vitesse", title: "Reconstruire le cache Coup d'œil") {
        run("/usr/bin/qlmanage", ["-r", "cache"]).status == 0 ? .done("Reconstruit") : .failed("qlmanage a échoué")
    },
    .init(id: "thumbnails", section: "Vitesse", title: "Reconstruire les vignettes de fichiers") {
        run("/usr/bin/qlmanage", ["-r"]).status == 0 ? .done("Reconstruites") : .failed("qlmanage a échoué")
    },
    .init(id: "dns", section: "Réseau", title: "Vider le cache DNS") { helperOutcome(runHelper(["flush-dns"]), "Vidé") },
    .init(id: "purge", section: "Mémoire", title: "Purger la mémoire physique inactive") {
        memoryPressure() < 2 ? .skipped("Pression mémoire normale") : helperOutcome(runHelper(["purge"]), "Mémoire libérée")
    },
    .init(id: "windows", section: "Nettoyage", title: "Effacer les états de fenêtre obsolètes") { staleWindowStates() },
    .init(id: "quarantine", section: "Nettoyage", title: "Effacer l'historique de quarantaine des téléchargements") { quarantineHistory() },
    .init(id: "startup", section: "Vérifications", title: "Vérifier les éléments de démarrage") { brokenStartupItems() },
    .init(id: "prefs", section: "Vérifications", title: "Vérifier les fichiers de préférences") { unreadablePreferences() },
    .init(id: "commands", section: "Vérifications", title: "Vérifier les commandes laissées par des apps supprimées") { orphanCommands() },
    .init(id: "images", section: "Vérifications", title: "Repérer les images disque montées") { mountedImages() },
]

struct Maintenance: Identifiable {
    let id: String
    let title: String
    let detail: String
    let work: @Sendable () -> (status: Int32, out: String, err: String)
}

@MainActor
final class OptimizeModel: ObservableObject {
    static let shared = OptimizeModel()

    let steps = optimizeSteps
    // Actions qui se voient (le Dock ou le Finder disparaissent un instant) : lancées à la main seulement.
    let manual: [Maintenance] = [
        .init(id: "dock", title: "Relancer le Dock", detail: "Icônes figées ou Dock qui ne répond plus") { run("/usr/bin/killall", ["Dock"]) },
        .init(id: "finder", title: "Relancer le Finder", detail: "Fenêtres ou icônes du bureau qui ne se mettent plus à jour") {
            run("/usr/bin/killall", ["Finder"])
        },
    ]
    @Published var outcomes: [String: StepOutcome] = [:]
    // Résultat de « mo optimize », section par section.
    @Published var moleSections: [MoleOptimizeSection] = []
    @Published var moleNote = ""
    @Published var showNoWifi = false
    @Published var current: String?
    @Published var running = false
    @Published var manualResults: [String: String] = [:]

    // Wi-Fi faible latence : coupe AWDL (AirDrop, AirPlay, Sidecar), qui fait varier le ping
    // en balayant d'autres canaux. macOS le rallume souvent : on le recoupe tant que l'option est active.
    @Published var lowLatency = false
    @Published var lowLatencyMessage = ""
    private var awdlTimer: Timer?

    var finished: Bool { !running && (!outcomes.isEmpty || !moleSections.isEmpty) }
    var moleLines: [MoleOptimizeLine] { moleSections.flatMap(\.lines) }
    var doneCount: Int {
        moleSections.isEmpty ? outcomes.values.filter { if case .done = $0 { true } else { false } }.count
            : moleLines.filter { moleOutcome($0) == 0 }.count
    }
    var skippedCount: Int {
        moleSections.isEmpty ? outcomes.values.filter { if case .skipped = $0 { true } else { false } }.count
            : moleLines.filter { moleOutcome($0) == 1 }.count
    }
    var attentionCount: Int {
        moleSections.isEmpty ? outcomes.values.filter { if case .attention = $0 { true } else { false } }.count
            : moleLines.filter { moleOutcome($0) == 2 }.count
    }

    // 0 : fait, 1 : rien à faire, 2 : à vérifier.
    func moleOutcome(_ line: MoleOptimizeLine) -> Int {
        if "◎⚠✗".contains(line.symbol) { return 2 }
        let idle = ["already", "skipped", "healthy", "valid", "clean", "no ", "not available", "not readable", "optimal"]
        if line.symbol == "-" || line.symbol == "✓" || idle.contains(where: { line.text.lowercased().contains($0) }) { return 1 }
        return 0
    }

    func runAll() {
        if molePath != nil {
            running = true
            moleSections = []
            outcomes = [:]
            LiveStatus.shared.set("Mole · optimisation…")
            Task {
                let r = await Task.detached { runMole(["optimize"]) }.value
                moleSections = parseOptimize(r.out)
                moleNote = r.out.contains("admin access not granted") || r.out.contains("Skipping sudo")
                    ? "Les optimisations qui demandent le mot de passe administrateur ont été passées par Mole (lancé hors terminal)."
                    : ""
                running = false
                if moleSections.isEmpty { runOwn() }
            }
            return
        }
        runOwn()
    }

    private func runOwn() {
        running = true
        outcomes = [:]
        Task {
            for step in steps {
                current = step.title
                LiveStatus.shared.set(step.title)
                outcomes[step.id] = await Task.detached { step.run() }.value
            }
            current = nil
            running = false
        }
    }

    func perform(_ task: Maintenance) {
        manualResults[task.id] = "…"
        Task {
            let r = await Task.detached { task.work() }.value
            manualResults[task.id] = r.status == 0 ? "Fait ✓" : "Échec : \(r.err.isEmpty ? r.out : r.err)"
        }
    }

    // Wi-Fi connecté : l'interface Wi-Fi (en0) a une adresse IP.
    nonisolated static func wifiConnected() -> Bool { run("/usr/sbin/ipconfig", ["getifaddr", "en0"]).status == 0 }

    func setLowLatency(_ on: Bool) {
        if on && !Self.wifiConnected() {
            showNoWifi = true
            lowLatency = false
            return
        }
        lowLatency = on
        awdlTimer?.invalidate()
        awdlTimer = nil
        lowLatencyMessage = on ? "Activation…" : "Rétablissement d'AirDrop et AirPlay…"
        Task {
            let r = await Task.detached { runHelper(["awdl", on ? "down" : "up"]) }.value
            guard r.status == 0 else {
                lowLatency = false
                lowLatencyMessage = "Échec : \(r.err)"
                return
            }
            lowLatencyMessage = on ? "Actif : AirDrop, AirPlay et Sidecar sont en pause" : "Désactivé"
            guard on else { return }
            awdlTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task.detached {
                    if run("/sbin/ifconfig", ["awdl0"]).out.contains("status: active") { _ = runHelper(["awdl", "down"]) }
                }
            }
        }
    }

    func restoreOnQuit() {
        guard lowLatency else { return }
        _ = run("/usr/bin/sudo", ["-n", helperPath, "awdl", "up"])
    }
}
