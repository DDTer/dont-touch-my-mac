import Foundation

/// A small in-memory color signature, never persisted in diagnostics.
struct SceneSignature {
    let columns: Int
    let rows: Int
    let aspect: Double
    let rgb: [UInt8]
}
struct OcclusionEvidence {
    var present = false
    var changedFraction = 0.0
    var outsideFraction = 0.0
    var armed = false
    var foregroundChange = 0.0
    var released = false
}

/// Maintains a previously confirmed reach when its hand leaves the field of view.
/// This measures local foreground change, not arm semantics or physical contact.
struct SceneOcclusion {
    private struct Snapshot {
        let time: Double
        let scene: SceneSignature
        let noHands: Bool
    }
    private struct Region {
        let x0: Double, x1: Double, y0: Double, y1: Double
        func contains(x: Double, y: Double) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 }
    }
    private var history: [Snapshot] = []
    private var background: SceneSignature?
    private var region: Region?
    private var lostHandAt: Double?
    private var foregroundReference: SceneSignature?
    private var changedSince: Double?
    private var released = false

    mutating func reset() {
        history.removeAll(); background = nil; region = nil
        lostHandAt = nil; foregroundReference = nil; changedSince = nil; released = false
    }
    mutating func end() { reset() }
    mutating func begin(hand: HandMeasurement, now: Double) {
        let usable = history.filter { now - $0.time >= 0.25 && now - $0.time <= 1.8 }
        // Prefer a recent frame before any hand appeared. Otherwise use the
        // oldest recent frame, before most of the approach expansion.
        let firstHandTime = history.first(where: { !$0.noHands })?.time ?? now
        guard let reference = usable.last(where: { $0.noHands && $0.time < firstHandTime }) ?? usable.first else { return }
        lostHandAt = nil; foregroundReference = nil; changedSince = nil; released = false
        background = reference.scene
        follow(hand: hand)
        history.removeAll()
    }
    mutating func follow(hand: HandMeasurement) {
        guard let background else { return }
        let wrist = hand.pose[0] ?? HandPoint(x: hand.x, y: hand.y - hand.length * 0.30)
        let palm = [5,9,13,17].compactMap { hand.pose[$0] }
        let center = palm.isEmpty ? HandPoint(x:hand.x,y:hand.y) :
            HandPoint(x:palm.map { $0.x }.reduce(0,+)/Double(palm.count),
                      y:palm.map { $0.y }.reduce(0,+)/Double(palm.count))
        let dx = wrist.x - center.x, dy = wrist.y - center.y
        let distance = hypot(dx,dy)
        // Continue from the palm through the wrist towards the forearm. A broad
        // corridor tolerates the last visible wrist pose being partially clipped.
        let reach = max(0.24, min(0.50, hand.length * 1.5))
        let end = distance > 0.015 ? HandPoint(x:wrist.x + dx/distance*reach,y:wrist.y + dy/distance*reach) :
            HandPoint(x:wrist.x,y:wrist.y - reach)
        let radius = max(0.075,min(0.18,hand.width*0.45))
        region = Region(x0:max(0,(min(wrist.x,end.x)-radius)/background.aspect),
                        x1:min(1,(max(wrist.x,end.x)+radius)/background.aspect),
                        y0:max(0,min(wrist.y,end.y)-radius), y1:min(1,max(wrist.y,end.y)+radius))
    }
    mutating func observe(_ scene: SceneSignature?, hands: [HandMeasurement], now: Double) -> OcclusionEvidence {
        guard let scene, scene.columns > 0, scene.rows > 0,
              scene.rgb.count == scene.columns*scene.rows*3 else { return OcclusionEvidence() }
        guard let background, let region else {
            history.append(Snapshot(time:now,scene:scene,noHands:hands.isEmpty))
            history.removeAll { now - $0.time > 1.8 }
            return OcclusionEvidence()
        }
        guard background.columns == scene.columns, background.rows == scene.rows,
              background.rgb.count == scene.rgb.count, abs(background.aspect - scene.aspect) < 0.01 else {
            reset(); return OcclusionEvidence()
        }
        let count = scene.columns * scene.rows
        func inside(_ i: Int) -> Bool {
            region.contains(x:(Double(i % scene.columns)+0.5)/Double(scene.columns),
                            y:1-(Double(i / scene.columns)+0.5)/Double(scene.rows))
        }
        let inRegion = (0..<count).map { inside($0) }
        // Compensate global exposure / white balance using cells outside the arm
        // corridor. A full-frame scene change cannot maintain the warning.
        var offsets: [[Double]] = [[],[],[]]
        for i in stride(from:0,to:count,by:3) where !inRegion[i] {
            for c in 0..<3 { offsets[c].append(Double(scene.rgb[i*3+c])-Double(background.rgb[i*3+c])) }
        }
        guard offsets[0].count >= 16 else { return OcclusionEvidence() }
        let shift = offsets.map { values in values.sorted()[values.count/2] }
        var changed = [Bool](repeating:false,count:count)
        var insideCount=0, insideChanged=0, outsideCount=0, outsideChanged=0
        for i in 0..<count {
            let delta = (0..<3).map { abs(Double(scene.rgb[i*3+$0])-Double(background.rgb[i*3+$0])-shift[$0]) }.max()!
            changed[i] = delta >= 28
            if inRegion[i] { insideCount += 1; if changed[i] { insideChanged += 1 } }
            else { outsideCount += 1; if changed[i] { outsideChanged += 1 } }
        }
        guard insideCount >= 8 else { return OcclusionEvidence() }
        let fraction = Double(insideChanged)/Double(insideCount)
        let outsideFraction = Double(outsideChanged)/Double(max(1,outsideCount))
        // Require a connected object instead of scattered camera/compression noise.
        var visited=Set<Int>(), largest=0
        for i in 0..<count where inRegion[i] && changed[i] && !visited.contains(i) {
            var stack=[i], size=0; visited.insert(i)
            while let j=stack.popLast() {
                size += 1
                let x=j % scene.columns, y=j / scene.columns
                let neighbors = [(x-1,y),(x+1,y),(x,y-1),(x,y+1)]
                for (nx,ny) in neighbors where nx >= 0 && nx < scene.columns && ny >= 0 && ny < scene.rows {
                    let k=ny*scene.columns+nx
                    if inRegion[k] && changed[k] && !visited.contains(k) { visited.insert(k); stack.append(k) }
                }
            }
            largest=max(largest,size)
        }
        var foregroundChange = 0.0
        var present = fraction >= 0.18 && Double(largest)/Double(insideCount) >= 0.10 && outsideFraction < 0.55
        if present && hands.isEmpty && !released {
            if lostHandAt == nil { lostHandAt = now; foregroundReference = scene }
            // Allow the reaching arm to settle for the first 250ms. Keep this
            // appearance even if intermittent hand landmarks reappear afterwards.
            if let lostHandAt, now - lostHandAt <= 0.25 { foregroundReference = scene }
            if let lostHandAt, now - lostHandAt >= 0.60, let foregroundReference {
                var exposure: [[Double]] = [[],[],[]]
                for i in stride(from:0,to:count,by:3) where !inRegion[i] {
                    for c in 0..<3 { exposure[c].append(Double(scene.rgb[i*3+c])-Double(foregroundReference.rgb[i*3+c])) }
                }
                let shift = exposure.map { $0.sorted()[$0.count/2] }
                var different = 0
                for i in 0..<count where inRegion[i] {
                    let delta = (0..<3).map { abs(Double(scene.rgb[i*3+$0])-Double(foregroundReference.rgb[i*3+$0])-shift[$0]) }.max()!
                    if delta >= 28 { different += 1 }
                }
                // A moved-away arm can reveal a different body pose instead of
                // the original empty background. Compare with the near object too.
                foregroundChange = Double(different)/Double(insideCount)
                if foregroundChange >= 0.28 {
                    if changedSince == nil { changedSince = now }
                    if now - changedSince! >= 0.12 { released = true }
                } else { changedSince = nil }
            }
        }
        if released { present = false }
        return OcclusionEvidence(present:present, changedFraction:fraction,outsideFraction:outsideFraction,armed:true,foregroundChange:foregroundChange,released:released)
    }
}

func runSceneOcclusionTests() {
    func image(arm: Bool = false, exposure: Int = 0, globalChange: Bool = false, noise: Bool = false, withdrawn: Bool = false) -> SceneSignature {
        let columns=48, rows=36
        var rgb=[UInt8](repeating:0,count:columns*rows*3)
        for y in 0..<rows { for x in 0..<columns {
            let forearm=arm && (20...28).contains(x) && (20...35).contains(y)
            let changed=forearm || globalChange || (noise && (x+y*3)%13 == 0)
            for c in 0..<3 { rgb[(y*columns+x)*3+c]=UInt8(min(255,80 + exposure + (changed ? (withdrawn ? [30,85,90][c] : [80,40,30][c]) : 0))) }
        } }
        return SceneSignature(columns:columns,rows:rows,aspect:4.0/3.0,rgb:rgb)
    }
    let hand=HandMeasurement(x:0.68,y:0.60,width:0.25,length:0.30,side:1,
                             pose:[0:HandPoint(x:0.68,y:0.45),9:HandPoint(x:0.68,y:0.60)])
    var monitor=SceneOcclusion()
    for i in 0..<10 { precondition(!monitor.observe(image(arm:true),hands:[],now:Double(i)/10).present) }
    print("PASS: foreground without a confirmed reach cannot arm the monitor")
    monitor.reset()
    for i in 0..<10 { _=monitor.observe(image(),hands:[],now:Double(i)/10) }
    monitor.begin(hand:hand,now:1)
    precondition(monitor.observe(image(arm:true),hands:[],now:1.1).present)
    for i in 0..<150 { precondition(monitor.observe(image(arm:true),hands:[],now:1.2+Double(i)/10).present) }
    print("PASS: stationary forearm-sized foreground persists after hand landmarks vanish")
    _ = monitor.observe(image(arm:true,withdrawn:true),hands:[],now:16.4)
    precondition(!monitor.observe(image(arm:true,withdrawn:true),hands:[],now:16.6).present)
    print("PASS: changed near object releases even when original background does not return")
    monitor.reset()
    for i in 0..<10 { _=monitor.observe(image(),hands:[],now:Double(i)/10) }
    monitor.begin(hand:hand,now:1)
    precondition(!monitor.observe(image(),hands:[],now:17).present)
    print("PASS: cleared forearm corridor releases support")
    precondition(!monitor.observe(image(exposure:35),hands:[],now:17.1).present)
    print("PASS: global exposure change cannot act as a foreground arm")
    precondition(!monitor.observe(image(globalChange:true),hands:[],now:17.2).present)
    print("PASS: whole-scene color change cannot act as a foreground arm")
    precondition(!monitor.observe(image(noise:true),hands:[],now:17.3).present)
    print("PASS: scattered changed pixels cannot maintain a warning")
    monitor.reset()
    precondition(!monitor.observe(image(arm:true),hands:[],now:18).present)
    print("PASS: pause and reset clear the retained foreground reference")
}
