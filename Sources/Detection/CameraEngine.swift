import AppKit
import AVFoundation
import Vision

struct HandFrame {
    let hands: [HandMeasurement]
    var span: Double { hands.map { $0.scale }.max() ?? 0 }
    var handCount: Int { hands.count }
    let recognizedCount: Int
    let reliablePointCount: Int
    let timestamp: Double
    let epoch: Int
    var processingSeconds = 0.0
}

final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.demo.donttouch.camera", qos: .userInitiated)
    private let request = VNDetectHumanHandPoseRequest()
    private var configured = false
    private var epoch = 0
    private var lastFrame = -Double.infinity
    private var observers: [NSObjectProtocol] = []
    var onFrame: ((HandFrame) -> Void)?
    var onReady: ((Int) -> Void)?
    var onStage: ((String, Int) -> Void)?
    var onError: ((LocalizedMessage, Int) -> Void)?

    override init() {
        super.init()
        request.maximumHandCount = 2
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error).map { LocalizedMessage("error.cameraDetails", [$0.localizedDescription]) } ?? "error.cameraRuntime"
            self?.queue.async { [weak self] in self?.report(message) }
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.report("error.cameraInterrupted") }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func report(_ message: LocalizedMessage) {
        let id = epoch
        DispatchQueue.main.async { [weak self] in self?.onError?(message, id) }
    }
    private func stage(_ message: String) {
        let id = epoch
        DispatchQueue.main.async { [weak self] in self?.onStage?(message, id) }
    }
    func start(epoch: Int) {
        queue.async { [self] in
            self.epoch = epoch; lastFrame = -.infinity
            if !configured {
                stage("camera.connecting")
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                        ?? AVCaptureDevice.default(for: .video) else {
                    report("error.cameraUnavailable"); return
                }
                do {
                    stage("camera.configuring")
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    session.sessionPreset = .medium
                    let output = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration(); report("error.cameraConfiguration"); return
                    }
                    session.addInput(input); session.addOutput(output)
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.commitConfiguration()
                    configured = true
                } catch { report(LocalizedMessage("error.cameraDetails", [error.localizedDescription])); return }
            }
            stage("camera.startingStream")
            if !session.isRunning { session.startRunning() }
            guard session.isRunning else { report("error.cameraStartup"); return }
            DispatchQueue.main.async { [weak self] in self?.onReady?(epoch) }
        }
    }
    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 0.045 else { return }
        lastFrame = now
        do {
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
            try handler.perform([request])
            var hands: [HandMeasurement] = []
            var reliablePointCount = 0
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            let aspect = buffer.map { Double(CVPixelBufferGetWidth($0)) / Double(CVPixelBufferGetHeight($0)) } ?? 1.333
            let names: [VNHumanHandPoseObservation.JointName] = [
                .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
                .indexMCP, .indexPIP, .indexDIP, .indexTip,
                .middleMCP, .middlePIP, .middleDIP, .middleTip,
                .ringMCP, .ringPIP, .ringDIP, .ringTip,
                .littleMCP, .littlePIP, .littleDIP, .littleTip
            ]
            for hand in request.results ?? [] {
                let points = try hand.recognizedPoints(.all)
                var pose: [Int: HandPoint] = [:]
                for (i, name) in names.enumerated() {
                    guard let point = points[name], point.confidence >= 0.25 else { continue }
                    pose[i] = HandPoint(x: point.location.x * aspect, y: point.location.y)
                }
                reliablePointCount = max(reliablePointCount, pose.count)
                guard pose.count >= 6 else { continue }
                let xs = pose.values.map { $0.x }, ys = pose.values.map { $0.y }
                let width = (xs.max() ?? 0) - (xs.min() ?? 0)
                let height = (ys.max() ?? 0) - (ys.min() ?? 0)
                let side: Int = hand.chirality == .left ? 1 : hand.chirality == .right ? 2 : 0
                hands.append(HandMeasurement(x: xs.reduce(0,+) / Double(xs.count), y: ys.reduce(0,+) / Double(ys.count), width: width, length: height, side: side, pose: pose))
            }
            let frame = HandFrame(hands: hands, recognizedCount: request.results?.count ?? 0, reliablePointCount: reliablePointCount, timestamp: now, epoch: epoch, processingSeconds: ProcessInfo.processInfo.systemUptime - now)
            DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
        } catch {
            report(LocalizedMessage("error.handDetection", [error.localizedDescription]))
        }
    }
}
