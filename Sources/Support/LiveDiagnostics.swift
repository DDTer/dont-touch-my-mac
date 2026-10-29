import Foundation

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
