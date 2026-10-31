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

    // "copyGame" is the key used by earlier versions of the library file
    enum CodingKeys: String, CodingKey {
        case id, exe, dir, name, outDir, wine, customWine, gfx
        case copyProgram = "copyGame"
        case retina, msync, esync, vsync, args, envs, winetricks, cover, coverH, detected
    }

    init(id: UUID = UUID(), exe: String = "", dir: String = "", name: String = "", outDir: String = "",
         wine: String = "gptk", customWine: String = "", gfx: String = "auto",
         copyProgram: Bool = true, retina: Bool = false, msync: Bool = true, esync: Bool = true, vsync: Bool = true,
         args: String = "", envs: String = "", winetricks: String = "", cover: String = "", coverH: String = "", detected: [String] = []) {
        self.id = id; self.exe = exe; self.dir = dir; self.name = name; self.outDir = outDir
        self.wine = wine; self.customWine = customWine; self.gfx = gfx
        self.copyProgram = copyProgram; self.retina = retina; self.msync = msync; self.esync = esync; self.vsync = vsync
        self.args = args; self.envs = envs; self.winetricks = winetricks; self.cover = cover; self.coverH = coverH; self.detected = detected
    }

    // esync and vsync are missing from library files saved by earlier versions
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        self.init(id: get(.id, UUID()), exe: get(.exe, ""), dir: get(.dir, ""), name: get(.name, ""), outDir: get(.outDir, ""),
                  wine: get(.wine, "gptk"), customWine: get(.customWine, ""), gfx: get(.gfx, "auto"),
                  copyProgram: get(.copyProgram, true), retina: get(.retina, false), msync: get(.msync, true),
                  esync: get(.esync, true), vsync: get(.vsync, true),
                  args: get(.args, ""), envs: get(.envs, ""), winetricks: get(.winetricks, ""), cover: get(.cover, ""), coverH: get(.coverH, ""), detected: get(.detected, []))
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

    init() { loadLibrary() }

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
                  args: args, envs: envs, winetricks: winetricks, cover: cover, coverH: coverH, detected: detected.map(\.rawValue))
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

    var canGenerate: Bool {
        !exe.isEmpty && !dir.isEmpty && !running && exe.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    func pickExe() {
        guard let p = choose(files: true, dirs: false, message: "Choose the executable (.exe)") else { return }
        exe = p
        if dir.isEmpty { dir = (p as NSString).deletingLastPathComponent }
        if name.isEmpty { name = ((p as NSString).lastPathComponent as NSString).deletingPathExtension }
    }
    func pickDir() { if let p = choose(files: false, dirs: true, message: "Choose the program folder") { dir = p } }
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
        guard FileManager.default.fileExists(atPath: exe) else {
            log = "The executable no longer exists: \(exe)\n"; return
        }
        var a = ["-e", exe, "-d", dir, "--gfx", gfx.flag]
        a += mode == .run ? ["--run"] : ["-o", outDir]
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { a += ["-n", name] }
        switch wineChoice {
        case .gptk: a += ["--fetch-wine", "gptk"]
        case .stable: a += ["--fetch-wine", "stable"]
        case .devel: a += ["--fetch-wine", "devel"]
        case .staging: a += ["--fetch-wine", "staging"]
        case .auto: break
        case .custom: if !customWine.isEmpty { a += ["-w", customWine, "--embed-wine"] }
        }
        if mode == .generate && !copyProgram { a.append("--link") }
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
        running = true; resultApp = nil; runningID = selectedID

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
                if mode == .run {
                    self.log += "\n■ Stopped (exit code \(proc.terminationStatus)).\n"
                } else if proc.terminationStatus == 0 {
                    let n = self.name.trimmingCharacters(in: .whitespaces).isEmpty
                        ? ((self.exe as NSString).lastPathComponent as NSString).deletingPathExtension : self.name
                    self.resultApp = self.outDir + "/" + n + ".app"
                    self.log += "\n✅ Finished.\n"
                } else {
                    self.log += "\n❌ Error (exit code \(proc.terminationStatus)).\n"
                }
            }
        }
        do { try p.run() } catch { running = false; proc = nil; log += "Could not run: \(error)\n" }
    }

    // splits on spaces, honouring single/double quotes
    private func shellSplit(_ s: String) -> [String] {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PathRow(label: "Executable (.exe)", text: $g.exe, action: g.pickExe)
                .help("The Windows program to launch. It must be inside the program folder.")
            PathRow(label: "Program folder", text: $g.dir, action: g.pickDir)
                .help("Folder holding the program and all its files (data, DLLs...).")
            if !g.exe.isEmpty && !g.dir.isEmpty && !g.canGenerate && !g.running {
                Text("The .exe must be inside the program folder.")
                    .foregroundColor(.red).font(.caption).padding(.leading, 138)
            }
            HStack {
                Text(mode == .run ? "Prefix name" : "App name").frame(width: 130, alignment: .trailing)
                TextField("(defaults to the exe name)", text: $g.name).textFieldStyle(.roundedBorder)
            }
            .help(mode == .run ? "Name of the Wine prefix (the fake Windows install) used to run the program."
                               : "Name of the generated .app.")
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
                        Text(g.running ? "Running…" : "Run program").frame(minWidth: 120)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!g.canGenerate)
                    Button("Stop", action: g.stop).disabled(!g.running)
                } else {
                    Button(action: g.generate) {
                        Text(g.running ? "Generating…" : "Generate .app").frame(minWidth: 120)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!g.canGenerate)
                }
                if g.running { ProgressView().controlSize(.small) }
                Button(g.selectedID == nil ? "Save to library" : "Update in library", action: g.saveCurrent)
                    .disabled(g.exe.isEmpty || g.dir.isEmpty)
                if mode == .generate, let app = g.resultApp {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app)]) }
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: app)) }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(g.log.isEmpty ? " " : g.log)
                        .font(.system(size: 11, design: .monospaced))
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
        .frame(minWidth: 680, minHeight: 580)
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
        ("mscoree.dll", "dotnet48"),
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
            if f == exe { out.bits = bits(of: data) }
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
    }
}

struct RootView: View {
    @StateObject private var g = Generator()
    var body: some View {
        LibraryView(g: g)
            .frame(minWidth: 640, minHeight: 480)
            .sheet(isPresented: $g.showForm) { FormSheet(g: g) }
    }
}

@main
struct DmgexeApp: App {
    var body: some Scene {
        WindowGroup("Dmgexe") { RootView() }
    }
}
