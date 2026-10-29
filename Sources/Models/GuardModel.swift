import AppKit
import SwiftUI
import AVFoundation
import Combine

@MainActor
final class GuardModel: ObservableObject {
    @Published private(set) var localizer = Localizer()
    @Published var languageMode: LanguageMode = .system {
        didSet {
            localizer.mode = languageMode
            UserDefaults.standard.set(languageMode.rawValue, forKey: "appLanguage")
            warningVoice?.stop(); warningVoice = nil
            onChange?()
        }
    }
    private var localeObserver: NSObjectProtocol?
    func t(_ key: String, _ arguments: String...) -> String { localizer.text(key, arguments) }
    func text(_ message: LocalizedMessage) -> String { localizer.text(message) }
    var statusText: String { text(status) }
    var motionText: String { motionStatus == "motion.approaching" ? t(motionStatus, String(Int(approachProgress * 100))) : t(motionStatus) }
    @Published var enabled = false
    @Published var starting = false
    @Published var status: LocalizedMessage = "status.paused"
    @Published var error: LocalizedMessage?
    @Published var span = 0.0
    @Published var handCount = 0
    @Published var motionStatus = "motion.waiting"
    @Published var approachProgress = 0.0
    @Published var recoveries = 0
    @Published var replaying = false
    private var replayTimer: Timer?
    @Published var sensitivity = 0.55 {
        didSet { gate.threshold = threshold; gate.requiredGrowth = 1.35 - sensitivity * 0.21; UserDefaults.standard.set(sensitivity, forKey: "sensitivity") }
    }
    @Published var customImage: NSImage?
    @Published var customName: String?
    @Published var sound = false {
        didSet {
            if !sound { warningVoice?.stop() }
            UserDefaults.standard.set(sound, forKey: "soundEnabled")
        }
    }
    private var warningVoice: NSSound?
    @Published var voiceVariant = 0 {
        didSet {
            warningVoice?.stop(); warningVoice = nil
            UserDefaults.standard.set(voiceVariant, forKey: "voiceVariant")
        }
    }
    @Published var triggers = 0
    let camera = CameraEngine()
    let diagnostics = LiveDiagnostics()
    var overlay: NSWindow?
    private var returnToApp: NSRunningApplication?
    var previewTimer: Timer?
    var watchdog: Timer?
    private var startupTimer: Timer?
    private var lastFrameAt = 0.0
    var isPreview = false
    var epoch = 0
    var gate = DetectionGate()
    private var sceneOcclusion = SceneOcclusion()
    var onChange: (() -> Void)?
    var threshold: Double { 0.25 - sensitivity * 0.12 }
    var now: Double { ProcessInfo.processInfo.systemUptime }

    init() {
        languageMode = LanguageMode(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system
        localizer.mode = languageMode
        localeObserver = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.localizer.preferredLanguages = Locale.preferredLanguages
                if self.languageMode == .system { self.warningVoice?.stop(); self.warningVoice = nil }
                self.onChange?()
            }
        }
        if UserDefaults.standard.object(forKey: "soundEnabled") != nil {
            sound = UserDefaults.standard.bool(forKey: "soundEnabled")
        }
        if UserDefaults.standard.object(forKey: "voiceVariant") != nil {
            voiceVariant = min(2, max(0, UserDefaults.standard.integer(forKey: "voiceVariant")))
        }
        if UserDefaults.standard.object(forKey: "sensitivity") != nil {
            sensitivity = min(1, max(0, UserDefaults.standard.double(forKey: "sensitivity")))
        }
        gate.threshold = threshold
        gate.requiredGrowth = 1.35 - sensitivity * 0.21
        camera.onFrame = { [weak self] frame in self?.receive(frame) }
        camera.onStage = { [weak self] message, id in
            guard let self, self.enabled, self.starting, self.epoch == id else { return }
            self.status = LocalizedMessage(message)
        }
        camera.onReady = { [weak self] id in
            guard let self, self.enabled, self.epoch == id else { return }
            self.startupTimer?.invalidate(); self.startupTimer = nil
            self.starting = false; self.status = "status.active"; self.onChange?()
            self.lastFrameAt = self.now
            self.watchdog?.invalidate()
            self.watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.enabled, !self.starting else { return }
                    if self.now - self.lastFrameAt > 5 {
                        self.fail("error.cameraNoFrames")
                    }
                }
            }
        }
        camera.onError = { [weak self] message, id in
            guard let self, self.enabled, self.epoch == id else { return }
            self.fail(message)
        }
    }

    func toggle() { enabled ? stop() : start() }

    func start() {
        guard !enabled else { return }
        error = nil; enabled = true; starting = true; status = "status.preparing"
        epoch += 1
        let id = epoch
        sceneOcclusion.reset(); gate.reset(now: now)
        onChange?()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCamera(epoch: id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.enabled, self.epoch == id else { return }
                    if granted { self.startCamera(epoch: id) }
                    else { self.fail("error.cameraPermission") }
                }
            }
        default: fail("error.cameraDenied")
        }
    }

    private func startCamera(epoch id: Int) {
        camera.start(epoch: id)
        startupTimer?.invalidate()
        startupTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled, self.starting, self.epoch == id else { return }
                self.fail("error.cameraTimeout")
            }
        }
    }

    func stop() {
        warningVoice?.stop()
        replayTimer?.invalidate(); replayTimer = nil; replaying = false
        epoch += 1; enabled = false; starting = false; status = "status.paused"
        camera.stop(); watchdog?.invalidate(); watchdog = nil
        startupTimer?.invalidate(); startupTimer = nil
        span = 0; handCount = 0; approachProgress = 0; motionStatus = "motion.waiting"; sceneOcclusion.reset(); gate.reset(now: now)
        hideOverlay(); onChange?()
    }

    func fail(_ message: LocalizedMessage) { stop(); error = message }

    func receive(_ frame: HandFrame, recordedOcclusion: Bool? = nil) {
        guard enabled, frame.epoch == epoch, !starting else { return }
        lastFrameAt = now
        span = frame.span; handCount = frame.recognizedCount
        guard !isPreview else { return }
        var occlusion = sceneOcclusion.observe(frame.scene, hands: frame.hands, now: frame.timestamp)
        if replaying, let recordedOcclusion { occlusion.present = recordedOcclusion }
        let event = gate.ingest(hands: frame.hands, now: frame.timestamp, nearOcclusion: occlusion.present)
        if event == .show, let hand = gate.protectedHand {
            sceneOcclusion.begin(hand: hand, now: frame.timestamp)
        } else if event == .hide {
            sceneOcclusion.end()
        } else if let hand = gate.protectedHand {
            sceneOcclusion.follow(hand: hand)
        }
        motionStatus = gate.reason; approachProgress = gate.progress
        if frame.recognizedCount > 0 && frame.hands.isEmpty && !gate.visible {
            motionStatus = "camera.occluded"
        }
        diagnostics.record(frame: frame, gate: gate, event: event, occlusion: occlusion)
        if let event {
            if event == .show { triggers += 1; showOverlay(preview: false) }
            else { recoveries += 1; hideOverlay() }
        }
    }

    // Integration-test entry point; never opens a camera or loads video.
    func replayRecordedCamera(_ url: URL) {
        stop()
        do {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
            var frames: [(Double, [HandMeasurement], Bool)] = []
            for line in lines {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let metrics = object["metrics"] as? [String: Double], let time = metrics["elapsed"],
                      let records = object["hands"] as? [[String: Any]] else { continue }
                let hands = records.compactMap { raw -> HandMeasurement? in
                    guard let x = raw["x"] as? Double, let y = raw["y"] as? Double,
                          let width = raw["width"] as? Double, let length = raw["length"] as? Double,
                          let side = raw["side"] as? Int else { return nil }
                    let pose = Dictionary(uniqueKeysWithValues: (raw["pose"] as? [String: [Double]] ?? [:]).compactMap { k, v -> (Int, HandPoint)? in
                        guard let key = Int(k), v.count == 2 else { return nil }
                        return (key, HandPoint(x: v[0], y: v[1]))
                    })
                    return HandMeasurement(x: x, y: y, width: width, length: length, side: side, pose: pose)
                }
                frames.append((time, hands, metrics["occlusionPresent"] == 1))
            }
            guard let firstHand = frames.first(where: { !$0.1.isEmpty })?.0 else {
                error = "error.replayEmpty"; return
            }
            frames.removeAll { $0.0 < firstHand - 1 }
            guard let origin = frames.first?.0 else { return }
            let started = now
            enabled = true; replaying = true; triggers = 0; recoveries = 0
            status = "status.replay"
            sceneOcclusion.reset(); gate.reset(now: started)
            var index = 0
            replayTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, self.replaying else { timer.invalidate(); return }
                    let elapsed = self.now - started
                    while index < frames.count && frames[index].0 - origin <= elapsed {
                        let (time, hands, occlusion) = frames[index]
                        self.receive(HandFrame(hands: hands, recognizedCount: hands.count, reliablePointCount: hands.map { $0.pose.count }.max() ?? 0, timestamp: started + time - origin, epoch: self.epoch), recordedOcclusion: occlusion)
                        index += 1
                    }
                    if index == frames.count {
                        timer.invalidate(); self.replayTimer = nil
                        self.hideOverlay(); self.enabled = false; self.replaying = false
                        self.status = LocalizedMessage("status.replayDone", [String(self.triggers), String(self.recoveries)])
                        self.onChange?()
                        print("CAMERA_REPLAY_RESULT triggers=\(self.triggers) recoveries=\(self.recoveries)")
                        fflush(stdout)
                    }
                }
            }
            onChange?()
        } catch { self.error = LocalizedMessage("error.replayRead", [error.localizedDescription]) }
    }

    func playWarningVoice(force: Bool = false) {
        guard sound || force else { return }
        let resource = localizer.language.voiceCode + "-" + ["a", "b", "c"][min(2, max(0, voiceVariant))]
        if warningVoice == nil, let url = Bundle.main.url(forResource: resource, withExtension: "wav", subdirectory: "Voices") {
            warningVoice = NSSound(contentsOf: url, byReference: false)
        }
        guard let warningVoice else { error = "error.voiceLoad"; return }
        warningVoice.stop()
        if !warningVoice.play() { error = "error.voicePlay" }
    }

    func preview() { showOverlay(preview: true) }

    func showOverlay(preview: Bool) {
        hideOverlay()
        if let previous = NSWorkspace.shared.frontmostApplication,
           previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            returnToApp = previous
        }
        isPreview = preview
        // The camera belongs to the built-in display. Fall back to the main display on desktops.
        let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let window = WarningWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView: WarningScreen(model: self, preview: preview))
        window.onEscape = { [weak self] in self?.dismissWarning() }
        overlay = window
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        playWarningVoice()
        if preview {
            previewTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissPreview() }
            }
        }
    }

    func hideOverlay() {
        previewTimer?.invalidate(); previewTimer = nil
        let hadOverlay = overlay != nil
        overlay?.orderOut(nil); overlay?.close(); overlay = nil
        isPreview = false
        if hadOverlay, let previous = returnToApp, !previous.isTerminated {
            previous.activate(options: [])
        }
        returnToApp = nil
    }

    func dismissPreview() { hideOverlay(); sceneOcclusion.reset(); gate.reset(now: now, cooldown: 2) }

    func dismissWarning() {
        warningVoice?.stop()
        if isPreview { dismissPreview() }
        else { stop() } // Escape is always an emergency pause, never an immediate retrigger.
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = t("image.title")
        panel.prompt = t("image.prompt")
        panel.message = t("image.message")
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            customImage = image; customName = url.lastPathComponent
        }
    }
}
