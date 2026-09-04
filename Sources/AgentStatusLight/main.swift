import AppKit
import AVFoundation
import Foundation
import ServiceManagement

enum AgentState: String, Codable { case working, completed, failed, awaitingInput = "awaiting-input", off
    var title: String { switch self { case .working: "Working"; case .completed: "Task completed"; case .failed: "Tool call failed"; case .awaitingInput: "Input required"; case .off: "Off" } }
    var color: NSColor { switch self { case .working: .systemYellow; case .completed: .systemGreen; case .failed: .systemRed; case .awaitingInput: .systemOrange; case .off: .secondaryLabelColor } }
}
struct StatusRecord: Codable { var state: AgentState; var updatedAt: Date; var source: String? }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let allSources = ["codex", "copilot", "cursor", "claude"]; private var sources: [String] = ["codex"]
    private var items: [String: NSStatusItem] = [:]; private var buttonSources: [ObjectIdentifier: String] = [:]; private var states: [String: AgentState] = [:]; private var pulse = 0.0; private var timer: Timer?
    private var players: [String: AVAudioPlayer] = [:]; private var pings: [String: NSSound] = [:]
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentStatusLight")
    private func name(_ source: String) -> String { source == "copilot" ? "GitHub Copilot" : source.capitalized }
    private func initial(_ source: String) -> String { switch source { case "codex": "O"; case "copilot": "G"; case "cursor": ">"; case "claude": "A"; default: "?" } }
    private func pref(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key) }
    private func read(_ source: String) -> AgentState { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; guard let x = try? Data(contentsOf: directory.appendingPathComponent("status.\(source).json")), let r = try? d.decode(StatusRecord.self, from: x) else { return .off }; return r.state == .completed && Date().timeIntervalSince(r.updatedAt) >= 20 ? .off : r.state }
    func applicationDidFinishLaunching(_ n: Notification) { if let stored = UserDefaults.standard.stringArray(forKey: "visibleSources") { sources = allSources.filter { stored.contains($0) } }; if sources.isEmpty { sources = ["codex"] }; UserDefaults.standard.set(sources, forKey: "visibleSources"); for source in sources { makeItem(source) }; timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }; if UserDefaults.standard.bool(forKey: "autoStartRelaunchPending") { UserDefaults.standard.removeObject(forKey: "autoStartRelaunchPending"); DispatchQueue.main.async { [weak self] in self?.registerLoginItem() } } }
    private func makeItem(_ source: String) { let item = NSStatusBar.system.statusItem(withLength: 28); item.button?.target = self; item.button?.action = #selector(menu(_:)); if let button = item.button { buttonSources[ObjectIdentifier(button)] = source; button.setAccessibilityLabel("Agent Status Light: \(name(source))") }; items[source] = item; states[source] = read(source); render(source) }
    private func refresh() { pulse += 0.24; for source in sources { let old = states[source] ?? .off; let new = read(source); if old != new { states[source] = new; if new == .failed && pref("playFailureSound") { failure(source) }; if new == .awaitingInput && pref("playInputSound") { ping(source) } }; if new == .working || old != new { render(source) } } }
    @objc private func menu(_ sender: NSStatusBarButton) { guard let source = buttonSources[ObjectIdentifier(sender)] else { return }; let m = NSMenu(); let h = NSMenuItem(title: "\(name(source)): \(states[source]?.title ?? "Off")", action: nil, keyEquivalent: ""); h.isEnabled = false; m.addItem(h); m.addItem(.separator()); let add = NSMenuItem(title: "Add", action: nil, keyEquivalent: ""); let addMenu = NSMenu(); let missing = allSources.filter { !sources.contains($0) }; if missing.isEmpty { let note = NSMenuItem(title: "All agents shown", action: nil, keyEquivalent: ""); note.isEnabled = false; addMenu.addItem(note) } else { for candidate in missing { let item = NSMenuItem(title: name(candidate), action: #selector(addAgent(_:)), keyEquivalent: ""); item.target = self; item.representedObject = candidate; addMenu.addItem(item) } }; add.submenu = addMenu; m.addItem(add); m.addItem(.separator()); let choose = NSMenuItem(title: "Choose logo…", action: #selector(choose(_:)), keyEquivalent: ""); choose.target = self; choose.representedObject = source; m.addItem(choose); let clear = NSMenuItem(title: "Use initial instead", action: #selector(clear(_:)), keyEquivalent: ""); clear.target = self; clear.representedObject = source; m.addItem(clear); let reveal = NSMenuItem(title: "Reveal status file", action: #selector(reveal(_:)), keyEquivalent: ""); reveal.target = self; reveal.representedObject = source; m.addItem(reveal); m.addItem(.separator()); let f = NSMenuItem(title: "Play failure sound", action: #selector(toggleFailure), keyEquivalent: ""); f.target = self; f.state = pref("playFailureSound") ? .on : .off; m.addItem(f); let p = NSMenuItem(title: "Play input-request sound", action: #selector(toggleInput), keyEquivalent: ""); p.target = self; p.state = pref("playInputSound") ? .on : .off; m.addItem(p); m.addItem(.separator()); let auto = NSMenuItem(title: "Start at Login", action: #selector(toggleAutoStart), keyEquivalent: ""); auto.target = self; auto.state = SMAppService.mainApp.status == .enabled ? .on : .off; m.addItem(auto); m.addItem(.separator()); let close = NSMenuItem(title: "Close \(name(source)) indicator", action: #selector(closeSelf(_:)), keyEquivalent: ""); close.target = self; close.representedObject = source; close.isEnabled = sources.count > 1; m.addItem(close); let quit = NSMenuItem(title: "Quit Agent Status Light", action: #selector(quit), keyEquivalent: "q"); quit.target = self; m.addItem(quit); items[source]?.menu = m; sender.performClick(nil); items[source]?.menu = nil }
    @objc private func addAgent(_ sender: NSMenuItem) { guard let source = sender.representedObject as? String, !sources.contains(source) else { return }; sources.append(source); UserDefaults.standard.set(sources, forKey: "visibleSources"); makeItem(source) }
    @objc private func closeSelf(_ sender: NSMenuItem) { guard let source = sender.representedObject as? String, sources.count > 1 else { return }; sources.removeAll { $0 == source }; UserDefaults.standard.set(sources, forKey: "visibleSources"); if let item = items.removeValue(forKey: source) { NSStatusBar.system.removeStatusItem(item) }; let ids = buttonSources.filter { $0.value == source }.map(\.key); for id in ids { buttonSources.removeValue(forKey: id) }; states.removeValue(forKey: source); players.removeValue(forKey: source); pings.removeValue(forKey: source) }
    @objc private func reveal(_ sender: NSMenuItem) { guard let source = sender.representedObject as? String else { return }; let url = directory.appendingPathComponent("status.\(source).json"); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); if !FileManager.default.fileExists(atPath: url.path) { writeState(source, states[source] ?? .off) }; NSWorkspace.shared.activateFileViewerSelecting([url]) }
    private func writeState(_ source: String, _ state: AgentState) { let d = JSONEncoder(); d.dateEncodingStrategy = .iso8601; let record = StatusRecord(state: state, updatedAt: Date(), source: source); guard let data = try? d.encode(record) else { return }; try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try? data.write(to: directory.appendingPathComponent("status.\(source).json"), options: .atomic) }
    @objc private func choose(_ s: NSMenuItem) { guard let source = s.representedObject as? String else { return }; let p = NSOpenPanel(); p.allowedFileTypes = ["png", "icns", "jpg", "jpeg", "tiff"]; if p.runModal() == .OK, let u = p.url { UserDefaults.standard.set(u.path, forKey: "iconPath.\(source)"); render(source) } }
    @objc private func clear(_ s: NSMenuItem) { if let source = s.representedObject as? String { UserDefaults.standard.removeObject(forKey: "iconPath.\(source)"); render(source) } }
    @objc private func toggleFailure() { UserDefaults.standard.set(!pref("playFailureSound"), forKey: "playFailureSound") }; @objc private func toggleInput() { UserDefaults.standard.set(!pref("playInputSound"), forKey: "playInputSound") }; @objc private func quit() { NSApp.terminate(nil) }
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
    private func render(_ source: String) { guard let b = items[source]?.button else { return }; let state = states[source] ?? .off; let image = NSImage(size: NSSize(width: 20, height: 18)); image.lockFocus(); let a = state == .working ? 0.45 + (sin(pulse) + 1) * 0.275 : 1.0; if let path = UserDefaults.standard.string(forKey: "iconPath.\(source)"), let logo = NSImage(contentsOfFile: path) { logo.draw(in: NSRect(x: 2, y: 2, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: a) } else { state.color.withAlphaComponent(a).setFill(); NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14)).fill(); (initial(source) as NSString).draw(at: NSPoint(x: 6, y: 3), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: NSColor.white]) }; image.unlockFocus(); b.image = image; b.toolTip = "\(name(source)): \(state.title)" }
    private func ping(_ source: String) { pings[source] = NSSound(named: NSSound.Name("Ping")); if pings[source]?.play() != true { NSSound.beep() } }
    private func failure(_ source: String) { let rate = 44100, count = Int(Double(rate) * 0.58); var samples = [Int16](repeating: 0, count: count); let notes = [(0.0, 0.24, 494.0), (0.29, 0.25, 370.0)]; for i in samples.indices { let t = Double(i) / Double(rate); var v = 0.0; for (s,l,f) in notes where t >= s && t < s+l { let n=t-s; let e=min(n/0.018,1)*min((s+l-t)/0.075,1); let q=2*Double.pi*f*n; v += e*(sin(q)+0.32*sin(2*q)+0.12*sin(3*q)) }; samples[i]=Int16(max(-1,min(1,v*0.38))*Double(Int16.max)) }; var d=Data(); func put<T:FixedWidthInteger>(_ x:T){var y=x.littleEndian; withUnsafeBytes(of:&y){d.append(contentsOf:$0)}}; let z=UInt32(samples.count*2); d.append("RIFF".data(using:.ascii)!); put(UInt32(36)+z); d.append("WAVEfmt ".data(using:.ascii)!); put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(rate)); put(UInt32(rate*2)); put(UInt16(2)); put(UInt16(16)); d.append("data".data(using:.ascii)!); put(z); for x in samples {put(x)}; do {players[source]=try AVAudioPlayer(data:d); players[source]?.volume=0.65; players[source]?.play()} catch {NSSound.beep()} }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory); let delegate = AppDelegate(); app.delegate = delegate; app.run()
