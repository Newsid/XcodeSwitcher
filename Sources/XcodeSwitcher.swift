import AppKit
import SwiftUI

// MARK: - Model

struct XcodeInstall: Identifiable, Hashable {
    let url: URL
    let version: String
    let build: String

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    /// Apple beta / RC builds end with a lowercase letter (e.g. 17A5241e).
    var isBeta: Bool { build.last?.isLowercase ?? false }
}

enum XcodeScanner {
    static let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    static let xcodeBundleID = "com.apple.dt.Xcode"

    /// Every Xcode bundle at the top level of /Applications, whatever its file name.
    static func scan() -> [XcodeInstall] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: applicationsURL,
                                                 includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { $0.pathExtension == "app" }
            .compactMap { url -> XcodeInstall? in
                guard let info = plist(url.appendingPathComponent("Contents/Info.plist")),
                      info["CFBundleIdentifier"] as? String == xcodeBundleID,
                      let version = info["CFBundleShortVersionString"] as? String
                else { return nil }
                let build = plist(url.appendingPathComponent("Contents/version.plist"))?["ProductBuildVersion"] as? String
                    ?? info["DTXcodeBuild"] as? String ?? ""
                return XcodeInstall(url: url, version: version, build: build)
            }
            .sorted {
                if $0.version != $1.version {
                    return $0.version.compare($1.version, options: .numeric) == .orderedDescending
                }
                return $0.build.compare($1.build, options: .numeric) == .orderedDescending
            }
    }

    /// The Xcode bundle that `xcode-select -p` currently points into, if any.
    static func activeDeveloperDir() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}

// MARK: - Switching

struct SwitchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum XcodeSwitcher {
    static let activeName = "Xcode.app"

    /// Target file name for every install: the selected one becomes Xcode.app,
    /// the others Xcode_<version>.app (build / counter appended only on clashes).
    static func plannedNames(selected: XcodeInstall, all: [XcodeInstall]) -> [XcodeInstall: String] {
        var result: [XcodeInstall: String] = [selected: activeName]
        let others = all.filter { $0 != selected }
        let versionCounts = Dictionary(grouping: others, by: \.version).mapValues(\.count)
        var used: Set<String> = [activeName.lowercased()]

        for x in others {
            let version = sanitize(x.version)
            var base = "Xcode_\(version)"
            if versionCounts[x.version, default: 0] > 1, !x.build.isEmpty {
                base += "_\(sanitize(x.build))"
            }
            var name = base + ".app"
            var n = 2
            while used.contains(name.lowercased()) {
                name = "\(base)_\(n).app"
                n += 1
            }
            used.insert(name.lowercased())
            result[x] = name
        }
        return result
    }

    /// Builds the shell script that renames bundles (two-phase, so names can be swapped
    /// freely) and points xcode-select at the new Xcode.app.
    static func script(selected: XcodeInstall, all: [XcodeInstall]) throws -> String {
        let plan = plannedNames(selected: selected, all: all)
        let dir = XcodeScanner.applicationsURL
        let moves = plan.filter { $0.key.fileName != $0.value }
            .sorted { $0.key.fileName < $1.key.fileName }

        // Refuse to overwrite something that isn't one of the Xcodes being renamed.
        let sourcePaths = Set(all.map { $0.url.path.lowercased() })
        for (_, name) in moves {
            let target = dir.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: target), !sourcePaths.contains(target.lowercased()) {
                throw SwitchError(message: "\(target) already exists and is not a detected Xcode. Move or rename it first.")
            }
        }

        var cmds = ["set -e", "cd \(q(dir.path))"]
        let token = UUID().uuidString.prefix(8)
        for (i, (x, _)) in moves.enumerated() {
            cmds.append("mv \(q(x.fileName)) \(q(".xcodeswitcher-\(token)-\(i).app"))")
        }
        for (i, (_, name)) in moves.enumerated() {
            cmds.append("mv \(q(".xcodeswitcher-\(token)-\(i).app")) \(q(name))")
        }
        cmds.append("/usr/bin/xcode-select --switch \(q(dir.appendingPathComponent(activeName).appendingPathComponent("Contents/Developer").path))")
        return cmds.joined(separator: "; ")
    }

    static func runAsAdmin(_ shell: String) throws {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"XcodeSwitcher needs to rename Xcode in /Applications and run xcode-select.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                throw CancellationError()
            }
            throw SwitchError(message: error[NSAppleScript.errorMessage] as? String ?? "Unknown error")
        }
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - View model

@MainActor
final class Store: ObservableObject {
    @Published var installs: [XcodeInstall] = []
    @Published var activePath: String?
    @Published var selection: XcodeInstall.ID?
    @Published var status: String?
    @Published var errorMessage: String?
    @Published var busy = false

    func reload() {
        installs = XcodeScanner.scan()
        activePath = XcodeScanner.activeDeveloperDir()
        if selection == nil || !installs.contains(where: { $0.id == selection }) {
            selection = installs.first(where: { isActive($0) })?.id ?? installs.first?.id
        }
    }

    func isActive(_ x: XcodeInstall) -> Bool {
        guard let activePath else { return false }
        let bundle = x.url.resolvingSymlinksInPath().path
        return activePath == bundle || activePath.hasPrefix(bundle + "/")
    }

    var selected: XcodeInstall? { installs.first { $0.id == selection } }

    var needsSwitch: Bool {
        guard let s = selected else { return false }
        if !isActive(s) || s.fileName != XcodeSwitcher.activeName { return true }
        let plan = XcodeSwitcher.plannedNames(selected: s, all: installs)
        return plan.contains { $0.key.fileName != $0.value }
    }

    func switchToSelected() {
        guard let target = selected else { return }
        errorMessage = nil
        status = nil

        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == XcodeScanner.xcodeBundleID
        }
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Xcode is running"
            alert.informativeText = "Xcode must be closed before it can be renamed. Quit it now?"
            alert.addButton(withTitle: "Quit Xcode and Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            running.forEach { $0.terminate() }
            busy = true
            Task {
                for _ in 0..<60 where running.contains(where: { !$0.isTerminated }) {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                busy = false
                if running.contains(where: { !$0.isTerminated }) {
                    errorMessage = "Xcode did not quit. Save your work, quit it, and try again."
                } else {
                    perform(target)
                }
            }
            return
        }
        perform(target)
    }

    private func perform(_ target: XcodeInstall) {
        busy = true
        defer { busy = false; reload() }
        do {
            let script = try XcodeSwitcher.script(selected: target, all: installs)
            try XcodeSwitcher.runAsAdmin(script)
            selection = XcodeScanner.applicationsURL.appendingPathComponent(XcodeSwitcher.activeName).path
            status = "Now using Xcode \(target.version) (\(target.build))."
        } catch is CancellationError {
            // User dismissed the password prompt.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Zoom

/// Text zoom factor driven by ⌘+ / ⌘- / ⌘0, remembered across launches.
enum Zoom {
    static let key = "zoomScale"
    static let range = 0.8...2.0
    static let step = 0.1

    static func clamp(_ v: Double) -> Double {
        min(max((v * 10).rounded() / 10, range.lowerBound), range.upperBound)
    }

    /// Push buttons keep a fixed bezel height per control size, so step it up with the zoom.
    static func controlSize(_ scale: Double) -> ControlSize {
        switch scale {
        case ..<0.95: return .small
        case ..<1.25: return .regular
        default: return .large
        }
    }

    /// macOS base point sizes of the text styles used in the UI.
    static func font(_ base: CGFloat, _ scale: Double, _ weight: Font.Weight = .regular) -> Font {
        .system(size: base * scale, weight: weight)
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var store = Store()
    @AppStorage(Zoom.key) private var scale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text("Choose the Xcode version to use")
                .font(Zoom.font(13, scale, .bold))

            if store.installs.isEmpty {
                VStack(spacing: 8 * scale) {
                    Image(systemName: "hammer").font(Zoom.font(26, scale)).foregroundStyle(.secondary)
                    Text("No Xcode found in /Applications").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.installs, selection: $store.selection) { x in
                    Row(install: x, active: store.isActive(x), scale: scale)
                        .tag(x.id)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else if let status = store.status {
                Label(status, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack {
                Button {
                    store.reload()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(Zoom.font(13, scale))
                }
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button { NSApp.terminate(nil) } label: {
                    Text("Quit").font(Zoom.font(13, scale))
                }
                Button { store.switchToSelected() } label: {
                    Text("Use Selected").font(Zoom.font(13, scale))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.busy || !store.needsSwitch)
            }
            .controlSize(Zoom.controlSize(scale))
        }
        .font(Zoom.font(13, scale))
        .padding(16 * scale)
        .frame(minWidth: 460 * scale, minHeight: 300 * scale)
        .onAppear { store.reload() }
    }
}

struct Row: View {
    let install: XcodeInstall
    let active: Bool
    let scale: Double

    var body: some View {
        HStack(spacing: 10 * scale) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: install.url.path))
                .resizable()
                .frame(width: 32 * scale, height: 32 * scale)
            VStack(alignment: .leading, spacing: 2 * scale) {
                HStack(spacing: 6 * scale) {
                    Text("Xcode \(install.version)").font(Zoom.font(13, scale, .semibold))
                    if install.isBeta { Badge(text: "beta", color: .orange, scale: scale) }
                    if active { Badge(text: "active", color: .green, scale: scale) }
                }
                Text("\(install.build) · \(install.fileName)")
                    .font(Zoom.font(10, scale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2 * scale)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    let scale: Double
    var body: some View {
        if #available(macOS 14, *) {
            ProminenceAwareBadge(text: text, color: color, scale: scale)
        } else {
            BadgeLabel(text: text, foreground: color, background: color.opacity(0.2), scale: scale)
        }
    }
}

/// Turns white on the blue (emphasized) selection highlight, where the tinted badge would be unreadable.
@available(macOS 14, *)
private struct ProminenceAwareBadge: View {
    let text: String
    let color: Color
    let scale: Double
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        if prominence == .increased {
            BadgeLabel(text: text, foreground: .white, background: .white.opacity(0.25), scale: scale)
        } else {
            BadgeLabel(text: text, foreground: color, background: color.opacity(0.2), scale: scale)
        }
    }
}

private struct BadgeLabel: View {
    let text: String
    let foreground: Color
    let background: Color
    let scale: Double
    var body: some View {
        Text(text)
            .font(Zoom.font(10, scale, .semibold))
            .padding(.horizontal, 6 * scale)
            .padding(.vertical, 1 * scale)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }
}

struct XcodeSwitcherApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(Zoom.key) private var scale = 1.0

    var body: some Scene {
        WindowGroup("Xcode Switcher") { ContentView() }
            .windowResizability(.contentSize)
            .commands {
                CommandGroup(after: .toolbar) {
                    Button("Actual Size") { scale = 1.0 }
                        .keyboardShortcut("0")
                        .disabled(scale == 1.0)
                    Button("Zoom In") { scale = Zoom.clamp(scale + Zoom.step) }
                        .keyboardShortcut("+")
                        .disabled(scale >= Zoom.range.upperBound)
                    Button("Zoom Out") { scale = Zoom.clamp(scale - Zoom.step) }
                        .keyboardShortcut("-")
                        .disabled(scale <= Zoom.range.lowerBound)
                    Divider()
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // "+" needs Shift on some layouts (e.g. US), so also accept ⌘= for Zoom In.
        // Shift is tolerated because "=" itself needs Shift on others (e.g. Italian).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift)
            guard mods == .command, event.charactersIgnoringModifiers == "=" else { return event }
            let d = UserDefaults.standard
            let current = d.object(forKey: Zoom.key) as? Double ?? 1.0
            d.set(Zoom.clamp(current + Zoom.step), forKey: Zoom.key)
            return nil
        }
    }
}

// MARK: - Entry point

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // Diagnostic mode: `XcodeSwitcher --dry-run [version-or-filename]` prints what would happen.
        if args.count >= 2, args[1] == "--dry-run" {
            let all = XcodeScanner.scan()
            let active = XcodeScanner.activeDeveloperDir() ?? "none"
            print("xcode-select: \(active)")
            all.forEach { print("found: \($0.fileName)  \($0.version) (\($0.build))") }
            if args.count >= 3, let sel = all.first(where: { $0.version == args[2] || $0.fileName == args[2] }) {
                XcodeSwitcher.plannedNames(selected: sel, all: all)
                    .sorted { $0.value < $1.value }
                    .forEach { print("plan: \($0.key.fileName) -> \($0.value)") }
                do { print("script: \(try XcodeSwitcher.script(selected: sel, all: all))") }
                catch { print("error: \(error.localizedDescription)") }
            }
            return
        }
        XcodeSwitcherApp.main()
    }
}
