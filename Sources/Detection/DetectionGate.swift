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
    var requiredGrowth = 1.2345
    private(set) var visible = false
    private(set) var progress = 0.0
    private(set) var growth = 1.0
    private(set) var reason = "motion.waiting"
    private(set) var diagnostics: [String: Double] = [:]
    var protectedHand: HandMeasurement? { visible ? ownerReference : nil }
    private var tracks: [Track] = []
    private var nextID = 0
    private var ownerID: Int?
    private var ownerReference: HandMeasurement?
    private var triggerScale = 0.0
    private var shownAt = -Double.infinity
    private var lastNear = -Double.infinity
    private var cooldownUntil = -Double.infinity
    private var previousTime = -Double.infinity
    private var retreatSince: Double?
    private var occludedSince: Double?
    private var approachSince: [Int: Double] = [:]
    private static let palmEdges = [(0,1),(0,5),(0,9),(0,13),(0,17),(5,9),(9,13),(13,17),(5,17)]
    private static let fingerEdges = [1,5,9,13,17].flatMap { start in (start..<(start + 3)).map { ($0,$0 + 1) } }

    private static func boneScale(_ hand: HandMeasurement, relativeTo reference: HandMeasurement) -> Double? {
        func medianRatio(_ edges: [(Int,Int)]) -> Double? {
            let ratios = edges.compactMap { a,b -> Double? in
                guard let p = reference.pose[a], let q = reference.pose[b],
                      let u = hand.pose[a], let v = hand.pose[b] else { return nil }
                let before = hypot(p.x - q.x, p.y - q.y)
                guard before >= 0.006 else { return nil }
                return hypot(u.x - v.x, u.y - v.y) / before
            }.sorted()
            guard ratios.count >= (edges.count == palmEdges.count ? 2 : 3) else { return nil }
            return ratios[ratios.count / 2]
        }
        guard let palm = medianRatio(palmEdges), let finger = medianRatio(fingerEdges),
              abs(log(max(palm, 0.001) / max(finger, 0.001))) < 0.30 else { return nil }
        return sqrt(palm * finger)
    }

    mutating func reset(now: Double, cooldown: Double = 0) {
        visible = false; progress = 0; growth = 1; tracks = []
        retreatSince = nil; occludedSince = nil; approachSince.removeAll()
        ownerID = nil; ownerReference = nil; triggerScale = 0
        lastNear = -.infinity; shownAt = -.infinity; previousTime = -.infinity
        cooldownUntil = now + cooldown
        reason = cooldown > 0 ? "motion.cooldown" : "motion.waiting"
    }

    @discardableResult
    mutating func triggerDirect(now: Double, hand: HandMeasurement? = nil) -> Event? {
        guard !visible, now >= cooldownUntil else { return nil }
        visible = true
        shownAt = now
        lastNear = now
        triggerScale = hand?.scale ?? 0.35
        ownerReference = hand
        progress = 1
        reason = "motion.confirmed"
        return .show
    }

    mutating func ingest(hands: [HandMeasurement], now: Double, nearOcclusion: Bool = false) -> Event? {
        diagnostics = ["frameGap": now - previousTime]
        guard now.isFinite, now > previousTime else { return nil }
        if now - previousTime > 0.35 { tracks.removeAll() }
        previousTime = now
        tracks.removeAll { now - $0.latest.time > (visible && $0.id == ownerID ? (nearOcclusion ? Double.infinity : 0.65) : 0.30) }
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
            var reliableOwner = false
            if let owner = tracks.first(where: { $0.id == ownerID && currentIDs.contains($0.id) }) {
                let hand = owner.latest.hand
                // Follow the closest *confirmed* pose after triggering. Comparing
                // only with the first trigger misses withdrawal from a later peak.
                let hasPose = !(ownerReference?.pose.isEmpty ?? true)
                let relative = hasPose
                    ? ownerReference.flatMap { Self.boneScale(hand, relativeTo: $0) }
                    : hand.scale / max(triggerScale, 0.001)
                if let relative {
                    reliableOwner = true
                    diagnostics["relativePeakScale"] = relative
                    if relative > 1.04, owner.history.count >= 2 {
                        let previous = owner.history[owner.history.count - 2].hand
                        let previousRelative = hasPose
                            ? ownerReference.flatMap { Self.boneScale(previous, relativeTo: $0) }
                            : previous.scale / max(triggerScale, 0.001)
                        if let previousRelative, previousRelative > 1.02 {
                            ownerReference = hand; triggerScale = hand.scale
                        }
                    }
                    lastNear = now
                    if relative <= 0.86 {
                        if retreatSince == nil { retreatSince = now }
                    } else { retreatSince = nil }
                } else {
                    // A changed keypoint set must not masquerade as shrinkage.
                    retreatSince = nil
                }
            } else if ownerID == nil, let closest = valid.max(by: { $0.scale < $1.scale }) {
                reliableOwner = true
                let relative = closest.scale / max(triggerScale, 0.001)
                diagnostics["relativePeakScale"] = relative
                lastNear = now
                if relative <= 0.86 {
                    if retreatSince == nil { retreatSince = now }
                } else { retreatSince = nil }
            } else {
                // A missing frame is not evidence of retreat; tolerate brief
                // occlusion while keeping disappearance recovery under 0.5s.
                retreatSince = nil
            }
            // Foreground evidence is only allowed to retain an existing warning.
            // A positively recognized withdrawal always wins over this evidence.
            if reliableOwner { occludedSince = nil }
            else if nearOcclusion && occludedSince == nil { occludedSince = now }
            let occlusionExpired = occludedSince.map { now - $0 >= 3.5 } ?? false
            if nearOcclusion && !occlusionExpired { lastNear = now }
            diagnostics["occlusionSeconds"] = occludedSince.map { now - $0 } ?? 0
            diagnostics["nearOcclusion"] = nearOcclusion ? 1 : 0
            reason = nearOcclusion && !reliableOwner ? "motion.occludedHold" : "motion.holding"
            let withdrawn = retreatSince.map { now - $0 >= 0.10 } ?? false
            if now - shownAt >= 0.28 && (withdrawn || occlusionExpired || now - lastNear >= 0.42) {
                reset(now: now, cooldown: 0.30)
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
        var qualifiedIDs = Set<Int>()
        for track in tracks where currentIDs.contains(track.id) {
            // Evaluate recent suffixes independently: initial holding/turning
            // must not dilute a valid short approach later in the same track.
            guard track.history.count >= 4 else { continue }
            for count in 4...track.history.count {
            let h = Array(track.history.suffix(count))
            diagnostics["evaluationFrames"] = Double(h.count)
            guard h.count >= 4, let first = h.first, let last = h.last,
                  last.time - first.time >= 0.14 else { continue }
            diagnostics["windowSeconds"] = last.time - first.time
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            var scales = h.map { $0.hand.scale }
            var widths = h.map { $0.hand.width }
            var lengths = h.map { $0.hand.length }
            var poseConsistent = true
            var usingBones = false
            var partialPose = false
            var boneAgreement = 0.0
            var centers = h.map { HandPoint(x: $0.hand.x, y: $0.hand.y) }
            if h.contains(where: { !$0.hand.pose.isEmpty }) {
                // Use exactly the SAME visible keypoints throughout this window.
                // A point appearing/disappearing cannot enlarge the measurement.
                let common = h.reduce(Set(first.hand.pose.keys)) { $0.intersection($1.hand.pose.keys) }.sorted()
                diagnostics["commonPoints"] = Double(common.count)
                let palmJoints = common.filter { [0,1,5,9,13,17].contains($0) }
                let centerJoints = palmJoints.count >= 2 ? palmJoints : common
                if !centerJoints.isEmpty {
                    centers = h.map { sample in
                        HandPoint(x: centerJoints.map { sample.hand.pose[$0]!.x }.reduce(0,+) / Double(centerJoints.count),
                                  y: centerJoints.map { sample.hand.pose[$0]!.y }.reduce(0,+) / Double(centerJoints.count))
                    }
                }
                let groups = Set(common.filter { $0 > 0 }.map { ($0 - 1) / 4 })
                partialPose = common.count == 4 && groups.count >= 2 &&
                    common.contains(where: { [0,1,5,9,13,17].contains($0) })
                guard common.count >= 5 || partialPose else { reason = "motion.keypoints"; continue }
                let pairs = common.enumerated().flatMap { i, a in common.dropFirst(i + 1).map { (a, $0) } }
                    .filter { a, b in
                        let p = first.hand.pose[a]!, q = first.hand.pose[b]!
                        return hypot(p.x - q.x, p.y - q.y) >= 0.012
                    }
                diagnostics["pointPairs"] = Double(pairs.count)
                guard pairs.count >= (partialPose ? 6 : 8) else { continue }
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
                let palmEdges = Self.palmEdges, fingerEdges = Self.fingerEdges
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
                if (palms.count >= 2 && fingers.count >= 3) || (palms.count >= 1 && fingers.count >= 2) {
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
                    let boneGrowth = (palms + fingers).map { values in
                        (values[values.count - 2] + values.last!) / (values[0] + values[1])
                    }
                    boneAgreement = Double(boneGrowth.filter { $0 >= 1.04 }.count) / Double(boneGrowth.count)
                    poseConsistent = palmGrowth >= 1.06 && fingerGrowth >= 1.06 &&
                        abs(log(palmGrowth / fingerGrowth)) <= 0.25 && boneAgreement >= 0.60
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
            // Accumulated path catches a sideways wave that returns to its start.
            // Reaching up from the keyboard is expected; horizontal motion gets
            // full weight while vertical motion remains a weaker constraint.
            let lateralTravel = zip(centers, centers.dropFirst()).map {
                hypot($1.x - $0.x, ($1.y - $0.y) * 0.35)
            }.reduce(0,+)
            let lateralRelative = lateralTravel / max(nearScale, 0.05)
            let depthDominant = log(max(ratio, 1)) >= lateralRelative * 0.42
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
            let coherent = poseConsistent && covariance > 0 && r2 >= (partialPose ? 0.85 : (usingBones ? 0.60 : 0.75)) &&
                Double(rising) / Double(h.count - 1) >= (usingBones ? 0.60 : 0.75) &&
                (usingBones || (widthRatio >= 1.10 && lengthRatio >= 1.10 && shapeChange <= 1.55)) &&
                depthDominant && lateralTravel <= 0.40
            diagnostics["ratio"] = ratio
            diagnostics["nearScale"] = nearScale
            diagnostics["rSquared"] = r2
            diagnostics["risingFraction"] = Double(rising) / Double(h.count - 1)
            diagnostics["widthRatio"] = widthRatio
            diagnostics["lengthRatio"] = lengthRatio
            diagnostics["shapeChange"] = shapeChange
            diagnostics["lateralTravel"] = lateralTravel
            diagnostics["depthDominant"] = depthDominant ? 1 : 0
            diagnostics["boneAgreement"] = boneAgreement
            diagnostics["poseConsistent"] = poseConsistent ? 1 : 0
            diagnostics["coherent"] = coherent ? 1 : 0
            if !poseConsistent && progress == 0 { reason = "motion.pose" }
            // With independent palm+finger evidence, require less expansion and
            // project at most 120ms ahead. Bounding-box-only input stays stricter.
            let targetGrowth = usingBones ? max(1.12, requiredGrowth - 0.07) : requiredGrowth
            let slope = covariance / max(varianceT, 0.000001)
            let predictedNear = nearScale * exp(min(0.14, max(0, slope) * 0.12))
            let reachesNear = nearScale >= threshold || (usingBones && nearScale >= threshold * 0.87 && predictedNear >= threshold)
            if coherent {
                progress = max(progress, min(1, max(0, (ratio - 1) / (targetGrowth - 1))) * min(1, nearScale / threshold))
                reason = "motion.approaching"
            }
            let stillGrowing = scales.last! >= scales[scales.count - 3] * 1.015
            // Low, nearly horizontal keyboard motion needs stronger evidence.
            let keyboardMotion = last.hand.y < 0.18 && last.hand.y - first.hand.y < 0.025
            let typingSafe = !keyboardMotion || ratio >= max(1.35, targetGrowth)
            diagnostics["targetGrowth"] = targetGrowth
            diagnostics["stillGrowing"] = stillGrowing ? 1 : 0
            diagnostics["reachesNear"] = reachesNear ? 1 : 0
            diagnostics["typingSafe"] = typingSafe ? 1 : 0
            if coherent && stillGrowing && typingSafe && ratio >= max(1.10, targetGrowth - 0.06) {
                qualifiedIDs.insert(track.id)
                if approachSince[track.id] == nil { approachSince[track.id] = now }
            }
            if coherent && stillGrowing && ratio >= targetGrowth && typingSafe &&
                nearScale * (1 - 1 / ratio) >= max(0.018, threshold * (usingBones ? 0.14 : 0.20)) && reachesNear {
                let strongGeometry = usingBones ? (r2 >= 0.80 && boneAgreement >= 0.80) :
                    (r2 >= 0.92 && shapeChange <= 1.25 && widthRatio >= 1.10 && lengthRatio >= 1.10)
                let confirmedInWindow = strongGeometry &&
                    scales.last! >= scales[scales.count - 2] * 1.02 &&
                    scales[scales.count - 2] >= scales[scales.count - 3] * 1.02
                let confirmedAcrossFrames = approachSince[track.id].map { now - $0 >= 0.06 } ?? false
                guard confirmedInWindow || confirmedAcrossFrames else { continue }
                visible = true; ownerID = track.id
                shownAt = now; lastNear = now; triggerScale = nearScale; ownerReference = last.hand
                progress = 1; reason = "motion.confirmed"
                return .show
            }
            }
        }
        approachSince = approachSince.filter { qualifiedIDs.contains($0.key) }
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
    // Anatomical 21-joint fixtures cover articulated hands, not only bounding boxes.
    func anatomical(_ factor: Double, x: Double = 0.65, y: Double = 0.50,
                    fingerFlex: Double = 0, omit: Set<Int> = []) -> HandMeasurement {
        let template: [(Double,Double)] = [
            (0,-0.10),(-0.045,-0.055),(-0.08,-0.02),(-0.105,0.015),(-0.13,0.045),
            (-0.045,0),(-0.05,0.07),(-0.052,0.12),(-0.054,0.16),
            (0,0.015),(0,0.09),(0,0.145),(0,0.19),
            (0.04,0.005),(0.045,0.075),(0.05,0.12),(0.055,0.155),
            (0.075,-0.02),(0.085,0.035),(0.09,0.075),(0.095,0.11)]
        var pose: [Int: HandPoint] = [:]
        for (i,p) in template.enumerated() where !omit.contains(i) {
            let tip = i > 4 && i % 4 != 1
            pose[i] = HandPoint(x: x + p.0 * factor,
                                y: y + (p.1 - (tip ? fingerFlex * Double(i % 4 + 1) * 0.012 : 0)) * factor)
        }
        let xs = pose.values.map { $0.x }, ys = pose.values.map { $0.y }
        return HandMeasurement(x: x, y: y, width: xs.max()! - xs.min()!, length: ys.max()! - ys.min()!, side: 1, pose: pose)
    }
    func timed(_ frames: [[HandMeasurement]], fps: Double = 20, sensitivity: Double? = nil) -> [(DetectionGate.Event,Double)] {
        var gate = DetectionGate(), events: [(DetectionGate.Event,Double)] = []
        if let sensitivity { gate.threshold = 0.25 - sensitivity * 0.12; gate.requiredGrowth = 1.35 - sensitivity * 0.21 }
        for (i,hands) in frames.enumerated() {
            let time = Double(i) / fps
            if let event = gate.ingest(hands: hands, now: time) { events.append((event,time)) }
        }
        return events
    }
    let naturalReach = (0..<25).map { [anatomical(0.42 + Double($0) * 0.025)] }
    let early = timed(naturalReach)
    precondition(early.count == 1 && early[0].0 == .show && early[0].1 <= 0.65, "natural reach must trigger within 650ms")
    print("PASS: anatomical approach triggers within 650ms (\(early[0].1)s)")
    let peakHold = naturalReach + (0..<10).map { _ in [anatomical(1.8)] }
    let withdrawal = timed(peakHold + (0..<15).map { _ in [anatomical(1.3)] })
    let retreatAt = Double(peakHold.count) / 20
    precondition(withdrawal.count == 2 && withdrawal[1].0 == .hide && withdrawal[1].1 - retreatAt <= 0.20,
                 "withdrawal from a later peak must restore within 200ms")
    print("PASS: withdrawal from post-trigger peak restores within 200ms")
    let disappearing = timed(naturalReach + (0..<20).map { _ in [] })
    precondition(disappearing.count == 2 && disappearing[1].1 - Double(naturalReach.count) / 20 <= 0.45)
    print("PASS: disappeared hand restores within 450ms")
    let typing = (0..<600).map { i in
        [anatomical(0.92 + sin(Double(i) * 0.5) * 0.04,
                    x: 0.6 + sin(Double(i) * 0.25) * 0.015, y: 0.14,
                    fingerFlex: sin(Double(i) * 0.8))]
    }
    precondition(timed(typing).isEmpty)
    print("PASS: 30 seconds of low typing / finger flex / scale noise")
    let waveWithScale = (0..<200).map { i in
        [anatomical(1 + sin(Double(i) * 0.12) * 0.18,
                    x: 0.65 + sin(Double(i) * 0.20) * 0.30)]
    }
    precondition(timed(waveWithScale).isEmpty)
    print("PASS: lateral waving with incidental scale changes")
    let diagonalReach = (0..<25).map { i in
        [anatomical(0.42 + Double(i) * 0.03, x: 0.65 + Double(i) * 0.002)]
    }
    precondition(timed(diagonalReach).first?.0 == .show)
    print("PASS: modest diagonal approach still triggers")
    let liftingReach = (0..<25).map { i in
        [anatomical(0.42 + Double(i) * 0.03, y: 0.16 + Double(i) * 0.014)]
    }
    precondition(timed(liftingReach).first?.0 == .show)
    print("PASS: reaching upward from keyboard is not treated as lateral waving")
    let pointingReach = (0..<25).map { i in
        [anatomical(0.42 + Double(i) * 0.03, omit: Set([10,11,12,14,15,16,18,19,20]))]
    }
    precondition(timed(pointingReach).first?.0 == .show)
    print("PASS: pointing finger reach with curled fingers triggers warning")
    let veryShortLoss = naturalReach + (0..<3).map { _ in [] } + (0..<10).map { _ in [anatomical(1.02)] }
    precondition(timed(veryShortLoss).map { $0.0 } == [.show])
    print("PASS: 150ms keypoint loss does not flicker warning")
    let partialLoss = naturalReach + (0..<5).map { _ in [anatomical(1.02, omit: Set(6...20))] } +
        (0..<10).map { _ in [anatomical(1.02)] }
    precondition(timed(partialLoss).map { $0.0 } == [.show])
    print("PASS: partial keypoint loss must not look like withdrawal")
    for fps in [10.0,20.0,30.0] {
        let frames = (0..<Int(fps * 1.5)).map { i in [anatomical(0.42 + Double(i) / fps * 0.5)] }
        precondition(timed(frames,fps:fps).first?.0 == .show)
    }
    print("PASS: approach at 10, 20 and 30 fps")
    for sensitivity in [0.0,0.55,1.0] {
        precondition(timed(typing,sensitivity:sensitivity).isEmpty)
        precondition(timed(waveWithScale,sensitivity:sensitivity).isEmpty)
        precondition(timed((0..<100).map { _ in [anatomical(1.8)] },sensitivity:sensitivity).isEmpty)
    }
    print("PASS: typing, lateral waving and static hand at low/default/high sensitivity")
    // Every frame has six joints; four remain common while visibility changes.
    func sparse(_ factor: Double, frame: Int, oneFinger: Bool = false) -> HandMeasurement {
        let core: Set<Int> = oneFinger ? [5,6,7,8] : [0,5,9,13]
        let extra: Set<Int> = frame % 2 == 0 ? [1,10] : [14,17]
        let keep = core.union(extra)
        return anatomical(factor, omit:Set(0...20).subtracting(keep))
    }
    let sparseReach = (0..<25).map { [sparse(0.70+Double($0)*0.035,frame:$0)] }
    precondition(timed(sparseReach,sensitivity:1).first?.0 == .show)
    print("PASS: four stable joints across multiple fingers can confirm a high-sensitivity reach")
    let oneFinger = (0..<25).map { i -> [HandMeasurement] in
        let factor = 0.70 + Double(i) * 0.035
        let pose = Dictionary(uniqueKeysWithValues: (5...8).map { joint in
            let d = Double(joint - 5) * 0.05 * factor
            return (joint,HandPoint(x:0.60+d,y:0.45+d))
        })
        return [HandMeasurement(x:0.65,y:0.50,width:0.16*factor,length:0.16*factor,side:1,pose:pose)]
    }
    precondition(timed(oneFinger,sensitivity:1).isEmpty)
    print("PASS: four joints on just one finger cannot confirm an approach")
    let sparseJitter = (0..<200).map { [sparse(1+sin(Double($0)*0.4)*0.03,frame:$0)] }
    precondition(timed(sparseJitter,sensitivity:1).isEmpty)
    print("PASS: sparse joint visibility plus small scale jitter does not trigger")
    var retained = DetectionGate(), heldEvents: [DetectionGate.Event] = []
    for (i,hands) in naturalReach.enumerated() {
        if let event=retained.ingest(hands:hands,now:Double(i)/20) { heldEvents.append(event) }
    }
    for i in 0..<60 {
        if let event=retained.ingest(hands:[],now:1.25+Double(i)/20,nearOcclusion:true) { heldEvents.append(event) }
    }
    precondition(heldEvents == [.show] && retained.visible)
    print("PASS: three seconds of forearm evidence retains warning without hand landmarks")
    for i in 0..<12 {
        if let event=retained.ingest(hands:[],now:4.25+Double(i)/20,nearOcclusion:false) { heldEvents.append(event) }
    }
    precondition(heldEvents == [.show,.hide])
    print("PASS: warning restores after forearm corridor clears")
    var emptyGate=DetectionGate()
    for i in 0..<100 { precondition(emptyGate.ingest(hands:[],now:Double(i)/20,nearOcclusion:true) == nil) }
    precondition(!emptyGate.visible)
    print("PASS: arm or foreground evidence alone must never trigger")
    var bounded = DetectionGate(), boundedEvents: [DetectionGate.Event] = []
    for (i,hands) in naturalReach.enumerated() {
        if let event=bounded.ingest(hands:hands,now:Double(i)/20) { boundedEvents.append(event) }
    }
    for i in 0..<100 {
        if let event=bounded.ingest(hands:[],now:1.25+Double(i)/20,nearOcclusion:true) { boundedEvents.append(event) }
    }
    precondition(boundedEvents == [.show,.hide] && !bounded.visible)
    print("PASS: ambiguous foreground cannot latch warning indefinitely")
    var retract = DetectionGate(), retractEvents: [DetectionGate.Event] = []
    for (i,hands) in naturalReach.enumerated() {
        if let event=retract.ingest(hands:hands,now:Double(i)/20) { retractEvents.append(event) }
    }
    for i in 0..<30 { _=retract.ingest(hands:[],now:1.25+Double(i)/20,nearOcclusion:true) }
    for i in 0..<10 {
        if let event=retract.ingest(hands:[anatomical(0.65)],now:2.75+Double(i)/20,nearOcclusion:true) { retractEvents.append(event) }
    }
    precondition(retractEvents == [.show,.hide])
    print("PASS: recognized withdrawal overrides remaining foreground after long occlusion")

}
