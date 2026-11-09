import SwiftUI
import AppKit

// MARK: - Model

/// One entry of the program library: every setting of the form, so a program can be
/// reloaded (or run directly) later with a single click.
struct SavedProgram: Codable, Identifiable, Equatable {
    var id = UUID()
    var exe = "", dir = "", name = "", outDir = ""
    var wine = "gptk", customWine = "", gfx = "auto"
    var copyProgram = true, retina = false, msync = true, esync = true, vsync = true
    var args = "", envs = "", winetricks = ""
    var detected: [String] = []   // GfxAPI raw values found by GfxScan
    var cover = "", coverH = ""   // vertical / horizontal cover image paths, empty if none
    var installer = false         // exe is a setup program to run first
    var installedExe = ""         // program found after installing, relative to the prefix ("drive_c/…")
    var virtualDesktop = ""       // "1920x1080" to run the program in a Wine virtual desktop, "" = off
    var winver = ""               // Windows version reported to the program ("" = runtime default, else xp/7/8/10/11)
    var prefixParent = ""         // folder (e.g. on an external drive) holding <name>/prefix; empty = the default place

    // "copyGame" is the key used by earlier versions of the library file
    enum CodingKeys: String, CodingKey {
        case id, exe, dir, name, outDir, wine, customWine, gfx
        case copyProgram = "copyGame"
        case retina, msync, esync, vsync, args, envs, winetricks, cover, coverH, detected
        case installer, installedExe, prefixParent, winver, virtualDesktop
    }

    init(id: UUID = UUID(), exe: String = "", dir: String = "", name: String = "", outDir: String = "",
         wine: String = "gptk", customWine: String = "", gfx: String = "auto",
         copyProgram: Bool = true, retina: Bool = false, msync: Bool = true, esync: Bool = true, vsync: Bool = true,
         args: String = "", envs: String = "", winetricks: String = "", cover: String = "", coverH: String = "", detected: [String] = [],
         installer: Bool = false, installedExe: String = "", prefixParent: String = "", winver: String = "", virtualDesktop: String = "") {
        self.id = id; self.exe = exe; self.dir = dir; self.name = name; self.outDir = outDir
        self.wine = wine; self.customWine = customWine; self.gfx = gfx
        self.copyProgram = copyProgram; self.retina = retina; self.msync = msync; self.esync = esync; self.vsync = vsync
        self.args = args; self.envs = envs; self.winetricks = winetricks; self.cover = cover; self.coverH = coverH; self.detected = detected
        self.installer = installer; self.installedExe = installedExe; self.prefixParent = prefixParent; self.winver = winver; self.virtualDesktop = virtualDesktop
    }

    // esync and vsync are missing from library files saved by earlier versions
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        self.init(id: get(.id, UUID()), exe: get(.exe, ""), dir: get(.dir, ""), name: get(.name, ""), outDir: get(.outDir, ""),
                  wine: get(.wine, "gptk"), customWine: get(.customWine, ""), gfx: get(.gfx, "auto"),
                  copyProgram: get(.copyProgram, true), retina: get(.retina, false), msync: get(.msync, true),
                  esync: get(.esync, true), vsync: get(.vsync, true),
                  args: get(.args, ""), envs: get(.envs, ""), winetricks: get(.winetricks, ""), cover: get(.cover, ""), coverH: get(.coverH, ""), detected: get(.detected, []),
                  installer: get(.installer, false), installedExe: get(.installedExe, ""), prefixParent: get(.prefixParent, ""), winver: get(.winver, ""), virtualDesktop: get(.virtualDesktop, ""))
    }

    func cover(_ o: CoverStyle) -> String { o == .vertical ? cover : coverH }

    var title: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? ((exe as NSString).lastPathComponent as NSString).deletingPathExtension : n
    }
}

final class Generator: ObservableObject {
    @Published var exe = "" { didSet { if exe != oldValue { scanGraphics() } } }
    @Published var detected: [GfxAPI] = []
    @Published var scan = ProgramScan()
    @Published var dir = ""
    @Published var name = ""
    @Published var outDir = NSHomeDirectory() + "/Desktop"
    @Published var wineChoice = WineChoice.gptk
    @Published var customWine = ""
    @Published var gfx = Gfx.auto
    @Published var copyProgram = true
    @Published var retina = false
    @Published var msync = true
    @Published var esync = true
    @Published var vsync = true
    @Published var args = ""
    @Published var envs = ""
    @Published var winetricks = ""
    @Published var cover = ""
    @Published var coverH = ""
    @Published var installer = false {
        didSet {   // pickExe pre-fills the name with "setup": drop it so the folder name is used instead
            if installer && !oldValue && name == ((exe as NSString).lastPathComponent as NSString).deletingPathExtension { name = "" }
        }
    }
    @Published var installedExe = ""
    @Published var prefixParent = ""
    @Published var winver = WinVer.runtimeDefault
    @Published var virtualDesktop = ""
    @Published var candidates: [String] = []   // programs an installer left, when it is not obvious which one starts it
    @Published var showCandidates = false
    @Published var showStorage = false
    @Published var wineCount = 0      // Wine processes alive now (polled), shown on the Storage button
    private var pendingMode = Mode.generate

    @Published var log = ""
    @Published var running = false
    @Published var hasMoltenVK = true
    @Published var resultApp: String?
    private var proc: Process?

    enum Mode: Hashable { case generate, run }
    @Published var tab = Mode.generate

    // Program library
    @Published var programs: [SavedProgram] = []
    @Published var selectedID: UUID?
    @Published var showForm = false
    @Published var runningID: UUID?

    init() {
        loadLibrary()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task.detached {
                let n = parseWineProcesses(runDmgexe(["--list-wine"]).out).count
                await MainActor.run { self?.wineCount = n }
            }
        }
    }

    var sortedPrograms: [SavedProgram] { programs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }

    private var storeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dmgexe/library.json")
    }

    private func loadLibrary() {
        // Earlier versions stored the library in games.json
        let legacy = storeURL.deletingLastPathComponent().appendingPathComponent("games.json")
        let url = FileManager.default.fileExists(atPath: storeURL.path) ? storeURL : legacy
        guard let d = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([SavedProgram].self, from: d) else { return }
        programs = list
    }

    private func persist() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(programs).write(to: storeURL)
    }

    private func snapshot(id: UUID) -> SavedProgram {
        SavedProgram(id: id, exe: exe, dir: dir, name: name, outDir: outDir,
                  wine: wineChoice.key, customWine: customWine, gfx: gfx.flag,
                  copyProgram: copyProgram, retina: retina, msync: msync, esync: esync, vsync: vsync,
                  args: args, envs: envs, winetricks: winetricks, cover: cover, coverH: coverH, detected: detected.map(\.rawValue),
                  installer: installer, installedExe: installedExe, prefixParent: prefixParent, winver: winver.key, virtualDesktop: virtualDesktop)
    }

    /// Adds the current form to the library, or updates the selected entry.
    func saveCurrent() {
        let program = snapshot(id: selectedID ?? UUID())
        if let i = programs.firstIndex(where: { $0.id == program.id }) { programs[i] = program } else { programs.append(program) }
        selectedID = program.id
        persist()
    }

    /// Looks for graphics API DLL names in the exe and its folder, off the main thread.
    func scanGraphics() {
        let path = exe
        guard !path.isEmpty else { detected = []; scan = ProgramScan(); return }
        Task.detached {
            let found = GfxScan.scan(exe: path)
            await MainActor.run { if self.exe == path { self.scan = found; self.detected = found.apis } }
        }
    }

    struct Suggestion {
        var wine: WineChoice?
        var gfx: Gfx?
        var tricks: [String] = []
        var isEmpty: Bool { wine == nil && gfx == nil && tricks.isEmpty }
        var text: String {
            var parts: [String] = []
            if let w = wine { parts.append(w.rawValue.replacingOccurrences(of: "Download ", with: "")) }
            if let x = gfx { parts.append(x.rawValue) }
            if !tricks.isEmpty { parts.append("winetricks " + tricks.joined(separator: " ")) }
            return parts.joined(separator: " · ")
        }
    }

    /// Settings that would suit the detected APIs and redistributables. Never overrides a choice
    /// that looks deliberate (custom/installed Wine, DXVK picked by hand, the software OpenGL).
    var suggestion: Suggestion {
        var s = Suggestion()
        let have = Set(winetricks.split(whereSeparator: \.isWhitespace).map(String.init))
        s.tricks = scan.tricks.filter { !have.contains($0) }
        if detected.contains(.dx12) || detected.contains(.dx11) {
            if [.stable, .devel, .staging].contains(wineChoice) && gfx != .dxvk { s.wine = .gptk }
        } else if detected.contains(.dx9) {
            if wineChoice == .gptk { s.wine = .staging }
            if gfx == .auto || gfx == .d3dmetal { s.gfx = .dxvk }
        }
        return s
    }

    func apply(_ s: Suggestion) {
        if let w = s.wine { wineChoice = w }
        if let x = s.gfx { gfx = x }
        if !s.tricks.isEmpty { winetricks = ([winetricks.trimmingCharacters(in: .whitespaces)] + s.tricks).filter { !$0.isEmpty }.joined(separator: " ") }
    }

    func chooseCover(for program: SavedProgram, _ style: CoverStyle) {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image]; p.message = "Choose a \(style.label.lowercased()) cover image"
        guard p.runModal() == .OK, let url = p.url else { return }
        if let path = try? Covers.importFile(url.path, id: program.id) { setCover(path, for: program.id, style) }
    }

    func setCover(_ path: String, for id: UUID, _ style: CoverStyle) {
        if let i = programs.firstIndex(where: { $0.id == id }) {
            let old = programs[i].cover(style)
            if old.hasPrefix(Covers.dir.path) { try? FileManager.default.removeItem(atPath: old) }
            if style == .vertical { programs[i].cover = path } else { programs[i].coverH = path }
            persist()
        }
        if selectedID == id { if style == .vertical { cover = path } else { coverH = path } }
    }

    func select(_ g: SavedProgram) {
        exe = g.exe; dir = g.dir; name = g.name
        if !g.outDir.isEmpty { outDir = g.outDir }
        wineChoice = .from(key: g.wine); customWine = g.customWine; gfx = .from(flag: g.gfx)
        copyProgram = g.copyProgram; retina = g.retina; msync = g.msync; esync = g.esync; vsync = g.vsync
        args = g.args; envs = g.envs; winetricks = g.winetricks; cover = g.cover; coverH = g.coverH
        installer = g.installer; installedExe = g.installedExe; prefixParent = g.prefixParent; winver = .from(key: g.winver); virtualDesktop = g.virtualDesktop
        selectedID = g.id
    }

    func newProgram() {
        select(SavedProgram(outDir: outDir))
        selectedID = nil
    }

    func delete(_ g: SavedProgram) {
        for c in [g.cover, g.coverH] where c.hasPrefix(Covers.dir.path) { try? FileManager.default.removeItem(atPath: c) }
        programs.removeAll { $0.id == g.id }
        if selectedID == g.id { selectedID = nil }
        persist()
    }

    /// Click-to-play from the library: load the entry and run it right away.
    func play(_ g: SavedProgram) {
        guard !running else { return }
        select(g); tab = .run; runProgram()
    }

    enum WineChoice: String, CaseIterable, Identifiable {
        case gptk = "Download GPTK (D3DMetal)"
        case stable = "Download runtime (stable)"
        case devel = "Download runtime (devel)"
        case staging = "Download runtime (staging)"
        case auto = "Use installed (auto-detect)"
        case custom = "Custom path…"
        var id: String { rawValue }
        var key: String { String(describing: self) }   // stable name used in the saved library
        static func from(key: String) -> WineChoice { allCases.first { $0.key == key } ?? .gptk }
    }
    enum WinVer: String, CaseIterable, Identifiable {
        case runtimeDefault = "Runtime default"
        case xp = "Windows XP", win7 = "Windows 7", win8 = "Windows 8", win10 = "Windows 10", win11 = "Windows 11"
        var id: String { rawValue }
        var key: String {   // value of --winver, and what the library stores
            switch self { case .runtimeDefault: return ""; case .xp: return "xp"; case .win7: return "7"
                          case .win8: return "8"; case .win10: return "10"; case .win11: return "11" }
        }
        static func from(key: String) -> WinVer { allCases.first { $0.key == key } ?? .runtimeDefault }
    }
    enum Gfx: String, CaseIterable, Identifiable {
        case auto = "Automatic"
        case d3dmetal = "D3DMetal (DX11/12)"
        case dxvk = "DXVK (DX9/10/11)"
        case opengl = "OpenGL 4.6 software (slow)"
        var id: String { rawValue }
        var flag: String {
            switch self { case .auto: return "auto"; case .d3dmetal: return "d3dmetal"; case .dxvk: return "dxvk"; case .opengl: return "opengl" }
        }
        static func from(flag: String) -> Gfx { allCases.first { $0.flag == flag } ?? .auto }
    }

    /// "" (off) or WIDTHxHEIGHT
    var virtualDesktopValid: Bool {
        let v = virtualDesktop.trimmingCharacters(in: .whitespaces)
        return v.isEmpty || v.range(of: #"^[0-9]{3,5}x[0-9]{3,5}$"#, options: .regularExpression) != nil
    }

    /// Options of dmgexe typed in the program's Arguments field: they would go to the program and be ignored.
    var argsThatAreDmgexeOptions: [String] {
        let known: Set<String> = ["--exe", "--dir", "--name", "--out", "--wine", "--icon", "--embed-wine", "--fetch-wine", "--gfx",
                                  "--profile", "--save-profile", "--run", "--install", "--installed-exe", "--wait", "--prefix-dir",
                                  "--winver", "--virtual-desktop", "--no-template", "--link", "--arg", "--env", "--winetricks",
                                  "--retina", "--no-msync", "--no-esync", "--no-vsync", "--no-d3dcompiler", "--win32"]
        return shellSplit(args).filter { known.contains($0) }
    }

    private var exeInsideDir: Bool { exe.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") }

    var canGenerate: Bool {
        if running || !virtualDesktopValid { return false }
        if !installedExe.isEmpty { return true }                  // already installed: only the prefix is needed
        if installer { return !exe.isEmpty && (dir.isEmpty || exeInsideDir) }
        return !exe.isEmpty && !dir.isEmpty && exeInsideDir
    }

    /// Name of the app / prefix. An installer is usually called setup.exe, so its folder names the program.
    var effectiveName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let stem = ((exe as NSString).lastPathComponent as NSString).deletingPathExtension
        if installer, ["setup", "install", "instal"].contains(where: { stem.lowercased().contains($0) }) {
            let folder = ((exe as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !folder.isEmpty && folder != "/" { return folder }
        }
        return stem
    }

    func forgetInstalled() { installedExe = "" }

    /// The prefix named `name` was deleted: the programs installed in it are gone, so forget them
    /// (the library card then offers to run the installer again).
    func prefixDeleted(_ name: String) {
        var changed = false
        for i in programs.indices where programs[i].title == name && !programs[i].installedExe.isEmpty {
            programs[i].installedExe = ""; changed = true
            if programs[i].id == selectedID { installedExe = "" }
        }
        if changed { persist() }
    }

    func pickExe() {
        guard let p = choose(files: true, dirs: false, message: "Choose the executable (.exe)") else { return }
        exe = p
        if dir.isEmpty { dir = (p as NSString).deletingLastPathComponent }
        if name.isEmpty { name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension }
    }
    func pickDir() { if let p = choose(files: false, dirs: true, message: "Choose the program folder") { dir = p } }
    func pickPrefixParent() { if let p = choose(files: false, dirs: true, message: "Folder (e.g. on an external drive) where the program's Windows environment will be kept") { prefixParent = p } }
    func pickOut() { if let p = choose(files: false, dirs: true, message: "Folder where the .app will be created") { outDir = p } }
    func pickWine() { if let p = choose(files: true, dirs: true, message: "Runtime binary or folder/.app") { customWine = p } }

    private func choose(files: Bool, dirs: Bool, message: String) -> String? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = files
        panel.canChooseDirectories = dirs
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func generate() { launch(.generate) }
    func runProgram() { launch(.run) }
    /// MoltenVK (Vulkan on Metal) is required by the DXVK backend. The GPTK runtime ships one,
    /// otherwise it must come from Homebrew.
    func checkMoltenVK() {
        let fm = FileManager.default
        var dirs = ["/opt/homebrew/lib", "/usr/local/lib"]
        let cache = NSHomeDirectory() + "/Library/Caches/dmgexe"
        for r in (try? fm.contentsOfDirectory(atPath: cache)) ?? [] {
            let base = "\(cache)/\(r)"
            for app in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where app.hasSuffix(".app") {
                dirs.append("\(base)/\(app)/Contents/Resources/wine/lib")
            }
        }
        hasMoltenVK = dirs.contains { fm.fileExists(atPath: $0 + "/libMoltenVK.dylib") }
    }

    func installMoltenVK() {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            log = "Homebrew is needed to install MoltenVK. Opening its website: install it, then press Install MoltenVK again.\n"
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return
        }
        log = "$ brew install molten-vk\n\n"
        running = true
        let p = Process()
        proc = p
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["install", "molten-vk"]
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.log += s.replacingOccurrences(of: "\r", with: "\n") }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false; self.proc = nil
                self.checkMoltenVK()
                self.log += self.hasMoltenVK ? "\n✅ MoltenVK installed.\n" : "\n❌ MoltenVK installation failed (exit code \(proc.terminationStatus)).\n"
            }
        }
        do { try p.run() } catch { running = false; proc = nil; log += "Could not run brew: \(error)\n" }
    }

    func stop() { proc?.terminate() }   // SIGTERM: dmgexe.sh stops the program and the wineserver

    private func launch(_ mode: Mode) {
        guard let script = Bundle.main.path(forResource: "dmgexe", ofType: "sh") else {
            log = "Cannot find dmgexe.sh inside the app.\n"; return
        }
        let installed = !installedExe.isEmpty
        let installing = installer && !installed
        if !installed {
            guard FileManager.default.fileExists(atPath: exe) else {
                log = "The executable no longer exists: \(exe)\n"; return
            }
        }
        if installed { name = effectiveName }   // the name is the prefix: it must not change once installed
        var a: [String]
        if installed {
            a = ["--installed-exe", installedExe, "-n", effectiveName, "--gfx", gfx.flag]
        } else if installing {
            a = ["-e", exe, "--install", "-n", effectiveName, "--gfx", gfx.flag] + (dir.isEmpty ? [] : ["-d", dir])
        } else {
            a = ["-e", exe, "-d", dir, "--gfx", gfx.flag]
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { a += ["-n", name] }
        }
        if winver != .runtimeDefault { a += ["--winver", winver.key] }
        let vd = virtualDesktop.trimmingCharacters(in: .whitespaces)
        if !vd.isEmpty { a += ["--virtual-desktop", vd] }
        if !prefixParent.isEmpty { a += ["--prefix-dir", prefixParent + "/" + effectiveName + "/prefix"] }
        a += mode == .run ? ["--run"] : ["-o", outDir]
        switch wineChoice {
        case .gptk: a += ["--fetch-wine", "gptk"]
        case .stable: a += ["--fetch-wine", "stable"]
        case .devel: a += ["--fetch-wine", "devel"]
        case .staging: a += ["--fetch-wine", "staging"]
        case .auto: break
        case .custom: if !customWine.isEmpty { a += ["-w", customWine, "--embed-wine"] }
        }
        if mode == .generate && !copyProgram && !installed && !installing { a.append("--link") }
        if retina { a.append("--retina") }
        if !msync { a.append("--no-msync") }
        if !esync { a.append("--no-esync") }
        if !vsync { a.append("--no-vsync") }
        for s in shellSplit(args) { a += ["--arg", s] }
        for l in envs.split(separator: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.contains("=") { a += ["--env", t] }
        }
        let wt = winetricks.trimmingCharacters(in: .whitespaces)
        if !wt.isEmpty { a += ["--winetricks", wt] }

        log = "$ dmgexe.sh " + a.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + "\n\n"
        running = true; resultApp = nil; runningID = selectedID; pendingMode = mode

        let p = Process()
        proc = p
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script] + a
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.log += s.replacingOccurrences(of: "\r", with: "\n") }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false; self.runningID = nil
                self.proc = nil
                if installing { self.finishInstall(mode, status: proc.terminationStatus); return }
                if mode == .run {
                    self.log += "\n■ Stopped (exit code \(proc.terminationStatus)).\n"
                } else if proc.terminationStatus == 0 {
                    self.resultApp = self.outDir + "/" + self.effectiveName + ".app"
                    self.log += "\n✅ Finished.\n"
                } else {
                    self.log += "\n❌ Error (exit code \(proc.terminationStatus)).\n"
                }
            }
        }
        do { try p.run() } catch { running = false; proc = nil; log += "Could not run: \(error)\n" }
    }

    /// After an installer run: the script prints `installed-exe: <path>` when it found the program,
    /// or `candidate: <path>` lines (exit code 3) when it needs the user to say which one.
    private func finishInstall(_ mode: Mode, status: Int32) {
        let lines = log.split(separator: "\n").map(String.init)
        func values(_ key: String) -> [String] {
            lines.filter { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)).trimmingCharacters(in: .whitespaces) }
        }
        if let found = values("installed-exe:").last {
            installedExe = found; name = effectiveName
            if selectedID != nil { saveCurrent() }
            log += "\n✅ Installed: \(found)\n"
            if selectedID == nil { log += "Press \"Save to library\" to remember it.\n" }
            if mode == .generate {
                if status == 0 { resultApp = outDir + "/" + effectiveName + ".app"; log += "✅ Finished.\n" }
                else { log += "❌ Error building the app (exit code \(status)).\n" }
            } else {
                log += "\n■ Stopped (exit code \(status)).\n"
            }
        } else if status == 3 {
            candidates = values("candidate:"); name = effectiveName
            showCandidates = true
            log += "\nThe installer left several programs. Choose the one that starts it.\n"
        } else {
            log += "\n❌ Error (exit code \(status)).\n"
        }
    }

    /// The user picked the program among the candidates: build / run it without reinstalling.
    func chooseInstalled(_ path: String) {
        showCandidates = false
        installedExe = path
        if selectedID != nil { saveCurrent() }
        launch(pendingMode)
    }

    // splits on spaces, honouring single/double quotes
    func shellSplit(_ s: String) -> [String] {
        var out: [String] = [], cur = "", q: Character? = nil, has = false
        for c in s {
            if let qq = q { if c == qq { q = nil } else { cur.append(c) } }
            else if c == "\"" || c == "'" { q = c; has = true }
            else if c == " " { if has || !cur.isEmpty { out.append(cur); cur = ""; has = false } }
            else { cur.append(c) }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
}

// MARK: - View

struct PathRow: View {
    let label: String
    @Binding var text: String
    let action: () -> Void
    var body: some View {
        HStack {
            Text(label).frame(width: 130, alignment: .trailing)
            TextField("", text: $text).textFieldStyle(.roundedBorder)
            Button("Choose…", action: action)
        }
    }
}

struct ContentView: View {
    @ObservedObject var g: Generator
    let mode: Generator.Mode

    /// Settings on the left, the log of what is running on the right (it used to sit below the form).
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView { form.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minWidth: 600, idealWidth: 640, maxWidth: 700)
            Divider()
            logPane.frame(minWidth: 380, maxWidth: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 600)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            PathRow(label: g.installer ? "Installer (.exe)" : "Executable (.exe)", text: $g.exe, action: g.pickExe)
                .help(g.installer ? "The setup program. It is run inside the app's Windows prefix and the program it installs is detected."
                                  : "The Windows program to launch. It must be inside the program folder.")
            PathRow(label: "Program folder", text: $g.dir, action: g.pickDir)
                .help("Folder holding the program and all its files (data, DLLs...).")
            if !g.exe.isEmpty && !g.dir.isEmpty && !g.canGenerate && !g.running {
                Text("The .exe must be inside the program folder.")
                    .foregroundColor(.red).font(.caption).padding(.leading, 138)
            }
            HStack {
                Spacer().frame(width: 130)
                Toggle("This is an installer (setup.exe)", isOn: $g.installer)
                    .help("For programs that are not installed yet. The installer runs inside the app's Windows prefix, the program it installs is detected, and the app (or Run) uses that program. Nothing is copied into the app.")
                    .disabled(!g.installedExe.isEmpty)
                Spacer()
            }
            if !g.installedExe.isEmpty {
                HStack {
                    Spacer().frame(width: 130)
                    Text("Installed: " + g.installedExe).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Install again") { g.forgetInstalled() }.controlSize(.small).disabled(g.running)
                        .help("Forgets the installed program so the installer runs again (the existing prefix is kept).")
                }
            }
            HStack {
                Text(mode == .run ? "Prefix name" : "App name").frame(width: 130, alignment: .trailing)
                TextField("(defaults to the exe name)", text: $g.name).textFieldStyle(.roundedBorder)
                    .disabled(!g.installedExe.isEmpty)
            }
            .help(mode == .run ? "Name of the Wine prefix (the fake Windows install) used to run the program."
                               : "Name of the generated .app.")
            PathRow(label: "Install location", text: $g.prefixParent, action: g.pickPrefixParent)
                .help("Optional. Keeps the program's Windows environment (and what an installer puts there) in <folder>/<name>/prefix, for example on an external drive. The drive must be connected whenever the program runs. Empty: ~/Library/Application Support. It cannot change after installing.")
                .disabled(!g.installedExe.isEmpty)
            if mode == .generate {
                PathRow(label: "Save to", text: $g.outDir, action: g.pickOut)
                    .help("Folder where the generated .app is saved.")
            }

            Divider()
            HStack {
                Text("Runtime").frame(width: 130, alignment: .trailing)
                Picker("", selection: $g.wineChoice) {
                    ForEach(Generator.WineChoice.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 280)
            }
            .help("The Wine build that runs the program. GPTK includes D3DMetal (best for DirectX 11/12); the others are plain Wine. It is downloaded once and cached.")
            if g.wineChoice == .custom {
                PathRow(label: "", text: $g.customWine, action: g.pickWine)
            }
            HStack {
                Text("Windows version").frame(width: 130, alignment: .trailing)
                Picker("", selection: $g.winver) {
                    ForEach(Generator.WinVer.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 280)
                if g.winver == .win11 && g.wineChoice == .gptk {
                    Text("The GPTK runtime is old and may not know Windows 11.").foregroundColor(.orange).font(.caption)
                }
            }
            .help("The Windows version Wine reports to the program. Some old programs only start as Windows XP/7, some new ones need 10. It does not install another Windows. Runtime default: leave Wine's own.")
            HStack {
                Text("Virtual desktop").frame(width: 130, alignment: .trailing)
                TextField("off (e.g. 1920x1080)", text: $g.virtualDesktop).textFieldStyle(.roundedBorder).frame(width: 170)
                Menu("Presets") {
                    Button("Off") { g.virtualDesktop = "" }
                    ForEach(["1280x720", "1600x900", "1920x1080", "2560x1440"], id: \.self) { r in Button(r) { g.virtualDesktop = r } }
                }.menuStyle(.borderlessButton).frame(width: 80)
                if !g.virtualDesktopValid { Text("Use WIDTHxHEIGHT, e.g. 1920x1080").foregroundColor(.red).font(.caption) }
            }
            .help("Runs the program inside a window of this size instead of letting it take over the screen and switch the display mode. The usual cure for a black screen: try it when the program shows nothing or you lose the mouse.")
            HStack {
                Text("Graphics").frame(width: 130, alignment: .trailing)
                Picker("", selection: $g.gfx) {
                    ForEach(Generator.Gfx.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 280)
            }
            .onAppear { g.checkMoltenVK() }
            .help("Translates DirectX to the Mac's graphics API. Auto: let dmgexe choose. D3DMetal: DX11/12 via Metal (needs the GPTK runtime). DXVK: DX9/10/11 via Vulkan. OpenGL: software rendering, slow.")
            if !g.exe.isEmpty {
                HStack {
                    Spacer().frame(width: 130)
                    Text((g.scan.bits.map { "\($0)-bit · " } ?? "")
                         + (g.detected.isEmpty ? "No graphics API detected in the program's files."
                                               : "Can use: " + g.detected.map(\.label).joined(separator: ", ")))
                        .foregroundColor(.secondary).font(.caption)
                    if g.gfx == .opengl {
                        Text("The OpenGL backend renders on the CPU (slow). Use it only if the program fails with the others.")
                            .foregroundColor(.orange).font(.caption)
                    }
                }
                .help("Guessed by looking for graphics DLL names in the exe and the DLLs next to it. A program with several backends lists several.")
                let sug = g.suggestion
                if !sug.isEmpty {
                    HStack {
                        Spacer().frame(width: 130)
                        Text("Suggested: " + sug.text).foregroundColor(.blue).font(.caption)
                        Button("Apply") { g.apply(sug) }.controlSize(.small)
                            .help("Sets the runtime, graphics backend and winetricks fields as suggested. You can still change them.")
                    }
                }
            }
            if g.gfx == .dxvk && g.wineChoice == .gptk {
                HStack {
                    Spacer().frame(width: 130)
                    Text("DXVK does not work with the GPTK runtime (it has no Vulkan). Use Wine Devel, Staging or Stable.")
                        .foregroundColor(.orange).font(.caption)
                }
            }
            if g.gfx == .dxvk && g.wineChoice != .gptk && !g.hasMoltenVK {
                HStack {
                    Spacer().frame(width: 130)
                    Text("DXVK needs MoltenVK, which was not found on this Mac.")
                        .foregroundColor(.orange).font(.caption)
                    Button("Install MoltenVK", action: g.installMoltenVK).disabled(g.running)
                        .help("Installs MoltenVK with Homebrew (brew install molten-vk). No restart needed.")
                }
            }
            HStack(spacing: 18) {
                Spacer().frame(width: 130)
                if mode == .generate {
                    Toggle("Link", isOn: Binding(get: { !g.copyProgram }, set: { g.copyProgram = !$0 }))
                        .help("On: the app points to the original folder (small, instant, but the folder must stay where it is). Off: the program is copied inside the app. Running directly always links.")
                }
                Toggle("Retina", isOn: $g.retina)
                    .help("Render at the screen's native resolution. Sharper but slower.")
                Toggle("MSYNC", isOn: $g.msync)
                    .help("Faster thread synchronization using macOS-native primitives. Disable only if the program hangs or fails to start.")
                Toggle("ESYNC", isOn: $g.esync)
                    .help("Alternative thread synchronization based on file descriptors. Used if MSYNC is unavailable. Disable on 'too many open files' errors.")
                Toggle("VSync", isOn: $g.vsync)
                    .help("Sync frames to the display refresh rate. Turning it off only takes effect with the DXVK backend; otherwise use the program's own settings.")
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Arguments").frame(width: 130, alignment: .trailing)
                        TextField("--fullscreen \"--foo bar\"", text: $g.args).textFieldStyle(.roundedBorder)
                    }
                    .help("Command-line arguments passed to the program. Quote values that contain spaces.")
                    if !g.argsThatAreDmgexeOptions.isEmpty {
                        HStack {
                            Spacer().frame(width: 130)
                            Text("\(g.argsThatAreDmgexeOptions.joined(separator: ", ")) is an option of Dmgexe, not of the program: here it is ignored. Use the matching field above (Virtual desktop, Windows version…) or Variables for environment variables.")
                                .foregroundColor(.red).font(.caption)
                        }
                    }
                    HStack {
                        Text("Winetricks").frame(width: 130, alignment: .trailing)
                        TextField("vcrun2022 dotnet48", text: $g.winetricks).textFieldStyle(.roundedBorder)
                    }
                    .help("Winetricks components to install on first launch (e.g. vcrun2022). Requires winetricks to be installed.")
                    HStack(alignment: .top) {
                        Text("Variables (K=V,\none per line)").multilineTextAlignment(.trailing)
                            .frame(width: 130, alignment: .trailing)
                        TextEditor(text: $g.envs).font(.system(.body, design: .monospaced))
                            .frame(height: 54).border(Color.gray.opacity(0.4))
                    }
                    .help("Extra environment variables for Wine, one KEY=VALUE per line (e.g. WINEDEBUG=-all).")
                }.padding(.top, 6)
            }

            HStack {
                if mode == .run {
                    Button(action: g.runProgram) {
                        Text(g.running ? "Running…" : (g.installer && g.installedExe.isEmpty ? "Install & run" : "Run program")).frame(minWidth: 120)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!g.canGenerate)
                    Button("Stop", action: g.stop).disabled(!g.running)
                } else {
                    Button(action: g.generate) {
                        Text(g.running ? "Generating…" : (g.installer && g.installedExe.isEmpty ? "Install & generate .app" : "Generate .app")).frame(minWidth: 120)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!g.canGenerate)
                }
                if g.running { ProgressView().controlSize(.small) }
                Button(g.selectedID == nil ? "Save to library" : "Update in library", action: g.saveCurrent)
                    .disabled((g.exe.isEmpty || g.dir.isEmpty) && g.installedExe.isEmpty)
                if mode == .generate, let app = g.resultApp {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app)]) }
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
                }
            }

        }
        .padding(16)
    }

    private var logPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Clear") { g.log = "" }.controlSize(.small).disabled(g.log.isEmpty || g.running)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(g.log.isEmpty ? "Output of the installer, the packager and the program appears here." : g.log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(g.log.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("end")
                }
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color.gray.opacity(0.4))
                .onChange(of: g.log) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(16)
    }
}

// MARK: - Storage (running processes, prefixes, templates and winetricks downloads)

struct PrefixInfo: Identifiable {
    var name: String, path: String, kb: Int, verbs: [String], pinned: Bool
    var id: String { name }
}
struct CacheInfo: Identifiable {
    var verb: String, path: String, kb: Int
    var id: String { path }
}
struct TemplateInfo: Identifiable {
    var key: String, kb: Int, verbs: [String], runtime: String, date: String
    var id: String { key }
}
struct WineProcess: Identifiable {
    var pid: String, app: String, time: String, command: String
    var id: String { pid }
}

func formatKB(_ kb: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .file) }

/// Runs dmgexe.sh, which owns the rules (what counts as a prefix, what is in use, how a process is told to stop).
func runDmgexe(_ args: [String]) -> (status: Int32, out: String) {
    guard let script = Bundle.main.path(forResource: "dmgexe", ofType: "sh") else { return (1, "dmgexe.sh not found") }
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [script] + args
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    p.environment = env; p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func parseWineProcesses(_ out: String) -> [WineProcess] {
    out.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5, f[0] == "wine" else { return nil }
        return WineProcess(pid: f[1], app: f[2], time: f[3], command: f[4])
    }
}

final class StorageModel: ObservableObject {
    @Published var prefixes: [PrefixInfo] = []
    @Published var caches: [CacheInfo] = []
    @Published var templates: [TemplateInfo] = []
    @Published var processes: [WineProcess] = []
    @Published var root = ""            // folder for new prefixes ("" = Application Support)
    @Published var loading = false
    @Published var busy = false         // a delete / move / stop is running
    @Published var error: String?

    static let defaultPlace = NSHomeDirectory() + "/Library/Application Support"

    /// Where a prefix of `name` belongs according to the current setting.
    func target(for name: String) -> String { (root.isEmpty ? Self.defaultPlace : root) + "/" + name + "/prefix" }

    func refresh() {
        loading = true
        Task.detached {
            let a = runDmgexe(["--list-prefixes"]).out, b = runDmgexe(["--list-cache"]).out
            let t = runDmgexe(["--list-templates"]).out, w = runDmgexe(["--list-wine"]).out
            let r = runDmgexe(["--get-prefix-root"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefixes: [PrefixInfo] = a.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 5, f[0] == "prefix" else { return nil }
                return PrefixInfo(name: f[1], path: f[2], kb: Int(f[3]) ?? 0, verbs: f[4].split(separator: ",").map(String.init),
                                  pinned: f.count > 5 && f[5] == "1")
            }
            let caches: [CacheInfo] = b.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 4, f[0] == "cache" else { return nil }
                return CacheInfo(verb: f[1], path: f[2], kb: Int(f[3]) ?? 0)
            }
            let templates: [TemplateInfo] = t.split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 7, f[0] == "template" else { return nil }
                return TemplateInfo(key: f[1], kb: Int(f[3]) ?? 0, verbs: f[4].split(separator: ",").map(String.init), runtime: f[5], date: f[6])
            }
            await MainActor.run {
                self.prefixes = prefixes.sorted { $0.kb > $1.kb }
                self.caches = caches.sorted { $0.kb > $1.kb }
                self.templates = templates.sorted { $0.kb > $1.kb }
                self.processes = parseWineProcesses(w)
                self.root = r
                self.loading = false
            }
        }
    }

    /// Cheap refresh of the process list only (it runs on a timer while the window is open).
    func refreshProcesses() {
        Task.detached {
            let w = parseWineProcesses(runDmgexe(["--list-wine"]).out)
            await MainActor.run { self.processes = w }
        }
    }

    /// Runs a command that changes something, then refreshes. `done` is told whether it worked.
    func run(_ args: [String], done: @escaping (Bool) -> Void = { _ in }) {
        busy = true
        Task.detached {
            let r = runDmgexe(args)
            await MainActor.run {
                self.busy = false
                if r.status != 0 {
                    let msg = r.out.replacingOccurrences(of: "error: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    self.error = msg.isEmpty ? "The command failed (exit code \(r.status))." : msg
                }
                done(r.status == 0)
                self.refresh()
            }
        }
    }
}

struct StorageView: View {
    @ObservedObject var g: Generator
    @StateObject private var m = StorageModel()
    @State private var pendingDelete: PrefixInfo?
    @State private var pendingMove: PrefixInfo?
    @State private var confirmAllCache = false
    @State private var confirmAllTemplates = false
    @State private var confirmStopAll = false

    private func entry(_ p: PrefixInfo) -> SavedProgram? { g.programs.first { $0.title == p.name } }

    private func deleteWarning(for p: PrefixInfo) -> String {
        if let e = entry(p), !e.installedExe.isEmpty {
            return "The program installed in it (\(e.installedExe.replacingOccurrences(of: "drive_c/", with: "C:/"))) will be deleted and you will have to run its installer again."
        }
        if entry(p) == nil {
            return "No program in the library uses it, but an .app you generated may still do. Its saved games inside the prefix are deleted too."
        }
        return "\(p.name) builds a new one the next time it runs (its winetricks components are installed again). Saved games kept inside the prefix are deleted."
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.message = "Folder where the Windows prefixes of your programs will be created from now on"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        m.run(["--set-prefix-root", url.path])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Storage").font(.title3.bold())
                if m.loading || m.busy { ProgressView().controlSize(.small) }
                Spacer()
                Text("Prefixes " + formatKB(m.prefixes.reduce(0) { $0 + $1.kb }) + " · templates " + formatKB(m.templates.reduce(0) { $0 + $1.kb }) + " · downloads " + formatKB(m.caches.reduce(0) { $0 + $1.kb }))
                    .foregroundColor(.secondary).font(.caption)
                Button("Refresh", action: m.refresh).disabled(m.loading)
                Button("Done") { g.showStorage = false }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            List {
                runningSection
                locationSection
                Section(header: Text("Windows prefixes (one per program)")) {
                    if m.prefixes.isEmpty { Text(m.loading ? "Looking…" : "No prefixes yet. They appear after a program runs for the first time.").foregroundColor(.secondary) }
                    ForEach(m.prefixes) { p in prefixRow(p) }
                }
                templatesSection
                downloadsSection
            }
        }
        .frame(width: 760, height: 620)
        .onAppear(perform: m.refresh)
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in m.refreshProcesses() }
        // `presenting:` hands the action the value that was pending when the alert opened. (Using a plain
        // isPresented binding does not work: SwiftUI clears the pending value before the button's action runs.)
        .alert("Delete the prefix of \(pendingDelete?.name ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { p in
            Button("Delete", role: .destructive) { m.run(["--delete-prefix", p.name]) { ok in if ok { g.prefixDeleted(p.name) } } }
            Button("Cancel", role: .cancel) {}
        } message: { p in Text(deleteWarning(for: p)) }
        .alert("Move the prefix of \(pendingMove?.name ?? "")?", isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
               presenting: pendingMove) { p in
            Button("Move") { m.run(["--move-prefix", p.name]) }
            Button("Cancel", role: .cancel) {}
        } message: { p in Text("From \(p.path)\nto \(m.target(for: p.name))\n\nOn another drive this copies the whole prefix first, which can take a while. Nothing is lost if it fails.") }
        .alert("Stop every Wine process?", isPresented: $confirmStopAll) {
            Button("Stop all", role: .destructive) { m.run(["--stop-wine", "all"]) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Programs running through Wine are closed without saving.") }
        .alert("Delete all prefix templates?", isPresented: $confirmAllTemplates) {
            Button("Delete", role: .destructive) { m.run(["--delete-template", "all"]) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Frees \(formatKB(m.templates.reduce(0) { $0 + $1.kb })) of templates (the space is only really freed when no prefix shares it). Prefixes already made from them are not affected.") }
        .alert("Delete all downloads?", isPresented: $confirmAllCache) {
            Button("Delete", role: .destructive) { m.run(["--delete-cache", "all"]) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Frees \(formatKB(m.caches.reduce(0) { $0 + $1.kb })).") }
        .alert("Could not do it", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })) {
            Button("OK") { m.error = nil }
        } message: { Text(m.error ?? "") }
    }

    // Wine processes running now, grouped by program: the way out when something stays behind.
    private var runningSection: some View {
        Section(header: HStack {
            Text("Running now" + (m.processes.isEmpty ? "" : " (\(m.processes.count))"))
            Spacer()
            Button("Stop all") { confirmStopAll = true }.controlSize(.small).disabled(m.processes.isEmpty || m.busy)
        }) {
            if m.processes.isEmpty {
                Text("No Wine processes are running.").foregroundColor(.secondary)
            } else {
                Text("Wine processes that are alive now. A closed program can leave some behind (services Wine starts); stopping them also lets you delete or move its prefix.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(Dictionary(grouping: m.processes, by: \.app).keys.sorted(), id: \.self) { app in
                let procs = m.processes.filter { $0.app == app }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(app).bold()
                        Text("\(procs.count) process" + (procs.count == 1 ? "" : "es")).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Stop") { m.run(["--stop-wine", app == "(unknown)" ? "all" : app]) }
                            .controlSize(.small).disabled(m.busy || app == "(unknown)")
                            .help(app == "(unknown)" ? "Stop these one by one (they do not belong to a known program)" : "Closes every Wine process of this program")
                    }
                    ForEach(procs) { pr in
                        HStack {
                            Text(pr.command.replacingOccurrences(of: "C:\\windows\\system32\\", with: "")).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(pr.time).font(.caption).foregroundColor(.secondary)
                            Button("Stop") { m.run(["--stop-wine", "pid:" + pr.pid]) }.controlSize(.mini).disabled(m.busy)
                        }.padding(.leading, 12)
                    }
                }.padding(.vertical, 2)
            }
        }
    }

    private var locationSection: some View {
        Section(header: Text("Where new prefixes are created")) {
            HStack {
                Text(m.root.isEmpty ? "Application Support (default)" : m.root).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…", action: chooseRoot).controlSize(.small).disabled(m.busy)
                Button("Use default") { m.run(["--set-prefix-root", "default"]) }.controlSize(.small).disabled(m.root.isEmpty || m.busy)
            }
            Text("Applies to every program, including those you generate or run later. Prefixes that already exist stay where they are until you move them (the Move button of each one). A program with its own \"Install location\" keeps that one. The drive must be connected whenever those programs run.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var templatesSection: some View {
        Section(header: HStack {
            Text("Prefix templates")
            Spacer()
            Button("Delete all") { confirmAllTemplates = true }.controlSize(.small).disabled(m.templates.isEmpty)
        }) {
            Text("The first prefix built with a given runtime and list of winetricks components is kept here; every later program that asks for the same starts from a copy of it instead of installing them again (minutes saved, no extra space on the same drive). Deleting a template does not touch any prefix made from it: the next program that needs it just builds it again.")
                .font(.caption).foregroundColor(.secondary)
            if m.templates.isEmpty { Text("None yet. One is saved when a program with winetricks components runs for the first time.").foregroundColor(.secondary) }
            ForEach(m.templates) { t in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.verbs.joined(separator: ", ")).bold()
                        Text(t.runtime + (t.date.isEmpty ? "" : " · " + t.date)).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(formatKB(t.kb)).foregroundColor(.secondary)
                    Button("Delete") { m.run(["--delete-template", t.key]) }.controlSize(.small).disabled(m.busy)
                }
            }
        }
    }

    private var downloadsSection: some View {
        Section(header: HStack {
            Text("Winetricks downloads")
            Spacer()
            Button("Delete all") { confirmAllCache = true }.controlSize(.small).disabled(m.caches.isEmpty)
        }) {
            Text("Installers that winetricks downloaded for the components you asked for. Deleting them frees space; they are only downloaded again if a component is installed again. The components already installed in a prefix are not affected.")
                .font(.caption).foregroundColor(.secondary)
            if m.caches.isEmpty { Text("Nothing downloaded.").foregroundColor(.secondary) }
            ForEach(m.caches) { c in
                HStack {
                    Text(c.verb)
                    Spacer()
                    Text(formatKB(c.kb)).foregroundColor(.secondary)
                    Button("Delete") { m.run(["--delete-cache", c.verb]) }.controlSize(.small).disabled(m.busy)
                }
            }
        }
    }

    private func prefixRow(_ p: PrefixInfo) -> some View {
        let e = entry(p)
        let requested = Set((e?.winetricks ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        let installed = Set(p.verbs)
        let missing = requested.subtracting(installed).sorted(), extra = installed.subtracting(requested).sorted()
        let running = m.processes.contains { $0.app == p.name }
        let elsewhere = p.path != m.target(for: p.name)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(p.name).bold()
                Text(e == nil ? "not in library" : (e!.installedExe.isEmpty ? "in library" : "in library · holds the installed program"))
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background((e == nil ? Color.orange : Color.green).opacity(0.2)).clipShape(Capsule())
                if running { Text("running").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1).background(Color.red.opacity(0.2)).clipShape(Capsule()) }
                Spacer()
                Text(formatKB(p.kb)).foregroundColor(.secondary)
                if !p.pinned && elsewhere {
                    Button(m.root.isEmpty ? "Move to default" : "Move to folder") { pendingMove = p }.controlSize(.small).disabled(m.busy || running)
                        .help("Moves this prefix to \(m.target(for: p.name))")
                }
                Button("Delete…") { pendingDelete = p }.controlSize(.small).disabled(m.busy || running)
                    .help(running ? "Stop its Wine processes first (section Running now)" : "Delete this Windows prefix")
            }
            Text(p.path + (p.pinned ? "  ·  fixed location (Install location)" : "")).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            if !p.verbs.isEmpty { Text("Winetricks installed: " + p.verbs.joined(separator: ", ")).font(.caption) }
            if e != nil && !missing.isEmpty {
                Text("Requested but not installed: " + missing.joined(separator: ", ") + " (they install when the program next starts, if winetricks is available)")
                    .font(.caption).foregroundColor(.orange)
            }
            if e != nil && !extra.isEmpty {
                Text("Installed but no longer requested: " + extra.joined(separator: ", ") + ". They cannot be removed one by one; delete the prefix to start clean.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

// MARK: - Graphics API detection

enum GfxAPI: String, CaseIterable {
    case opengl, dx9, dx11, dx12, vulkan
    var label: String {
        switch self {
        case .opengl: return "OpenGL"
        case .dx9: return "DirectX 9"
        case .dx11: return "DirectX 10/11"
        case .dx12: return "DirectX 12"
        case .vulkan: return "Vulkan"
        }
    }
}

/// What a static look at the program's files reveals.
struct ProgramScan {
    var apis: [GfxAPI] = []
    var bits: Int?            // 32 or 64, from the PE header (nil if the exe could not be read)
    var tricks: [String] = [] // winetricks verbs for redistributables it links but does not ship
}

/// Static guess of the graphics APIs and redistributables a program needs. A Windows exe names the
/// DLLs it links (import table) or loads at run time (SDL, GLFW, engines) as plain text, so looking
/// for those names in the exe and the DLLs next to it finds both. It says what the program *can*
/// use, not what it ends up using: an engine with several backends will list several.
enum GfxScan {
    private static let needles: [(String, GfxAPI)] = [
        ("opengl32.dll", .opengl), ("d3d9.dll", .dx9), ("d3d10.dll", .dx11), ("d3d10_1.dll", .dx11),
        ("d3d11.dll", .dx11), ("d3d12.dll", .dx12), ("vulkan-1.dll", .vulkan),
    ]
    /// DLL name (or prefix, for the d3dx family) -> winetricks verb
    private static let redists: [(String, String)] = [
        ("vcruntime140.dll", "vcrun2022"), ("msvcp140.dll", "vcrun2022"),
        ("msvcp120.dll", "vcrun2013"), ("msvcr120.dll", "vcrun2013"),
        ("msvcp110.dll", "vcrun2012"), ("msvcr110.dll", "vcrun2012"),
        ("msvcp100.dll", "vcrun2010"), ("msvcr100.dll", "vcrun2010"),
        ("d3dx9_", "d3dx9"), ("d3dx10_", "d3dx10"), ("d3dx11_", "d3dx11_43"),
    ]
    private static let maxBytes = 48 << 20, maxFiles = 60

    static func scan(exe: String) -> ProgramScan {
        let fm = FileManager.default
        let folder = (exe as NSString).deletingLastPathComponent
        var files = [exe]
        let siblings = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        let dlls = siblings.filter { $0.lowercased().hasSuffix(".dll") }.sorted()
        files += dlls.prefix(maxFiles).map { folder + "/" + $0 }
        let shipped = Set(dlls.map { $0.lowercased() })
        var found = Set<GfxAPI>(), tricks: [String] = []
        var out = ProgramScan()
        for f in files {
            guard let h = FileHandle(forReadingAtPath: f) else { continue }
            defer { try? h.close() }
            guard let data = try? h.read(upToCount: maxBytes), !data.isEmpty else { continue }
            if f == exe {
                out.bits = bits(of: data)
                // .NET is a heavy install (many minutes under Wine): only suggest it for a managed program.
                // Native programs often contain the text "mscoree.dll" without needing .NET at all.
                if isManaged(data) { tricks.append("dotnet48") }
            }
            let lower = Data(data.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
            func has(_ name: String) -> Bool {
                lower.range(of: Data(name.utf8)) != nil || lower.range(of: Data(name.utf8.flatMap { [$0, 0] })) != nil
            }
            for (name, api) in needles where !found.contains(api) && has(name) { found.insert(api) }
            for (name, verb) in redists where !tricks.contains(verb) && !shipped.contains(name) && has(name) { tricks.append(verb) }
        }
        out.apis = GfxAPI.allCases.filter(found.contains)
        out.tricks = tricks
        return out
    }

    /// A .NET assembly has a CLR header: entry 14 of the optional header's data directories.
    private static func isManaged(_ d: Data) -> Bool {
        guard d.count > 0x40, d[0] == 0x4D, d[1] == 0x5A else { return false }
        let pe = Int(d[0x3C]) | Int(d[0x3D]) << 8 | Int(d[0x3E]) << 16 | Int(d[0x3F]) << 24
        guard pe + 26 <= d.count, d[pe] == 0x50, d[pe + 1] == 0x45 else { return false }
        let magic = Int(d[pe + 24]) | Int(d[pe + 25]) << 8
        let dir = pe + 24 + (magic == 0x20b ? 112 : 96) + 14 * 8
        guard dir + 4 <= d.count else { return false }
        return (Int(d[dir]) | Int(d[dir + 1]) << 8 | Int(d[dir + 2]) << 16 | Int(d[dir + 3]) << 24) != 0
    }

    /// PE header: e_lfanew at 0x3C, then "PE\0\0" and the Machine field.
    private static func bits(of d: Data) -> Int? {
        guard d.count > 0x40, d[0] == 0x4D, d[1] == 0x5A else { return nil }
        let pe = Int(d[0x3C]) | Int(d[0x3D]) << 8 | Int(d[0x3E]) << 16 | Int(d[0x3F]) << 24
        guard pe + 6 <= d.count, d[pe] == 0x50, d[pe + 1] == 0x45 else { return nil }
        switch Int(d[pe + 4]) | Int(d[pe + 5]) << 8 {
        case 0x14c: return 32
        case 0x8664, 0xAA64: return 64
        default: return nil
        }
    }
}

// MARK: - Covers

enum CoverStyle: String, CaseIterable, Identifiable {
    case vertical, horizontal
    var id: String { rawValue }
    var label: String { self == .vertical ? "Vertical" : "Horizontal" }
    var aspect: CGFloat { self == .vertical ? 2.0 / 3.0 : 16.0 / 9.0 }
    var icon: String { self == .vertical ? "rectangle.portrait" : "rectangle" }
}

/// Cover images chosen by the user, copied under covers/.
enum Covers {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dmgexe/covers")
    }

    /// Copies a local image under covers/ and returns its path.
    static func importFile(_ path: String, id: UUID) throws -> String {
        try store(try Data(contentsOf: URL(fileURLWithPath: path)), id: id)
    }

    private static func store(_ data: Data, id: UUID) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // unique name so the grid reloads the image after a change
        let file = dir.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString.prefix(8)).img")
        try data.write(to: file)
        return file.path
    }

    private static let cache = NSCache<NSString, NSImage>()
    static func image(_ path: String) -> NSImage? {
        if let i = cache.object(forKey: path as NSString) { return i }
        guard let i = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}

// MARK: - Library grid

struct CoverCard: View {
    @ObservedObject var g: Generator
    let program: SavedProgram
    let style: CoverStyle
    @State private var hover = false

    private var image: NSImage? {
        let path = program.cover(style)
        return path.isEmpty ? nil : Covers.image(path)
    }

    var body: some View {
        // the clear base fixes the card size; the artwork is an overlay so it can never grow the layout
        Color.clear
        .aspectRatio(style.aspect, contentMode: .fit)
        .overlay { art }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: hover ? 8 : 3)
        .scaleEffect(hover ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
        .onTapGesture { g.play(program) }
        .help("Run \(program.title)")
        .contextMenu {
            Button("Run") { g.play(program) }.disabled(g.running)
            Button("Settings…") { g.select(program); g.showForm = true }
            Menu("Cover") {
                ForEach(CoverStyle.allCases) { st in
                    Button("Set \(st.label.lowercased()) cover…") { g.chooseCover(for: program, st) }
                    Button("Remove \(st.label.lowercased()) cover") { g.setCover("", for: program.id, st) }
                        .disabled(program.cover(st).isEmpty)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { g.delete(program) }
        }
    }

    private var art: some View {
        ZStack(alignment: .bottom) {
            if let img = image {
                Image(nsImage: img).resizable().scaledToFill().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            } else {
                LinearGradient(colors: [.indigo.opacity(0.7), .purple.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                Text(program.title).font(.headline).foregroundColor(.white)
                    .multilineTextAlignment(.center).padding(10).frame(maxHeight: .infinity)
            }
            if hover || g.runningID == program.id {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                Text(program.title).font(.caption.bold()).foregroundColor(.white).lineLimit(2)
                    .multilineTextAlignment(.center).padding(8)
            }
            if g.runningID == program.id {
                Color.black.opacity(0.35); ProgressView().frame(maxHeight: .infinity)
            }
        }
    }
}

struct LibraryView: View {
    @ObservedObject var g: Generator
    @AppStorage("coverStyle") private var styleRaw = CoverStyle.vertical.rawValue
    private var style: CoverStyle { CoverStyle(rawValue: styleRaw) ?? .vertical }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.headline)
                Spacer()
                Picker("", selection: $styleRaw) {
                    ForEach(CoverStyle.allCases) { Image(systemName: $0.icon).tag($0.rawValue).help($0.label) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 80)
                    .help("Show vertical or horizontal covers")
                if g.running {
                    Button("Stop", action: g.stop)
                }
                Button { g.showStorage = true } label: {
                    Label(g.wineCount > 0 ? "Storage · \(g.wineCount) Wine running" : "Storage", systemImage: g.wineCount > 0 ? "exclamationmark.circle" : "internaldrive")
                }
                .tint(g.wineCount > 0 ? .orange : nil)
                .help("Wine processes running now, Windows prefixes (where they are, move or delete them), templates and downloads")
                Button { g.newProgram(); g.showForm = true } label: { Label("Add program", systemImage: "plus") }
                    .help("Add a program or generate an .app")
            }
            .padding(10)
            Divider()
            if g.programs.isEmpty {
                Spacer()
                Text("No saved programs yet.\nPress \"Add program\", fill in the form and press \"Save to library\".")
                    .multilineTextAlignment(.center).foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [style == .vertical ? GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)
                                                         : GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 18)], spacing: 18) {
                        ForEach(g.sortedPrograms) { CoverCard(g: g, program: $0, style: style) }
                    }.padding(18)
                }
            }
        }
    }
}

/// Asks which of the programs an installer left is the one to start.
struct CandidatePicker: View {
    @ObservedObject var g: Generator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which program starts it?").font(.headline)
            Text("The installer finished and left more than one program. It will not run again.")
                .font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(g.candidates, id: \.self) { c in
                        Button { g.chooseInstalled(c) } label: {
                            Text(c.replacingOccurrences(of: "drive_c/", with: "C:/")).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }.frame(maxHeight: 220)
            HStack { Spacer(); Button("Cancel") { g.showCandidates = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 520)
    }
}

struct FormSheet: View {
    @ObservedObject var g: Generator
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let p = g.programs.first(where: { $0.id == g.selectedID }) {
                    ForEach(CoverStyle.allCases) { st in
                        Button { g.chooseCover(for: p, st) } label: {
                            Group {
                                if let img = p.cover(st).isEmpty ? nil : Covers.image(p.cover(st)) {
                                    Image(nsImage: img).resizable().scaledToFill()
                                } else { Color.gray.opacity(0.3).overlay(Image(systemName: "photo")) }
                            }
                            .frame(width: 60 * st.aspect, height: 60).clipShape(RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).help("Set \(st.label.lowercased()) cover")
                    }
                }
                Spacer()
                Button("Done") { g.showForm = false }.keyboardShortcut(.cancelAction)
            }
            .padding([.top, .horizontal], 12)
            TabView(selection: $g.tab) {
                ContentView(g: g, mode: .generate).tabItem { Text("Generate app") }.tag(Generator.Mode.generate)
                ContentView(g: g, mode: .run).tabItem { Text("Run program") }.tag(Generator.Mode.run)
            }
            .padding(.top, 6)
        }
        .sheet(isPresented: $g.showCandidates) { CandidatePicker(g: g) }
    }
}

struct RootView: View {
    @StateObject private var g = Generator()
    var body: some View {
        LibraryView(g: g)
            .frame(minWidth: 640, minHeight: 480)
            .sheet(isPresented: $g.showForm) { FormSheet(g: g) }
            .sheet(isPresented: $g.showStorage) { StorageView(g: g) }
    }
}

@main
struct DmgexeApp: App {
    var body: some Scene {
        WindowGroup("Dmgexe") { RootView() }
    }
}
