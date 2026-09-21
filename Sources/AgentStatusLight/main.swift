import AppKit
import AVFoundation
import Foundation
import ServiceManagement

enum AgentState: String, Codable { case working, completed, failed, awaitingInput = "awaiting-input", off
    var title: String { switch self { case .working: "Working"; case .completed: "Task completed"; case .failed: "Tool call failed"; case .awaitingInput: "Input required"; case .off: "Off" } }
    var color: NSColor { switch self { case .working: NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.0, alpha: 1.0); case .completed: .systemGreen; case .failed: .systemRed; case .awaitingInput: .systemOrange; case .off: .secondaryLabelColor } }
}
struct StatusRecord: Codable { var state: AgentState; var updatedAt: Date; var source: String? }
struct SessionRecord: Codable { var state: AgentState; var updatedAt: Date; var source: String?; var session: String?; var label: String?; var terminal: String?; var tty: String?; var terminalPid: Int? }
struct SessionInfo { let key: String; let label: String; let state: AgentState; let updatedAt: Date; let url: URL; let terminal: String?; let tty: String?; let terminalPid: Int? }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let allSources = ["codex", "copilot", "cursor", "claude"]; private var sources: [String] = ["codex"]
    private var items: [String: NSStatusItem] = [:]; private var buttonSources: [ObjectIdentifier: String] = [:]; private var states: [String: AgentState] = [:]; private var pulse = 0.0; private var timer: Timer?
    private var players: [String: AVAudioPlayer] = [:]; private var inputPlayers: [String: AVAudioPlayer] = [:]; private var pings: [String: NSSound] = [:]
    private var awaitAlertedAt: [String: Date] = [:]
    private var sessions: [String: [SessionInfo]] = [:]; private var sessionAlertedAt: [String: Date] = [:]; private var tickCount = 0
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentStatusLight")
    private var sessionsDirectory: URL { directory.appendingPathComponent("sessions") }
    private func name(_ source: String) -> String { source == "copilot" ? "GitHub Copilot" : source.capitalized }
    private func initial(_ source: String) -> String { switch source { case "codex": "O"; case "copilot": "G"; case "cursor": ">"; case "claude": "A"; default: "?" } }
    private func pref(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key) }
    private func inputVolume() -> Float { Float(min(max(UserDefaults.standard.object(forKey: "inputSoundVolume") as? Double ?? 0.5, 0.0), 1.0)) }
    private func statusRecord(_ source: String) -> (AgentState, Date?) { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; guard let x = try? Data(contentsOf: directory.appendingPathComponent("status.\(source).json")), let r = try? d.decode(StatusRecord.self, from: x) else { return (.off, nil) }; return (r.state == .completed && Date().timeIntervalSince(r.updatedAt) >= 20 ? .off : r.state, r.updatedAt) }
    private func read(_ source: String) -> AgentState { statusRecord(source).0 }
    private func loadSessions() { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil) else { sessions = [:]; return }; var grouped: [String: [SessionInfo]] = [:]; let now = Date(); for file in files where file.pathExtension == "json" { guard let data = try? Data(contentsOf: file), let r = try? d.decode(SessionRecord.self, from: data), let source = r.source, !source.isEmpty else { continue }; let age = now.timeIntervalSince(r.updatedAt); if age > 86400 || r.state == .off { continue }; if r.state == .completed && age >= 20 { continue }; let key = (r.session?.isEmpty == false) ? r.session! : file.deletingPathExtension().lastPathComponent; let label = (r.label?.isEmpty == false) ? r.label! : key; grouped[source, default: []].append(SessionInfo(key: key, label: label, state: r.state, updatedAt: r.updatedAt, url: file, terminal: r.terminal, tty: r.tty, terminalPid: r.terminalPid)) }; sessions = grouped }
    private func rank(_ state: AgentState) -> Int { switch state { case .awaitingInput: 0; case .failed: 1; case .working: 2; case .completed: 3; case .off: 4 } }
    private func aggregate(_ source: String) -> (AgentState, Date?) { let list = sessions[source] ?? []; if let best = list.min(by: { rank($0.state) < rank($1.state) }) { return (best.state, best.updatedAt) }; return statusRecord(source) }
    func applicationDidFinishLaunching(_ n: Notification) { if let stored = UserDefaults.standard.stringArray(forKey: "visibleSources") { sources = allSources.filter { stored.contains($0) } }; if sources.isEmpty { sources = ["codex"] }; UserDefaults.standard.set(sources, forKey: "visibleSources"); for source in sources { makeItem(source) }; timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }; if UserDefaults.standard.bool(forKey: "autoStartRelaunchPending") { UserDefaults.standard.removeObject(forKey: "autoStartRelaunchPending"); DispatchQueue.main.async { [weak self] in self?.registerLoginItem() } } }
    private func makeItem(_ source: String) { let item = NSStatusBar.system.statusItem(withLength: 20); item.button?.target = self; item.button?.action = #selector(menu(_:)); if let button = item.button { buttonSources[ObjectIdentifier(button)] = source; button.setAccessibilityLabel("Agent Status Light: \(name(source))") }; items[source] = item; states[source] = read(source); render(source) }
    private func refresh() { pulse += 0.24; tickCount += 1; if tickCount % 2 == 1 { loadSessions() }; for source in sources { let old = states[source] ?? .off; let (new, updated) = aggregate(source); states[source] = new; let list = sessions[source] ?? []; if list.isEmpty { if new == .failed && old != new && pref("playFailureSound") { failure(source) }; if new == .awaitingInput && pref("playInputSound") { let last = awaitAlertedAt[source] ?? .distantPast; let freshAwait = updated.map { $0 > last } ?? false; let settled = updated.map { Date().timeIntervalSince($0) >= 0.75 } ?? true; if settled && (old != new || freshAwait) { ping(source); awaitAlertedAt[source] = updated ?? Date() } } } else { for s in list { let key = "\(source)|\(s.key)"; if s.state == .failed { let last = sessionAlertedAt[key] ?? .distantPast; if s.updatedAt > last { sessionAlertedAt[key] = s.updatedAt; if pref("playFailureSound") { failure(source) } } } else if s.state == .awaitingInput { let last = sessionAlertedAt[key] ?? .distantPast; if s.updatedAt > last && Date().timeIntervalSince(s.updatedAt) >= 0.75 { sessionAlertedAt[key] = s.updatedAt; if pref("playInputSound") { ping(source) } } } } }; if new == .working || old != new { render(source) } } }
    @objc private func menu(_ sender: NSStatusBarButton) { guard let source = buttonSources[ObjectIdentifier(sender)] else { return }; let m = NSMenu(); let h = NSMenuItem(title: "\(name(source)): \(states[source]?.title ?? "Off")", action: nil, keyEquivalent: ""); h.isEnabled = false; m.addItem(h); loadSessions(); let live = sessions[source] ?? []; if live.count > 1 { let heading = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: ""); heading.isEnabled = false; m.addItem(heading); let counts = Dictionary(grouping: live, by: { $0.label }).mapValues { $0.count }; for s in live.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) { let suffix = (counts[s.label] ?? 0) > 1 ? " (\(s.key.prefix(4)))" : ""; let row = NSMenuItem(title: "\(s.label)\(suffix) — \(s.state.title)", action: #selector(activateSession(_:)), keyEquivalent: ""); row.target = self; row.representedObject = s.url.path; m.addItem(row) } }; m.addItem(.separator()); let add = NSMenuItem(title: "Add", action: nil, keyEquivalent: ""); let addMenu = NSMenu(); let missing = allSources.filter { !sources.contains($0) }; if missing.isEmpty { let note = NSMenuItem(title: "All agents shown", action: nil, keyEquivalent: ""); note.isEnabled = false; addMenu.addItem(note) } else { for candidate in missing { let item = NSMenuItem(title: name(candidate), action: #selector(addAgent(_:)), keyEquivalent: ""); item.target = self; item.representedObject = candidate; addMenu.addItem(item) } }; add.submenu = addMenu; m.addItem(add); m.addItem(.separator()); let choose = NSMenuItem(title: "Choose logo…", action: #selector(choose(_:)), keyEquivalent: ""); choose.target = self; choose.representedObject = source; m.addItem(choose); let clear = NSMenuItem(title: "Use initial instead", action: #selector(clear(_:)), keyEquivalent: ""); clear.target = self; clear.representedObject = source; m.addItem(clear); let reveal = NSMenuItem(title: "Reveal status file", action: #selector(reveal(_:)), keyEquivalent: ""); reveal.target = self; reveal.representedObject = source; m.addItem(reveal); m.addItem(.separator()); let f = NSMenuItem(title: "Play failure sound", action: #selector(toggleFailure), keyEquivalent: ""); f.target = self; f.state = pref("playFailureSound") ? .on : .off; m.addItem(f); let p = NSMenuItem(title: "Play input-request sound", action: #selector(toggleInput), keyEquivalent: ""); p.target = self; p.state = pref("playInputSound") ? .on : .off; m.addItem(p); let vs = NSMenuItem(title: "Input sound volume", action: nil, keyEquivalent: ""); let vsMenu = NSMenu(); for (volumeLabel, volumeValue) in [("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1.0)] { let volumeItem = NSMenuItem(title: volumeLabel, action: #selector(setInputVolume(_:)), keyEquivalent: ""); volumeItem.target = self; volumeItem.representedObject = volumeValue; volumeItem.state = abs(Double(inputVolume()) - volumeValue) < 0.01 ? .on : .off; vsMenu.addItem(volumeItem) }; vs.submenu = vsMenu; m.addItem(vs); let tool = NSMenuItem(title: "Alert for Copilot tool approvals", action: #selector(toggleCopilotToolAlerts), keyEquivalent: ""); tool.target = self; tool.state = pref("copilotToolAlerts") ? .on : .off; m.addItem(tool); m.addItem(.separator()); let auto = NSMenuItem(title: "Start at Login", action: #selector(toggleAutoStart), keyEquivalent: ""); auto.target = self; auto.state = SMAppService.mainApp.status == .enabled ? .on : .off; m.addItem(auto); m.addItem(.separator()); let close = NSMenuItem(title: "Close \(name(source)) indicator", action: #selector(closeSelf(_:)), keyEquivalent: ""); close.target = self; close.representedObject = source; close.isEnabled = sources.count > 1; m.addItem(close); let quit = NSMenuItem(title: "Quit Agent Status Light", action: #selector(quit), keyEquivalent: "q"); quit.target = self; m.addItem(quit); items[source]?.menu = m; sender.performClick(nil); items[source]?.menu = nil }
    @objc private func activateSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let info = sessions.values.flatMap({ $0 }).first(where: { $0.url.path == path }) else { return }
        if activateTerminalWindow(info) { return }
        if let pid = info.terminalPid, pid > 0, let app = NSRunningApplication(processIdentifier: pid_t(pid)) { app.activate(options: [.activateAllWindows]); return }
        NSWorkspace.shared.activateFileViewerSelecting([info.url])
    }
    private func activateTerminalWindow(_ info: SessionInfo) -> Bool {
        guard let tty = info.tty, !tty.isEmpty, let terminal = info.terminal, !terminal.isEmpty else { return false }
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        let script: String
        switch terminal {
        case "Terminal":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if (tty of t) is "\(ttyPath)" then
                            set frontmost of w to true
                            set selected tab of w to t
                            activate
                            return
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        case "iTerm2", "iTerm":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) is "\(ttyPath)" then
                                select w
                                select t
                                select s
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """
        default:
            return false
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return result != nil && error == nil
    }
    @objc private func addAgent(_ sender: NSMenuItem) { guard let source = sender.representedObject as? String, !sources.contains(source) else { return }; sources.append(source); UserDefaults.standard.set(sources, forKey: "visibleSources"); makeItem(source) }
    @objc private func closeSelf(_ sender: NSMenuItem) { guard let source = sender.representedObject as? String, sources.count > 1 else { return }; sources.removeAll { $0 == source }; UserDefaults.standard.set(sources, forKey: "visibleSources"); if let item = items.removeValue(forKey: source) { NSStatusBar.system.removeStatusItem(item) }; let ids = buttonSources.filter { $0.value == source }.map(\.key); for id in ids { buttonSources.removeValue(forKey: id) }; states.removeValue(forKey: source); players.removeValue(forKey: source); pings.removeValue(forKey: source); inputPlayers.removeValue(forKey: source); awaitAlertedAt.removeValue(forKey: source); sessions.removeValue(forKey: source); sessionAlertedAt = sessionAlertedAt.filter { !$0.key.hasPrefix(source + "|") } }
    @objc private func reveal(_ sender: NSMenuItem) { guard let source = sender.representedObject as? String else { return }; let url = directory.appendingPathComponent("status.\(source).json"); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); if !FileManager.default.fileExists(atPath: url.path) { writeState(source, states[source] ?? .off) }; NSWorkspace.shared.activateFileViewerSelecting([url]) }
    private func writeState(_ source: String, _ state: AgentState) { let d = JSONEncoder(); d.dateEncodingStrategy = .iso8601; let record = StatusRecord(state: state, updatedAt: Date(), source: source); guard let data = try? d.encode(record) else { return }; try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try? data.write(to: directory.appendingPathComponent("status.\(source).json"), options: .atomic) }
    @objc private func choose(_ s: NSMenuItem) { guard let source = s.representedObject as? String else { return }; let p = NSOpenPanel(); p.allowedFileTypes = ["png", "icns", "jpg", "jpeg", "tiff"]; if p.runModal() == .OK, let u = p.url { UserDefaults.standard.set(u.path, forKey: "iconPath.\(source)"); render(source) } }
    @objc private func clear(_ s: NSMenuItem) { if let source = s.representedObject as? String { UserDefaults.standard.removeObject(forKey: "iconPath.\(source)"); render(source) } }
    @objc private func setInputVolume(_ sender: NSMenuItem) { guard let value = sender.representedObject as? Double else { return }; UserDefaults.standard.set(value, forKey: "inputSoundVolume") }
    @objc private func toggleFailure() { UserDefaults.standard.set(!pref("playFailureSound"), forKey: "playFailureSound") }; @objc private func toggleInput() { UserDefaults.standard.set(!pref("playInputSound"), forKey: "playInputSound") }; @objc private func toggleCopilotToolAlerts() { UserDefaults.standard.set(!pref("copilotToolAlerts"), forKey: "copilotToolAlerts") }; @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleAutoStart() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            do { try service.unregister() } catch { showAlert("Couldn't disable Start at Login", error.localizedDescription) }
        } else if service.status == .requiresApproval {
            showAlert("Start at Login needs approval", "Approve Agent Status Light in System Settings, then check this item again.")
            SMAppService.openSystemSettingsLoginItems()
        } else if Bundle.main.bundleURL.deletingLastPathComponent().path != "/Applications" {
            installToApplicationsAndRelaunch()
        } else {
            registerLoginItem()
        }
    }
    private func registerLoginItem() {
        let service = SMAppService.mainApp
        do {
            try service.register()
            if service.status == .requiresApproval {
                showAlert("Start at Login needs approval", "Approve Agent Status Light in System Settings to finish enabling it.")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            showAlert("Couldn't enable Start at Login", error.localizedDescription)
        }
    }
    private func installToApplicationsAndRelaunch() {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/Agent Status Light.app")
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            UserDefaults.standard.set(true, forKey: "autoStartRelaunchPending")
            // Launching through NSWorkspace would just activate this running
            // instance (same bundle identifier), so start the new copy's
            // executable directly, then close the old instance.
            let relauncher = Process()
            relauncher.executableURL = destination.appendingPathComponent("Contents/MacOS/AgentStatusLight")
            try relauncher.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
        } catch {
            showAlert("Couldn't copy Agent Status Light to /Applications", "\(error.localizedDescription)\n\nMove the app to /Applications manually, launch it from there, and choose Start at Login again.")
        }
    }
    private func showAlert(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
    private func render(_ source: String) { guard let b = items[source]?.button else { return }; let state = states[source] ?? .off; let image = NSImage(size: NSSize(width: 20, height: 18)); image.lockFocus(); let a = state == .working ? 0.7 + (sin(pulse) + 1) * 0.15 : 1.0; if let path = UserDefaults.standard.string(forKey: "iconPath.\(source)"), let logo = NSImage(contentsOfFile: path) { logo.draw(in: NSRect(x: 2, y: 2, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: a) } else { state.color.withAlphaComponent(a).setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14)).fill(); let glyph = initial(source) as NSString; let glyphColor: NSColor = state == .off ? .black : .white; glyph.draw(at: NSPoint(x: 5, y: 4), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: glyphColor]) }; image.unlockFocus(); b.image = image; let count = sessions[source]?.count ?? 0; b.toolTip = count > 1 ? "\(name(source)): \(state.title) · \(count) sessions" : "\(name(source)): \(state.title)" }
    private func logSound(_ entry: String) { let stamp = ISO8601DateFormatter().string(from: Date()); let url = directory.appendingPathComponent("app-sounds.log"); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); let line = "\(stamp) \(entry)\n"; if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() } else { try? Data(line.utf8).write(to: url) } }
    private func ping(_ source: String) { if let url = Bundle.main.url(forResource: "InputSound", withExtension: "wav"), let player = try? AVAudioPlayer(contentsOf: url) { inputPlayers[source] = player; player.volume = inputVolume(); player.play(); logSound("input-cue source=\(source) volume=\(inputVolume())"); return }; logSound("input-fallback source=\(source)"); pings[source] = NSSound(named: NSSound.Name("Ping")); if pings[source]?.play() != true { NSSound.beep() } }
    private func failure(_ source: String) { let rate = 44100, count = Int(Double(rate) * 0.58); var samples = [Int16](repeating: 0, count: count); let notes = [(0.0, 0.24, 494.0), (0.29, 0.25, 370.0)]; for i in samples.indices { let t = Double(i) / Double(rate); var v = 0.0; for (s,l,f) in notes where t >= s && t < s+l { let n=t-s; let e=min(n/0.018,1)*min((s+l-t)/0.075,1); let q=2*Double.pi*f*n; v += e*(sin(q)+0.32*sin(2*q)+0.12*sin(3*q)) }; samples[i]=Int16(max(-1,min(1,v*0.38))*Double(Int16.max)) }; var d=Data(); func put<T:FixedWidthInteger>(_ x:T){var y=x.littleEndian; withUnsafeBytes(of:&y){d.append(contentsOf:$0)}}; let z=UInt32(samples.count*2); d.append("RIFF".data(using:.ascii)!); put(UInt32(36)+z); d.append("WAVEfmt ".data(using:.ascii)!); put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate*2)); put(UInt16(2)); put(UInt16(16)); d.append("data".data(using:.ascii)!); put(z); for x in samples {put(x)}; do {players[source]=try AVAudioPlayer(data:d); players[source]?.volume=0.65; players[source]?.play(); logSound("failure-cue source=\(source)")} catch {NSSound.beep(); logSound("failure-beep source=\(source)")} }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory); let delegate = AppDelegate(); app.delegate = delegate; app.run()
