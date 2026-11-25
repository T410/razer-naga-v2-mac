import AppKit
import NagaCore

struct ApplicationFocus {
    var bundleIdentifier: String?
    var name: String?
    var executablePath: String?
    var windowsExecutable: String?

    private var isWineHost: Bool {
        [bundleIdentifier, name, executablePath].compactMap { $0?.lowercased() }.contains { value in
            ["wine", "crossover", "whisky", "sikarugir", "porting kit", "portingkit", "steam_windows"]
                .contains { value.contains($0) }
        }
    }

    private var windowsFilename: String? {
        if let windowsExecutable { return Self.windowsFilename(windowsExecutable) }
        guard bundleIdentifier == nil || isWineHost else { return nil }
        return name.flatMap(Self.windowsFilename) ?? executablePath.flatMap(Self.windowsFilename)
    }

    func match(in profiles: [ApplicationProfile]) -> ApplicationProfile? {
        if let windowsFilename, let profile = profiles.first(where: { $0.id == .wineExecutable(windowsFilename) }) {
            return profile
        }
        guard let bundleIdentifier else { return nil }
        return profiles.first { $0.id == .bundleIdentifier(bundleIdentifier) }
    }

    private static func windowsFilename(_ path: String) -> String? {
        let unquoted = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard let filename = unquoted.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last?.lowercased(),
              filename.count > 4, filename.hasSuffix(".exe") else { return nil }
        return filename
    }

    init(bundleIdentifier: String? = nil, name: String? = nil, executablePath: String? = nil,
         windowsExecutable: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.executablePath = executablePath
        self.windowsExecutable = windowsExecutable
    }

    init(app: NSRunningApplication, checkWine: Bool) {
        self.init(bundleIdentifier: app.bundleIdentifier, name: app.localizedName, executablePath: app.executableURL?.path)
        guard checkWine, windowsFilename == nil, isWineHost || bundleIdentifier == nil else { return }
        windowsExecutable = Self.processExecutable(pid: app.processIdentifier)
    }

    private static func processExecutable(pid: pid_t) -> String? {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, u_int(query.count), nil, &size, nil, 0) == 0, (5...262_144).contains(size) else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, u_int(query.count), &bytes, &size, nil, 0) == 0, size > 4 else { return nil }
        let argumentCount = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard (1...4096).contains(argumentCount) else { return nil }
        // The kernel returns the Unix executable path, NUL padding, argv, then env.
        guard let pathEnd = bytes[4..<size].firstIndex(of: 0),
              let start = bytes[pathEnd..<size].firstIndex(where: { $0 != 0 }) else { return nil }
        let arguments = bytes[start..<size].split(separator: 0, maxSplits: argumentCount, omittingEmptySubsequences: false)
        for argument in arguments.prefix(argumentCount) {
            if let filename = windowsFilename(String(decoding: argument, as: UTF8.self)) { return filename }
        }
        return nil
    }
}
