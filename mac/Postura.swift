// Postura: camera posture guard for macOS. Clearly bad posture (or, once taught, no glasses) makes a glowing front close in
// over every display; when it has covered the screen, mouse, keyboard, Cmd-Tab and Force Quit are blocked until the posture
// is fixed. The judgement (p = 0..1 bad, why) comes from postura-eye.py; this app owns the camera, the timing and the screens.
// Out of frame, far away, turned away, screen locked or on a call: never blocks. Everything runs on the Mac; no images are saved.
import AppKit
import Metal
import QuartzCore
import SwiftUI
import AVFoundation
import Quartz
import Vision
import Carbon.HIToolbox

let fm = FileManager.default
let supportDir = ProcessInfo.processInfo.environment["POSTURA_HOME"].map { URL(fileURLWithPath: $0) }
    ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Postura")
let statusURL = supportDir.appendingPathComponent("status.json")
let trainURL = supportDir.appendingPathComponent("train")
let logURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/postura.log")
try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
func log(_ s: String) {
    let line = "\(stamp.string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}
/// UI language: `defaults write <bundle id> language es|en`, else Spanish when the Mac's first language is Spanish, else English.
let spanish = (UserDefaults.standard.string(forKey: "language") ?? Locale.preferredLanguages.first ?? "en").hasPrefix("es")
func L(_ es: String, _ en: String) -> String { spanish ? es : en }
/// The posture judge runs in a Python venv: $POSTURA_PYTHON, the per-user one (created on first launch), or strict mode's.
func pythonPath() -> String? {
    if let p = ProcessInfo.processInfo.environment["POSTURA_PYTHON"] { return p }
    let strict = ProcessInfo.processInfo.environment["POSTURA_HOME"] == nil ? ["/usr/local/libexec/postura/venv/bin/python3"] : []
    return ([supportDir.appendingPathComponent("venv/bin/python3").path] + strict).first { fm.isExecutableFile(atPath: $0) }
}
let prefs = UserDefaults.standard
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

// p is smoothed over ~1.2 s. Bad for GRACE s starts the liquid; it takes FILL s to cover the screen; good drains it in DRAIN s.
let BLOCK = 0.65, RELEASE = 0.40, GRACE = 1.0, FILL = 3.5, DRAIN = 1.0, FIXES_PER_DAY = 5, HOLD = 90.0

final class Eye {
    var input: FileHandle?, busy = false
    var onSample: (([String: Any]) -> Void)?
    let root = Bundle.main.resourceURL!
    func start() {
        guard let py = pythonPath() else { log("no python yet"); return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [root.appendingPathComponent("postura-eye.py").path]
        p.environment = ["POSTURA_MODELS": root.appendingPathComponent("models").path, "GLOG_minloglevel": "2", "TF_CPP_MIN_LOG_LEVEL": "2",
                         "HOME": NSHomeDirectory(), "POSTURA_LANG": spanish ? "es" : "en", "POSTURA_HOME": supportDir.path,
                         "POSTURA_GLASSES": requireGlasses() ? "1" : "0"]
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        var buf = Data()
        o.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }                 // closed pipe: without this the handler spins for ever
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 10) {
                let line = buf[buf.startIndex..<nl]; buf.removeSubrange(buf.startIndex...nl)
                self.busy = false
                if let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if let e = j["error"] { log("eye error \(e)") } else { self.onSample?(j) }
                }
            }
        }
        p.terminationHandler = { _ in log("eye exited, restarting"); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() } }
        try? p.run(); input = i.fileHandleForWriting; busy = false; proc = p
    }
    var proc: Process?
    func restart() { proc?.terminate() }   // the termination handler starts a fresh one with the current settings
    func send(_ pb: CVPixelBuffer) {
        guard !busy, let fh = input else { return }
        autoreleasepool {
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            var d = "\(w) \(h)\n".data(using: .utf8)!; d.reserveCapacity(w * h * 4 + 16)
            for y in 0..<h { d.append(Data(bytesNoCopy: base + y * bpr, count: w * 4, deallocator: .none)) }
            busy = true
            do { try fh.write(contentsOf: d) } catch { busy = false }
        }
    }
}

class KeyWin: NSWindow { override var canBecomeKey: Bool { true } }
/// One line of text that dissolves from one string to the next as a whole. Nothing is typed out, nothing moves sideways.
final class Line: NSView {
    let font: NSFont, color: NSColor, label = CATextLayer()
    private(set) var text = ""
    static let ease = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    init(_ parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, align: CATextLayerAlignmentMode = .left, digits: Bool = false) {
        font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight); color = NSColor.white.withAlphaComponent(alpha)
        super.init(frame: NSRect(x: x, y: y, width: width, height: ceil(size * 1.32)))
        wantsLayer = true; layer?.opacity = 0
        label.frame = bounds; label.alignmentMode = align; label.truncationMode = .end; label.contentsScale = 2
        label.shadowColor = NSColor.black.cgColor; label.shadowOpacity = 0.35; label.shadowRadius = 12; label.shadowOffset = .zero
        layer?.addSublayer(label); parent.addSubview(self)
    }
    required init?(coder: NSCoder) { nil }
    func set(_ s: String) {
        guard s != text else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.string = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        if !text.isEmpty { let x = CATransition(); x.type = .fade; x.duration = 0.9; x.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); label.add(x, forKey: "swap") }
        CATransaction.commit(); text = s
    }
}
/// Fades a view's layer from wherever it is now, so an interrupted fade never jumps.
func fade(_ v: NSView, _ on: Bool, delay: Double, duration: Double) {
    guard let l = v.layer else { return }
    let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = l.presentation()?.opacity ?? l.opacity; a.toValue = on ? 1 : 0
    a.beginTime = CACurrentMediaTime() + delay; a.duration = duration; a.fillMode = .backwards; a.timingFunction = Line.ease
    CATransaction.begin(); CATransaction.setDisableActions(true); l.opacity = on ? 1 : 0; l.add(a, forKey: "fade"); CATransaction.commit()
}

/// The person in front of the camera as a shape only: a 160x120 signed distance field (negative inside) from Vision's person mask.
/// No picture is kept or shown. `cur` drifts towards `goal`, so the outline flows instead of stepping.
final class Silhouette {
    static let w = 160, h = 120
    private let queue = DispatchQueue(label: "postura.shape", qos: .userInitiated), lock = NSLock()
    private var busy = false, wanted = false, goal: [Float]?, cur: [Float] = [], ring: [MTLTexture] = [], turn = 0
    private let request: VNGeneratePersonSegmentationRequest = { let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = .balanced; r.outputPixelFormat = kCVPixelFormatType_OneComponent8; return r }()
    /// Called by the cover: shapes are only computed while one is on screen.
    func want(_ on: Bool) { lock.lock(); if on && !wanted { goal = nil; cur = [] }; wanted = on; lock.unlock() }
    func feed(_ pb: CVPixelBuffer) {
        lock.lock(); let go = wanted && !busy; if go { busy = true }; lock.unlock()
        guard go else { return }
        queue.async { [self] in
            let f = autoreleasepool { () -> [Float]? in
                guard (try? VNImageRequestHandler(cvPixelBuffer: pb).perform([request])) != nil, let m = request.results?.first?.pixelBuffer else { return nil }
                return Silhouette.field(m)
            }
            lock.lock(); busy = false; if wanted, let f { goal = f }; lock.unlock()
        }
    }
    /// nil when there is (almost) nobody in the mask.
    static func field(_ m: CVPixelBuffer) -> [Float]? {
        CVPixelBufferLockBaseAddress(m, .readOnly); defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
        let mw = CVPixelBufferGetWidth(m), mh = CVPixelBufferGetHeight(m), bpr = CVPixelBufferGetBytesPerRow(m)
        guard let base = CVPixelBufferGetBaseAddress(m)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var inside = [Bool](repeating: false, count: w * h), n = 0
        for y in 0..<h { for x in 0..<w where base[(y * mh / h) * bpr + x * mw / w] > 127 { inside[y * w + x] = true; n += 1 } }
        guard n > w * h / 40, n < w * h * 97 / 100 else { return nil }
        func chamfer(_ zero: Bool) -> [Float] {                                        // distance to the nearest cell whose value is `zero`
            var d = inside.map { $0 == zero ? Float(0) : 1e4 }
            for y in 0..<h { for x in 0..<w { let i = y * w + x
                if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }
                if y > 0 { d[i] = min(d[i], d[i - w] + 1); if x > 0 { d[i] = min(d[i], d[i - w - 1] + 1.4142) }; if x < w - 1 { d[i] = min(d[i], d[i - w + 1] + 1.4142) } } } }
            for y in (0..<h).reversed() { for x in (0..<w).reversed() { let i = y * w + x
                if x < w - 1 { d[i] = min(d[i], d[i + 1] + 1) }
                if y < h - 1 { d[i] = min(d[i], d[i + w] + 1); if x > 0 { d[i] = min(d[i], d[i + w - 1] + 1.4142) }; if x < w - 1 { d[i] = min(d[i], d[i + w + 1] + 1.4142) } } } }
            return d
        }
        let a = chamfer(true), b = chamfer(false)
        var f = zip(a, b).map { ($0 - $1) / Float(h) }
        for _ in 0..<3 {                                                                // rounds off the cells: a flowing line, not a cut-out
            let g = f
            for y in 0..<h { for x in 0..<w {
                var s: Float = 0; for dy in -1...1 { for dx in -1...1 { s += g[min(h - 1, max(0, y + dy)) * w + min(w - 1, max(0, x + dx))] } }
                f[y * w + x] = s / 9 } }
        }
        return f
    }
    /// Once per animation frame; nil while there is no shape to show.
    func texture() -> MTLTexture? {
        lock.lock(); let g = goal; lock.unlock()
        guard let g, let dev = Glow.gpu?.dev else { return nil }
        if cur.count != g.count { cur = g } else { for i in g.indices { cur[i] += (g[i] - cur[i]) * 0.14 } }
        if ring.isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: Silhouette.w, height: Silhouette.h, mipmapped: false); d.usage = .shaderRead
            ring = (0..<4).compactMap { _ in dev.makeTexture(descriptor: d) }
        }
        guard !ring.isEmpty else { return nil }
        turn = (turn + 1) % ring.count
        ring[turn].replace(region: MTLRegionMake2D(0, 0, Silhouette.w, Silhouette.h), mipmapLevel: 0, withBytes: cur, bytesPerRow: Silhouette.w * 4)
        return ring[turn]
    }
}
let silhouette = Silhouette()

/// When the shape appears and how: every PERIOD s the outline is drawn by a passing light, holds, and dissolves outwards.
/// Direction, number of echoes and inner light change each time, so no two look the same. It is never shown continuously.
struct Apparition {
    static let PERIOD = 8.0, LIFE = 5.2
    var line: Float = 0, fill: Float = 0, grow: Float = 0, width: Float = 0, sweep: Float = 0, angle: Float = 0, echo: Float = 0, gap: Float = 0
    var alive = false
    init(_ t: Double) {                                                                  // t = seconds since the message appeared
        guard t >= 1.2 else { return }
        let n = Int((t - 1.2) / Apparition.PERIOD), u = (t - 1.2) - Double(n) * Apparition.PERIOD
        guard u < Apparition.LIFE else { return }
        func s(_ a: Double, _ b: Double) -> Float { let x = Float(min(1, max(0, (u - a) / (b - a)))); return x * x * (3 - 2 * x) }
        func r(_ k: Double) -> Float { let v = sin(Double(n + 1) * k) * 43758.5453; return Float(v - floor(v)) }
        let out = s(2.5, Apparition.LIFE), go = s(0.3, 1.9)
        alive = true; sweep = go; angle = (r(12.9898) - 0.5) * 2.4 + .pi / 2             // mostly upwards, from a different side every time
        line = s(0.2, 0.8) * (1 - s(2.9, Apparition.LIFE)); fill = (0.35 + 0.65 * r(78.233)) * go * (1 - s(2.2, 4.0))
        grow = 0.20 * out * (r(39.425) < 0.3 ? 0.35 : 1); width = 0.006 + 0.05 * out
        echo = out * (1 - s(3.4, Apparition.LIFE)) * (r(3.17) < 0.35 ? 0.4 : 1); gap = 0.05 + 0.07 * out
    }
}

/// The light of the warning, drawn in one small Metal pass (1/4 of the points, 30 fps) and stretched. Everything in it is soft, so it
/// looks the same as the former stack of full-resolution blurred layers, which cost the window server enough to slow the whole Mac.
final class Glow {
    struct Params {
        var size = SIMD2<Float>(0, 0), pad = SIMD2<Float>(0, 0)
        var front = SIMD4<Float>(0, 0, 0, 1)          // half-width, half-height, wave amplitude, feather
        var rim = SIMD4<Float>(0, 1, 1, 0)            // wave amplitude, rim width factor, front width factor, time
        var opacity = SIMD4<Float>(0, 0, 0, 0)        // tint, colour wash, rim, front
        var frame = SIMD4<Float>(0, 0, 1, 1)          // where the camera frame lies: left, bottom, width, height
        var shapeA = SIMD4<Float>(0, 0, 0.01, 0)      // line, inner light, line width, growth (in frame heights)
        var shapeB = SIMD4<Float>(0, 0, 0, 0.1)       // sweep, its direction, echoes, their spacing
        var stops: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero)
    }
    static let scale: CGFloat = 4
    static let gpu: (dev: MTLDevice, queue: MTLCommandQueue, pipe: MTLRenderPipelineState)? = {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let lib = try? d.makeLibrary(source: shader, options: nil) else { log("no Metal"); return nil }
        let r = MTLRenderPipelineDescriptor(); r.vertexFunction = lib.makeFunction(name: "v"); r.fragmentFunction = lib.makeFunction(name: "f"); r.colorAttachments[0].pixelFormat = .rgba16Float
        guard let p = try? d.makeRenderPipelineState(descriptor: r) else { log("no Metal pipeline"); return nil }
        return (d, q, p)
    }()
    static let blank: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false); d.usage = .shaderRead
        let t = gpu?.dev.makeTexture(descriptor: d); var far: Float = 9; t?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &far, bytesPerRow: 4); return t
    }()
    let layer = CAMetalLayer(), work = DispatchQueue(label: "postura.glow", qos: .userInteractive), lock = NSLock()
    var inFlight = 0
    init() {
        layer.device = Glow.gpu?.dev; layer.pixelFormat = .rgba16Float; layer.isOpaque = false; layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB); layer.contentsGravity = .resize; layer.magnificationFilter = .linear
    }
    /// Never waits on the main thread: a frame is skipped when two are still on their way.
    func render(_ p: Params, _ shape: MTLTexture?) {
        guard let gpu = Glow.gpu else { return }
        lock.lock(); let busy = inFlight >= 2; if !busy { inFlight += 1 }; lock.unlock()
        if busy { return }
        work.async { [self] in
            func done() { lock.lock(); inFlight -= 1; lock.unlock() }
            guard let d = layer.nextDrawable(), let c = gpu.queue.makeCommandBuffer() else { done(); return }
            Glow.encode(p, shape, into: d.texture, c, gpu.pipe)
            c.addCompletedHandler { _ in done() }
            c.present(d); c.commit()
        }
    }
    static func encode(_ p: Params, _ shape: MTLTexture?, into t: MTLTexture, _ c: MTLCommandBuffer, _ pipe: MTLRenderPipelineState) {
        let r = MTLRenderPassDescriptor(); r.colorAttachments[0].texture = t; r.colorAttachments[0].loadAction = .dontCare; r.colorAttachments[0].storeAction = .store
        guard let e = c.makeRenderCommandEncoder(descriptor: r) else { return }
        var q = p; e.setFragmentTexture(shape ?? Glow.blank, index: 0); e.setRenderPipelineState(pipe); e.setFragmentBytes(&q, length: MemoryLayout<Params>.stride, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
    }
    static func cdf(_ z: Float) -> Float { 1 / (1 + exp(-1.702 * min(20, max(-20, z)))) }
    /// 0 inside the front, 1 outside it, feathered (the CPU twin of box() in the shader, for the frost mask).
    static func region(_ q: SIMD2<Float>, _ p: Params) -> Float {
        let u = q.x / p.front.x, v = q.y / p.front.y, g = min(1, sqrt(u * u + v * v)), th = atan2(v, u), s2 = sin(2 * th), t = p.rim.w
        let wave = 0.55 * sin(3 * th + 0.45 * t) + 0.30 * sin(5 * th - 0.70 * t + 1.3) + 0.15 * sin(9 * th + 1.10 * t + 2.1)
        let k = 1 - 0.06 * s2 * s2 * g * g, a = p.front.x * k + p.front.z * wave * g * g, b = p.front.y * k + p.front.z * wave * g * g, r = p.front.w
        return 1 - (cdf((a - q.x) / r) - cdf((-a - q.x) / r)) * (cdf((b - q.y) / r) - cdf((-b - q.y) / r))
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct P { float2 size, pad; float4 front, rim, op, frame, sa, sb; float4 st[7]; };
    struct V { float4 pos [[position]]; float2 uv; };
    vertex V v(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V o; o.pos = float4(q * 2 - 1, 0, 1); o.uv = q; return o; }
    static float cdf(float z) { return 1 / (1 + exp(-1.702 * clamp(z, -20.0, 20.0))); }
    // a filled rounded rectangle (half-size ab, corners drawn in by c) whose rim carries three slow travelling waves, grown by `grow`
    // and blurred by r: the closed form of a Gaussian-blurred box, so it has no creases anywhere
    static float box(float2 q, float2 ab, float c, float cp, float amp, float t, float grow, float r) {
        float2 u = q / ab; float g = min(1.0, length(u)), th = atan2(u.y, u.x), s2 = sin(2 * th);
        float wave = 0.55 * sin(3 * th + 0.45 * t) + 0.30 * sin(5 * th - 0.70 * t + 1.3) + 0.15 * sin(9 * th + 1.10 * t + 2.1);
        float2 h = ab * (1 - c * pow(s2 * s2, cp) * g * g) + amp * wave * g * g + grow;
        return max(0.0, cdf((h.x - q.x) / r) - cdf((-h.x - q.x) / r)) * max(0.0, cdf((h.y - q.y) / r) - cdf((-h.y - q.y) / r));
    }
    static float stroke(float2 q, float2 ab, float c, float cp, float amp, float t, float half_, float r) {
        return clamp(box(q, ab, c, cp, amp, t, half_, r) - box(q, ab, c, cp, amp, t, -half_, r), 0.0, 1.0);
    }
    static float3 around(float a, constant P& p) {
        a = fract(a); float3 c = p.st[0].rgb;
        for (int i = 0; i < 6; i++) { float w = max(p.st[i + 1].w - p.st[i].w, 1e-4); c = mix(c, p.st[i + 1].rgb, clamp((a - p.st[i].w) / w, 0.0, 1.0)); }
        return c;
    }
    static float at(texture2d<float> s, int2 i) { i = clamp(i, int2(0), int2(s.get_width() - 1, s.get_height() - 1)); return s.read(uint2(i)).r; }
    static float field(texture2d<float> s, float2 uv) {                             // bilinear by hand: 32-bit floats are not filterable everywhere
        float2 x = uv * float2(s.get_width(), s.get_height()) - 0.5, fx = fract(x); int2 i = int2(floor(x));
        return mix(mix(at(s, i), at(s, i + int2(1, 0)), fx.x), mix(at(s, i + int2(0, 1)), at(s, i + int2(1, 1)), fx.x), fx.y);
    }
    fragment float4 f(V in [[stage_in]], constant P& p [[buffer(0)]], texture2d<float> shape [[texture(0)]]) {
        float2 q = (in.uv - 0.5) * p.size; float t = p.rim.w, R = length(q);
        float ang = atan2(q.x, q.y) / (2 * M_PI_F) + t / 14;
        float3 light = around(ang, p), wash = 0;
        float blur = min(0.35, 70 / (6.2832 * max(R, 1.0)));                          // the wash is blurred by 70 pt: wider in angle near the centre
        for (int i = -4; i <= 4; i++) wash += around(ang + blur * i * 0.45, p) * exp(-0.1 * float(i * i));
        float ws = 0; for (int i = -4; i <= 4; i++) ws += exp(-0.1 * float(i * i));
        wash /= ws;
        float3 mean = 0; for (int i = 0; i < 6; i++) mean += p.st[i].rgb / 6;
        wash = mix(mean, wash, smoothstep(0.0, 320.0, R));
        float region = 1, front = 0;
        if (p.front.x > 4 && p.front.y > 4) {
            region = 1 - box(q, p.front.xy, 0.06, 1, p.front.z, t, 0, p.front.w);
            front = stroke(q, p.front.xy, 0.06, 1, p.front.z, t, 10 * p.rim.z, 36) * p.op.w;
        }
        float2 e = p.size / 2; float k = p.rim.y, ra = p.rim.x, rt = t * 0.8 + 7, keep = 1;
        keep *= 1 - stroke(q, e, 0.04, 4, ra, rt, 4 * k, 2); keep *= 1 - stroke(q, e, 0.04, 4, ra, rt, 10 * k, 6);
        keep *= 1 - stroke(q, e, 0.04, 4, ra, rt, 22 * k, 18); keep *= 1 - stroke(q, e, 0.04, 4, ra, rt, 44 * k, 52);
        float rim = (1 - keep) * p.op.z;
        float4 o = float4(float3(0.12, 0.08, 0.22), 1) * p.op.x;                       // premultiplied, back to front
        float w = p.op.y * region; o = float4(wash, 1) * w + o * (1 - w);
        o = float4(light, 1) * rim + o * (1 - rim);
        o = float4(light, 1) * front + o * (1 - front);
        if (p.sa.x + p.sa.y + p.sb.z > 0.001) {                                         // the person as light: outline, inner glow, echoes
            float2 c = (in.uv * p.size - p.frame.xy) / p.frame.zw;                      // 0..1 in the camera frame, y up
            float edge = smoothstep(0.0, 0.16, c.x) * (1 - smoothstep(0.84, 1.0, c.x)) * smoothstep(0.10, 0.34, c.y) * (1 - smoothstep(0.90, 1.0, c.y));
            float d = field(shape, float2(1 - c.x, 1 - c.y));                           // mirrored, like a mirror
            d += 0.006 * sin(c.y * 21 + t * 1.3) * sin(c.x * 17 - t * 0.9);             // a slight breath, never a hard contour
            float along = dot(c - 0.5, float2(cos(p.sb.y), sin(p.sb.y))) + 0.5;
            float head = mix(-0.35, 1.5, p.sb.x), lit = 1 - smoothstep(head - 0.35, head, along);
            float spark = exp(-pow((along - head + 0.1) / 0.10, 2.0)) * (1 - p.sb.x);
            float w = p.sa.z, g = p.sa.w;
            float L = exp(-pow((d - g) / w, 2.0)) * 0.9 + exp(-abs(d - g) / (w * 4 + 0.02)) * 0.35;
            L *= p.sa.x * lit * mix(1.0, 0.45, saturate(g / 0.2)) * (1 + 1.2 * spark);
            float E = 0; for (int i = 1; i <= 3; i++) E += exp(-pow((d - g * 0.5 - p.sb.w * i) / (0.010 + 0.006 * i), 2.0)) / (1 + i);
            float F = d < 0 ? 0.10 + 0.55 * exp(d / 0.045) : 0.55 * exp(-d / 0.03) + 0.10 * exp(-d / 0.02);
            float3 hue = around(ang * 0.5 + along * 0.7 + t / 20, p), glow = hue * (F * p.sa.y * lit * 0.8 + E * p.sb.z * 0.75) + mix(hue, float3(1), 0.62) * L;
            glow = 1 - exp(-glow * edge * 1.15);
            o.rgb = o.rgb + glow * (1 - o.rgb * 0.75); o = float4(min(o.rgb, 1.0), o.a + (1 - o.a) * max(glow.r, max(glow.g, glow.b)));
        }
        return o;
    }
    """
}

/// The warning, after the Apple Intelligence edge glow: light lives on the physical screen edge and floods inward as posture
/// stays bad, with every boundary feathered (no hard line anywhere). Blur and colour follow one soft, slowly waving front;
/// correcting posture pulls it back to the edge. Locked: the whole screen is frosted and tinted, the rim breathes.
final class Liquid {
    static let palette: [SIMD4<Float>] = ["BC82F3", "F5B9EA", "8D9FFF", "FF6778", "FFBA71", "C686FF"].map { h in
        let v = Int(h, radix: 16)!; return SIMD4(Float(v >> 16 & 255) / 255, Float(v >> 8 & 255) / 255, Float(v & 255) / 255, 1) }
    let win: KeyWin, blur = NSVisualEffectView(), glow = Glow(), frost = CALayer()
    let content = NSView(), title: Line, why: Line, foot: Line, date: Line, clock: Line, button = NSButton()
    let dayFmt = DateFormatter(), timeFmt = DateFormatter()
    let main: Bool; var lastShuffle = -10.0, shown = false, shownAt = 0.0, lastClock = -10.0
    var from: [SIMD4<Float>] = [], to: [SIMD4<Float>] = [], size = CGSize.zero, frostOpen = true
    init(frame f: NSRect, main: Bool, target: AnyObject, action: Selector) {
        let W = f.width, H = f.height; size = f.size; self.main = main
        win = KeyWin(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())); win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]; win.ignoresMouseEvents = true
        win.appearance = NSAppearance(named: .darkAqua)
        let root = win.contentView!; root.wantsLayer = true
        blur.appearance = NSAppearance(named: .aqua); blur.material = .fullScreenUI; blur.blendingMode = .behindWindow; blur.state = .active; blur.frame = root.bounds; root.addSubview(blur)
        blur.wantsLayer = true; frost.frame = root.bounds; frost.contentsGravity = .resize; blur.layer?.mask = frost
        let host = NSView(frame: root.bounds); host.wantsLayer = true; root.addSubview(host)
        glow.layer.frame = host.bounds; glow.layer.drawableSize = CGSize(width: ceil(W / Glow.scale), height: ceil(H / Glow.scale)); host.layer?.addSublayer(glow.layer)
        content.frame = root.bounds; root.addSubview(content)
        // the middle belongs to the shape: the time sits in the top left corner, the message in the bottom left one, the action bottom right
        let m = max(40, W * 0.035), tw = W - 2 * m, ts = min(44, H * 0.055), ws = min(19, H * 0.026), cs = min(34, H * 0.045)
        var y = m * 0.9
        func up(_ size: CGFloat, gap: CGFloat) -> CGFloat { defer { y += ceil(size * 1.32) + gap }; return y }
        foot = Line(content, x: m, y: up(13, gap: 12), width: tw * 0.6, size: 13, weight: .regular, alpha: 0.8)
        why = Line(content, x: m, y: up(ws, gap: 2), width: tw, size: ws, weight: .medium, alpha: 0.9)
        title = Line(content, x: m, y: up(ts, gap: 0), width: tw, size: ts, weight: .semibold)
        clock = Line(content, x: m, y: H - m * 0.9 - ceil(cs * 1.32), width: tw / 2, size: cs, weight: .semibold, digits: true)
        date = Line(content, x: m, y: clock.frame.minY - 22, width: tw / 2, size: 15, weight: .medium, alpha: 0.8)
        dayFmt.locale = Locale(identifier: spanish ? "es_ES" : "en_US"); dayFmt.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        timeFmt.locale = Locale.current; timeFmt.dateFormat = (DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current) ?? "H:mm")
            .replacingOccurrences(of: "a", with: "").replacingOccurrences(of: "\u{202F}", with: "").trimmingCharacters(in: .whitespaces)
        if main {
            button.frame = NSRect(x: W - m - 440, y: m * 0.9, width: 440, height: 40); button.bezelStyle = .rounded; button.controlSize = .large
            button.font = .systemFont(ofSize: 15, weight: .medium); button.focusRingType = .none
            button.target = target; button.action = action; content.addSubview(button)
        }
        content.wantsLayer = true; button.wantsLayer = true; button.layer?.opacity = 0
        shuffle(0); from = to
    }
    /// New random stop positions, eased over 1.2 s, so the colours drift around the edge. A stop is rgb + its place on the circle.
    func shuffle(_ t: Double) {
        from = stops(t); lastShuffle = t
        var c = Liquid.palette.map { SIMD4($0.x, $0.y, $0.z, Float.random(in: 0...1)) }.sorted { $0.w < $1.w }
        var last = c[0]; last.w = 1; c.append(last); c[0].w = 0; to = c                // closes the circle with no seam
    }
    func stops(_ t: Double) -> [SIMD4<Float>] {
        guard from.count == to.count, !to.isEmpty else { return to }
        let x = Float(min(1, max(0, (t - lastShuffle) / 1.2))), e = x * x * (3 - 2 * x)
        return zip(from, to).map { $0 + ($1 - $0) * e }
    }
    /// The frost mask: the same front as the glow, computed small (1/16) and stretched; dropped once the front has closed.
    func drawFrost(_ p: Glow.Params) {
        if p.front.x <= 4 || p.front.y <= 4 { if frostOpen { frostOpen = false; blur.layer?.mask = nil }; return }
        if !frostOpen { frostOpen = true; blur.layer?.mask = frost }
        let w = Int(size.width / 16), h = Int(size.height / 16)
        guard w > 0, h > 0 else { return }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for j in 0..<h { for i in 0..<w {
            let q = SIMD2(Float((CGFloat(i) + 0.5) * size.width / CGFloat(w) - size.width / 2), Float(size.height / 2 - (CGFloat(j) + 0.5) * size.height / CGFloat(h)))
            let v = UInt8(255 * min(1, max(0, Glow.region(q, p)))), k = (j * w + i) * 4
            px[k] = v; px[k + 1] = v; px[k + 2] = v; px[k + 3] = v
        } }
        guard let d = CGDataProvider(data: Data(px) as CFData),
              let m = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: d, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        frost.contents = m
    }
    /// The message fades in once, top to bottom, and out together.
    func reveal(_ on: Bool, t: Double) {
        guard on != shown else { return }; shown = on; if on { shownAt = t }
        for (i, v) in [clock, date, title, why, foot].enumerated() { fade(v, on, delay: on ? 0.12 * Double(i) : 0, duration: on ? 1.0 : 0.3) }
        if button.superview != nil { fade(button, on && button.isEnabled, delay: on ? 0.9 : 0, duration: on ? 0.8 : 0.3) }
    }
    func draw(level: Double, t: Double, shape: MTLTexture?) {
        if t - lastShuffle > 1.2 { shuffle(t) }
        let bw = size.width, bh = size.height, short = min(bw, bh)
        let s = CGFloat(min(1, max(0, level))), ease = s * s * (3 - 2 * s), breathe = CGFloat(0.5 + 0.5 * sin(1.3 * t))
        let locked = CGFloat(min(1, max(0, (level - 0.88) / 0.12)))
        let fade = min(1, 6 * s)                                                     // everything eases in from nothing and back out
        let soft = 30 + 110 * ease                                                   // feather radius grows as the light moves in
        let d = ease * (short / 2 + 1.15 * soft)                                     // how far the front has travelled; closes only at the end
        let a = bw / 2 + soft - d, b = bh / 2 + soft - d
        var p = Glow.Params()
        p.size = SIMD2(Float(bw), Float(bh)); p.front = SIMD4(Float(a), Float(b), Float(max(0, min(14 + 30 * ease, 0.12 * min(a, b)))), Float(soft))
        p.rim = SIMD4(Float(4 + 8 * breathe * (0.4 + 0.6 * locked)), Float(0.7 + 0.45 * ease + 0.2 * locked * breathe), Float(0.8 + 0.4 * ease), Float(t))
        p.opacity = SIMD4(Float(0.66 * locked),                                      // tint: depth behind the message, not a grey dim
                          Float(fade * (0.25 + 0.35 * ease - 0.22 * locked + 0.06 * locked * breathe)),
                          Float(fade * min(1, 0.6 + 2.5 * s) * (0.85 + 0.15 * breathe)),
                          Float(0.45 * min(1, 4 * s) * (1 - locked)))                // a faint luminous edge on the front, never a line
        let fh = bh * 0.9, fw = fh * 4 / 3; p.frame = SIMD4(Float((bw - fw) / 2), 0, Float(fw), Float(fh))
        if shown, shape != nil {
            let a = Apparition(t - shownAt)
            p.shapeA = SIMD4(a.line, a.fill, max(0.004, a.width), a.grow); p.shapeB = SIMD4(a.sweep, a.angle, a.echo, a.gap)
        }
        let c = stops(t); withUnsafeMutableBytes(of: &p.stops) { $0.copyBytes(from: c.withUnsafeBytes { Array($0) }) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blur.alphaValue = fade; drawFrost(p)
        CATransaction.commit()
        glow.render(p, shape)
        if t - lastClock > 1 { lastClock = t; let today = Date(); date.set(dayFmt.string(from: today)); clock.set(timeFmt.string(from: today)) }
        reveal(level >= (shown ? 0.85 : 0.97), t: t)
    }
    /// With no corrections left there is no dead button, only the line of text that says so.
    func setButton(_ s: String, enabled: Bool) {
        if button.title != s { button.title = s }
        guard button.isEnabled != enabled else { return }
        button.isEnabled = enabled; if shown, button.superview != nil { fade(button, enabled, delay: 0, duration: 0.4) }
    }
}

final class Guard: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession(), queue = DispatchQueue(label: "postura.camera"), eye = Eye()
    var lastFrame = Date.distantPast, lastProcessed = Date.distantPast, lastSampleAt = Date.distantPast, lastSeen = Date.distantPast
    var pBar = 0.0, badSince: Date?, graceUntil = Date.distantPast, lastFaceAt = Date.distantPast
    var level = 0.0, blocked = false, releasing = false, lastAnim = Date(), t0 = Date()
    var present = false, dodging = false, training = "", reason = "", reasonKind = "", note = "", noteUntil = Date.distantPast, lastSample: [String: Any] = [:]
    var camera = true, inCall = false, locked = false, poweringOff = false
    var screenFrames: [NSRect] = [], liquids: [Liquid] = [], hud: NSWindow?, hudText: NSTextField?, keyMonitor: Any?
    var message: (String, String)?, messageAt = Date.distantPast, pendingKey = "", pendingAt = Date.distantPast
    var blockedSeconds = 0.0, raisedAt = Date.distantPast, wroteAt = Date.distantPast, wroteMode = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in self.poweringOff = true }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {   // lid opened / display woke: the camera stops while asleep
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in log("wake"); self.reset("wake"); self.restartCamera() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            // locking hides the Dock and the menu bar, which posts this too: only a real change of displays rebuilds the cover
            if !self.liquids.isEmpty, self.screenFrames != NSScreen.screens.map(\.frame) { self.dropLiquids() }
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { _ in log("camera runtime error"); self.restartCamera() }
        log("start")
        eye.onSample = { s in DispatchQueue.main.async { self.handle(s, Date()) } }
        shell.start()
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { if ok { self.startCamera() } else { self.camera = false; log("camera denied") } } }
        every(1.0 / 30) { self.animate() }
        every(0.5) { self.tick() }
        every(10) { self.checkCall() }
        startWatchdog()
        checkCall(); showHUD(); installHotkeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in   // while blocked this app has the keyboard: plain G corrects it
            if self.blocked, e.charactersIgnoringModifiers?.lowercased() == "g" { self.teach("good") }
            return nil
        }
    }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { shell.show(); return false }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply { poweringOff ? .terminateNow : .terminateCancel }

    // Run-loop timers once stopped for good while the screen was covered (24 Nov 2026) although the main queue kept running, so
    // everything periodic runs on the main queue. If the animation still stops, the watchdog ends the process: that removes the
    // cover at once, and the guard or launchd starts a fresh copy. systemUptime stands still during sleep, so waking is no stall.
    var sources: [DispatchSourceTimer] = []
    let beatLock = NSLock(); var beat = ProcessInfo.processInfo.systemUptime
    func every(_ s: Double, _ f: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + s, repeating: s, leeway: .milliseconds(s < 0.1 ? 2 : 50))
        t.setEventHandler(handler: f); t.resume(); sources.append(t)
    }
    func startWatchdog() {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 2)
                self.beatLock.lock(); let idle = ProcessInfo.processInfo.systemUptime - self.beat; self.beatLock.unlock()
                if idle > 8 { log("watchdog: no animation for \(Int(idle)) s, restarting"); _exit(1) }
            }
        }
    }

    // MARK: camera
    func startCamera() {
        let devs = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        guard let dev = devs.first(where: { !$0.localizedName.contains("Virtual") }) ?? devs.first,
              let input = try? AVCaptureDeviceInput(device: dev) else { camera = false; log("no camera"); return }
        session.sessionPreset = .vga640x480
        if session.canAddInput(input) { session.addInput(input) }
        let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        // 15 frames/s: macOS runs its video effects (portrait, studio light) on every frame, twice as many as anything here needs
        queue.async {
            self.session.startRunning()
            if dev.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }), (try? dev.lockForConfiguration()) != nil {
                dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15); dev.unlockForConfiguration()
            }
        }
        camera = true; log("camera \(dev.localizedName)")
    }
    func restartCamera() {
        guard camera else { return }
        queue.async { if self.session.inputs.isEmpty { DispatchQueue.main.async { self.startCamera() } } else if !self.session.isRunning { self.session.startRunning() } }
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        let now = Date()  // 2.5 frames/s while all is well, 6/s while something looks wrong
        if level > 0.85, let live = CMSampleBufferGetImageBuffer(sb) { silhouette.feed(live) }
        guard now.timeIntervalSince(lastProcessed) > (level == 0 && pBar < RELEASE && training.isEmpty ? 0.4 : 0.16), let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastProcessed = now
        eye.send(pb)
    }

    // MARK: judgement -> smoothed p
    func reset(_ why: String) { if (level > 0 || blocked) && pBar > 0 { log("clear: \(why)") }; pBar = 0; badSince = nil }
    func handle(_ s: [String: Any], _ now: Date) {
        let dt = min(1.0, max(0.05, now.timeIntervalSince(lastSampleAt)))
        lastFrame = now; lastSampleAt = now; lastSample = s
        training = s["training"] as? String ?? ""
        let seen = (s["face"] as? Bool) == true, person = (s["person"] as? Bool) == true
        if seen || person { lastSeen = now }
        present = now.timeIntervalSince(lastSeen) < 2.5   // a missed frame or two is not "gone": hold the current state
        // Once a warning is under way, leaning out of view, hiding the face or turning away never clears it: it keeps
        // counting as bad until you come back and sit well, or are really gone for HOLD seconds.
        let warning = level > 0 || pBar >= BLOCK, unjudged = (s["kind"] as? String) == "unjudged"
        dodging = warning && (!seen || unjudged) && now.timeIntervalSince(lastFaceAt) < HOLD
        if seen && !unjudged { lastFaceAt = now }
        if dodging {
            pBar += (1 - exp(-dt / 1.2)) * (1 - pBar); badSince = badSince ?? now; reasonKind = "hidden"
            reason = L("no te veo", "can't see you"); return
        }
        if !present { reset("nobody in frame"); return }
        // a "person" without a face (a coat on a chair, a back, a hand) must not keep the cover up for ever: after HOLD it counts as gone
        if warning && !seen && now.timeIntervalSince(lastFaceAt) >= HOLD { reset("no face for \(Int(HOLD)) s"); return }
        if !training.isEmpty || now < graceUntil { pBar = 0; badSince = nil; return }
        if !seen { return }
        let p = (s["p"] as? NSNumber)?.doubleValue ?? 0
        pBar += (1 - exp(-dt / 1.2)) * (p - pBar)
        if pBar >= BLOCK { badSince = badSince ?? now; reason = s["why"] as? String ?? ""; reasonKind = s["kind"] as? String ?? "" } else if pBar < RELEASE { badSince = nil }
    }
    func brief(_ s: [String: Any]) -> String {
        ["pitch", "roll", "yaw", "neck", "fwd", "noseY", "shY", "shTilt", "dist", "glasses", "faces"].compactMap { k in (s[k] as? NSNumber).map { "\(k)=\(f2($0.doubleValue))" } }.joined(separator: " ")
    }

    // MARK: liquid level 0..1, 30 times a second
    func animate() {
        let now = Date(), dt = min(0.2, now.timeIntervalSince(lastAnim)); lastAnim = now
        beatLock.lock(); beat = ProcessInfo.processInfo.systemUptime; beatLock.unlock()
        let bad = (present || dodging) && !locked && pBar >= BLOCK && badSince != nil && now.timeIntervalSince(badSince!) >= GRACE && now >= graceUntil
        let good = (!present && !dodging) || locked || pBar < RELEASE || now < graceUntil
        let cap = inCall ? 0.22 : 1.0     // on a call only a thin edge glow shows, it never blocks
        // a released cover always drains completely: wavering at the threshold must not lock, unlock and lock again
        if releasing { level = max(0, level - dt / DRAIN); if level <= 0 { releasing = false } }
        else if bad { level = min(cap, level + dt / FILL) } else if good { level = max(0, level - dt / DRAIN) }
        if level > cap { level = max(cap, level - dt / DRAIN) }
        if level >= 1, !blocked { setBlocked(true) } else if level < 0.97, blocked { releasing = true; setBlocked(false) }
        if blocked { blockedSeconds += dt }
        if level <= 0 { silhouette.want(false); message = nil; if !liquids.isEmpty { dropLiquids() }; return }
        if liquids.isEmpty {
            screenFrames = NSScreen.screens.map(\.frame)
            liquids = NSScreen.screens.map { Liquid(frame: $0.frame, main: $0 == NSScreen.main || NSScreen.screens.count == 1, target: self, action: #selector(fixClicked)) }
            liquids.forEach { $0.win.ignoresMouseEvents = !blocked; $0.win.orderFrontRegardless() }
        }
        let t = now.timeIntervalSince(t0)
        let showing = liquids.contains { $0.shown && Apparition(t - $0.shownAt + 0.6).alive }
        silhouette.want(showing)
        let shape = showing ? silhouette.texture() : nil
        for l in liquids { l.draw(level: level, t: t, shape: shape) }
    }
    func dropLiquids() { liquids.forEach { $0.win.orderOut(nil) }; liquids = [] }
    func setBlocked(_ on: Bool) {
        blocked = on
        liquids.forEach { $0.win.ignoresMouseEvents = !on }
        if on {
            log("BAD \(reason) p=\(f2(pBar)) \(brief(lastSample))")
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableSessionTermination, .disableHideApplication, .disableAppleMenu]
        } else {
            log("ok p=\(f2(pBar)) \(brief(lastSample))")
            NSApp.presentationOptions = []; NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: teaching and corrections
    // "good"/"bad": the last 4 s and next 6 s become posture examples (postura-eye.py). "good" while it says bad is a
    // correction: it also drains the liquid, limited per day so it cannot be used to slouch all day.
    @objc func fixClicked() { teach("good") }
    func fixesLeft() -> Int { max(0, FIXES_PER_DAY - UserDefaults.standard.integer(forKey: "fixes-" + String(stamp.string(from: Date()).prefix(10)))) }
    func teach(_ label: String) {
        let now = Date(); var label = label
        if label == "good" && (level > 0 || pBar >= 0.5) {
            let key = "fixes-" + String(stamp.string(from: now).prefix(10)), used = UserDefaults.standard.integer(forKey: key)
            if used >= FIXES_PER_DAY { flash(L("Sin más correcciones hoy", "No corrections left today") + " (\(FIXES_PER_DAY)/\(FIXES_PER_DAY))"); log("FIX refused: limit reached"); return }
            UserDefaults.standard.set(used + 1, forKey: key)
            if reasonKind == "glasses" || reasonKind == "sunglasses" { label = "gafas" }      // "I do have my glasses on"
            log("FIX \(used + 1)/\(FIXES_PER_DAY) as \(label), was: \(reason) p=\(f2(pBar)) \(brief(lastSample))")
            graceUntil = now.addingTimeInterval(8); pBar = 0; badSince = nil
        } else { log("LABEL \(label) p=\(f2(pBar)) \(brief(lastSample))") }
        try? label.write(to: trainURL, atomically: true, encoding: .utf8)
        flash(label == "bad" ? L("Aprendiendo: esta postura es MALA…", "Learning: this posture is BAD…") : label == "gafas" ? L("Aprendiendo: llevas las gafas puestas…", "Learning: you are wearing your glasses…") : L("Aprendiendo: esta postura es BUENA…", "Learning: this posture is GOOD…"))
    }
    func flash(_ s: String) { note = s; noteUntil = Date().addingTimeInterval(6) }
    func installHotkeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
            var id = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let which = id.id
            DispatchQueue.main.async { g.teach(which == 1 ? "good" : "bad") }
            return noErr
        }, 1, &spec, nil, nil)
        let mods = UInt32(cmdKey | optionKey | controlKey)
        var r1: EventHotKeyRef?, r2: EventHotKeyRef?
        let a = RegisterEventHotKey(UInt32(kVK_ANSI_G), mods, EventHotKeyID(signature: OSType(0x50535452), id: 1), GetApplicationEventTarget(), 0, &r1)
        let b = RegisterEventHotKey(UInt32(kVK_ANSI_B), mods, EventHotKeyID(signature: OSType(0x50535452), id: 2), GetApplicationEventTarget(), 0, &r2)
        log("hotkeys G=\(a) B=\(b)")
    }

    // MARK: HUD and housekeeping, twice a second
    func showHUD() {  // small always-visible verdict, so you can see what it thinks without asking
        guard let f = NSScreen.main?.visibleFrame else { return }
        // a small frosted capsule, like a system HUD; its text crossfades instead of jumping
        let w = NSWindow(contentRect: NSRect(x: f.minX + 10, y: f.minY + 10, width: 440, height: 26), styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .statusBar; w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let v = NSVisualEffectView(frame: w.contentView!.bounds); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        v.wantsLayer = true; v.layer?.cornerRadius = 13; v.layer?.masksToBounds = true; w.contentView = v
        let t = NSTextField(labelWithString: ""); t.frame = NSRect(x: 12, y: 5, width: 420, height: 16); t.font = .systemFont(ofSize: 11.5, weight: .medium)
        t.lineBreakMode = .byTruncatingTail; t.wantsLayer = true; v.addSubview(t)
        w.alphaValue = 0; w.orderFrontRegardless(); hud = w; hudText = t
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.6; w.animator().alphaValue = 1 }
    }
    func tick() {
        let now = Date()
        locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let stale = now.timeIntervalSince(lastFrame)
        if stale > 6 { present = false; reset("no frames") }
        if stale > 12, camera, !locked { restartCamera() }                       // lid was closed, camera taken away, etc.
        let k = reasonKind, left = fixesLeft(), glasses = k == "glasses" || k == "sunglasses"
        let cap = reason.prefix(1).uppercased() + reason.dropFirst()
        let (head, line): (String, String) = {
            switch k {
            case "glasses": return (L("Ponte las gafas", "Put your glasses on"), L("Sin gafas · se quita en cuanto te las pongas", "No glasses · this clears as soon as you put them on"))
            case "sunglasses": return (L("Ponte tus gafas", "Put your glasses on"), L("Las gafas de sol no cuentan · ponte las tuyas", "Sunglasses don't count · wear your own glasses"))
            case "both": return (L("Siéntate bien y ponte las gafas", "Sit up and put your glasses on"), cap + L(" · se quita cuando arregles las dos cosas", " · clears when both are fixed"))
            case "hidden": return (L("Vuelve frente a la cámara", "Come back in front of the camera"), L("Apartarte no lo quita · siéntate bien donde te vea", "Moving out of view doesn't clear it · sit up where I can see you"))
            default: return (L("Siéntate bien", "Sit up straight"), cap + L(" · se quita en cuanto corrijas la postura", " · this clears as soon as you fix your posture"))
            }
        }()
        // the judge may change its mind several times a second; the words change only when the new reason has held for 3 s, at most every 6 s
        if head + line != pendingKey { pendingKey = head + line; pendingAt = now }
        if level > 0, message == nil || level < 0.9 || (now.timeIntervalSince(pendingAt) >= 3 && now.timeIntervalSince(messageAt) >= 6), message?.0 != head || message?.1 != line {
            message = (head, line); messageAt = now
        }
        for l in liquids {
            l.title.set(message?.0 ?? head); l.why.set(message?.1 ?? line)
            l.setButton(left > 0 ? (glasses ? L("Las llevo puestas — pulsa G o haz clic (quedan \(left) hoy)", "I'm wearing them — press G or click (\(left) left today)")
                                            : L("Estoy bien sentado — pulsa G o haz clic (quedan \(left) hoy)", "I'm sitting fine — press G or click (\(left) left today)"))
                                 : L("Sin correcciones por hoy", "No corrections left today"), enabled: left > 0)
            l.foot.set(L("Todo sigue funcionando por detrás.", "Everything keeps running in the background.") + (left > 0 ? "" : L("  Sin correcciones por hoy.", "  No corrections left today.")))
        }
        if blocked, let w = (liquids.first { $0.main } ?? liquids.first)?.win, !NSApp.isActive || !w.isKeyWindow || now.timeIntervalSince(raisedAt) > 3 {
            raisedAt = now; if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }     // only when something took the front; repeating it is slow
            liquids.forEach { $0.win.orderFrontRegardless() }; w.makeKey()
        }
        var text = "", color = NSColor.systemGreen
        if now < noteUntil { text = note; color = .systemYellow }
        else if !camera { text = L("Postura: sin cámara (Ajustes → Privacidad → Cámara)", "Postura: no camera (Settings → Privacy → Camera)"); color = .systemOrange }
        else if !present { text = L("Postura: no te veo, no hago nada", "Postura: can't see you, doing nothing"); color = .systemGray }
        else if pBar >= BLOCK { text = "● \(L("MAL", "BAD")) \(Int(pBar * 100))% · \(reason)"; color = .systemRed }
        else if pBar >= RELEASE { text = "● \(L("dudoso", "unsure")) \(Int(pBar * 100))% · \(reason)"; color = .systemYellow }
        else { text = "● \(L("bien", "good")) \(Int(pBar * 100))%   " + L("⌃⌥⌘B = esto es malo · ⌃⌥⌘G = esto es bueno", "⌃⌥⌘B = this is bad · ⌃⌥⌘G = this is good") }
        if let h = hudText, h.stringValue != text || h.textColor != color {
            let x = CATransition(); x.type = .fade; x.duration = 0.35; x.timingFunction = Line.ease; h.layer?.add(x, forKey: "swap")
            h.stringValue = text; h.textColor = color
        }
        if prefs.object(forKey: "showHUD") as? Bool ?? true { if hud?.isVisible == false { hud?.orderFrontRegardless() } } else { hud?.orderOut(nil) }
        shell.update(level: level, blocked: blocked, p: pBar, present: present || dodging, camera: camera, inCall: inCall,
                     reason: reason.prefix(1).uppercased() + reason.dropFirst(), secs: blockedSeconds, left: left)
        let mode = blocked ? "blocked" : level > 0 ? "filling" : "off"
        if mode == wroteMode, now.timeIntervalSince(wroteAt) < 2 { return }                  // every 2 s or on a change: less disk writing
        wroteMode = mode; wroteAt = now
        let st: [String: Any] = ["mode": mode, "level": level, "reason": reason, "p": pBar, "present": present,
                                 "inCall": inCall, "locked": locked, "blockedSeconds": Int(blockedSeconds), "fixesLeft": left, "at": Int(now.timeIntervalSince1970), "sample": lastSample]
        if let d = try? JSONSerialization.data(withJSONObject: st) { try? d.write(to: statusURL) }
    }
    func checkCall() {
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "pgrep -x CptHost >/dev/null || pmset -g assertions | grep -qE 'WebRTC has active PeerConnections|Teams.*[Cc]all|FaceTime'"]
            try? p.run(); p.waitUntilExit()
            let c = p.terminationStatus == 0
            DispatchQueue.main.async { self.inCall = c }
        }
    }
}

// MARK: - App shell: menu bar item, settings window, keep-alive login agent, single instance, first-run setup

let agentLabel = "io.github.samihalawa.postura"
let agentURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
/// Strict mode (root daemons, see mac/install.sh) keeps the app alive itself; the per-user agent is then not used.
let strictMode = fm.fileExists(atPath: "/Library/LaunchDaemons/com.sami.postura.plist")
let underAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel
func requireGlasses() -> Bool { prefs.object(forKey: "requireGlasses") as? Bool ?? fm.fileExists(atPath: supportDir.appendingPathComponent("glasses_yes.npy").path) }
func keepRunning() -> Bool { prefs.object(forKey: "keepRunning") as? Bool ?? true }
@discardableResult func sh(_ cmd: String) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}
let showNote = Notification.Name("io.github.samihalawa.postura.show")

/// Everything the window and the menu show, refreshed twice a second by Guard.tick().
final class Model: ObservableObject {
    @Published var state = ""
    @Published var detail = ""
    @Published var symbol = "figure.stand"
    @Published var tint = Color.green
    @Published var p = 0.0
    @Published var blocked = "0 s"
    @Published var fixesLeft = FIXES_PER_DAY
    @Published var setup = ""
    @Published var glasses = requireGlasses()
    @Published var hud = prefs.object(forKey: "showHUD") as? Bool ?? true
    @Published var keep = keepRunning()
    @Published var language = prefs.string(forKey: "language") ?? ""
}

struct SettingsView: View {
    @ObservedObject var m: Model
    let teach: (String) -> Void
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: m.symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(m.tint)
                        .frame(width: 44, height: 44).background(m.tint.opacity(0.15), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.state).font(.title3.weight(.semibold)).contentTransition(.opacity)
                        Text(m.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2).contentTransition(.opacity)
                    }
                }
                .padding(.vertical, 4).animation(.smooth, value: m.state).animation(.smooth, value: m.detail)
                if m.setup.isEmpty {
                    LabeledContent(L("Mala postura", "Bad posture score")) {
                        HStack(spacing: 10) {
                            ProgressView(value: m.p).progressViewStyle(.linear).tint(m.tint).frame(width: 150)
                            Text("\(Int(m.p * 100))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                        }.animation(.smooth, value: m.p)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView().progressViewStyle(.linear)
                        Text(m.setup).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Section(L("Hoy", "Today")) {
                LabeledContent(L("Tiempo bloqueado", "Time blocked"), value: m.blocked)
                LabeledContent(L("Correcciones disponibles", "Corrections left"), value: "\(m.fixesLeft) / \(FIXES_PER_DAY)")
            }
            Section {
                HStack {
                    Button { teach("good") } label: { Label(L("Buena postura", "Good posture"), systemImage: "hand.thumbsup") }
                    Button { teach("bad") } label: { Label(L("Mala postura", "Bad posture"), systemImage: "hand.thumbsdown") }
                }
                if m.glasses {
                    HStack {
                        Button { teach("gafas") } label: { Label(L("Llevo gafas", "Wearing glasses"), systemImage: "eyeglasses") }
                        Button { teach("singafas") } label: { Label(L("Sin gafas", "No glasses"), systemImage: "eye") }
                    }
                }
            } header: { Text(L("Enseñar", "Teach")) } footer: {
                Text(L("Marca lo que ves ahora; aprende de los próximos segundos. Atajos: ⌃⌥⌘G buena, ⌃⌥⌘B mala.",
                       "Labels what the camera sees now and over the next few seconds. Shortcuts: ⌃⌥⌘G good, ⌃⌥⌘B bad."))
            }
            Section(L("Opciones", "Options")) {
                Toggle(L("Exigir gafas", "Require glasses"), isOn: $m.glasses).onChange(of: m.glasses) { _, v in prefs.set(v, forKey: "requireGlasses"); g.eye.restart() }
                Toggle(L("Mostrar estado en pantalla", "Show status pill"), isOn: $m.hud).onChange(of: m.hud) { _, v in prefs.set(v, forKey: "showHUD") }
                if !strictMode {
                    Toggle(L("Mantener Postura activa", "Keep Postura running"), isOn: $m.keep).onChange(of: m.keep) { _, v in shell.setKeepRunning(v) }
                }
                Picker(L("Idioma", "Language"), selection: $m.language) {
                    Text(L("Sistema", "System")).tag(""); Text("English").tag("en"); Text("Español").tag("es")
                }.onChange(of: m.language) { _, v in
                    if v.isEmpty { prefs.removeObject(forKey: "language") } else { prefs.set(v, forKey: "language") }; shell.relaunch()
                }
            }
            Section {
                LabeledContent(L("Versión", "Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                HStack {
                    Link(destination: URL(string: "https://github.com/samihalawa/postura")!) { Label("GitHub", systemImage: "arrow.up.right.square") }
                    Spacer()
                    Button(L("Abrir registro", "Open Log")) { NSWorkspace.shared.open(logURL) }
                }
            } footer: { Text(L("Todo se procesa en este Mac. No se guarda ninguna imagen.", "Everything is processed on this Mac. No images are saved.")) }
        }
        .formStyle(.grouped).frame(width: 440).fixedSize(horizontal: false, vertical: true)
    }
}

final class Shell: NSObject, NSMenuDelegate, NSWindowDelegate {
    let model = Model()
    var item: NSStatusItem?, window: NSWindow?, header = NSMenuItem(), sub = NSMenuItem()

    /// Runs before anything else. Returns false when this process should step aside for the copy that is already running.
    func launch() -> Bool {
        if ProcessInfo.processInfo.environment["POSTURA_DEV"] != nil { return true }   // a second copy for development
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != me &&
            ($0.bundleIdentifier == agentLabel || $0.bundleIdentifier == "com.sami.postura") }
        if !others.isEmpty { DistributedNotificationCenter.default().postNotificationName(showNote, object: nil, deliverImmediately: true); return false }
        if !strictMode && !underAgent && keepRunning() && writeAgent() {      // opened by hand: let launchd own the process from now on
            prefs.set(true, forKey: "showWindowOnce")
            sh("launchctl bootout gui/\(getuid())/\(agentLabel); launchctl bootstrap gui/\(getuid()) '\(agentURL.path)'")
            return false
        }
        return true
    }
    /// Writes the keep-alive login agent for this copy of the app; true when it had to be (re)written.
    func writeAgent() -> Bool {
        let exe = Bundle.main.executablePath ?? ""
        if let d = NSDictionary(contentsOf: agentURL), (d["ProgramArguments"] as? [String])?.first == exe,
           sh("launchctl print gui/\(getuid())/\(agentLabel)") == 0 { return false }
        let plist: NSDictionary = ["Label": agentLabel, "ProgramArguments": [exe], "RunAtLoad": true, "KeepAlive": true,
                                   "ThrottleInterval": 5, "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
                                   "StandardErrorPath": fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/postura.out.log").path]
        try? fm.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return plist.write(to: agentURL, atomically: true)
    }
    func setKeepRunning(_ on: Bool) {
        prefs.set(on, forKey: "keepRunning")
        if on { _ = writeAgent(); log("keep running: on"); relaunch() }
        else { log("keep running: off"); try? fm.removeItem(at: agentURL); sh("launchctl bootout gui/\(getuid())/\(agentLabel) &") }
    }
    /// Starts a fresh copy (new language, new agent); launchd or the next copy takes over.
    func relaunch() {
        let path = Bundle.main.bundlePath
        if underAgent { exit(0) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 1; open '\(path)'"]; try? p.run(); exit(0)
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: showNote, object: nil, queue: .main) { _ in self.show() }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Postura")
        let menu = NSMenu(); menu.delegate = self; header.isEnabled = false; sub.isEnabled = false
        menu.addItem(header); menu.addItem(sub); menu.addItem(.separator())
        func add(_ t: String, _ sym: String, _ a: Selector, _ key: String = "") {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: key); i.target = self; i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil); menu.addItem(i)
        }
        add(L("Abrir Postura", "Open Postura"), "macwindow", #selector(show))
        menu.addItem(.separator())
        add(L("Esto es buena postura", "This Is Good Posture"), "hand.thumbsup", #selector(good))
        add(L("Esto es mala postura", "This Is Bad Posture"), "hand.thumbsdown", #selector(bad))
        menu.addItem(.separator())
        add(L("Ajustes…", "Settings…"), "gearshape", #selector(show), ",")
        add(L("Acerca de Postura", "About Postura"), "info.circle", #selector(about))
        it.menu = menu; item = it
        if pythonPath() == nil { setup() } else { g.eye.start() }
        if prefs.bool(forKey: "showWindowOnce") || pythonPath() == nil { prefs.removeObject(forKey: "showWindowOnce"); DispatchQueue.main.async { self.show() } }
    }
    func menuNeedsUpdate(_ menu: NSMenu) { header.title = model.state; sub.title = model.detail }
    @objc func good() { g.teach("good") }
    @objc func bad() { g.teach("bad") }
    @objc func about() { NSApp.activate(ignoringOtherApps: true); NSApp.orderFrontStandardAboutPanel(nil) }
    @objc func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(m: model) { g.teach($0) }))
            w.title = "Postura"; w.styleMask = [.titled, .closable, .miniaturizable]; w.isReleasedWhenClosed = false; w.delegate = self
            w.center(); window = w
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)   // no focus ring on a teach button: a stray space must not label anything
    }

    /// First launch: a private Python with MediaPipe, made with uv (Homebrew's, or uv's own installer into Application Support).
    func setup() {
        model.setup = L("Descargando (1–2 min, solo la primera vez)…", "Downloading (1–2 minutes, first launch only)…")
        let sup = supportDir.path, out = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/postura-setup.log").path
        let script = """
        set -e; exec >>'\(out)' 2>&1; date
        UV=$(for u in /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.local/bin/uv" '\(sup)/bin/uv'; do [ -x "$u" ] && echo "$u" && break; done)
        if [ -z "$UV" ]; then curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR='\(sup)/bin' UV_NO_MODIFY_PATH=1 sh; UV='\(sup)/bin/uv'; fi
        "$UV" venv --python 3.11 '\(sup)/venv.tmp'
        "$UV" pip install --python '\(sup)/venv.tmp/bin/python3' mediapipe opencv-python-headless numpy
        rm -rf '\(sup)/venv'; mv '\(sup)/venv.tmp' '\(sup)/venv'
        """
        log("setup: creating the posture model environment")
        DispatchQueue.global().async {
            let ok = sh(script) == 0 && pythonPath() != nil
            DispatchQueue.main.async {
                if ok { log("setup: done"); self.model.setup = ""; g.eye.start() }
                else { log("setup: failed, see postura-setup.log"); self.model.setup = L("Ha fallado. Se reintentará en 1 min. Detalles en postura-setup.log", "Failed. Retrying in a minute. Details in postura-setup.log")
                       DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.setup() } }
            }
        }
    }

    /// Called by Guard.tick(): status for the menu bar icon, the menu and the window.
    func update(level: Double, blocked: Bool, p: Double, present: Bool, camera: Bool, inCall: Bool, reason: String, secs: Double, left: Int) {
        let (st, d, sym, tint): (String, String, String, Color) = {
            if !model.setup.isEmpty { return (L("Preparando…", "Setting up…"), L("Primera vez: instalando el modelo", "First launch: installing the model"), "arrow.down.circle", .blue) }
            if !camera { return (L("Sin cámara", "No camera"), L("Permítela en Ajustes → Privacidad → Cámara", "Allow it in Settings → Privacy → Camera"), "video.slash", .orange) }
            if blocked { return (L("Bloqueado", "Blocked"), reason, "figure.fall", .red) }
            if level > 0 { return (L("Corrige la postura", "Fix your posture"), reason, "figure.fall", .orange) }
            if inCall { return (L("En una llamada", "On a call"), L("Solo un aviso suave, nunca bloquea", "Only a gentle hint, never blocks"), "phone", .blue) }
            if !present { return (L("No te veo", "Not watching"), L("Nadie delante de la cámara", "Nobody in front of the camera"), "eye.slash", .gray) }
            if p >= RELEASE { return (L("Dudoso", "Unsure"), reason, "figure.stand", .yellow) }
            return (L("Buena postura", "Good posture"), L("Vigilando", "Watching"), "figure.stand", .green)
        }()
        if model.state != st { model.state = st }; if model.detail != d { model.detail = d }
        if model.symbol != sym { model.symbol = sym; item?.button?.image = NSImage(systemSymbolName: sym, accessibilityDescription: st) }
        if model.tint != tint { model.tint = tint }
        if window?.isVisible == true { model.p = p }
        if model.fixesLeft != left { model.fixesLeft = left }
        let bt = secs < 60 ? "\(Int(secs)) s" : "\(Int(secs / 60)) min"; if model.blocked != bt { model.blocked = bt }
        let tip = "Postura · \(st)"; if item?.button?.toolTip != tip { item?.button?.toolTip = tip }
    }
}
let shell = Shell()

signal(SIGPIPE, SIG_IGN)   // writing to a judge that has just exited must be an error, not the end of the app
let app = NSApplication.shared
let g = Guard()
if !shell.launch() { exit(0) }
app.delegate = g
app.setActivationPolicy(.accessory)
app.run()
