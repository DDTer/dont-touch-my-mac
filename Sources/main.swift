import AppKit
import SwiftUI
import AVFoundation
import Combine

let lime = Color(red: 0.79, green: 0.98, blue: 0.29)
let ink = Color(red: 0.055, green: 0.065, blue: 0.065)
let muted = Color(red: 0.57, green: 0.61, blue: 0.59)

final class LiveDiagnostics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.localdemo.donttouch.diagnostics")
    private var file: FileHandle?
    private var count = 0
    private let started = ProcessInfo.processInfo.systemUptime
    init() {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("camera-diagnostics.enabled").path) else { return }
        let url = folder.appendingPathComponent("live-diagnostics.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }
    func record(frame: HandFrame, gate: DetectionGate, event: DetectionGate.Event?, occlusion: OcclusionEvidence) {
        guard file != nil else { return }
        var metrics = gate.diagnostics.filter { $0.value.isFinite }
        metrics["elapsed"] = frame.timestamp - started
        metrics["visionMilliseconds"] = frame.processingSeconds * 1000
        metrics["deliveryMilliseconds"] = max(0, ProcessInfo.processInfo.systemUptime - frame.timestamp) * 1000
        metrics["occlusionPresent"] = occlusion.present ? 1 : 0
        metrics["occlusionArmed"] = occlusion.armed ? 1 : 0
        metrics["occlusionFraction"] = occlusion.changedFraction
        metrics["occlusionOutside"] = occlusion.outsideFraction
        metrics["occlusionReleaseChange"] = occlusion.foregroundChange
        metrics["occlusionReleased"] = occlusion.released ? 1 : 0
        metrics["recognized"] = Double(frame.recognizedCount)
        metrics["usable"] = Double(frame.hands.count)
        metrics["points"] = Double(frame.reliablePointCount)
        metrics["rawScale"] = frame.span
        metrics["threshold"] = gate.threshold
        metrics["requiredGrowth"] = gate.requiredGrowth
        metrics["visible"] = gate.visible ? 1 : 0
        let replayHands: [[String: Any]] = frame.hands.map { hand in
            ["x": hand.x, "y": hand.y, "width": hand.width, "length": hand.length, "side": hand.side,
             "pose": Dictionary(uniqueKeysWithValues: hand.pose.map { (String($0.key), [$0.value.x, $0.value.y]) })]
        }
        let object: [String: Any] = ["hands": replayHands, "metrics": metrics, "reason": gate.reason, "event": event.map { $0 == .show ? "show" : "hide" } ?? "none"]
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(10)
        queue.async { [self] in
            guard count < 6000 else { return }
            count += 1
            try? file?.write(contentsOf: data)
        }
    }
}

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
            var frames: [(Double,[HandMeasurement],Bool)] = []
            for line in lines {
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let metrics = object["metrics"] as? [String: Double], let time = metrics["elapsed"],
                      let records = object["hands"] as? [[String: Any]] else { continue }
                let hands = records.compactMap { raw -> HandMeasurement? in
                    guard let x = raw["x"] as? Double, let y = raw["y"] as? Double,
                          let width = raw["width"] as? Double, let length = raw["length"] as? Double,
                          let side = raw["side"] as? Int else { return nil }
                    let pose = Dictionary(uniqueKeysWithValues: (raw["pose"] as? [String: [Double]] ?? [:]).compactMap { k,v -> (Int,HandPoint)? in
                        guard let key = Int(k), v.count == 2 else { return nil }
                        return (key, HandPoint(x: v[0], y: v[1]))
                    })
                    return HandMeasurement(x: x, y: y, width: width, length: length, side: side, pose: pose)
                }
                frames.append((time,hands,metrics["occlusionPresent"] == 1))
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
                        let (time,hands,occlusion) = frames[index]
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

final class WarningWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

struct Poster: View {
    @ObservedObject var model: GuardModel
    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, geo.size.height * 1.5)
            ZStack {
                lime
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(model.t("poster.kicker")).font(.system(size: w * 0.022, weight: .bold, design: .monospaced))
                        Spacer()
                        Image(systemName: "hand.raised.fill").font(.system(size: w * 0.033, weight: .bold))
                    }
                    Spacer(minLength: 10)
                    HStack(alignment: .center, spacing: 0) {
                        Text(model.t("poster.title"))
                            .font(.system(size: w * (model.localizer.language == .en ? 0.125 : model.localizer.language == .zh ? 0.14 : 0.105), weight: .black, design: .rounded))
                            .tracking(-w * 0.006).lineSpacing(-w * 0.016)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: w * 0.64, alignment: .leading)
                        Spacer(minLength: 0)
                        Image(systemName: "hand.raised.slash.fill")
                            .font(.system(size: w * 0.23, weight: .black))
                            .rotationEffect(.degrees(-12))
                    }
                    Spacer(minLength: 10)
                    HStack(alignment: .bottom) {
                        Text(model.t("poster.subtitle"))
                            .font(.system(size: w * 0.033, weight: .semibold))
                        Spacer()
                        Text(model.t("poster.thanks"))
                            .font(.system(size: w * 0.016, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                    }
                }.padding(w * 0.055)
                .foregroundStyle(ink)
            }
        }
    }
}

struct WarningScreen: View {
    @ObservedObject var model: GuardModel
    let preview: Bool
    var body: some View {
        ZStack(alignment: .bottom) {
            if let image = model.customImage {
                Color.black
                Image(nsImage: image).resizable().scaledToFit().padding(.bottom, 52)
            } else { Poster(model: model) }
            HStack(spacing: 8) {
                Circle().fill(lime).frame(width: 6, height: 6)
                Text(model.t(model.replaying ? "status.replay" : preview ? "guard.previewFooter" : "guard.retract"))
                Text("·").foregroundStyle(.gray)
                Button(model.t(preview ? "guard.escapeClose" : "guard.escapePause")) { model.dismissWarning() }
                    .buttonStyle(.plain).fontWeight(.semibold)
            }
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.black.opacity(0.9), in: Capsule())
            .padding(.bottom, 20)
        }.ignoresSafeArea()
    }
}

final class PreviewSurface: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); preview.frame = bounds }
}
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.preview.session = session
        if let connection = view.preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        return view
    }
    func updateNSView(_ nsView: PreviewSurface, context: Context) {}
}

struct MainScreen: View {
    @ObservedObject var model: GuardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(spacing: 11) {
                Image(systemName: "hand.raised.slash.fill").font(.system(size: 23, weight: .semibold)).foregroundStyle(lime)
                VStack(alignment: .leading, spacing: 4) {
                    Text("don’t touch my MAC!").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(model.t("app.tagline")) .font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("V" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.10.2")).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(muted)
                    Picker(model.t("language.label"), selection: $model.languageMode) {
                        ForEach(LanguageMode.allCases) { mode in
                            Text(model.localizer.modeName(mode)).tag(mode)
                        }
                    }.pickerStyle(.menu).controlSize(.small).frame(width: 205)
                }
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Group {
                        if let image = model.customImage {
                            ZStack { Color.black; Image(nsImage: image).resizable().scaledToFit() }
                        } else { Poster(model: model) }
                    }
                    .frame(height: 310).clipShape(RoundedRectangle(cornerRadius: 12))
                    HStack {
                        Label(model.t("image.caption"), systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11)).foregroundStyle(muted)
                        Spacer()
                        Button(model.t("image.change")) { model.chooseImage() }.buttonStyle(.plain).foregroundStyle(lime).font(.system(size: 11, weight: .medium))
                        if model.customImage != nil {
                            Button(model.t("image.reset")) { model.customImage = nil; model.customName = nil }
                                .buttonStyle(.plain).foregroundStyle(muted).font(.system(size: 11))
                        }
                    }
                    if let name = model.customName {
                        Text(name).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text(model.t("privacy.local"))
                    }.font(.system(size: 10)).foregroundStyle(muted).padding(.top, 5)
                }.frame(width: 435)
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 7) {
                        Circle().fill(model.enabled ? lime : muted).frame(width: 6, height: 6)
                        Text(model.t(model.starting ? "status.starting" : model.enabled ? "status.on" : "status.off"))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(model.enabled ? lime : muted)
                    }
                    Text(model.statusText).font(.system(size: 18, weight: .semibold))
                    Text(model.t("guard.instructions"))
                        .font(.system(size: 12)).foregroundStyle(muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                    Button(action: { model.toggle() }) {
                        HStack {
                            Image(systemName: model.enabled ? "pause.fill" : "hand.raised.fill")
                            Text(model.t(model.enabled ? "guard.pause" : "guard.enable"))
                        }.font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(ink).background(lime, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                    Button(action: { model.preview() }) {
                        Label(model.t("guard.preview"), systemImage: "play.rectangle")
                            .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.09)))
                    }.buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.08))
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(model.t("sensitivity.label")); Spacer(); Text(model.t(model.sensitivity > 0.7 ? "sensitivity.high" : model.sensitivity < 0.3 ? "sensitivity.low" : "sensitivity.medium")).foregroundStyle(muted) }
                            .font(.system(size: 11))
                        Slider(value: $model.sensitivity, in: 0...1).tint(lime)
                        Text(model.t("sensitivity.hint"))
                            .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Toggle(model.t("voice.enable"), isOn: $model.sound).toggleStyle(.checkbox).font(.system(size: 11)).tint(lime)
                        Spacer(minLength: 4)
                        Picker(model.t("voice.label"), selection: $model.voiceVariant) {
                            Text(model.t("voice.variant", "A")).tag(0)
                            Text(model.t("voice.variant", "B")).tag(1)
                            Text(model.t("voice.variant", "C")).tag(2)
                        }.labelsHidden().pickerStyle(.menu).controlSize(.mini).frame(width: 88)
                        Button(model.t("voice.audition")) { model.playWarningVoice(force: true) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(lime)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 16) {
                ZStack {
                    Color.black.opacity(0.3)
                    if model.enabled && !model.starting && !model.replaying {
                        CameraPreview(session: model.camera.session)
                    } else {
                        Image(systemName: "video.slash").font(.system(size: 20)).foregroundStyle(muted)
                    }
                }.frame(width: 130, height: 73).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.replaying ? model.t("camera.replayOff") : model.enabled ? model.motionText : model.t("camera.off"))
                        .font(.system(size: 11, weight: .medium))
                    Text(model.enabled ? model.t("camera.counts", String(model.handCount), String(model.triggers), String(model.recoveries)) : model.t("camera.permissionHint"))
                        .font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(lime).frame(width: max(0, g.size.width * model.approachProgress))
                                Rectangle().fill(.white.opacity(0.7)).frame(width: 1).offset(x: g.size.width)
                            }
                        }.frame(height: 4)
                        Text("\(Int(model.approachProgress * 100))%")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(muted).frame(width: 45)
                    }.frame(maxWidth: 260)
                }
                Spacer()
                Text(model.t("guard.shortcuts"))
                    .font(.system(size: 10)).foregroundStyle(muted).lineSpacing(5).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }.padding(13).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle")
                    Text(model.text(error)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(model.t("settings.open")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }.buttonStyle(.plain).foregroundStyle(lime)
                }.font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.72, blue: 0.45))
            }
        }
        .padding(25).frame(width: 790)
        .foregroundStyle(Color.white.opacity(0.93)).background(ink)
        .preferredColorScheme(.dark)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = GuardModel()
    var mainWindow: NSWindow!
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var subscriptions: [AnyCancellable] = []
    var sleepObserver: NSObjectProtocol?
    var lockObserver: NSObjectProtocol?
    var localizedMenuItems: [(NSMenuItem, String)] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let root = MainScreen(model: model)
        let host = NSHostingController(rootView: root)
        mainWindow = NSWindow(contentViewController: host)
        mainWindow.title = "Don’t Touch My Mac!"
        mainWindow.styleMask = [.titled, .closable, .miniaturizable]
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.backgroundColor = NSColor(red: 0.055, green: 0.065, blue: 0.065, alpha: 1)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.center()
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu()
        menu.addItem(withTitle: "Don’t Touch My Mac!", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "menu.open", #selector(openMain), "")
        toggleItem = add(menu, "guard.enable", #selector(toggle), "")
        add(menu, "guard.preview", #selector(preview), "")
        menu.addItem(.separator())
        add(menu, "menu.quit", #selector(quit), "q")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.raised.slash", accessibilityDescription: "Don't Touch My Mac")
        statusItem.menu = menu
        model.onChange = { [weak self] in self?.refreshMenus() }
        let appMenu = NSMenu()
        let container = NSMenuItem()
        appMenu.addItem(container)
        let sub = NSMenu()
        add(sub, "menu.about", #selector(openMain), "")
        sub.addItem(.separator())
        add(sub, "menu.quitApp", #selector(quit), "q")
        container.submenu = sub
        NSApp.mainMenu = appMenu
        refreshMenus()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.stop() }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.stop() }
        }
        if let option = CommandLine.arguments.firstIndex(of: "--replay-camera"), CommandLine.arguments.indices.contains(option + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[option + 1])
            DispatchQueue.main.async { [weak self] in self?.model.replayRecordedCamera(url) }
        } else if let path = try? String(contentsOf: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("camera-replay-test.enabled"), encoding: .utf8) {
            let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async { [weak self] in self?.model.replayRecordedCamera(url) }
        }
    }
    @discardableResult func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: model.t(title), action: action, keyEquivalent: key)
        localizedMenuItems.append((item, title))
        item.target = self; menu.addItem(item); return item
    }
    func refreshMenus() {
        for (item, key) in localizedMenuItems { item.title = model.t(key) }
        toggleItem.title = model.t(model.enabled ? "guard.pause" : "guard.enable")
        statusItem.button?.toolTip = model.t(model.enabled ? "status.on" : "status.off")
    }
    @objc func openMain() { mainWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggle() { model.toggle() }
    @objc func preview() { model.preview() }
    @objc func quit() { model.stop(); NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}

if CommandLine.arguments.contains("--self-test") { runGateTests(); runSceneOcclusionTests(); runLocalizationTests(); exit(0) }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
