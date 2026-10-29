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
    var scene: SceneSignature?
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
                    guard let point = points[name], point.confidence >= 0.20 else { continue }
                    pose[i] = HandPoint(x: point.location.x * aspect, y: point.location.y)
                }
                reliablePointCount = max(reliablePointCount, pose.count)
                guard pose.count >= 2 else { continue }
                let xs = pose.values.map { $0.x }, ys = pose.values.map { $0.y }
                let width = max(0.04, (xs.max() ?? 0) - (xs.min() ?? 0))
                let height = max(0.04, (ys.max() ?? 0) - (ys.min() ?? 0))
                let side: Int = hand.chirality == .left ? 1 : hand.chirality == .right ? 2 : 0
                hands.append(HandMeasurement(x: xs.reduce(0,+) / Double(xs.count), y: ys.reduce(0,+) / Double(ys.count), width: width, length: height, side: side, pose: pose))
            }
            let scene = buffer.flatMap { sceneSignature($0) }
            let frame = HandFrame(hands: hands, recognizedCount: request.results?.count ?? 0, reliablePointCount: reliablePointCount, timestamp: now, epoch: epoch, processingSeconds: ProcessInfo.processInfo.systemUptime - now, scene: scene)
            DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
        } catch {
            report(LocalizedMessage("error.handDetection", [error.localizedDescription]))
        }
    }
    private func sceneSignature(_ buffer: CVPixelBuffer) -> SceneSignature? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width=CVPixelBufferGetWidth(buffer), height=CVPixelBufferGetHeight(buffer)
        guard width > 0 && height > 0 else { return nil }
        let stride=CVPixelBufferGetBytesPerRow(buffer), bytes=base.assumingMemoryBound(to:UInt8.self)
        let columns=48, rows=36
        var rgb=[UInt8](repeating:0,count:columns*rows*3)
        for y in 0..<rows { for x in 0..<columns {
            for c in 0..<3 {
                var sum=0
                for (dx,dy) in [(0.25,0.25),(0.75,0.25),(0.25,0.75),(0.75,0.75)] {
                    let px=min(width-1,Int((Double(x)+dx)*Double(width)/Double(columns)))
                    let py=min(height-1,Int((Double(y)+dy)*Double(height)/Double(rows)))
                    sum += Int(bytes[py*stride+px*4+(2-c)])
                }
                rgb[(y*columns+x)*3+c]=UInt8(sum/4)
            }
        } }
        return SceneSignature(columns:columns,rows:rows,aspect:Double(width)/Double(height),rgb:rgb)
    }

}
