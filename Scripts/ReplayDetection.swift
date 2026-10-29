import Foundation

// Replays local diagnostic landmarks. Neither video nor landmarks enter the report.
@main
struct ReplayDetection {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: replay_detection.sh input.jsonl output.json\n", stderr); exit(2)
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard input.standardizedFileURL != output.standardizedFileURL else {
            fputs("Input and output must be different files.\n", stderr); exit(2)
        }
        let rows = try String(contentsOf: input, encoding: .utf8).split(separator: "\n")
        var gate = DetectionGate(), events: [[String:Any]] = []
        var samples = 0, usable = 0
        for row in rows {
            guard let object = try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String:Any],
                  let rawHands = object["hands"] as? [[String:Any]],
                  let metrics = object["metrics"] as? [String:Double],
                  let time = metrics["elapsed"], time.isFinite else { continue }
            let hands = rawHands.compactMap { raw -> HandMeasurement? in
                guard let x=raw["x"] as? Double, let y=raw["y"] as? Double,
                      let width=raw["width"] as? Double, let length=raw["length"] as? Double,
                      let side=raw["side"] as? Int else { return nil }
                let pose = Dictionary(uniqueKeysWithValues: (raw["pose"] as? [String:[Double]] ?? [:]).compactMap { key,value -> (Int,HandPoint)? in
                    guard let index=Int(key), value.count == 2 else { return nil }
                    return (index,HandPoint(x:value[0],y:value[1]))
                })
                return HandMeasurement(x:x,y:y,width:width,length:length,side:side,pose:pose)
            }
            gate.threshold = metrics["threshold"] ?? 0.184
            let sensitivity = min(1,max(0,(0.25 - gate.threshold)/0.12))
            gate.requiredGrowth = 1.35 - sensitivity * 0.21
            if let event = gate.ingest(hands:hands,now:time,nearOcclusion:metrics["occlusionPresent"] == 1) {
                events.append(["time":time,"event":event == .show ? "show":"hide"])
            }
            samples += 1
            if !hands.isEmpty { usable += 1 }
        }
        guard samples > 0 else { fputs("No valid diagnostic frames.\n", stderr); exit(2) }
        let report: [String:Any] = ["algorithm":"0.10", "samples":samples, "framesWithHands":usable, "events":events,
            "limitation":"Unlabeled landmark replay does not establish live recall, false-positive rate or camera latency."]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:output,options:.atomic)
        print("Replayed \(samples) frames; \(events.count) transitions. Summary saved.")
    }
}
