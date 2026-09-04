import AppKit
import AVFoundation
import Foundation

enum AgentState: String, Codable, CaseIterable {
    case working, completed, failed, awaitingInput = "awaiting-input", off

    var title: String {
        switch self {
        case .working: "Working"
        case .completed: "Task completed"
        case .failed: "Tool call failed"
        case .awaitingInput: "Input required"
        case .off: "Off"
        }
    }

    var color: NSColor {
        switch self {
        case .working: .systemYellow
        case .completed: .systemGreen
        case .failed: .systemRed
        case .awaitingInput: .systemOrange
        case .off: .secondaryLabelColor
        }
    }
}

struct StatusRecord: Codable {
    var state: AgentState
    var updatedAt: Date
    var source: String?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let completedDisplayDuration: TimeInterval = 20
    private let failureSoundPreferenceKey = "playFailureSound"
    private let inputSoundPreferenceKey = "playInputSound"
    private var item: NSStatusItem!
    private var state: AgentState = .off
    private var pulse = 0.0
    private var shouldPlayStateSounds = false
    private var failureSoundPlayer: AVAudioPlayer?
    private var inputSound: NSSound?
    private var pulseTimer: Timer?
    private var stateTimer: Timer?
    private let statusURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentStatusLight/status.json")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A fixed width avoids AppKit collapsing an image-only, accessory-app
        // status item to zero width on newer macOS releases.
        item = NSStatusBar.system.statusItem(withLength: 32)
        item.isVisible = true
        item.button?.title = " AI"
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel("Agent Status Light")
        item.button?.target = self
        item.button?.action = #selector(showMenu)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setState(readState(), persist: false)
        // A missing state file resolves to `.off`, which is also the initial
        // value. Render anyway so a first launch always has a visible item.
        renderIcon()
        shouldPlayStateSounds = true

        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advancePulse()
            }
        }
        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setState(self.readState(), persist: false)
            }
        }
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        let headline = NSMenuItem(title: "Agent Status: \(state.title)", action: nil, keyEquivalent: "")
        headline.isEnabled = false
        menu.addItem(headline)
        menu.addItem(.separator())
        for candidate in AgentState.allCases {
            let action = #selector(selectState(_:))
            let menuItem = NSMenuItem(title: candidate.title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = candidate.rawValue
            menuItem.state = candidate == state ? .on : .off
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let failureSound = NSMenuItem(title: "Play failure sound", action: #selector(toggleFailureSound), keyEquivalent: "")
        failureSound.target = self
        failureSound.state = failureSoundEnabled ? .on : .off
        menu.addItem(failureSound)
        let inputSound = NSMenuItem(title: "Play input-request sound", action: #selector(toggleInputSound), keyEquivalent: "")
        inputSound.target = self
        inputSound.state = inputSoundEnabled ? .on : .off
        menu.addItem(inputSound)
        let location = NSMenuItem(title: "Reveal status file", action: #selector(revealStatusFile), keyEquivalent: "")
        location.target = self
        menu.addItem(location)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Status Light", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let selected = AgentState(rawValue: raw) else { return }
        setState(selected, persist: true)
    }

    @objc private func revealStatusFile() {
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: statusURL.path) { persistState() }
        NSWorkspace.shared.activateFileViewerSelecting([statusURL])
    }

    @objc private func toggleFailureSound() {
        failureSoundEnabled.toggle()
    }

    @objc private func toggleInputSound() {
        inputSoundEnabled.toggle()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func readState() -> AgentState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: statusURL),
              let record = try? decoder.decode(StatusRecord.self, from: data) else { return state }
        if record.state == .completed,
           Date().timeIntervalSince(record.updatedAt) >= completedDisplayDuration {
            return .off
        }
        return record.state
    }

    private func setState(_ newState: AgentState, persist: Bool) {
        guard state != newState || persist else { return }
        let previousState = state
        state = newState
        renderIcon()
        if shouldPlayStateSounds,
           newState != previousState {
            if newState == .failed, failureSoundEnabled {
                playFailureSound()
            } else if newState == .awaitingInput, inputSoundEnabled {
                playInputSound()
            }
        }
        if persist { persistState() }
    }

    private var failureSoundEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: failureSoundPreferenceKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: failureSoundPreferenceKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: failureSoundPreferenceKey) }
    }

    private var inputSoundEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: inputSoundPreferenceKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: inputSoundPreferenceKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: inputSoundPreferenceKey) }
    }

    private func playFailureSound() {
        do {
            failureSoundPlayer = try AVAudioPlayer(data: makeFailureSound())
            failureSoundPlayer?.volume = 0.65
            failureSoundPlayer?.play()
        } catch {
            NSSound.beep()
        }
    }

    private func playInputSound() {
        inputSound = NSSound(named: NSSound.Name("Ping"))
        if inputSound?.play() != true {
            NSSound.beep()
        }
    }

    /// An original, two-note descending alert. It is synthesized locally rather
    /// than copied from or derived from a third-party sound recording.
    private func makeFailureSound() -> Data {
        let sampleRate = 44_100
        let duration = 0.58
        let sampleCount = Int(Double(sampleRate) * duration)
        let notes: [(start: Double, length: Double, frequency: Double)] = [
            (0.00, 0.24, 494.0),
            (0.29, 0.25, 370.0),
        ]
        var samples = [Int16](repeating: 0, count: sampleCount)

        for index in samples.indices {
            let time = Double(index) / Double(sampleRate)
            var value = 0.0
            for note in notes where time >= note.start && time < note.start + note.length {
                let noteTime = time - note.start
                let attack = min(noteTime / 0.018, 1.0)
                let release = min((note.start + note.length - time) / 0.075, 1.0)
                let envelope = attack * release
                let phase = 2.0 * Double.pi * note.frequency * noteTime
                // A small harmonic blend gives the tones a friendly, voiced quality.
                value += envelope * (sin(phase) + 0.32 * sin(phase * 2.0) + 0.12 * sin(phase * 3.0))
            }
            samples[index] = Int16(max(-1.0, min(1.0, value * 0.38)) * Double(Int16.max))
        }

        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)
        wav.append("RIFF".data(using: .ascii)!)
        append(UInt32(36) + dataSize)
        wav.append("WAVEfmt ".data(using: .ascii)!)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * MemoryLayout<Int16>.size))
        append(UInt16(MemoryLayout<Int16>.size))
        append(UInt16(16))
        wav.append("data".data(using: .ascii)!)
        append(dataSize)
        for sample in samples { append(sample) }
        return wav
    }

    private func persistState() {
        let record = StatusRecord(state: state, updatedAt: Date(), source: "menu-bar")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: statusURL, options: .atomic)
    }

    private func advancePulse() {
        guard state == .working else { return }
        pulse += 0.24
        renderIcon()
    }

    private func renderIcon() {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let alpha = state == .working ? 0.45 + (sin(pulse) + 1) * 0.275 : 1.0
        state.color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14)).fill()
        image.unlockFocus()
        image.isTemplate = false
        item.button?.image = image
        item.button?.toolTip = "Agent Status Light: \(state.title)"
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
