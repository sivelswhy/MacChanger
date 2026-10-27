import AppKit
import SceneKit
import SwiftUI

// Interface à onglets : chaque onglet a sa planète en 3D et sa teinte. Nettoyage, Analyse,
// Optimisation s'ouvrent sur un accueil centré sur la planète, puis sur le détail ;
// Apps et État montrent directement leur contenu. Textures : Solar System Scope (CC BY 4.0) et NASA.

enum AppTab: String, CaseIterable, Identifiable {
    case clean, uninstall, optimize, analyze, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: "Nettoyer"
        case .uninstall: "Apps"
        case .optimize: "Optimiser"
        case .analyze: "Analyser"
        case .status: "État"
        }
    }

    var planet: Planet {
        switch self {
        case .clean: .earth
        case .uninstall: .mars
        case .optimize: .mercury
        case .analyze: .jupiter
        case .status: .sun
        }
    }

    var tagline: String {
        switch self {
        case .clean: "Les nuages passent sur les continents\net emportent la poussière avec eux."
        case .uninstall: "Le vent rouge efface les pas\nde ceux qui sont partis."
        case .optimize: "Un tour du soleil en quelques semaines :\nrien ne traîne ici."
        case .analyze: "Ses tempêtes se voient de loin.\nVoyez où va votre espace."
        case .status: "Il brûle sans relâche\net veille sur tout le reste."
        }
    }

    // Fond de l'onglet : un dégradé sombre dans la couleur de la planète.
    var tint: (top: Color, bottom: Color) {
        switch self {
        case .clean: (Color(red: 0.12, green: 0.17, blue: 0.29), Color(red: 0.06, green: 0.08, blue: 0.15))
        case .uninstall: (Color(red: 0.24, green: 0.10, blue: 0.11), Color(red: 0.12, green: 0.05, blue: 0.06))
        case .optimize: (Color(red: 0.19, green: 0.18, blue: 0.18), Color(red: 0.09, green: 0.09, blue: 0.09))
        case .analyze: (Color(red: 0.27, green: 0.16, blue: 0.09), Color(red: 0.13, green: 0.08, blue: 0.05))
        case .status: (Color(red: 0.21, green: 0.18, blue: 0.08), Color(red: 0.10, green: 0.09, blue: 0.05))
        }
    }
}

enum Planet: String {
    case moon, sun, earth, mars, jupiter, mercury

    var glow: Color {
        switch self {
        case .moon: Color(red: 0.85, green: 0.85, blue: 0.95)
        case .sun: Color(red: 1.0, green: 0.6, blue: 0.2)
        case .earth: Color(red: 0.3, green: 0.6, blue: 1.0)
        case .mars: Color(red: 0.95, green: 0.4, blue: 0.25)
        case .jupiter: Color(red: 0.9, green: 0.7, blue: 0.5)
        case .mercury: Color(red: 0.7, green: 0.65, blue: 0.6)
        }
    }

    // Inclinaison de l'axe (radians) et durée d'un tour (secondes).
    var tilt: CGFloat { self == .earth ? 0.41 : self == .jupiter ? 0.05 : 0.12 }
    var period: TimeInterval { self == .sun ? 90 : self == .jupiter ? 40 : 70 }
}

@MainActor
final class TabSelection: ObservableObject {
    @Published var selected: AppTab = .clean
    @Published var detail: Set<AppTab> = []
    @Published var showMenu = false
    @Published var showDiagnostic = false
    @Published var showWifi = false

    func open(_ tab: AppTab) { withAnimation(.easeInOut(duration: 0.25)) { _ = detail.insert(tab) } }
    func close(_ tab: AppTab) { withAnimation(.easeInOut(duration: 0.25)) { _ = detail.remove(tab) } }
}

let accent = Color(red: 0.55, green: 0.68, blue: 1.0)
let positive = Color(red: 0.45, green: 0.82, blue: 0.6)
let faint = Color.white.opacity(0.55)

// MARK: - Fenêtre

struct RootView: View {
    @ObservedObject var tabs: TabSelection
    let wifiPanel: NSView

    var body: some View {
        ZStack {
            LinearGradient(colors: [tabs.selected.tint.top, tabs.selected.tint.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.4), value: tabs.selected)
            Starfield().opacity(0.35).ignoresSafeArea()
            VStack(spacing: 0) {
                TabBar(tabs: tabs)
                    .padding(.top, 30)
                    .padding(.bottom, 14)
                Group {
                    switch tabs.selected {
                    case .clean: CleanTab()
                    case .uninstall: AppsTab()
                    case .optimize: OptimizeTab()
                    case .analyze: AnalyzeTab()
                    case .status: StatusTab()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Le panneau Wi-Fi reste monté (caché) : ses contrôles AppKit ne quittent jamais la fenêtre.
            WifiOverlay(tabs: tabs, panel: wifiPanel)
                .opacity(tabs.showWifi ? 1 : 0)
                .allowsHitTesting(tabs.showWifi)
            if tabs.showDiagnostic { DiagnosticOverlay(tabs: tabs) }
            NoWifiCard()
            if molePath == nil { MoleMissingBanner() }
        }
        .environmentObject(tabs)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 640)
    }
}

struct TabBar: View {
    @ObservedObject var tabs: TabSelection
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            Button { tabs.showMenu.toggle() } label: {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .padding(2)
                    .background(Circle().fill(.white.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .help("Plus")
            .popover(isPresented: $tabs.showMenu, arrowEdge: .bottom) { AppMenu(tabs: tabs) }
            .padding(.trailing, 6)
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { tabs.selected = tab }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .foregroundStyle(tabs.selected == tab ? .black : .white.opacity(0.65))
                        .background {
                            if tabs.selected == tab {
                                Capsule().fill(.white.opacity(0.95)).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.07)))
        .overlay(Capsule().stroke(.white.opacity(0.06)))
    }
}

struct AppMenu: View {
    @ObservedObject var tabs: TabSelection
    @ObservedObject var optimize = OptimizeModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            item("stethoscope", "Diagnostic") { tabs.showDiagnostic = true }
            item("dot.radiowaves.left.and.right", optimize.lowLatency ? "Wi-Fi faible latence ✓" : "Wi-Fi faible latence") {
                optimize.setLowLatency(!optimize.lowLatency)
            }
            item("wifi", "Adresse MAC et crédits Wi-Fi") { tabs.showWifi = true }
            item("doc.text.magnifyingglass", "Journaux d'Hippocampe") {
                NSWorkspace.shared.open(home.appending(path: "Library/Logs/MacChanger"))
            }
            Divider().padding(.vertical, 4)
            item("info.circle", "À propos d'Hippocampe") { NSApp.orderFrontStandardAboutPanel(nil) }
        }
        .padding(8)
        .frame(width: 250)
    }

    func item(_ symbol: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button {
            tabs.showMenu = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(faint)
                Text(title)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Wi-Fi faible latence demandé sans Wi-Fi connecté.
struct NoWifiCard: View {
    @ObservedObject var model = OptimizeModel.shared

    var body: some View {
        if model.showNoWifi {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.showNoWifi = false }
                VStack(alignment: .leading, spacing: 18) {
                    Text("WiFi à faible latence").font(.system(size: 20, weight: .bold))
                    Text("Connectez-vous au WiFi pour utiliser cet outil.").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                    Button { model.showNoWifi = false } label: {
                        Text("Fermer").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
                .frame(width: 380)
                .background(RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))
            }
        }
    }
}

// Sans la CLI Mole, Hippocampe utilise ses fonctions intégrées, plus limitées.
struct MoleMissingBanner: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Moteur Mole absent : fonctions de base seulement").font(.system(size: 12))
                    Button("Installer") {
                        _ = run("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to do script \"brew install mole\"",
                                                       "-e", "tell application \"Terminal\" to activate"])
                    }
                    .buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.4)))
                .help("Installe la CLI open source Mole avec Homebrew, puis relancez Hippocampe.")
            }
            Spacer()
        }
        .padding(.top, 34)
        .padding(.trailing, 20)
    }
}

// MARK: - Planète

struct PlanetView: NSViewRepresentable {
    let planet: Planet

    final class Coordinator: NSObject {
        var planet: Planet?
        var node: SCNNode?

        // Glisser fait tourner la planète, en plus de sa rotation lente.
        @objc func drag(_ gesture: NSPanGestureRecognizer) {
            guard let node, let view = gesture.view else { return }
            let t = gesture.translation(in: view)
            node.eulerAngles.y += t.x * 0.01
            node.eulerAngles.x -= t.y * 0.005
            gesture.setTranslation(.zero, in: view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.addGestureRecognizer(NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:))))
        show(planet, in: view, context.coordinator)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if context.coordinator.planet != planet { show(planet, in: view, context.coordinator) }
    }

    private func show(_ planet: Planet, in view: SCNView, _ coordinator: Coordinator) {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear

        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 96
        let material = SCNMaterial()
        material.diffuse.contents = Bundle.main.url(forResource: planet.rawValue, withExtension: "jpg", subdirectory: "planets")
            .flatMap(NSImage.init(contentsOf:))
        material.lightingModel = planet == .sun ? .constant : .lambert
        sphere.firstMaterial = material

        let spin = SCNNode(geometry: sphere)
        spin.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: planet.period)))
        let axis = SCNNode()
        axis.eulerAngles.z = planet.tilt
        axis.addChildNode(spin)
        scene.rootNode.addChildNode(axis)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38
        camera.position = SCNVector3(0, 0, 3.2)
        scene.rootNode.addChildNode(camera)

        // Lumière venue de la gauche, un peu de face : un liseré d'ombre sur le bord droit.
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1100
        sun.eulerAngles = SCNVector3(-0.2, -0.45, 0)
        scene.rootNode.addChildNode(sun)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 160
        scene.rootNode.addChildNode(ambient)

        view.scene = scene
        view.pointOfView = camera
        view.isPlaying = true
        coordinator.planet = planet
        coordinator.node = axis
    }
}

// Ciel étoilé fixe, tiré d'une graine pour rester identique d'un lancement à l'autre.
struct Starfield: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / Double(1 << 53)
            }
            for _ in 0..<180 {
                let p = CGPoint(x: next() * size.width, y: next() * size.height)
                let r = 0.4 + next() * 1.0
                context.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: r, height: r)), with: .color(.white.opacity(0.2 + next() * 0.6)))
            }
        }
    }
}

// MARK: - Éléments communs

struct LandingButton: View {
    let title: String
    var busy = false
    var width: CGFloat = 236
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 20)
            .frame(minWidth: width, minHeight: 44)
            .background(Capsule().fill(.white.opacity(busy ? 0.55 : 0.96)))
            .foregroundStyle(.black)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

// Accueil d'un onglet : la planète au centre, un chiffre ou un poème, et l'action principale.
struct Landing: View {
    let tab: AppTab
    var headline: String?
    var subline: String?
    var link: String?
    var onLink: () -> Void = {}
    let button: String
    var busy = false
    var footnote: String?
    var live = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tab.planet.glow.opacity(0.22), .clear], center: .center, startRadius: 100, endRadius: 200))
                    .frame(width: 400, height: 400)
                PlanetView(planet: tab.planet).frame(width: 260, height: 260)
            }
            .frame(height: 300)
            .padding(.bottom, 40)
            if let headline {
                Text(headline)
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                    .padding(.bottom, 8)
                HStack(spacing: 5) {
                    if let subline { Text(subline).foregroundStyle(faint) }
                    if let link {
                        if subline != nil { Text("·").foregroundStyle(.white.opacity(0.3)) }
                        Button(link, action: onLink).buttonStyle(.plain).foregroundStyle(accent).fontWeight(.semibold)
                    }
                }
                .font(.system(size: 13))
                .lineLimit(1)
                .padding(.bottom, 12)
            } else {
                Text(tab.tagline)
                    .font(.system(size: 16, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.bottom, 22)
            }
            LandingButton(title: button, busy: busy, action: action)
            Group {
                if live {
                    LiveLine()
                } else {
                    Text(footnote ?? " ").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }
}

// Ce que l'app fait en ce moment (dossier parcouru, étape en cours), rafraîchi en continu.
struct LiveLine: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { _ in
            let text = LiveStatus.shared.get()
            Text(text.hasPrefix("/") ? tildePath(URL(fileURLWithPath: text)) : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// En-tête d'une page de détail : titre, résumé et retour.
struct DetailHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(faint).lineLimit(1)
            }
            Spacer()
            trailing
            Button(action: back) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("Retour")
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.06)))
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08)))
    }
}

// Case à cocher : vide, partielle (−) ou pleine ; verrouillée pour un élément en cours d'utilisation.
struct CheckBox: View {
    var state: Int
    var locked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(locked ? Color.white.opacity(0.12) : state > 0 ? accent : .clear)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(state > 0 && !locked ? 0 : 0.35), lineWidth: 1.2)
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(faint)
                } else if state == 2 {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
                } else if state == 1 {
                    Capsule().fill(.black).frame(width: 8, height: 2)
                }
            }
            .frame(width: 16, height: 16)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
    }
}

// Courbe d'historique, remplie en dégradé.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var ceiling: Double?

    var body: some View {
        GeometryReader { g in
            let points = Self.points(values, ceiling: ceiling, in: g.size)
            ZStack {
                Self.area(points, height: g.size.height)
                    .fill(LinearGradient(colors: [color.opacity(0.3), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { $0.addLines(points) }.stroke(color, lineWidth: 1.5)
            }
        }
    }

    static func points(_ values: [Double], ceiling: Double?, in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)] }
        let top = max(ceiling ?? (values.max() ?? 1), 1e-9)
        return values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: size.height * (1 - CGFloat(min(v, top) / top)))
        }
    }

    static func area(_ points: [CGPoint], height: CGFloat) -> Path {
        Path { p in
            guard let first = points.first, let last = points.last else { return }
            p.move(to: CGPoint(x: first.x, y: height))
            p.addLines(points)
            p.addLine(to: CGPoint(x: last.x, y: height))
            p.closeSubpath()
        }
    }
}

// Barres d'historique, la plus récente à droite.
struct BarHistory: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let shown = Array(values.suffix(20))
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(0.75))
                        .frame(height: max(2, g.size.height * min(1, v)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct Meter: View {
    let fraction: Double
    var color: Color = accent

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule().fill(color).frame(width: g.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
    }
}

// « 77,3 Ko » → (« 77,3 », « Ko ») pour afficher l'unité en petit.
func splitUnit(_ text: String) -> (String, String) {
    let parts = text.components(separatedBy: .whitespaces)
    guard parts.count >= 2 else { return (text, "") }
    return (parts.dropLast().joined(separator: " "), parts.last ?? "")
}

struct BigValue: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: 30, weight: .bold)).monospacedDigit().lineLimit(1)
            Text(unit).font(.system(size: 14, weight: .medium)).foregroundStyle(faint).lineLimit(1)
        }
    }
}

// MARK: - Wi-Fi

// Changement d'adresse MAC et crédits du train, ouverts depuis le menu du logo.
struct WifiOverlay: View {
    @ObservedObject var tabs: TabSelection
    let panel: NSView

    struct Host: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { tabs.showWifi = false }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Adresse MAC Wi-Fi").font(.system(size: 22, weight: .bold))
                        Text("Changement d'adresse et surveillance des crédits du train").font(.system(size: 12)).foregroundStyle(faint)
                    }
                    Spacer()
                    Button { tabs.showWifi = false } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                            .background(Circle().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
                Card { Host(view: panel).fixedSize() }
                Text("Les crédits restants s'affichent aussi dans la barre des menus. Fermer la fenêtre laisse l'app tourner.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(24)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08)))
            .shadow(radius: 30)
        }
    }
}

// MARK: - Nettoyage

struct CleanTab: View {
    @ObservedObject var model = CleanModel.shared
    @EnvironmentObject var tabs: TabSelection

    var body: some View {
        if tabs.detail.contains(.clean) {
            CleanReview(model: model, back: { tabs.close(.clean) })
        } else if !model.scanned {
            Landing(tab: .clean, button: model.scanning ? "Recherche…" : "Rechercher", busy: model.scanning, live: model.scanning) { model.scan() }
        } else {
            Landing(tab: .clean,
                    headline: model.lastFreed.map { "\(formatBytes($0)) libérés" } ?? "\(formatBytes(model.total)) trouvés",
                    subline: "\(formatBytes(model.selectedSize)) à nettoyer",
                    link: model.scanning ? nil : "Rechercher à nouveau", onLink: { model.scan() },
                    button: "Examiner les résultats", busy: model.scanning || model.cleaning,
                    footnote: model.message.isEmpty ? nil : model.message, live: model.scanning || model.cleaning) { tabs.open(.clean) }
        }
    }
}

struct CleanReview: View {
    @ObservedObject var model: CleanModel
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: model.cleaning ? "Nettoyage…" : "Prêt à nettoyer",
                         subtitle: "\(formatBytes(model.selectedSize)) à nettoyer · \(formatBytes(diskSpace().free + model.selectedSize)) libres ensuite"
                             + (model.fromMole ? " · plan établi par Mole" : ""),
                         back: back) {
                Button { model.scan() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(faint)
                .disabled(model.scanning)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($model.groups) { $group in CleanGroupCard(group: $group, model: model) }
                }
            }
            Divider().opacity(0.3)
            CleanFooter(model: model)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .alert("Supprimer \(formatBytes(model.selectedSize)) ?", isPresented: $model.confirming) {
            Button("Supprimer", role: .destructive) { model.clean() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les éléments cochés sont supprimés définitivement. Les dossiers système protégés et les caches des apps ouvertes ne sont jamais touchés.")
        }
    }
}

struct CleanFooter: View {
    @ObservedObject var model: CleanModel

    var body: some View {
        HStack(spacing: 6) {
            Text("\(model.selectedCount) sélectionnés").foregroundStyle(faint)
            Button("Tout") { model.select(all: true) }.buttonStyle(.plain).foregroundStyle(accent)
            Text("·").foregroundStyle(.white.opacity(0.3))
            Button("Aucun") { model.select(all: false) }.buttonStyle(.plain).foregroundStyle(accent)
            Text("·").foregroundStyle(.white.opacity(0.3))
            Button("Recommandés") { model.select() }.buttonStyle(.plain).foregroundStyle(accent)
            if !model.kept.isEmpty {
                Text("·").foregroundStyle(.white.opacity(0.3))
                Image(systemName: "shield.fill").foregroundStyle(positive)
                Text("\(model.kept.count) protégés").foregroundStyle(faint)
                Button("Tout libérer") { model.clearKept() }.buttonStyle(.plain).foregroundStyle(accent)
            }
            Spacer()
            LandingButton(title: "Supprimer \(formatBytes(model.selectedSize)) définitivement", busy: model.cleaning || model.scanning) {
                model.confirming = true
            }
        }
        .font(.system(size: 13, weight: .medium))
    }
}

struct CleanGroupCard: View {
    @Binding var group: CleanGroup
    let model: CleanModel

    var checkState: Int { group.allSelected ? 2 : group.noneSelected ? 0 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                CheckBox(state: checkState) { model.toggleGroup(group.id) }
              HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title).font(.system(size: 14, weight: .semibold))
                    Text(group.readable ? group.detail : "Accès complet au disque requis pour la mesurer ; cochée, le Finder la videra")
                        .font(.system(size: 12)).foregroundStyle(faint)
                }
                Spacer()
                if !group.scanned {
                    ProgressView().controlSize(.small)
                } else if group.readable {
                    Text("\(formatBytes(group.selectedSize)) / \(formatBytes(group.total))")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(accent)
                }
                Image(systemName: group.expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(faint)
                    .frame(width: 20)
              }
              .contentShape(Rectangle())
              .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { group.expanded.toggle() } }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if group.expanded {
                LazyVStack(spacing: 0) {
                    ForEach($group.items) { $item in CleanItemRow(item: $item) { model.toggleKept(item.url) } }
                }
                .padding(.leading, 30)
                .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.06)))
    }
}

struct CleanItemRow: View {
    @Binding var item: CleanItem
    let toggleKept: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(state: item.selected ? 2 : 0, locked: item.inUse || item.kept || item.reviewOnly) { item.selected.toggle() }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.reviewOnly && !item.note.isEmpty ? item.note : item.url.lastPathComponent).font(.system(size: 12.5))
                    if item.reviewOnly {
                        Text("À gérer").font(.system(size: 11)).foregroundStyle(faint)
                            .help("Mole signale cet espace sans le nettoyer : il contient des données utiles (machines virtuelles, émulateurs, modèles…). Libérez-le depuis l'app concernée.")
                    }
                    if item.inUse {
                        Text("App ouverte").font(.system(size: 11)).foregroundStyle(faint)
                            .help("Ce cache appartient à une app ouverte : il est verrouillé pour ne pas la perturber. Quittez-la puis relancez l'analyse.")
                    }
                    if item.kept {
                        Text("Toujours gardé").font(.system(size: 11)).foregroundStyle(positive)
                            .help("Protégé par le bouclier : jamais supprimé. Cliquez sur le bouclier pour le libérer.")
                    }
                    if !item.recommended && !item.inUse && !item.kept && !item.reviewOnly {
                        Text("À vérifier").font(.system(size: 11)).foregroundStyle(.orange.opacity(0.85))
                            .help(item.note.isEmpty ? "Pas coché d'office : vérifiez son contenu avant de le supprimer." : item.note)
                    }
                }
                Text(tildePath(item.url)).font(.system(size: 11, design: .monospaced)).foregroundStyle(faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(formatBytes(item.size)).font(.system(size: 12)).monospacedDigit().foregroundStyle(faint)
            if !item.reviewOnly { Button(action: toggleKept) {
                Image(systemName: item.kept ? "shield.fill" : "shield").font(.system(size: 12))
                    .foregroundStyle(item.kept ? positive : faint)
            }
            .buttonStyle(.plain)
            .help(item.kept ? "Ne plus protéger" : "Toujours garder : jamais supprimé par le nettoyage") }
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(faint)
            }
            .buttonStyle(.plain)
            .help("Afficher dans le Finder")
        }
        .padding(.vertical, 6)
        .padding(.trailing, 16)
    }
}

// MARK: - Apps

struct AppsTab: View {
    @ObservedObject var model = UninstallModel.shared

    var title: String {
        model.selectedApps.count == 1 ? model.selectedApps[0].name : "\(model.selectedApps.count) apps"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppsToolbar(model: model)
            switch model.section {
            case 0: AppsList(model: model)
            case 1: UpdatesList(apps: model)
            default: StartupView()
            }
        }
        .padding(.horizontal, 24)
        .onAppear { if !model.loaded { model.load() } }
        .alert("Désinstaller \(title) ?", isPresented: $model.confirming) {
            Button("Mettre à la Corbeille", role: .destructive) { model.uninstall() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les apps ouvertes sont quittées, puis elles et leurs restes dans ~/Library vont à la Corbeille, d'où vous pouvez les récupérer.")
        }
    }
}

struct AppsToolbar: View {
    @ObservedObject var model: UninstallModel
    @ObservedObject var updates = UpdatesModel.shared
    @ObservedObject var startup = StartupModel.shared

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                segment("Désinstaller", 0)
                segment(updates.outdatedCount > 0 ? "Mises à jour · \(updates.outdatedCount)" : "Mises à jour", 1)
                segment("Démarrage", 2)
            }
            .padding(3)
            .background(Capsule().fill(.white.opacity(0.07)))
            Button {
                switch model.section {
                case 0: model.load()
                case 1: updates.check(model.apps)
                default: startup.load()
                }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(faint)
            Spacer()
            if model.section < 2 {
                ForEach(AppSort.allCases, id: \.self) { s in sortButton(s) }
                if model.section == 1 {
                    Menu {
                        ForEach(UpdateFilter.allCases, id: \.self) { f in
                            Button((updates.filter == f ? "✓ " : "") + f.rawValue) { updates.filter = f }
                        }
                    } label: {
                        Label(updates.filter == .all ? "Filtrer" : updates.filter.rawValue, systemImage: "line.3.horizontal.decrease")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                TextField("Rechercher", text: $model.filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
        }
    }

    func sortButton(_ s: AppSort) -> some View {
        Button { model.setSort(s) } label: {
            Text(s.rawValue + (model.sort == s ? (model.ascending ? " ↑" : " ↓") : ""))
                .font(.system(size: 13, weight: model.sort == s ? .semibold : .regular))
                .foregroundStyle(model.sort == s ? .white : faint)
        }
        .buttonStyle(.plain)
    }

    func segment(_ title: String, _ index: Int) -> some View {
        Button {
            model.section = index
            if index == 1 && !updates.checked && !updates.checking && model.loaded { updates.check(model.apps) }
            if index == 2 && startup.logins.isEmpty && startup.background.isEmpty { startup.load() }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(model.section == index ? .white : faint)
                .background(Capsule().fill(model.section == index ? .white.opacity(0.14) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct AppsList: View {
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Apps installées").font(.system(size: 13, weight: .semibold))
                Text(model.loaded ? "\(model.apps.count) apps · \(formatBytes(model.totalSize))" : "Inventaire…")
                    .font(.system(size: 13)).foregroundStyle(faint)
            }
            .padding(.leading, 14)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.visibleApps) { app in AppRow(app: app, model: model) }
                }
            }
            if !model.selection.isEmpty || !model.message.isEmpty { SelectionBar(model: model) }
        }
        .padding(.bottom, model.selection.isEmpty && model.message.isEmpty ? 16 : 0)
    }
}

struct AppRow: View {
    let app: AppEntry
    @ObservedObject var model: UninstallModel

    var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty }
    var selected: Bool { model.selection.contains(app.url) }
    var expanded: Bool { model.expanded.contains(app.url) }
    var meta: String { [app.version, app.size.map(formatBytes) ?? "…"].filter { !$0.isEmpty }.joined(separator: " · ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // La case reste hors de la zone qui déplie la ligne : sinon le clic est intercepté.
            HStack(spacing: 14) {
              HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 5) {
                        Text(meta).foregroundStyle(faint)
                        if running {
                            Text("·").foregroundStyle(.white.opacity(0.3))
                            Text("ouverte maintenant").foregroundStyle(positive)
                        } else if let used = app.lastUsed {
                            Text("·").foregroundStyle(.white.opacity(0.3))
                            Text("ouverte " + relativeDate(used)).foregroundStyle(faint)
                        }
                    }
                    .font(.system(size: 12))
                }
                Spacer()
                if expanded {
                    Text(model.details[app.url] == nil ? "Recherche…"
                         : "Supprime \(app.size.map(formatBytes) ?? "…") · +\(formatBytes(model.leftoverSize(app)))")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8))
                }
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(faint)
              }
              .contentShape(Rectangle())
              .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { model.toggleExpanded(app) } }
                CheckBox(state: selected ? 2 : 0) { model.toggle(app) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if expanded { AppFiles(app: app, model: model) }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(expanded ? 0.06 : selected ? 0.08 : 0)))
        .contextMenu {
            Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            Button("Ouvrir") { NSWorkspace.shared.open(app.url) }
        }
    }
}

// Chaque fichier qui partira avec l'app : l'app elle-même, puis ses restes, décochables un par un.
struct AppFiles: View {
    let app: AppEntry
    @ObservedObject var model: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("À supprimer").font(.system(size: 13, weight: .semibold))
                Text(model.molePlanned.contains(app.url) ? "Plan de Mole" : "Recherche intégrée · plan de Mole en cours…")
                    .font(.system(size: 11)).foregroundStyle(faint)
            }
            .padding(.bottom, 6)
            FileLine(kind: "Application", path: app.url.path, size: app.size, checked: true, locked: true, url: app.url) {}
            if let files = model.details[app.url] {
                ForEach(files) { file in
                    FileLine(kind: file.kind, path: tildePath(file.url), size: file.size, checked: file.selected, url: file.url) {
                        model.toggleFile(app, file)
                    }
                }
                if files.isEmpty {
                    Text("Aucun reste trouvé en dehors de l'app").font(.system(size: 12)).foregroundStyle(faint).padding(.vertical, 6)
                }
            } else {
                ProgressView().controlSize(.small).padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

struct FileLine: View {
    let kind: String
    let path: String
    let size: Int64?
    let checked: Bool
    var locked = false
    let url: URL
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(state: checked ? 2 : 0) { toggle() }.disabled(locked)
            Text(kind).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(width: 150, alignment: .leading)
            Text(path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(faint)
            }
            .buttonStyle(.plain)
            .help("Afficher dans le Finder")
            Text(size.map { $0 == 0 ? "Vide" : formatBytes($0) } ?? "…")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(faint).frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}

struct SelectionBar: View {
    @ObservedObject var model: UninstallModel

    var summary: String {
        let apps = model.selectedApps
        let size = formatBytes(apps.compactMap(\.size).reduce(0, +))
        return apps.count == 1 ? "\(apps[0].name) · \(size)" : "\(apps.count) apps · \(size)"
    }

    var body: some View {
        HStack(spacing: 12) {
            if let first = model.selectedApps.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.url.path)).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(summary).font(.system(size: 13, weight: .semibold))
                        Button("Effacer la sélection") { model.selection = [] }
                            .buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 13, weight: .medium))
                    }
                    Text("Les restes dans ~/Library sont retirés avec l'app").font(.system(size: 11)).foregroundStyle(faint)
                }
            } else {
                Text(model.message).font(.system(size: 13)).foregroundStyle(faint)
            }
            Spacer()
            if !model.selection.isEmpty {
                LandingButton(title: "Désinstaller \(model.selection.count)", busy: model.working) { model.confirming = true }
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider().opacity(0.3) }
    }
}

// MARK: - Mises à jour

struct UpdatesList: View {
    @ObservedObject var apps: UninstallModel
    @ObservedObject var model = UpdatesModel.shared

    var shown: [AppUpdate] {
        model.items.filter { model.matches($0) && (apps.filter.isEmpty || $0.app.name.localizedCaseInsensitiveContains(apps.filter)) }
            .sorted { a, b in
                // D'abord les mises à jour disponibles, puis les apps à jour, puis celles qu'on ne peut pas vérifier ;
                // le tri choisi s'applique dans chaque groupe.
                let ra = rank(a), rb = rank(b)
                return ra != rb ? ra < rb : apps.before(a.app, b.app)
            }
    }

    func rank(_ u: AppUpdate) -> Int {
        if u.isOutdated && !model.isIgnored(u) { return 0 }
        if u.isCurrent || model.isIgnored(u) { return 1 }
        return 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Mises à jour").font(.system(size: 13, weight: .semibold))
                if model.checked {
                    Text("\(model.outdatedCount) disponibles · \(model.verifiedCount) apps vérifiées").font(.system(size: 13)).foregroundStyle(faint)
                }
            }
            .padding(.leading, 14)
            if model.checking {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Homebrew, App Store, flux Sparkle…").font(.system(size: 13, weight: .semibold))
                    LiveLine()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.checked {
                VStack(spacing: 12) {
                    Text("Vérifiez si vos apps ont une nouvelle version.").foregroundStyle(faint)
                    LandingButton(title: "Rechercher les mises à jour") { model.check(apps.apps) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { u in UpdateRow(update: u, model: model) }
                    }
                }
            }
            if !model.message.isEmpty {
                Text(model.message).font(.system(size: 12)).foregroundStyle(faint).padding(.vertical, 8)
            }
        }
        .padding(.bottom, 12)
    }
}

struct UpdateRow: View {
    let update: AppUpdate
    @ObservedObject var model: UpdatesModel

    var ignored: Bool { model.isIgnored(update) }
    var expanded: Bool { model.expanded.contains(update.id) }

    var actionTitle: String {
        switch update.source {
        case .homebrew: "Mettre à jour"
        case .appStore: "Ouvrir l'App Store"
        case .sparkle: "Télécharger"
        case .website: "Ouvrir l'app"
        }
    }

    var status: String {
        switch update.state {
        case .outdated: "\(update.installed) → \(update.latest ?? "?")"
        case .current: "\(update.installed) · à jour"
        case .unknown(let reason): update.installed.isEmpty ? reason : "\(update.installed) · \(reason)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: update.app.url.path)).resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(update.app.name).font(.system(size: 14, weight: .semibold))
                        Badge(text: update.source.rawValue)
                    }
                    Text(status).font(.system(size: 12))
                        .foregroundStyle(update.isOutdated && !ignored ? Color.orange.opacity(0.9) : update.isCurrent ? positive : faint)
                        .lineLimit(1)
                }
                Spacer()
                if update.notes != nil || update.notesURL != nil {
                    Button {
                        if expanded { model.expanded.remove(update.id) } else { model.expanded.insert(update.id) }
                    } label: {
                        Text(expanded ? "Masquer les notes" : "Notes de version").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(accent)
                }
                if update.isOutdated && ignored {
                    Text("Ignorée").font(.system(size: 12)).foregroundStyle(faint)
                    Button("Ne plus ignorer") { model.unignore(update) }.buttonStyle(.plain).foregroundStyle(accent)
                        .font(.system(size: 12, weight: .medium))
                } else if update.isOutdated {
                    Button("Ignorer") { model.ignore(update) }.buttonStyle(.plain).foregroundStyle(faint)
                        .font(.system(size: 12.5, weight: .medium))
                        .help("Ne plus proposer la version \(update.latest ?? "")")
                    LandingButton(title: actionTitle, busy: model.working.contains(update.id), width: 120) { model.update(update) }
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let notes = update.notes {
                        Text(notes).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).textSelection(.enabled)
                    }
                    if let link = update.notesURL {
                        Button("Notes complètes sur le site") { NSWorkspace.shared.open(link) }.buttonStyle(.plain).foregroundStyle(accent)
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .padding(.leading, 52)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Démarrage

struct StartupView: View {
    @ObservedObject var model = StartupModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.loading { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "Éléments de connexion", count: model.logins.count)
                    ForEach(model.logins) { item in
                        StartupLine(icon: NSWorkspace.shared.icon(forFile: item.path), title: item.name,
                                    subtitle: "S'ouvre à la connexion · " + tildePath(URL(fileURLWithPath: item.path)),
                                    file: URL(fileURLWithPath: item.path), enabled: item.enabled, editable: true) { model.setLogin(item, $0) }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle(title: "Autorisés en arrière-plan", count: model.background.count)
                    ForEach(model.background) { item in
                        StartupLine(icon: item.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }, title: item.label,
                                    subtitle: item.scopeText + (item.program.isEmpty ? "" : " · " + item.program),
                                    file: item.url, enabled: item.enabled, editable: item.editable) { model.setBackground(item, $0) }
                    }
                }
                Text(model.message.isEmpty
                     ? "Couper un agent l'empêche de se relancer au démarrage. Les services système passent par l'outil administrateur d'Hippocampe."
                     : model.message)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
    }
}

struct StartupLine: View {
    let icon: NSImage?
    let title: String
    let subtitle: String
    let file: URL
    let enabled: Bool
    let editable: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape.2").font(.system(size: 18)).foregroundStyle(faint)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                Image(systemName: "folder").foregroundStyle(faint)
            }
            .buttonStyle(.plain)
            .help("Afficher dans le Finder")
            Toggle("", isOn: Binding(get: { enabled }, set: { toggle($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(!editable)
                .help(editable ? (enabled ? "Ne plus lancer au démarrage" : "Lancer de nouveau au démarrage")
                               : "Déclaré par l'app elle-même : à gérer dans Réglages Système › Général › Ouverture")
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Optimisation

struct OptimizeTab: View {
    @ObservedObject var model = OptimizeModel.shared
    @EnvironmentObject var tabs: TabSelection

    var summary: String {
        var parts = ["\(model.doneCount) optimisées", "\(model.skippedCount) ignorées"]
        if model.attentionCount > 0 { parts.append("\(model.attentionCount) à vérifier") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if tabs.detail.contains(.optimize) {
            OptimizeDetails(model: model, summary: summary, back: { tabs.close(.optimize) })
        } else {
            Landing(tab: .optimize,
                    headline: model.finished ? "Optimisation terminée" : nil,
                    subline: model.finished ? summary : nil,
                    link: model.finished ? "Voir le détail" : nil, onLink: { tabs.open(.optimize) },
                    button: model.running ? "Optimisation…" : model.finished ? "Optimiser à nouveau" : "Optimiser",
                    busy: model.running,
                    footnote: model.finished ? nil : "Chaque étape vérifie d'abord si elle est utile · détail et actions manuelles ensuite",
                    live: model.running) {
                model.runAll()
            }
        }
    }
}

struct OptimizeDetails: View {
    @ObservedObject var model: OptimizeModel
    let summary: String
    let back: () -> Void

    func steps(_ match: (OptimizeStep, StepOutcome?) -> Bool) -> [OptimizeStep] {
        model.steps.filter { match($0, model.outcomes[$0.id]) }
    }

    var body: some View {
        let corrections = steps { step, _ in step.section == "Corrections" }
        let done = steps { step, o in if step.section != "Corrections", case .done = o { true } else { false } }
        let attention = steps { step, o in if step.section != "Corrections", case .attention = o { true } else { false } }
        let failed = steps { step, o in if step.section != "Corrections", case .failed = o { true } else { false } }
        let skipped = steps { step, o in if step.section != "Corrections", case .skipped = o { true } else { false } }
        let pending = steps { step, o in step.section != "Corrections" && o == nil }

        VStack(alignment: .leading, spacing: 16) {
            DetailHeader(title: "Détails d'optimisation", subtitle: model.outcomes.isEmpty ? "Pas encore lancée" : summary, back: back) {
                LandingButton(title: model.running ? "En cours…" : "Optimiser", busy: model.running, width: 110) { model.runAll() }
            }
            if !model.moleNote.isEmpty {
                Text(model.moleNote).font(.system(size: 12)).foregroundStyle(.orange.opacity(0.85))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !model.moleSections.isEmpty {
                        MoleOptimizeList(model: model)
                        ManualSection(model: model)
                    } else {
                    StepSection(title: "Corrections", steps: corrections, model: model)
                    if !done.isEmpty { StepSection(title: "Terminées", steps: done, model: model, grouped: true) }
                    if !attention.isEmpty { StepSection(title: "À vérifier", steps: attention, model: model) }
                    if !failed.isEmpty { StepSection(title: "Échecs", steps: failed, model: model) }
                    if !pending.isEmpty { StepSection(title: model.running ? "En attente" : "Étapes", steps: pending, model: model) }
                    if !skipped.isEmpty { StepSection(title: "Ignorées", steps: skipped, model: model) }
                    ManualSection(model: model)
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
    }
}

// Résultat de « mo optimize » : faites, à vérifier, puis rien à faire, section par section.
struct MoleOptimizeList: View {
    @ObservedObject var model: OptimizeModel

    func rows(_ outcome: Int) -> [(String, MoleOptimizeLine)] {
        model.moleSections.flatMap { section in section.lines.filter { model.moleOutcome($0) == outcome }.map { (section.title, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach([(0, "Terminées"), (2, "À vérifier"), (1, "Rien à faire")], id: \.0) { outcome, title in
                let lines = rows(outcome)
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(title: title, count: lines.count)
                        ForEach(lines, id: \.1.id) { section, line in
                            HStack(spacing: 12) {
                                Group {
                                    switch outcome {
                                    case 0: Image(systemName: "checkmark").foregroundStyle(positive)
                                    case 2: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                    default: Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(faint)
                                    }
                                }
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 16)
                                Text(section).font(.system(size: 13.5))
                                Spacer()
                                Text(line.text).font(.system(size: 12)).foregroundStyle(faint).lineLimit(1).truncationMode(.tail)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
        }
    }
}

struct SectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                Spacer()
                Text("\(count)").font(.system(size: 12)).foregroundStyle(faint)
            }
            Divider().opacity(0.3)
        }
    }
}

struct StepSection: View {
    let title: String
    let steps: [OptimizeStep]
    @ObservedObject var model: OptimizeModel
    var grouped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: title, count: steps.count)
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                if grouped && (i == 0 || steps[i - 1].section != step.section) {
                    Text(step.section).font(.system(size: 13, weight: .semibold)).foregroundStyle(Planet.mercury.glow)
                        .padding(.top, 8)
                }
                StepRow(step: step, outcome: model.outcomes[step.id], current: model.current == step.title)
            }
        }
    }
}

struct StepRow: View {
    let step: OptimizeStep
    let outcome: StepOutcome?
    let current: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if current {
                    ProgressView().controlSize(.mini)
                } else {
                    switch outcome {
                    case .done: Image(systemName: "checkmark").foregroundStyle(positive)
                    case .attention: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    case .failed: Image(systemName: "xmark").foregroundStyle(.red.opacity(0.8))
                    default: Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(faint)
                    }
                }
            }
            .font(.system(size: 11, weight: .bold))
            .frame(width: 16)
            Text(step.title).font(.system(size: 13.5))
            Spacer()
            Text(current ? "En cours…" : outcome?.text ?? "").font(.system(size: 12)).foregroundStyle(faint).lineLimit(1)
        }
        .padding(.vertical, 5)
    }
}

struct ManualSection: View {
    @ObservedObject var model: OptimizeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Actions manuelles", count: model.manual.count + 1)
            LowLatencyRow(model: model)
            ForEach(model.manual) { task in
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(accent).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).font(.system(size: 13.5))
                        Text(model.manualResults[task.id] ?? task.detail).font(.system(size: 12)).foregroundStyle(faint)
                    }
                    Spacer()
                    LandingButton(title: "Lancer", busy: model.manualResults[task.id] == "…", width: 90) { model.perform(task) }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct LowLatencyRow: View {
    @ObservedObject var model: OptimizeModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(accent).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wi-Fi faible latence").font(.system(size: 13.5))
                Text(model.lowLatencyMessage.isEmpty
                     ? "Met AirDrop, AirPlay et Sidecar en pause pour un ping stable (jeux, visio)"
                     : model.lowLatencyMessage)
                    .font(.system(size: 12)).foregroundStyle(faint)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.lowLatency }, set: { model.setLowLatency($0) }))
                .toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Analyse

struct AnalyzeTab: View {
    @ObservedObject var model = AnalyzeModel.shared
    @EnvironmentObject var tabs: TabSelection

    var scanning: Bool { model.started && model.pending > 0 }

    var body: some View {
        if tabs.detail.contains(.analyze) {
            AnalyzeMap(model: model, back: { tabs.close(.analyze) })
        } else {
            // La carte s'ouvre une fois les tailles calculées ; en attendant, on suit le parcours en direct.
            Landing(tab: .analyze,
                    headline: model.started && model.pending == 0 ? "\(formatBytes(model.total)) cartographiés" : nil,
                    subline: model.started && model.pending == 0 ? "\(model.items.count) éléments dans le dossier personnel" : nil,
                    link: model.started && model.pending == 0 ? "Recommencer" : nil, onLink: { model.open(home) },
                    button: scanning ? "Cartographie…" : model.started ? "Afficher la carte" : "Cartographier le dossier personnel",
                    busy: scanning,
                    footnote: scanning ? nil : "Ou choisissez un autre dossier dans la carte", live: scanning) {
                if model.started { tabs.open(.analyze) } else { model.open(home) }
            }
            .onChange(of: model.pending) { pending in
                if pending == 0 && model.started { tabs.open(.analyze) }
            }
        }
    }
}

struct AnalyzeMap: View {
    @ObservedObject var model: AnalyzeModel
    let back: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            AnalyzeSidebar(model: model).frame(width: 230)
            VStack(alignment: .leading, spacing: 10) {
                AnalyzeTopBar(model: model, back: back)
                Group {
                    if model.showDuplicates {
                        DuplicatesView(model: model)
                    } else {
                        TreemapView(model: model)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.12)))
                Text(model.message.isEmpty ? "Double-clic pour ouvrir un dossier · clic droit pour le Finder ou la Corbeille" : model.message)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .alert("Mettre « \(model.toTrash?.url.lastPathComponent ?? "") » à la Corbeille ?",
               isPresented: Binding(get: { model.toTrash != nil }, set: { if !$0 { model.toTrash = nil } })) {
            Button("Mettre à la Corbeille", role: .destructive) { if let item = model.toTrash { model.trash(item) } }
            Button("Annuler", role: .cancel) {}
        }
    }
}

struct AnalyzeTopBar: View {
    @ObservedObject var model: AnalyzeModel
    let back: () -> Void

    var body: some View {
        let space = diskSpace()
        HStack(spacing: 10) {
            Button { model.up() } label: { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(faint).disabled(model.current.path == "/")
            Text(model.current == home ? "Dossier personnel" : tildePath(model.current))
                .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.head)
            Spacer()
            if model.pending > 0 {
                ProgressView().controlSize(.small)
                Text("\(model.pending) en cours de calcul").font(.system(size: 11)).foregroundStyle(faint)
            }
            Circle().fill(Planet.jupiter.glow).frame(width: 7, height: 7)
            Text("Utilisé \(formatBytes(space.total - space.free)) / \(formatBytes(space.total))")
                .font(.system(size: 11)).foregroundStyle(faint)
            Button { model.choose() } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.plain).foregroundStyle(faint).help("Choisir un dossier")
            Button(action: back) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(faint).help("Retour")
        }
    }
}

struct AnalyzeSidebar: View {
    @ObservedObject var model: AnalyzeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                PlanetView(planet: .jupiter).frame(width: 90, height: 90)
                Text("\(model.items.count) éléments · \(formatBytes(model.total))")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                tab("Ce dossier", 0)
                tab("Gros fichiers", 1)
                tab("Doublons", 2)
            }
            .padding(.leading, 6)
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.showDuplicates {
                        DuplicateSidebar(model: model)
                    } else if model.showLarge {
                        if model.scanningLarge { ProgressView().controlSize(.small).padding() }
                        ForEach(model.largeFiles) { item in
                            SidebarRow(item: item, model: model,
                                       detail: "\(formatBytes(item.size ?? 0)) · \(tildePath(item.url.deletingLastPathComponent()))")
                        }
                    } else {
                        ForEach(model.items) { item in SidebarRow(item: item, model: model, detail: share(item)) }
                    }
                }
            }
        }
    }

    func share(_ item: DiskItem) -> String {
        guard let size = item.size else { return "Calcul…" }
        let percent = model.total > 0 ? Int(Double(size) * 100 / Double(model.total)) : 0
        return "\(formatBytes(size)) · \(percent) %"
    }

    var mode: Int { model.showDuplicates ? 2 : model.showLarge ? 1 : 0 }

    func tab(_ title: String, _ index: Int) -> some View {
        Button {
            model.showLarge = index == 1
            model.showDuplicates = index == 2
            if index == 1 && model.largeFiles.isEmpty && !model.scanningLarge { model.findLarge() }
            if index == 2 && !model.duplicatesDone && !model.scanningDuplicates { model.findDuplicatesHere() }
        } label: {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(mode == index ? .white : faint)
        }
        .buttonStyle(.plain)
    }
}

struct DuplicateSidebar: View {
    @ObservedObject var model: AnalyzeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.scanningDuplicates {
                ProgressView().controlSize(.small)
                Text("Comparaison des fichiers de même taille, puis de leur contenu…")
                    .font(.system(size: 11.5)).foregroundStyle(faint)
            } else if model.duplicatesDone {
                Text("\(model.duplicates.count) groupes de doublons").font(.system(size: 13, weight: .semibold))
                Text("\(formatBytes(model.duplicateSavings)) récupérables").font(.system(size: 12)).foregroundStyle(positive)
                Text("Fichiers d'au moins 1 Mo au contenu strictement identique (SHA-256), quel que soit leur nom. ~/Library, les dossiers cachés et l'intérieur des apps sont ignorés.")
                    .font(.system(size: 11)).foregroundStyle(faint)
                Button("Relancer la recherche") { model.findDuplicatesHere() }.buttonStyle(.plain).foregroundStyle(accent)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}

// Groupes de fichiers identiques : le plus ancien est gardé, les copies cochées partent à la Corbeille.
struct DuplicatesView: View {
    @ObservedObject var model: AnalyzeModel

    var body: some View {
        VStack(spacing: 0) {
            if model.scanningDuplicates {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Recherche des doublons dans \(tildePath(model.current))").font(.system(size: 13, weight: .semibold))
                    LiveLine()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if model.duplicates.isEmpty {
                Text(model.duplicatesDone ? "Aucun doublon trouvé ici." : "Choisissez « Doublons » pour lancer la recherche.")
                    .foregroundStyle(faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach($model.duplicates) { $group in DuplicateGroupCard(group: $group) }
                    }
                    .padding(10)
                }
                HStack {
                    Text("\(model.duplicates.flatMap(\.files).filter(\.remove).count) copies cochées").foregroundStyle(faint)
                    Spacer()
                    LandingButton(title: "Mettre \(formatBytes(model.duplicateSavings)) à la Corbeille") { model.trashDuplicates() }
                }
                .font(.system(size: 13, weight: .medium))
                .padding(10)
            }
        }
    }
}

struct DuplicateGroupCard: View {
    @Binding var group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.on.doc").foregroundStyle(accent)
                Text(group.files.first?.url.lastPathComponent ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(group.files.count) exemplaires · \(formatBytes(group.size)) chacun").font(.system(size: 12)).foregroundStyle(faint)
                Spacer()
                if group.cloned {
                    Text("Clone APFS").font(.system(size: 11)).foregroundStyle(.orange.opacity(0.85))
                        .help("Certaines copies partagent l'espace disque de l'original (clones APFS) : les supprimer libère peu de place.")
                }
                Text("\(formatBytes(group.reclaimable)) récupérables").font(.system(size: 12, weight: .semibold)).foregroundStyle(positive)
            }
            ForEach($group.files) { $file in
                HStack(spacing: 10) {
                    CheckBox(state: file.remove ? 2 : 0) { file.remove.toggle() }
                    Text(file.remove ? "Supprimer" : "Garder").font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(file.remove ? .orange.opacity(0.9) : positive).frame(width: 64, alignment: .leading)
                    Text(tildePath(file.url)).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(file.modified.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundStyle(faint)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            if group.files.allSatisfy(\.remove) {
                Text("Tous les exemplaires sont cochés : aucun ne serait gardé.").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
    }
}

struct SidebarRow: View {
    let item: DiskItem
    @ObservedObject var model: AnalyzeModel
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(faint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if item.isDirectory { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(faint) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if item.isDirectory { model.open(item.url) } }
        .contextMenu { ItemMenu(item: item, model: model) }
    }
}

struct ItemMenu: View {
    let item: DiskItem
    let model: AnalyzeModel

    var body: some View {
        Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Mettre à la Corbeille…") { model.toTrash = item }
    }
}

struct TreemapView: View {
    @ObservedObject var model: AnalyzeModel

    static let palette: [Color] = [
        Color(red: 0.60, green: 0.46, blue: 0.40), Color(red: 0.66, green: 0.52, blue: 0.32),
        Color(red: 0.70, green: 0.42, blue: 0.30), Color(red: 0.55, green: 0.47, blue: 0.40),
        Color(red: 0.50, green: 0.40, blue: 0.34), Color(red: 0.63, green: 0.55, blue: 0.43),
    ]

    var body: some View {
        GeometryReader { g in
            let source = model.showLarge ? model.largeFiles : model.items
            let shown = Array(source.filter { ($0.size ?? 0) > 0 }.prefix(40))
            let rects = treemap(shown.map { Double($0.size ?? 0) }, in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    TreemapTile(item: item, rect: i < rects.count ? rects[i] : .zero,
                                color: Self.palette[i % Self.palette.count], model: model)
                }
            }
        }
    }
}

struct TreemapTile: View {
    let item: DiskItem
    let rect: CGRect
    let color: Color
    let model: AnalyzeModel

    var body: some View {
        let w = max(0, rect.width - 4), h = max(0, rect.height - 4)
        RoundedRectangle(cornerRadius: 7)
            .fill(color)
            .overlay {
                if w > 70 && h > 36 {
                    VStack(spacing: 2) {
                        Label(item.url.lastPathComponent, systemImage: item.isDirectory ? "folder" : "doc")
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(item.size.map(formatBytes) ?? "").font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(6)
                }
            }
            .frame(width: w, height: h)
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture(count: 2) { if item.isDirectory { model.open(item.url) } }
            .contextMenu { ItemMenu(item: item, model: model) }
            .help("\(item.url.lastPathComponent) · \(item.size.map(formatBytes) ?? "")")
    }
}

// MARK: - État

struct StatusTab: View {
    @ObservedObject var model = StatusModel.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    HealthCard(model: model)
                    CPUCard(model: model)
                    MemoryCard(model: model)
                    NetworkCard(model: model)
                    if let battery = model.battery { BatteryCard(battery: battery) } else { SystemCard(model: model) }
                    DiskCard(model: model)
                    ThermalCard(model: model)
                    ProcessCountCard(model: model)
                }
                ProcessTable(model: model)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

struct StatCard<Graph: View>: View {
    let symbol: String
    let title: String
    var badge: String?
    let value: String
    let unit: String
    let footer: String
    var footerRight: String?
    @ViewBuilder var graph: Graph

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11))
                    Text(title).font(.system(size: 11, weight: .bold)).tracking(1)
                    Spacer()
                    if let badge { Badge(text: badge) }
                }
                .foregroundStyle(faint)
                BigValue(value: value, unit: unit)
                graph.frame(height: 34)
                HStack {
                    Text(footer).lineLimit(1)
                    Spacer()
                    if let footerRight { Text(footerRight).foregroundStyle(.white.opacity(0.8)) }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(faint)
            }
        }
    }
}

struct HealthCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "heart.text.square").font(.system(size: 11))
                    Text("SANTÉ").font(.system(size: 11, weight: .bold)).tracking(1)
                    Spacer()
                }
                .foregroundStyle(positive)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        BigValue(value: "\(model.score)", unit: model.verdict)
                        Text(model.factors.first ?? (model.fromMole ? "Score calculé par Mole" : "Toutes les mesures sont normales"))
                            .font(.system(size: 11.5)).foregroundStyle(faint).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    PlanetView(planet: .sun).frame(width: 54, height: 54)
                }
                .frame(height: 64)
                Text("\(model.system) · allumé depuis \(model.uptimeText)").font(.system(size: 11.5)).foregroundStyle(faint).lineLimit(1)
            }
        }
    }
}

struct CPUCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        StatCard(symbol: "cpu", title: "PROCESSEUR", badge: "\(ProcessInfo.processInfo.activeProcessorCount) cœurs",
                 value: "\(Int(model.cpu * 100))", unit: "%",
                 footer: model.cpu < 0.1 ? "Au repos" : model.cpu < 0.6 ? "Actif" : "Très sollicité",
                 footerRight: String(format: "charge %.1f", model.load)) {
            BarHistory(values: model.cpuHistory, color: positive)
        }
    }
}

struct MemoryCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        StatCard(symbol: "memorychip", title: "MÉMOIRE",
                 badge: model.pressure >= 4 ? "Pression critique" : model.pressure >= 2 ? "Pression élevée" : "Pression normale",
                 value: "\(Int(model.memoryFraction * 100))", unit: "%",
                 footer: "\(formatBytes(model.memoryUsed)) · \(formatBytes(model.swap)) de swap") {
            Sparkline(values: model.memoryHistory, color: Color(red: 0.9, green: 0.8, blue: 0.55), ceiling: 1)
        }
    }
}

struct NetworkCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        let (value, unit) = splitUnit(formatBytes(Int64(model.download)))
        StatCard(symbol: "globe", title: "RÉSEAU", value: value, unit: unit + "/s",
                 footer: "Envoi \(formatBytes(Int64(model.upload)))/s", footerRight: model.download > 1_000_000 ? "Chargé" : "Calme") {
            Sparkline(values: model.downloadHistory, color: accent)
        }
    }
}

struct BatteryCard: View {
    let battery: BatteryInfo

    var body: some View {
        StatCard(symbol: battery.charging ? "battery.100.bolt" : "battery.75", title: "BATTERIE",
                 badge: battery.health.map { "\($0) % de santé" },
                 value: "\(battery.percent)", unit: battery.charging ? "% · en charge" : "%",
                 footer: battery.cycles.map { "\($0) cycles de charge" } ?? "Batterie interne") {
            Meter(fraction: Double(battery.percent) / 100, color: battery.percent < 20 ? .orange : positive)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

struct SystemCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        StatCard(symbol: "desktopcomputer", title: "SYSTÈME", badge: model.model, value: model.uptimeText, unit: "",
                 footer: model.chip) {
            Spacer()
        }
    }
}

struct DiskCard: View {
    @ObservedObject var model: StatusModel

    var usedText: String {
        let used = model.diskTotal - model.diskFree
        let percent = model.diskTotal > 0 ? Int(Double(used) * 100 / Double(model.diskTotal)) : 0
        return "\(formatBytes(used)) utilisés · \(percent) %"
    }

    var body: some View {
        let (value, unit) = splitUnit(formatBytes(model.diskFree))
        StatCard(symbol: "internaldrive", title: "ESPACE LIBRE", badge: formatBytes(model.diskTotal), value: value, unit: unit,
                 footer: usedText) {
            Meter(fraction: model.diskTotal > 0 ? 1 - Double(model.diskFree) / Double(model.diskTotal) : 0, color: accent)
                .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

struct ThermalCard: View {
    @ObservedObject var model: StatusModel

    var level: Double {
        switch model.thermal {
        case .nominal: 0.25
        case .fair: 0.5
        case .serious: 0.75
        default: 1
        }
    }

    var body: some View {
        StatCard(symbol: "thermometer.medium", title: "TEMPÉRATURE", badge: model.chip.isEmpty ? nil : model.chip,
                 value: model.thermalText, unit: "", footer: "État thermique signalé par macOS") {
            Meter(fraction: level, color: level > 0.5 ? .orange : positive).frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

struct ProcessCountCard: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        StatCard(symbol: "square.stack.3d.up", title: "PROCESSUS", badge: model.model,
                 value: "\(model.processCount)", unit: "en cours",
                 footer: model.processes.first.map { "Le plus gourmand : \($0.name)" } ?? "") {
            Spacer()
        }
    }
}

struct ProcessTable: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack {
                    Text("NOM (\(model.processCount))").frame(maxWidth: .infinity, alignment: .leading)
                    Text("MÉM.").frame(width: 90, alignment: .trailing)
                    Text("% CPU").frame(width: 130, alignment: .trailing)
                    Text("PID").frame(width: 70, alignment: .trailing)
                    Spacer().frame(width: 30)
                }
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(faint)
                .padding(.bottom, 8)
                ForEach(model.processes) { p in ProcessLine(process: p) }
            }
        }
    }
}

struct ProcessLine: View {
    let process: ProcessRow

    var icon: NSImage? { NSRunningApplication(processIdentifier: pid_t(process.id))?.icon }

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                if let icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(faint).frame(width: 18, height: 18)
                }
                Text(process.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatBytes(process.memory)).frame(width: 90, alignment: .trailing)
            HStack(spacing: 8) {
                Meter(fraction: process.cpu / 100, color: .white.opacity(0.6)).frame(width: 50)
                Text(String(format: "%.1f", process.cpu)).frame(width: 40, alignment: .trailing)
            }
            .frame(width: 130, alignment: .trailing)
            Text("\(process.id)").foregroundStyle(faint).frame(width: 70, alignment: .trailing)
            Menu {
                Button("Afficher dans le Finder") {
                    if let path = processPath(process.id) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Button("Copier le nom du processus") { copy(process.name) }
                Button("Copier le PID") { copy("\(process.id)") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .padding(.vertical, 6)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Diagnostic

struct DiagnosticOverlay: View {
    @ObservedObject var tabs: TabSelection
    @ObservedObject var status = StatusModel.shared

    var body: some View {
        let sections = status.report()
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { tabs.showDiagnostic = false }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diagnostic").font(.system(size: 22, weight: .bold))
                        Text("L'état du Mac et d'Hippocampe, à joindre pour signaler un problème.")
                            .font(.system(size: 12)).foregroundStyle(faint)
                    }
                    Spacer()
                    Button { tabs.showDiagnostic = false } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                            .background(Circle().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(sections, id: \.0) { section in DiagnosticSection(title: section.0, rows: section.1) }
                    }
                }
                HStack {
                    Button("Afficher les journaux dans le Finder") {
                        NSWorkspace.shared.open(home.appending(path: "Library/Logs/MacChanger"))
                    }
                    .buttonStyle(.plain).foregroundStyle(faint)
                    Spacer()
                    Button("Copier le rapport") {
                        let text = sections.map { s in ([s.0] + s.1.map { "\($0.0): \($0.1)" }).joined(separator: "\n") }
                            .joined(separator: "\n\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.12)))
                }
                .font(.system(size: 12.5, weight: .medium))
            }
            .padding(24)
            .frame(width: 560, height: 560)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color(white: 0.16)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08)))
            .shadow(radius: 30)
        }
        .onAppear { status.start() }
        .onDisappear { status.stop() }
    }
}

struct DiagnosticSection: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(positive)
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .top) {
                        Text(row.0).foregroundStyle(faint).frame(width: 160, alignment: .leading)
                        Text(row.1).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }
}
