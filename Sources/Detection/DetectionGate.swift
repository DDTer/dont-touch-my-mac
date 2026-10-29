import Foundation

/// Normalized visible hand geometry. Relative pose consistency distinguishes
/// approaching from spreading fingers; no physical depth is claimed.
struct HandPoint {
    let x: Double
    let y: Double
}
struct HandMeasurement {
    let x: Double
    let y: Double
    let width: Double
    let length: Double
    let side: Int
    var pose: [Int: HandPoint] = [:]
    var scale: Double { sqrt(width * length) }
    var shape: Double { width / max(length, 0.001) }
}

struct DetectionGate {
    enum Event: Equatable { case show, hide }
    struct Sample {
        let time: Double
        let hand: HandMeasurement
    }
    struct Track {
        let id: Int
        var history: [Sample]
        var latest: Sample { history.last! }
    }
    var threshold = 0.184
    var requiredGrowth = 1.2565
    private(set) var visible = false
    private(set) var progress = 0.0
    private(set) var growth = 1.0
    private(set) var reason = "motion.waiting"
    private(set) var diagnostics: [String: Double] = [:]
    private var tracks: [Track] = []
    private var nextID = 0
    private var ownerID: Int?
    private var ownerReference: HandMeasurement?
    private var triggerScale = 0.0
    private var shownAt = -Double.infinity
    private var lastNear = -Double.infinity
    private var cooldownUntil = -Double.infinity
    private var previousTime = -Double.infinity

    mutating func reset(now: Double, cooldown: Double = 0) {
        visible = false; progress = 0; growth = 1; tracks = []
        ownerID = nil; ownerReference = nil; triggerScale = 0
        lastNear = -.infinity; shownAt = -.infinity; previousTime = -.infinity
        cooldownUntil = now + cooldown
        reason = cooldown > 0 ? "motion.cooldown" : "motion.waiting"
    }

    mutating func ingest(hands: [HandMeasurement], now: Double) -> Event? {
        diagnostics = ["frameGap": now - previousTime]
        guard now.isFinite, now > previousTime else { return nil }
        if now - previousTime > 0.35 { tracks.removeAll() }
        previousTime = now
        tracks.removeAll { now - $0.latest.time > (visible && $0.id == ownerID ? 0.65 : 0.30) }
        let valid = hands.filter {
            $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.length.isFinite &&
            $0.width > 0.015 && $0.length > 0.015 && $0.scale < 1.5 &&
            $0.shape > 0.35 && $0.shape < 2.5
        }
        var used = Set<Int>()
        var currentIDs = Set<Int>()
        for hand in valid {
            // A one-to-one match prevents alternating hands from forming a fake approach.
            let match = tracks.indices.filter { i in
                let last = tracks[i].latest.hand
                let distance = hypot(hand.x - last.x, hand.y - last.y)
                return !used.contains(tracks[i].id) &&
                    (hand.side == 0 || last.side == 0 || hand.side == last.side || distance < 0.10) &&
                    distance <= 0.24 && abs(log(hand.scale / last.scale)) < 0.60
            }.min { a, b in
                func cost(_ i: Int) -> Double {
                    let last = tracks[i].latest.hand
                    return hypot(hand.x - last.x, hand.y - last.y) + 0.3 * abs(log(hand.scale / last.scale))
                }
                return cost(a) < cost(b)
            }
            if let i = match {
                tracks[i].history.append(Sample(time: now, hand: hand))
                tracks[i].history.removeAll { now - $0.time > 0.85 }
                used.insert(tracks[i].id); currentIDs.insert(tracks[i].id)
            } else {
                nextID += 1
                tracks.append(Track(id: nextID, history: [Sample(time: now, hand: hand)]))
                used.insert(nextID); currentIDs.insert(nextID)
            }
        }
        diagnostics["validHands"] = Double(valid.count)
        diagnostics["tracks"] = Double(tracks.count)
        diagnostics["history"] = Double(tracks.map { $0.history.count }.max() ?? 0)
        if visible {
            if let owner = tracks.first(where: { $0.id == ownerID && currentIDs.contains($0.id) }) {
                let hand = owner.latest.hand
                var stillNear = hand.scale >= max(threshold * 0.65, triggerScale * 0.72)
                if let reference = ownerReference {
                    let palms = [(0,1),(0,5),(0,9),(0,13),(0,17),(5,9),(9,13),(13,17),(5,17)]
                    let fingers = [1,5,9,13,17].flatMap { start in (start..<(start + 3)).map { ($0,$0 + 1) } }
                    func ratios(_ edges: [(Int,Int)]) -> [Double] {
                        edges.compactMap { a,b in
                            guard let p = reference.pose[a], let q = reference.pose[b],
                                  let u = hand.pose[a], let v = hand.pose[b] else { return nil }
                            let initial = hypot(p.x - q.x, p.y - q.y)
                            guard initial >= 0.006 else { return nil }
                            return hypot(u.x - v.x, u.y - v.y) / initial
                        }
                    }
                    let palm = ratios(palms).sorted(), finger = ratios(fingers).sorted()
                    if palm.count >= 2 && finger.count >= 3 {
                        let relative = sqrt(palm[palm.count / 2] * finger[finger.count / 2])
                        stillNear = relative >= 0.80
                        diagnostics["relativeBoneScale"] = relative
                    }
                }
                if stillNear { lastNear = now }
            }
            reason = "motion.holding"
            if now - lastNear >= 0.65 && now - shownAt >= 1.0 {
                reset(now: now, cooldown: 1.0)
                return .hide
            }
            return nil
        }
        progress = 0; growth = 1
        guard now >= cooldownUntil else {
            // Discard the cooldown history: a fresh approach must follow cooldown.
            tracks.removeAll()
            reason = "motion.cooldown"
            return nil
        }
        reason = valid.isEmpty ? "motion.waiting" : "motion.detected"
        for track in tracks where currentIDs.contains(track.id) {
            // Evaluate recent suffixes independently: initial holding/turning
            // must not dilute a valid short approach later in the same track.
            guard track.history.count >= 4 else { continue }
            for count in 4...track.history.count {
            let h = Array(track.history.suffix(count))
            diagnostics["evaluationFrames"] = Double(h.count)
            guard h.count >= 4, let first = h.first, let last = h.last,
                  last.time - first.time >= 0.25 else { continue }
            diagnostics["windowSeconds"] = last.time - first.time
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            var scales = h.map { $0.hand.scale }
            var widths = h.map { $0.hand.width }
            var lengths = h.map { $0.hand.length }
            var poseConsistent = true
            var usingBones = false
            if h.contains(where: { !$0.hand.pose.isEmpty }) {
                // Use exactly the SAME visible keypoints throughout this window.
                // A point appearing/disappearing cannot enlarge the measurement.
                let common = h.reduce(Set(first.hand.pose.keys)) { $0.intersection($1.hand.pose.keys) }.sorted()
                diagnostics["commonPoints"] = Double(common.count)
                guard common.count >= 5 else { reason = "motion.keypoints"; continue }
                let pairs = common.enumerated().flatMap { i, a in common.dropFirst(i + 1).map { (a, $0) } }
                    .filter { a, b in
                        let p = first.hand.pose[a]!, q = first.hand.pose[b]!
                        return hypot(p.x - q.x, p.y - q.y) >= 0.012
                    }
                diagnostics["pointPairs"] = Double(pairs.count)
                guard pairs.count >= 8 else { continue }
                let distances = h.map { sample in pairs.map { a, b in
                    let p = sample.hand.pose[a]!, q = sample.hand.pose[b]!
                    return hypot(p.x - q.x, p.y - q.y)
                } }
                scales = distances.map { sqrt($0.map { $0 * $0 }.reduce(0,+) / Double($0.count)) }
                widths = h.map { sample in
                    let xs = common.map { sample.hand.pose[$0]!.x }
                    return max(0.001, xs.max()! - xs.min()!)
                }
                lengths = h.map { sample in
                    let ys = common.map { sample.hand.pose[$0]!.y }
                    return max(0.001, ys.max()! - ys.min()!)
                }
                let logRatios = pairs.indices.map { i in log(max(0.001, distances.last![i]) / max(0.001, distances.first![i])) }
                let center = median(logRatios)
                let deviations = logRatios.map { abs($0 - center) }.sorted()
                // Spreading fingers changes relative joint distances. A rigid hand
                // approaching makes most distances expand by the same factor.
                poseConsistent = median(deviations) <= 0.14 && deviations[Int(Double(deviations.count - 1) * 0.8)] <= 0.27

                // Anatomical bone lengths are unaffected by finger spread. Use
                // robust palm + finger evidence instead of requiring the entire
                // articulated hand to stay a rigid shape during a natural reach.
                let palmEdges = [(0,1),(0,5),(0,9),(0,13),(0,17),(5,9),(9,13),(13,17),(5,17)]
                let fingerEdges = [1,5,9,13,17].flatMap { start in (start..<(start + 3)).map { ($0,$0 + 1) } }
                func lengthsForEdges(_ edges: [(Int,Int)]) -> [[Double]] {
                    edges.compactMap { a,b in
                        var values: [Double] = []
                        for sample in h {
                            guard let p = sample.hand.pose[a], let q = sample.hand.pose[b] else { return nil }
                            let distance = hypot(p.x - q.x, p.y - q.y)
                            guard distance >= 0.006 else { return nil }
                            values.append(distance)
                        }
                        return values
                    }
                }
                let palms = lengthsForEdges(palmEdges), fingers = lengthsForEdges(fingerEdges)
                if palms.count >= 2 && fingers.count >= 3 {
                    func growthOf(_ edges: [[Double]]) -> Double {
                        median(edges.map { values in
                            (values[values.count - 2] + values.last!) / (values[0] + values[1])
                        })
                    }
                    let palmGrowth = growthOf(palms), fingerGrowth = growthOf(fingers)
                    scales = h.indices.map { i in
                        let palm = median(palms.map { $0[i] / $0[0] })
                        let finger = median(fingers.map { $0[i] / $0[0] })
                        return sqrt(palm * finger)
                    }
                    poseConsistent = palmGrowth >= 1.07 && fingerGrowth >= 1.10
                    usingBones = true
                    diagnostics["palmGrowth"] = palmGrowth
                    diagnostics["fingerGrowth"] = fingerGrowth
                    diagnostics["palmBones"] = Double(palms.count)
                    diagnostics["fingerBones"] = Double(fingers.count)
                }
            }
            let startScale = (scales[0] + scales[1]) / 2
            let endScale = (scales[scales.count - 2] + scales.last!) / 2
            let nearScale = (h[h.count - 2].hand.scale + last.hand.scale) / 2
            let ratio = endScale / max(startScale, 0.001)
            growth = max(growth, ratio)
            let widthRatio = (widths[widths.count - 2] + widths.last!) / max(widths[0] + widths[1], 0.001)
            let lengthRatio = (lengths[lengths.count - 2] + lengths.last!) / max(lengths[0] + lengths[1], 0.001)
            let shapes = zip(widths, lengths).map { $0 / max($1, 0.001) }
            let shapeChange = (shapes.max() ?? 1) / max(shapes.min() ?? 1, 0.001)
            let lateralTravel = hypot(last.hand.x - first.hand.x, last.hand.y - first.hand.y)
            let meanT = h.map { $0.time }.reduce(0,+) / Double(h.count)
            let logs = scales.map { log(max($0, 0.001)) }
            let meanS = logs.reduce(0,+) / Double(h.count)
            var covariance = 0.0, varianceT = 0.0, varianceS = 0.0
            for (i, sample) in h.enumerated() {
                let dt = sample.time - meanT, ds = logs[i] - meanS
                covariance += dt * ds; varianceT += dt * dt; varianceS += ds * ds
            }
            let r2 = covariance * covariance / max(varianceT * varianceS, 0.0000001)
            let rising = zip(scales, scales.dropFirst()).filter { $1 >= $0 * 0.96 }.count
            let coherent = poseConsistent && covariance > 0 && r2 >= (usingBones ? 0.60 : 0.75) &&
                Double(rising) / Double(h.count - 1) >= (usingBones ? 0.60 : 0.75) &&
                widthRatio >= 1.10 && lengthRatio >= 1.10 &&
                (usingBones || shapeChange <= 1.55) && lateralTravel <= 0.40
            diagnostics["ratio"] = ratio
            diagnostics["nearScale"] = nearScale
            diagnostics["rSquared"] = r2
            diagnostics["risingFraction"] = Double(rising) / Double(h.count - 1)
            diagnostics["widthRatio"] = widthRatio
            diagnostics["lengthRatio"] = lengthRatio
            diagnostics["shapeChange"] = shapeChange
            diagnostics["lateralTravel"] = lateralTravel
            diagnostics["poseConsistent"] = poseConsistent ? 1 : 0
            diagnostics["coherent"] = coherent ? 1 : 0
            if !poseConsistent && progress == 0 { reason = "motion.pose" }
            if coherent {
                progress = max(progress, min(1, max(0, (ratio - 1) / (requiredGrowth - 1))) * min(1, nearScale / threshold))
                reason = "motion.approaching"
            }
            let stillGrowing = scales.last! >= scales[scales.count - 3] * 1.025
            if coherent && stillGrowing && ratio >= requiredGrowth &&
                nearScale * (1 - 1 / ratio) >= max(0.025, threshold * 0.20) && nearScale >= threshold {
                visible = true; ownerID = track.id
                shownAt = now; lastNear = now; triggerScale = nearScale; ownerReference = last.hand
                progress = 1; reason = "motion.confirmed"
                return .show
            }
            }
        }
        return nil
    }
}

func runGateTests() {
    func hand(_ scale: Double, x: Double = 0.5, widthFactor: Double = 1, side: Int = 1) -> HandMeasurement {
        HandMeasurement(x: x, y: 0.5, width: scale * widthFactor, length: scale, side: side)
    }
    func run(_ name: String, _ frames: [[HandMeasurement]], expected: [DetectionGate.Event]) {
        var gate = DetectionGate(), events: [DetectionGate.Event] = []
        for (i, hands) in frames.enumerated() {
            if let event = gate.ingest(hands: hands, now: Double(i) / 10) { events.append(event) }
        }
        precondition(events == expected, "\(name): \(events)")
        print("PASS: \(name)")
    }
    run("no hand / 60 seconds", (0..<600).map { _ in [] }, expected: [])
    run("large stationary hand must not trigger", (0..<100).map { _ in [hand(0.32)] }, expected: [])
    run("lateral waving must not trigger", (0..<100).map { [hand(0.24, x: 0.5 + sin(Double($0) * 0.3) * 0.25)] }, expected: [])
    run("small scale jitter must not trigger", (0..<100).map { [hand(0.25 + sin(Double($0)) * 0.008)] }, expected: [])
    run("palm rotation / width only must not trigger", (0..<15).map { [hand(0.14, widthFactor: 0.7 + Double($0) * 0.09)] }, expected: [])
    let approach = (0..<11).map { [hand(0.085 + Double($0) * 0.014)] }
    run("approach then hold gives one warning", approach + (0..<30).map { _ in [hand(0.225)] }, expected: [.show])
    run("approach then withdraw recovers", approach + (0..<30).map { _ in [] }, expected: [.show, .hide])
    run("retreat while still visible recovers", approach + (0..<30).map { _ in [hand(0.07)] }, expected: [.show, .hide])
    run("hand moving away must not trigger", (0..<15).map { [hand(0.30 - Double($0) * 0.012)] }, expected: [])
    run("one-frame jump must not trigger", (0..<25).map { [hand($0 == 12 ? 0.4 : 0.14)] }, expected: [])
    run("different hands cannot form approach", (0..<30).map { $0 % 2 == 0 ? [hand(0.09, x: 0.1, side: 1)] : [hand(0.26, x: 0.9, side: 2)] }, expected: [])
    run("two static hands, order swaps", (0..<30).map { $0 % 2 == 0 ? [hand(0.09, x: 0.2), hand(0.26, x: 0.8, side: 2)] : [hand(0.26, x: 0.8, side: 2), hand(0.09, x: 0.2)] }, expected: [])
    run("brief occlusion does not dismiss warning", approach + (0..<4).map { _ in [] } + (0..<20).map { _ in [hand(0.225)] }, expected: [.show])
    // A lost track is intentionally not reassigned after 0.3s: conservative recovery.
    func poseHand(_ factor: Double, x: Double = 0.5, omitted: Set<Int> = [], spread: Double = 0) -> HandMeasurement {
        let template: [(Double,Double)] = [(0,-0.10),(-0.05,0.01),(-0.06,0.10),(0,0.03),(0,0.12),(0.04,0.02),(0.05,0.10),(0.07,0),(0.09,0.07)]
        var pose: [Int: HandPoint] = [:]
        for (i, p) in template.enumerated() where !omitted.contains(i) {
            let movingTip = [2,4,6,8].contains(i)
            pose[i] = HandPoint(x: x + p.0 * factor * (movingTip ? 1 + spread : 1), y: 0.5 + p.1 * factor * (movingTip ? 1 + spread : 1))
        }
        let xs = pose.values.map { $0.x }, ys = pose.values.map { $0.y }
        return HandMeasurement(x: xs.reduce(0,+) / Double(xs.count), y: ys.reduce(0,+) / Double(ys.count), width: xs.max()! - xs.min()!, length: ys.max()! - ys.min()!, side: 1, pose: pose)
    }
    let poseApproach = (0..<11).map { [poseHand(0.65 + Double($0) * 0.10)] }
    run("keypoint geometry approach and withdrawal", poseApproach + (0..<30).map { _ in [] }, expected: [.show, .hide])
    run("keypoint geometry static close fist", (0..<60).map { _ in [poseHand(1.8)] }, expected: [])
    run("keypoint geometry lateral wave", (0..<60).map { [poseHand(1.8, x: 0.5 + sin(Double($0) * 0.3) * 0.2)] }, expected: [])
    run("finger spreading without approach", (0..<12).map { [poseHand(1.0, spread: Double($0) * 0.10)] }, expected: [])
    run("changing visibility must not fake growth", (0..<30).map { [poseHand(1.8, omitted: $0 < 12 ? [2,4] : [])] }, expected: [])
    run("pose approach with missing palm points", (0..<11).map { [poseHand(0.65 + Double($0) * 0.10, omitted: [0,1])] } + (0..<30).map { _ in [] }, expected: [.show,.hide])
    run("handedness classifier flicker must preserve track", (0..<11).map { [hand(0.085 + Double($0) * 0.014, side: $0 % 2 == 0 ? 1 : 2)] } + (0..<30).map { _ in [] }, expected: [.show,.hide])
    let turnThenReach = (0..<10).map { [hand(0.35 - Double($0) * 0.023)] } + (0..<6).map { [hand(0.12 + Double($0) * 0.04)] }
    run("retreat then fast reach must not be diluted", turnThenReach + (0..<20).map { _ in [] }, expected: [.show,.hide])
    var gap = DetectionGate()
    for (t, scale) in [(0.0,0.08),(1.0,0.14),(2.0,0.22),(3.0,0.3)] {
        precondition(gap.ingest(hands: [hand(scale)], now: t) == nil, "sparse frames must reset trend")
    }
    print("PASS: frame gaps cannot accumulate approach")
    gap.reset(now: 4, cooldown: 1)
    precondition(!gap.visible && gap.ingest(hands: [hand(0.5)], now: 4.1) == nil)
    print("PASS: reset / cooldown")
}
