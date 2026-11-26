// Postura: camera posture guard for macOS. Clearly bad posture makes a glowing front close in
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
import UniformTypeIdentifiers
import Accelerate
import Carbon.HIToolbox
import CoreImage

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
func cameraDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
}
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

// The display score is smoothed. CoverTiming gates the actual cover on sustained observations.
let BLOCK = 0.72, RELEASE = 0.40

struct CoverTiming {
    static let dwell = 5.0, fill = 5.0, clearDelay = 2.0, drain = 2.5
    private var qualifyingSince: Date?
    private var clearSince: Date?

    enum Motion: Equatable { case fill, hold, drain }

    mutating func observe(hide: Bool, at now: Date, covering: Bool) {
        if hide {
            if qualifyingSince == nil { qualifyingSince = now }
            clearSince = nil
        } else {
            if !covering { qualifyingSince = nil }
            if clearSince == nil { clearSince = now }
            if let clearSince, now.timeIntervalSince(clearSince) >= Self.clearDelay {
                qualifyingSince = nil
            }
        }
    }

    func motion(at now: Date, covering: Bool) -> Motion {
        if let clearSince {
            return covering && now.timeIntervalSince(clearSince) < Self.clearDelay ? .hold : .drain
        }
        guard let qualifyingSince, now.timeIntervalSince(qualifyingSince) >= Self.dwell else { return covering ? .hold : .drain }
        return .fill
    }

    static func visualLevel(_ progress: Double) -> Double {
        // Ease both ends of the transition while preserving its elapsed time.
        progress * progress * (3 - 2 * progress)
    }
}

final class Eye {
    private let lock = NSLock()
    private var input: FileHandle?, busy = false, pending: CVPixelBuffer?
    var onSample: (([String: Any], CVPixelBuffer?) -> Void)?
    let root = Bundle.main.resourceURL!
    func start() {
        guard let py = pythonPath() else { log("no python yet"); return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [root.appendingPathComponent("postura-eye.py").path]
        p.environment = ["POSTURA_MODELS": root.appendingPathComponent("models").path, "GLOG_minloglevel": "2", "TF_CPP_MIN_LOG_LEVEL": "2",
                         "HOME": NSHomeDirectory(), "POSTURA_LANG": spanish ? "es" : "en", "POSTURA_HOME": supportDir.path,
                         "POSTURA_GLASSES": prefs.bool(forKey: "requireGlasses") ? "1" : "0"]
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        var buf = Data()
        o.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }                 // closed pipe: without this the handler spins for ever
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 10) {
                let line = buf[buf.startIndex..<nl]; buf.removeSubrange(buf.startIndex...nl)
                self.lock.lock()
                let frame = self.pending
                self.pending = nil
                self.busy = false
                self.lock.unlock()
                if let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any], j["error"] == nil {
                    self.onSample?(j, frame)
                } else {
                    log("eye returned an invalid sample")
                    self.onSample?([:], frame)
                }
            }
        }
        p.terminationHandler = { _ in log("eye exited, restarting"); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() } }
        try? p.run()
        lock.lock(); input = i.fileHandleForWriting; pending = nil; busy = false; lock.unlock()
        proc = p
    }
    var proc: Process?
    func restart() { proc?.terminate() }   // the termination handler starts a fresh one with the current settings
    func send(_ pb: CVPixelBuffer, preview: Bool) {
        lock.lock()
        guard !busy, let fh = input else { lock.unlock(); return }
        busy = true; pending = preview ? pb : nil
        lock.unlock()
        do {
            let data = autoreleasepool { () -> Data? in
                CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
                guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
                let width = 640, height = 480
                var data = Data((preview ? "\(width) \(height) owner\n" : "\(width) \(height)\n").utf8)
                let headerSize = data.count
                data.count += width * height * 4
                let result = data.withUnsafeMutableBytes { bytes in
                    var source = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: bpr)
                    var output = vImage_Buffer(data: bytes.baseAddress! + headerSize, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: width * 4)
                    return vImageScale_ARGB8888(&source, &output, nil, vImage_Flags(kvImageNoFlags))
                }
                return result == kvImageNoError ? data : nil
            }
            guard let data else { throw CocoaError(.fileReadUnknown) }
            try fh.write(contentsOf: data)
        } catch {
            lock.lock(); busy = false; pending = nil; lock.unlock()
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
        if !text.isEmpty { let x = CATransition(); x.type = .fade; x.duration = 1.8; x.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); label.add(x, forKey: "swap") }
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

/// Only the exact frame that passed identity matching enters the display pipeline.
final class Silhouette {
    private let queue = DispatchQueue(label: "postura.shape", qos: .userInitiated), lock = NSLock()
    private var busy = false, epoch = 0
    private var latest: (image: CGImage, captured: CFTimeInterval)?
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private let request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    func clear() {
        lock.lock(); defer { lock.unlock() }
        if busy || latest != nil { epoch += 1 }
        latest = nil
    }

    func feed(_ frame: CVPixelBuffer, crop: SIMD3<Float>) {
        lock.lock()
        guard !busy else { lock.unlock(); return }
        busy = true
        let ticket = epoch
        let captured = CACurrentMediaTime()
        lock.unlock()
        queue.async { [self] in
            let image = autoreleasepool { portrait(frame, crop: crop) }
            lock.lock(); defer { lock.unlock() }
            busy = false
            guard ticket == epoch else { return }
            latest = image.map { ($0, captured) }
        }
    }

    private func portrait(_ frame: CVPixelBuffer, crop: SIMD3<Float>) -> CGImage? {
        guard (try? VNImageRequestHandler(cvPixelBuffer: frame).perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return nil }
        let camera = CIImage(cvPixelBuffer: frame)
        let extent = camera.extent
        let height = min(extent.height, extent.width * 0.75, extent.height * CGFloat(crop.z) * 1.75)
        let width = height / 0.75
        let x = min(extent.width - width, max(0, CGFloat(crop.x) * extent.width - width / 2))
        let y = min(extent.height - height, max(0, (1 - CGFloat(crop.y)) * extent.height - height * 0.64))
        let rect = CGRect(x: x, y: y, width: width, height: height).integral.intersection(extent)
        let matte = CIImage(cvPixelBuffer: mask)
        let scaled = matte.transformed(by: CGAffineTransform(scaleX: extent.width / matte.extent.width,
                                                              y: extent.height / matte.extent.height))
        let softened = scaled.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: rect)
        let transparent = CIImage(color: .clear).cropped(to: rect)
        let cutout = camera.cropped(to: rect).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: transparent,
            kCIInputMaskImageKey: softened
        ])
        return context.createCGImage(cutout, from: rect)
    }

    func image() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, CACurrentMediaTime() - latest.captured < 0.75 else { return nil }
        return latest.image
    }
}
let silhouette = Silhouette()

/// The light of the warning, drawn in one small Metal pass (at half the points, 30 fps) and stretched. Everything in it is soft, so it
/// looks the same as the former stack of full-resolution blurred layers, which cost the window server enough to slow the whole Mac.
final class Glow {
    struct Params {
        var size = SIMD2<Float>(0, 0), pad = SIMD2<Float>(0, 0)
        var front = SIMD4<Float>(0, 0, 0, 1)          // half-width, half-height, wave amplitude, feather
        var rim = SIMD4<Float>(0, 1, 1, 0)            // wave amplitude, rim width factor, front width factor, time
        var opacity = SIMD4<Float>(0, 0, 0, 0)        // tint, colour wash, rim, front
        var stops: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero)
    }
    static let scale: CGFloat = 2
    static let gpu: (dev: MTLDevice, queue: MTLCommandQueue, pipe: MTLRenderPipelineState)? = {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let lib = try? d.makeLibrary(source: shader, options: nil) else { log("no Metal"); return nil }
        let r = MTLRenderPipelineDescriptor(); r.vertexFunction = lib.makeFunction(name: "v"); r.fragmentFunction = lib.makeFunction(name: "f"); r.colorAttachments[0].pixelFormat = .rgba16Float
        guard let p = try? d.makeRenderPipelineState(descriptor: r) else { log("no Metal pipeline"); return nil }
        return (d, q, p)
    }()
    let layer = CAMetalLayer(), work = DispatchQueue(label: "postura.glow", qos: .userInteractive), lock = NSLock()
    var inFlight = 0
    init() {
        layer.device = Glow.gpu?.dev; layer.pixelFormat = .rgba16Float; layer.isOpaque = false; layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB); layer.contentsGravity = .resize; layer.magnificationFilter = .linear
    }
    /// Never waits on the main thread: a frame is skipped when two are still on their way.
    func render(_ p: Params) {
        guard let gpu = Glow.gpu else { return }
        lock.lock(); let busy = inFlight >= 2; if !busy { inFlight += 1 }; lock.unlock()
        if busy { return }
        work.async { [self] in
            func done() { lock.lock(); inFlight -= 1; lock.unlock() }
            guard let d = layer.nextDrawable(), let c = gpu.queue.makeCommandBuffer() else { done(); return }
            Glow.encode(p, into: d.texture, c, gpu.pipe)
            c.addCompletedHandler { _ in done() }
            c.present(d); c.commit()
        }
    }
    static func encode(_ p: Params, into t: MTLTexture, _ c: MTLCommandBuffer, _ pipe: MTLRenderPipelineState) {
        let r = MTLRenderPassDescriptor(); r.colorAttachments[0].texture = t; r.colorAttachments[0].loadAction = .dontCare; r.colorAttachments[0].storeAction = .store
        guard let e = c.makeRenderCommandEncoder(descriptor: r) else { return }
        var q = p; e.setRenderPipelineState(pipe); e.setFragmentBytes(&q, length: MemoryLayout<Params>.stride, index: 0)
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
    struct P { float2 size, pad; float4 front, rim, op; float4 st[7]; };
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
    fragment float4 f(V in [[stage_in]], constant P& p [[buffer(0)]]) {
        float2 q = (in.uv - 0.5) * p.size; float t = p.rim.w, R = length(q);
        float ang = atan2(q.x, q.y) / (2 * M_PI_F) + t / 60;
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
        float2 e = p.size / 2; float k = p.rim.y, ra = p.rim.x, rt = t * 0.35 + 7, keep = 1;
        keep *= 1 - stroke(q, e, 0.04, 4, ra, rt, 4 * k, 2); keep *= 1 - stroke(q, e, 0.04, 4, ra, rt, 10 * k, 6);
        keep *= 1 - stroke(q, e, 0.04, 4, ra, rt, 22 * k, 18); keep *= 1 - stroke(q, e, 0.04, 4, ra, rt, 44 * k, 52);
        float rim = (1 - keep) * p.op.z;
        float4 o = float4(float3(0.21, 0.17, 0.29), 1) * p.op.x;                       // premultiplied, back to front
        float w = p.op.y * region; o = float4(wash, 1) * w + o * (1 - w);
        o = float4(light, 1) * rim + o * (1 - rim);
        o = float4(light, 1) * front + o * (1 - front);
        return o;
    }
    """
}

/// A single glass lens around the cutout. Only the camera layer changes between frames.
final class GlassPortrait {
    let layer = CALayer()
    private let video = CALayer()
    private var displayedImage: CGImage?

    init(frame: CGRect, scale: CGFloat) {
        layer.frame = frame
        layer.isHidden = true
        let bounds = layer.bounds
        let path = Self.outline(in: bounds.insetBy(dx: 3, dy: 3))

        func shape() -> CAShapeLayer {
            let mask = CAShapeLayer()
            mask.frame = bounds
            mask.path = path
            mask.contentsScale = scale
            return mask
        }

        func gradient(_ colors: [NSColor], _ stops: [NSNumber]) -> CAGradientLayer {
            let glass = CAGradientLayer()
            glass.frame = bounds
            glass.contentsScale = scale
            glass.startPoint = CGPoint(x: 0.14, y: 1)
            glass.endPoint = CGPoint(x: 0.83, y: 0)
            glass.colors = colors.map(\.cgColor)
            glass.locations = stops
            return glass
        }

        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.32
        layer.shadowOffset = CGSize(width: 1, height: -9)
        layer.shadowRadius = 16
        layer.shadowPath = path

        let tint = gradient([
            .white.withAlphaComponent(0.30),
            NSColor(srgbRed: 0.64, green: 0.60, blue: 0.77, alpha: 0.16),
            NSColor(srgbRed: 0.09, green: 0.07, blue: 0.19, alpha: 0.25),
            .white.withAlphaComponent(0.13)
        ], [0, 0.32, 0.68, 1])
        tint.mask = shape()
        layer.addSublayer(tint)

        let contents = CALayer()
        contents.frame = bounds
        contents.mask = shape()
        video.frame = bounds.insetBy(dx: bounds.width * 0.10, dy: bounds.height * 0.055)
        video.contentsGravity = .resizeAspect
        video.minificationFilter = .trilinear
        video.transform = CATransform3DMakeScale(-1, 1, 1)
        contents.addSublayer(video)
        layer.addSublayer(contents)

        let rim = gradient([
            .white.withAlphaComponent(0.95),
            NSColor(srgbRed: 0.80, green: 0.87, blue: 1, alpha: 0.56),
            .white.withAlphaComponent(0.12),
            NSColor(srgbRed: 0.92, green: 0.81, blue: 1, alpha: 0.52)
        ], [0, 0.26, 0.59, 1])
        let stroke = shape()
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.white.cgColor
        stroke.lineWidth = 1.5
        rim.mask = stroke
        layer.addSublayer(rim)
    }

    /// A wide, asymmetric silhouette keeps the shoulders in view without a circular crop.
    private static func outline(in rect: CGRect) -> CGPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let path = CGMutablePath()
        path.move(to: p(0.46, 0.98))
        path.addCurve(to: p(0.98, 0.54), control1: p(0.76, 1.04), control2: p(0.97, 0.88))
        path.addCurve(to: p(0.63, 0.025), control1: p(1.00, 0.22), control2: p(0.85, 0.04))
        path.addCurve(to: p(0.025, 0.44), control1: p(0.30, -0.005), control2: p(0.04, 0.09))
        path.addCurve(to: p(0.46, 0.98), control1: p(0.007, 0.75), control2: p(0.14, 0.92))
        path.closeSubpath()
        return path
    }

    func show(_ image: CGImage?) {
        guard displayedImage !== image else { return }
        let appearing = displayedImage == nil
        displayedImage = image
        video.contents = image
        layer.isHidden = image == nil
        if image == nil { layer.removeAnimation(forKey: "appear") }
        if appearing, image != nil {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.36
            appear.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(appear, forKey: "appear")
        }
    }
}

/// The warning, after the Apple Intelligence edge glow: light lives on the physical screen edge and floods inward as posture
/// stays bad, with every boundary feathered (no hard line anywhere). Blur and colour follow one soft, slowly waving front;
/// correcting posture pulls it back to the edge. Locked: the whole screen is frosted and tinted, the rim breathes.
final class Liquid {
    static let palette: [SIMD4<Float>] = ["BC82F3", "F5B9EA", "8D9FFF", "FF6778", "FFBA71", "C686FF"].map { h in
        let v = Int(h, radix: 16)!; return SIMD4(Float(v >> 16 & 255) / 255, Float(v >> 8 & 255) / 255, Float(v & 255) / 255, 1) }
    let win: KeyWin, blur = NSVisualEffectView(), glow = Glow(), frost = CALayer()
    let content = NSView(), portrait: GlassPortrait, title: Line, why: Line, foot: Line, date: Line, clock: Line, button = NSButton()
    let dayFmt = DateFormatter(), timeFmt = DateFormatter()
    private var buttonSurface: NSView?
    private var lastFrost = -1.0
    let main: Bool; var lastShuffle = -10.0, shown = false, lastClock = -10.0
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
        content.frame = root.bounds; content.wantsLayer = true; root.addSubview(content)
        let margin = max(24, min(W, H) * 0.045)
        let portraitWidth = min(320, min(W * 0.30, H * 0.39))
        let portraitHeight = portraitWidth * 0.76
        portrait = GlassPortrait(frame: NSRect(x: W - margin - portraitWidth, y: H - margin - portraitHeight,
                                              width: portraitWidth, height: portraitHeight),
                                 scale: win.backingScaleFactor)
        if main { content.layer?.addSublayer(portrait.layer) }
        // the middle belongs to the shape: the time sits in the top left corner, the message in the bottom left one, the action bottom right
        let m = max(40, W * 0.035), tw = W - 2 * m, ts = min(44, H * 0.055), ws = min(19, H * 0.026), cs = min(58, H * 0.067)
        var y = m * 0.9
        func up(_ size: CGFloat, gap: CGFloat) -> CGFloat { defer { y += ceil(size * 1.32) + gap }; return y }
        foot = Line(content, x: m, y: up(13, gap: 12), width: tw * 0.6, size: 13, weight: .regular, alpha: 0.8)
        why = Line(content, x: m, y: up(ws, gap: 2), width: tw, size: ws, weight: .medium, alpha: 0.9)
        title = Line(content, x: m, y: up(ts, gap: 0), width: tw, size: ts, weight: .semibold)
        clock = Line(content, x: m, y: H - m * 0.9 - ceil(cs * 1.32), width: tw / 2, size: cs, weight: .semibold, digits: true)
        date = Line(content, x: m, y: clock.frame.minY - 26, width: tw / 2, size: 17, weight: .medium, alpha: 0.8)
        dayFmt.locale = Locale(identifier: spanish ? "es_ES" : "en_US"); dayFmt.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        timeFmt.locale = Locale.current; timeFmt.dateFormat = (DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current) ?? "H:mm")
            .replacingOccurrences(of: "a", with: "").replacingOccurrences(of: "\u{202F}", with: "").trimmingCharacters(in: .whitespaces)
        if main {
            let width = min(234, tw * 0.38)
            let frame = NSRect(x: W - m - width, y: m * 0.9, width: width, height: 48)
            button.frame = frame; button.bezelStyle = .rounded; button.controlSize = .large
            button.font = .systemFont(ofSize: 15, weight: .medium)
            button.target = target; button.action = action
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(frame: frame)
                glass.cornerRadius = 24
                if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
                button.isBordered = false
                button.frame = glass.bounds
                button.autoresizingMask = [.width, .height]
                glass.contentView = button
                buttonSurface = glass
            } else {
                buttonSurface = button
            }
            if let surface = buttonSurface {
                surface.wantsLayer = true
                surface.layer?.opacity = 0
                content.addSubview(surface)
            }
        }
        shuffle(0); from = to
    }
    /// New random stop positions, eased over 9 s, so the colours drift around the edge. A stop is rgb + its place on the circle.
    func shuffle(_ t: Double) {
        from = stops(t); lastShuffle = t
        var c = Liquid.palette.shuffled().enumerated().map { SIMD4($1.x, $1.y, $1.z, (Float($0) + Float.random(in: 0...0.5)) / 6) }   // never two stops close together: no wedges
        var last = c[0]; last.w = 1; c.append(last); c[0].w = 0; to = c                // closes the circle with no seam
    }
    func stops(_ t: Double) -> [SIMD4<Float>] {
        guard from.count == to.count, !to.isEmpty else { return to }
        let x = Float(min(1, max(0, (t - lastShuffle) / 9))), e = x * x * (3 - 2 * x)
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
    func reveal(_ on: Bool) {
        guard on != shown else { return }; shown = on
        for (i, v) in [clock, date, title, why, foot].enumerated() { fade(v, on, delay: on ? 0.25 * Double(i) : 0, duration: on ? 2.0 : 0.4) }
        if let surface = buttonSurface { fade(surface, on && button.isEnabled, delay: 0, duration: on ? 0.45 : 0.25) }
    }
    func draw(level: Double, t: Double, image: CGImage?) {
        if t - lastShuffle > 9 { shuffle(t) }
        let bw = size.width, bh = size.height, short = min(bw, bh)
        let ease = CGFloat(min(1, max(0, level))), breathe = CGFloat(0.5 + 0.5 * sin(0.55 * t))
        let locked = CGFloat(min(1, max(0, (level - 0.88) / 0.12)))
        let fade = CGFloat(CoverTiming.visualLevel(min(1, level / 0.24)))                                                     // everything eases in from nothing and back out
        let soft = 30 + 110 * ease                                                   // feather radius grows as the light moves in
        let d = ease * (short / 2 + 1.15 * soft)                                     // how far the front has travelled; closes only at the end
        let a = bw / 2 + soft - d, b = bh / 2 + soft - d
        var p = Glow.Params()
        p.size = SIMD2(Float(bw), Float(bh)); p.front = SIMD4(Float(a), Float(b), Float(max(0, min(14 + 30 * ease, 0.12 * min(a, b)))), Float(soft))
        p.rim = SIMD4(Float(4 + 8 * breathe * (0.4 + 0.6 * locked)), Float(0.7 + 0.45 * ease + 0.2 * locked * breathe), Float(0.8 + 0.4 * ease), Float(t))
        p.opacity = SIMD4(Float(0.92 * locked),                                      // tint: depth behind the message, not a grey dim
                          Float(fade * (0.25 + 0.35 * ease - 0.30 * locked + 0.06 * locked * breathe)),
                          Float(fade * min(1, 0.6 + 2.5 * ease) * (0.85 + 0.15 * breathe)),
                          Float(0.45 * min(1, 4 * ease) * (1 - locked)))                // a faint luminous edge on the front, never a line
        let colors = stops(t)
        colors.withUnsafeBytes { bytes in
            withUnsafeMutableBytes(of: &p.stops) { $0.copyBytes(from: bytes) }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blur.alphaValue = fade
        if t - lastFrost >= 1.0 / 22 || (p.front.y <= 4 && frostOpen) {
            lastFrost = t
            drawFrost(p)
        }
        if main { portrait.show(shown ? image : nil) }
        CATransaction.commit()
        glow.render(p)
        if t - lastClock > 1 { lastClock = t; let today = Date(); date.set(dayFmt.string(from: today)); clock.set(timeFmt.string(from: today)) }
        reveal(level >= (shown ? 0.80 : 0.90))
    }
    /// With no corrections left there is no dead button, only the line of text that says so.
    func setButton(_ s: String, enabled: Bool) {
        if button.title != s { button.title = s }
        guard button.isEnabled != enabled else { return }
        button.isEnabled = enabled; if shown, let surface = buttonSurface { fade(surface, enabled, delay: 0, duration: 0.25) }
    }
}

final class CameraReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let buffer = CMSampleBufferGetImageBuffer(sample) { onFrame?(buffer) }
    }
}

final class Guard: NSObject, NSApplicationDelegate {
    let session = AVCaptureSession(), queue = DispatchQueue(label: "postura.camera"), eye = Eye()
    let receiver = CameraReceiver(), videoOutput = AVCaptureVideoDataOutput()
    var lastFrame = Date.distantPast, lastProcessed = Date.distantPast, lastSampleAt = Date.distantPast
    var pBar = 0.0
    var level = 0.0, blocked = false, releasing = false, lastAnim = Date(), t0 = Date()
    var present = false, reason = "", reasonKind = "", note = "", noteUntil = Date.distantPast, lastSample: [String: Any] = [:]
    var cameraName = ""
    var coverTiming = CoverTiming()
    var lastCameraRestart = Date.distantPast
    var camera = true, inCall = false, locked = false, poweringOff = false
    private var ownerPreviewVisible = false
    private var feedbackRequestedUntil = Date.distantPast
    private let cameraStateLock = NSLock()
    private var cameraInterval = 0.4, requestPortrait = false

    private func updateCameraSampling() {
        cameraStateLock.lock()
        cameraInterval = level == 0 && pBar < RELEASE ? 0.4 : 0.16
        requestPortrait = level >= 0.95
        cameraStateLock.unlock()
    }
    var screenFrames: [NSRect] = [], liquids: [Liquid] = [], hud: NSWindow?, hudText: NSTextField?, keyMonitor: Any?
    var message: (String, String)?, messageAt = Date.distantPast, pendingKey = "", pendingAt = Date.distantPast
    var blockedSeconds = 0.0, wroteAt = Date.distantPast, wroteMode = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in self.poweringOff = true }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {   // lid opened / display woke: the camera stops while asleep
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in log("wake"); self.revealScreen("wake"); self.restartCamera() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            // locking hides the Dock and the menu bar, which posts this too: only a real change of displays rebuilds the cover
            if !self.liquids.isEmpty, self.screenFrames != NSScreen.screens.map(\.frame) { self.dropLiquids() }
        }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { _ in log("camera runtime error"); self.restartCamera() }
        log("start")
        DispatchQueue.global(qos: .utility).async { _ = Glow.gpu }
        eye.onSample = { s, frame in
            DispatchQueue.main.async {
                if let frame {
                    if self.blocked, let crop = s["ownerCrop"] as? [Double], crop.count == 3,
                       crop.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
                        silhouette.feed(frame, crop: SIMD3(Float(crop[0]), Float(crop[1]), Float(crop[2])))
                    } else {
                        silhouette.clear()
                    }
                }
                if !s.isEmpty { self.handle(s, Date()) }
                else { self.revealScreen("camera analysis failed") }
            }
        }
        shell.start()
        requestCamera()
        if !underAgent && !strictMode { shell.show() }
        every(1.0 / 30) { self.animate() }
        every(0.5) { self.tick() }
        every(10) { self.checkCall() }
        startWatchdog()
        checkCall(); showHUD(); installHotkeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in   // while blocked this app has the keyboard: plain G corrects it
            guard self.blocked else { return e }
            if e.charactersIgnoringModifiers?.lowercased() == "g" { self.fixClicked() }
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
    func requestCamera() {
        let asking = AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        if asking {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        AVCaptureDevice.requestAccess(for: .video) { allowed in
            DispatchQueue.main.async {
                if allowed { self.startCamera() }
                else { self.camera = false; log("camera permission denied") }
            }
        }
    }
    func startCamera() {
        let devices = cameraDevices()
        let selected = ProcessInfo.processInfo.environment["POSTURA_CAMERA"] ?? prefs.string(forKey: "cameraDevice") ?? ""
        let device = selected.isEmpty
            ? devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first
            : devices.first(where: { $0.uniqueID == selected || $0.localizedName == selected })
        guard let dev = device, let input = try? AVCaptureDeviceInput(device: dev) else {
            camera = false; log("camera unavailable: \(selected)"); return
        }
        let out = videoOutput
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        session.beginConfiguration()
        if dev.deviceType == .builtInWideAngleCamera {
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            } else if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            }
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            camera = false; log("could not configure camera input: \(dev.localizedName)"); return
        }
        session.addInput(input)
        receiver.onFrame = { [weak self] in self?.cameraFrame($0) }
        out.setSampleBufferDelegate(receiver, queue: queue)
        guard session.canAddOutput(out) else {
            session.removeInput(input)
            session.commitConfiguration()
            camera = false; log("could not configure camera output: \(dev.localizedName)"); return
        }
        session.addOutput(out)
        session.commitConfiguration()
        lastCameraRestart = Date()
        camera = true; cameraName = dev.localizedName; log("camera \(dev.localizedName)")
        queue.async {
            self.session.startRunning()
            if !self.session.isRunning { log("camera session failed to start") }
        }
    }
    func restartCamera() {
        guard camera, Date().timeIntervalSince(lastCameraRestart) >= 5 else { return }
        lastCameraRestart = Date()
        queue.async {
            if self.session.inputs.isEmpty { DispatchQueue.main.async { self.startCamera() }; return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.startRunning()
        }
    }
    func cameraFrame(_ pb: CVPixelBuffer) {
        let now = Date()  // 2.5 frames/s while all is well, 6/s while something looks wrong
        cameraStateLock.lock()
        let interval = cameraInterval, portrait = requestPortrait
        cameraStateLock.unlock()
        guard now.timeIntervalSince(lastProcessed) > interval else { return }
        if lastProcessed == .distantPast { log("camera delivering frames") }
        lastProcessed = now
        eye.send(pb, preview: portrait)
    }

    // MARK: judgement -> smoothed p
    func reset(_ why: String) { if (level > 0 || blocked) && pBar > 0 { log("clear: \(why)") }; pBar = 0 }
    func revealScreen(_ why: String) {
        reset(why)
        coverTiming = CoverTiming()
        present = false; releasing = false; level = 0
        reason = ""; reasonKind = ""; message = nil
        if blocked { setBlocked(false) }
        if !liquids.isEmpty { dropLiquids() }
        silhouette.clear(); ownerPreviewVisible = false
        updateCameraSampling()
    }
    func handle(_ s: [String: Any], _ now: Date) {
        let dt = min(1.0, max(0.05, now.timeIntervalSince(lastSampleAt)))
        lastFrame = now; lastSampleAt = now; lastSample = s
        if let saved = s["trainingSaved"] as? Int {
            flash(saved > 0
                  ? L("Ejemplo guardado", "Example saved")
                  : L("No se registró un ejemplo. Mira a la cámara y repite.", "No example recorded. Face the camera and try again."))
        }
        guard s["person"] as? Bool == true else { revealScreen("nobody in frame"); return }
        present = true
        if s["postureUnjudged"] as? String == "far" { revealScreen("person in background"); return }
        if locked {
            reset("posture correction")
            coverTiming = CoverTiming()
            return
        }
        let judged = (s["face"] as? Bool) == true && (s["kind"] as? String) != "unjudged"
        let score = judged ? (s["p"] as? NSNumber)?.doubleValue ?? 0 : 0
        pBar += (1 - exp(-dt / 1.2)) * (score - pBar)

        // Ambiguous posture can never start a cover. Once full, wait for a
        // clearly corrected posture or an empty frame before uncovering.
        let shouldCover = score >= BLOCK || (blocked && (!judged || score > RELEASE))
        if !releasing { coverTiming.observe(hide: shouldCover, at: now, covering: level > 0) }
        if score >= BLOCK {
            reason = s["why"] as? String ?? ""
            reasonKind = s["kind"] as? String ?? ""
        } else if blocked && !judged {
            reason = L("postura fuera de vista", "posture out of view")
            reasonKind = "hidden"
        } else if judged && reasonKind == "hidden" {
            reason = s["why"] as? String ?? ""
            reasonKind = s["kind"] as? String ?? ""
        }
    }
    func brief(_ s: [String: Any]) -> String {
        ["pitch", "roll", "yaw", "neck", "fwd", "noseY", "shY", "shTilt", "dist", "faces"].compactMap { k in (s[k] as? NSNumber).map { "\(k)=\(f2($0.doubleValue))" } }.joined(separator: " ")
    }

    // MARK: liquid level 0..1, 30 times a second
    func animate() {
        let now = Date(), dt = min(0.1, max(0, now.timeIntervalSince(lastAnim))); lastAnim = now
        beatLock.lock(); beat = ProcessInfo.processInfo.systemUptime; beatLock.unlock()
        let motion = coverTiming.motion(at: now, covering: level > 0)
        let good = motion == .drain || locked
        let cap = inCall ? 0.22 : 1.0
        // Finish an uncover before accumulating a new sustained verdict.
        if good && level > 0 { releasing = true; coverTiming = CoverTiming() }
        if releasing {
            level = max(0, level - dt / CoverTiming.drain)
            if level <= 0 { releasing = false }
        } else if level > cap {
            level = max(cap, level - dt / CoverTiming.drain)
        } else if motion == .fill && !good {
            level = min(cap, level + dt / CoverTiming.fill)
        }
        if level >= 1, !blocked { setBlocked(true) } else if level < 0.97, blocked { releasing = true; setBlocked(false) }
        if blocked { blockedSeconds += dt }
        updateCameraSampling()
        if level <= 0 { silhouette.clear(); ownerPreviewVisible = false; message = nil; if !liquids.isEmpty { dropLiquids() }; return }
        if liquids.isEmpty {
            screenFrames = NSScreen.screens.map(\.frame)
            liquids = NSScreen.screens.map { Liquid(frame: $0.frame, main: $0 == NSScreen.main || NSScreen.screens.count == 1, target: self, action: #selector(fixClicked)) }
            liquids.forEach { $0.win.ignoresMouseEvents = !blocked; $0.win.orderFrontRegardless() }
        }
        let t = now.timeIntervalSince(t0)
        let image = blocked ? silhouette.image() : nil
        let visualLevel = CoverTiming.visualLevel(level)
        for l in liquids { l.draw(level: visualLevel, t: t, image: image) }
        ownerPreviewVisible = image != nil && liquids.contains { $0.main && !$0.portrait.layer.isHidden }
    }
    func dropLiquids() { liquids.forEach { $0.win.orderOut(nil) }; liquids = [] }
    func setBlocked(_ on: Bool) {
        blocked = on
        liquids.forEach { $0.win.ignoresMouseEvents = !on }
        if on {
            log("BAD \(reason) p=\(f2(pBar)) \(brief(lastSample))")
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableSessionTermination, .disableHideApplication, .disableAppleMenu]
            (liquids.first { $0.main } ?? liquids.first)?.win.makeKey()
        } else {
            log("ok p=\(f2(pBar)) \(brief(lastSample))")
            NSApp.presentationOptions = []
        }
    }

    // MARK: teaching and corrections
    // Feedback collects six seconds of live posture or eyewear measurements.
    var glassesWarning: Bool { reasonKind == "glasses" || reasonKind == "sunglasses" }
    @objc func fixClicked() { teach(glassesWarning ? "gafas" : "good") }
    func teach(_ label: String) {
        guard Date() >= feedbackRequestedUntil, (lastSample["training"] as? String ?? "").isEmpty else { return }
        let eyewear = label == "gafas" || label == "singafas"
        guard lastSample["face"] as? Bool == true,
              (eyewear || lastSample["body"] as? Bool == true),
              (lastSample["kind"] as? String) != "unjudged",
              Date().timeIntervalSince(lastSampleAt) < 1.25 else {
            flash(eyewear ? L("Mira a la cámara", "Face the camera") :
                  L("Colócate con la cara y los hombros visibles", "Keep your face and shoulders in view"))
            return
        }
        do {
            try label.write(to: trainURL, atomically: true, encoding: .utf8)
            log("LABEL \(label) p=\(f2(pBar)) \(brief(lastSample))")
            feedbackRequestedUntil = Date().addingTimeInterval(1.25)
            flash(L("Preparando el ejemplo…", "Getting ready to record…"))
        } catch {
            flash(L("No se pudo guardar el ejemplo", "Could not save feedback"))
        }
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
        if stale > 1.25, present || level > 0 { revealScreen("no frames") }
        if stale > 12, now.timeIntervalSince(lastCameraRestart) > 12, camera, !locked { restartCamera() }                       // lid was closed, camera taken away, etc.
        let k = reasonKind
        let cap = reason.prefix(1).uppercased() + reason.dropFirst()
        let (head, line): (String, String) = {
            switch k {
            case "glasses", "sunglasses": return (L("Ponte las gafas", "Put on your glasses"), cap)
            case "both": return (L("Siéntate bien y ponte las gafas", "Sit up and put on your glasses"), cap)
            case "hidden": return (L("Vuelve frente a la cámara", "Come back in front of the camera"), L("Siéntate bien donde te vea", "Sit upright where the camera can see you"))
            default: return (L("Siéntate bien", "Sit up straight"), cap + L(" · se quita en cuanto corrijas la postura", " · this clears as soon as you fix your posture"))
            }
        }()
        // the judge may change its mind several times a second; the words change only when the new reason has held for 4 s, at most every 12 s
        if head + line != pendingKey { pendingKey = head + line; pendingAt = now }
        if level > 0, message == nil || level < 0.9 || (now.timeIntervalSince(pendingAt) >= 4 && now.timeIntervalSince(messageAt) >= 12), message?.0 != head || message?.1 != line {
            message = (head, line); messageAt = now
        }
        let recording = lastSample["training"] as? String ?? ""
        let remaining = (lastSample["trainingRemaining"] as? NSNumber)?.doubleValue ?? 0
        for l in liquids {
            l.title.set(message?.0 ?? head); l.why.set(message?.1 ?? line)
            let ready = recording.isEmpty && now >= feedbackRequestedUntil
            let action = glassesWarning ? L("Llevo mis gafas", "I’m wearing my glasses") : L("Mi postura es buena", "My posture is good")
            l.setButton(action, enabled: ready)
            if !recording.isEmpty && remaining > 0 {
                l.foot.set(L("Mantén la posición", "Hold your position") + " · \(Int(ceil(remaining))) s")
            } else {
                l.foot.set(now < noteUntil ? note : "")
            }
        }
        if blocked, let w = (liquids.first { $0.main } ?? liquids.first)?.win, !NSApp.isActive || !w.isKeyWindow {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            w.makeKeyAndOrderFront(nil)
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
        shell.update(level: level, blocked: blocked, p: pBar, present: present, camera: camera, inCall: inCall,
                     reason: reason.prefix(1).uppercased() + reason.dropFirst(), kind: reasonKind,
                     feedback: now < noteUntil ? note : "", sample: stale <= 1.25 ? lastSample : [:])
        let mode = blocked ? "blocked" : level > 0 ? "filling" : "off"
        if mode == wroteMode, now.timeIntervalSince(wroteAt) < 2 { return }                  // every 2 s or on a change: less disk writing
        wroteMode = mode; wroteAt = now
        var st: [String: Any] = ["mode": mode, "level": level, "reason": reason, "p": pBar, "present": present,
                                 "inCall": inCall, "locked": locked, "blockedSeconds": Int(blockedSeconds), "at": Int(now.timeIntervalSince1970), "sample": lastSample]
        st["ownerPreview"] = ownerPreviewVisible
        st["camera"] = cameraName
        if let d = try? JSONSerialization.data(withJSONObject: st) { try? d.write(to: statusURL, options: .atomic) }
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
@discardableResult func sh(_ cmd: String) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}
let showNote = Notification.Name("io.github.samihalawa.postura.show")

/// Everything the window and the menu show, refreshed twice a second by Guard.tick().
final class Model: ObservableObject {
    @Published var settingsPresented = false
    @Published var cameraAvailable = true
    @Published var framingReady = false
    @Published var glassesRequired = prefs.bool(forKey: "requireGlasses")
    @Published var glassesReady = false
    @Published var recordingLabel = ""
    @Published var recordingTime = 0.0
    @Published var feedback = ""
    @Published var state = L("Iniciando", "Starting…")
    @Published var detail = ""
    @Published var symbol = "figure.stand"
    @Published var tint = Color.green
    @Published var setup = ""
    @Published var hud = prefs.object(forKey: "showHUD") as? Bool ?? true
    @Published var cameraDevice = prefs.string(forKey: "cameraDevice") ?? ""
    @Published var language = prefs.string(forKey: "language") ?? ""
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.backgroundColor = NSColor.black.cgColor
        view.layer = preview
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private extension View {
    @ViewBuilder func glassControl() -> some View {
        if #available(macOS 26.0, *) { buttonStyle(.glass) }
        else { buttonStyle(.bordered) }
    }
}

struct ExampleButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let time: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Label(label, systemImage: icon)
                if selected {
                    Text("\(max(1, Int(ceil(time)))) s")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .glassControl()
        .controlSize(.large)
        .overlay {
            if selected {
                Capsule()
                    .trim(from: 0, to: min(1, max(0, time / 6)))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .animation(.linear(duration: 0.4), value: time)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityValue(selected ? L("Grabando", "Recording") : "")
    }
}

struct PosturaView: View {
    @ObservedObject var model: Model
    let teach: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Postura").font(.system(size: 26, weight: .semibold))
                Spacer()
                Button { model.settingsPresented = true } label: {
                    Label(L("Ajustes", "Settings"), systemImage: "gearshape")
                }
                .glassControl()
                .keyboardShortcut(",", modifiers: .command)
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: model.symbol)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(model.tint)
                        .frame(width: 52, height: 52)
                        .background(model.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.state).font(.title3.weight(.semibold))
                        if !model.detail.isEmpty {
                            Text(model.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if !model.setup.isEmpty { ProgressView().controlSize(.small) }
                }

            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.separator.opacity(0.6))
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 8) {
                if model.cameraAvailable {
                    CameraPreview(session: g.session)
                        .frame(height: 212)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .accessibilityLabel(L("Vista de la cámara", "Live camera view"))
                    if !model.framingReady {
                        Text(L("Coloca la cara y los hombros dentro del encuadre.", "Sit so your face and shoulders are in view."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button(L("Permitir acceso a la cámara", "Open Camera Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(L("Comentarios sobre tu postura", "Posture feedback")).font(.headline)
                HStack(spacing: 8) {
                    ExampleButton(label: L("Buena postura", "Good posture"), icon: "hand.thumbsup",
                                  selected: model.recordingLabel == "good", time: model.recordingTime) { teach("good") }
                    ExampleButton(label: L("Mala postura", "Bad posture"), icon: "hand.thumbsdown",
                                  selected: model.recordingLabel == "bad", time: model.recordingTime) { teach("bad") }
                }
                .disabled(!model.recordingLabel.isEmpty || !model.setup.isEmpty)
                Text(model.recordingLabel.isEmpty
                     ? (model.feedback.isEmpty ? L("Marca tu postura si Postura se equivoca.", "Label your posture if Postura gets it wrong.") : model.feedback)
                     : L("Mantén la postura hasta que termine la cuenta.", "Hold your posture until the countdown ends."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 458)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $model.settingsPresented) { PosturaSettingsView(model: model) }
    }
}

struct PosturaSettingsView: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Picker(L("Cámara", "Camera"), selection: $model.cameraDevice) {
                    Text(L("Automática", "Automatic")).tag("")
                    ForEach(cameraDevices(), id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
                }.onChange(of: model.cameraDevice) { _, value in
                    prefs.set(value, forKey: "cameraDevice")
                    shell.relaunch()
                }
                Toggle(L("Exigir gafas", "Require glasses"), isOn: $model.glassesRequired)
                    .onChange(of: model.glassesRequired) { _, value in
                        prefs.set(value, forKey: "requireGlasses")
                        g.eye.restart()
                    }
                    .disabled(!model.recordingLabel.isEmpty)
                if model.glassesRequired {
                    Text(model.glassesReady
                         ? L("Puedes actualizar tus ejemplos con la cámara.", "Update your glasses examples with the camera.")
                         : L("Graba un ejemplo con gafas y otro sin ellas.", "Record one example with glasses and one without."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ExampleButton(label: L("Con gafas", "With glasses"), icon: "eyeglasses",
                                      selected: model.recordingLabel == "gafas", time: model.recordingTime) { g.teach("gafas") }
                        ExampleButton(label: L("Sin gafas", "Without glasses"), icon: "eye",
                                      selected: model.recordingLabel == "singafas", time: model.recordingTime) { g.teach("singafas") }
                    }.disabled(!model.recordingLabel.isEmpty)
                    if !model.feedback.isEmpty && model.recordingLabel.isEmpty {
                        Text(model.feedback).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(L("Mostrar estado en pantalla", "Show status on screen"), isOn: $model.hud)
                    .onChange(of: model.hud) { _, value in prefs.set(value, forKey: "showHUD") }
                Picker(L("Idioma", "Language"), selection: $model.language) {
                    Text(L("Sistema", "System")).tag(""); Text("English").tag("en"); Text("Español").tag("es")
                }.onChange(of: model.language) { _, value in
                    if value.isEmpty { prefs.removeObject(forKey: "language") }
                    else { prefs.set(value, forKey: "language") }
                    shell.relaunch()
                }
            }
            .formStyle(.grouped)
            Button(L("Listo", "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding([.trailing, .bottom], 18)
        }
        .frame(width: 438, height: model.glassesRequired ? 370 : 255)
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
        if !strictMode && !underAgent && writeAgent() {      // opened by hand: let launchd own the process from now on
            prefs.set(true, forKey: "showWindowOnce")
            let result = sh("launchctl bootout gui/\(getuid())/\(agentLabel); launchctl bootstrap gui/\(getuid()) '\(agentURL.path)'")
            if result == 0 { return false }
            log("login service could not start: \(result)")
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
        add(L("Buena postura", "Good posture"), "hand.thumbsup", #selector(good))
        add(L("Mala postura", "Bad posture"), "hand.thumbsdown", #selector(bad))
        menu.addItem(.separator())
        add(L("Ajustes…", "Settings…"), "gearshape", #selector(showSettings), ",")
        add(L("Acerca de Postura", "About Postura"), "info.circle", #selector(about))
        it.menu = menu; item = it
        if pythonPath() == nil { setup() } else { g.eye.start() }
        if prefs.bool(forKey: "showWindowOnce") || pythonPath() == nil { prefs.removeObject(forKey: "showWindowOnce"); DispatchQueue.main.async { self.show() } }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        header.title = model.state
        sub.title = model.detail
    }
    @objc func good() { g.teach("good") }
    @objc func bad() { g.teach("bad") }
    @objc func about() { NSApp.activate(ignoringOtherApps: true); NSApp.orderFrontStandardAboutPanel(nil) }
    @objc func showSettings() {
        show()
        model.settingsPresented = true
    }
    @objc func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PosturaView(model: model) { g.teach($0) }))
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
    func update(level: Double, blocked: Bool, p: Double, present: Bool, camera: Bool, inCall: Bool, reason: String, kind: String, feedback: String, sample: [String: Any]) {
        if model.cameraAvailable != camera { model.cameraAvailable = camera }
        let inFrame = sample["face"] as? Bool == true && sample["body"] as? Bool == true
        if model.framingReady != inFrame { model.framingReady = inFrame }
        let label = sample["training"] as? String ?? ""
        if model.recordingLabel != label { model.recordingLabel = label }
        let remaining = (sample["trainingRemaining"] as? NSNumber)?.doubleValue ?? 0
        if model.recordingTime != remaining { model.recordingTime = remaining }
        if let ready = sample["glassesReady"] as? Bool, model.glassesReady != ready { model.glassesReady = ready }
        if model.feedback != feedback { model.feedback = feedback }
        let (st, d, sym, tint): (String, String, String, Color) = {
            if !model.setup.isEmpty { return (L("Preparando…", "Setting up…"), L("Primera vez: instalando el modelo", "First launch: installing the model"), "arrow.down.circle", .blue) }
            if !camera { return (L("Sin cámara", "No camera"), L("Permítela en Ajustes → Privacidad → Cámara", "Allow it in Settings → Privacy → Camera"), "video.slash", .orange) }
            if level > 0 && (kind == "glasses" || kind == "sunglasses" || kind == "both") {
                let title = kind == "both" ? L("Corrige la postura y ponte las gafas", "Sit up and put on your glasses")
                    : L("Ponte las gafas", "Put on your glasses")
                return (title, reason, "eyeglasses", blocked ? .red : .orange)
            }
            if blocked { return (L("Corrige la postura", "Sit up to continue"), reason, "figure.fall", .red) }
            if level > 0 {
                let action = L("Corrige la postura", "Adjust your posture")
                return (action, reason, "figure.fall", .orange)
            }
            if inCall { return (L("En una llamada", "On a call"), L("Solo un aviso suave, nunca bloquea", "Only a gentle hint, never blocks"), "phone", .blue) }
            if !present { return (L("Esperando", "Waiting for you"), L("Siéntate donde te vea la cámara", "Sit where the camera can see you"), "eye.slash", .gray) }
            if p >= RELEASE { return (L("Comprobando la postura", "Checking your posture"), "", "figure.stand", .orange) }
            return (L("Buena postura", "Good posture"), L("Detección activa", "Posture detection is running"), "figure.stand", .green)
        }()
        if model.state != st { model.state = st }; if model.detail != d { model.detail = d }
        if model.symbol != sym { model.symbol = sym; item?.button?.image = NSImage(systemSymbolName: sym, accessibilityDescription: st) }
        if model.tint != tint { model.tint = tint }
        let tip = "Postura · \(st)"; if item?.button?.toolTip != tip { item?.button?.toolTip = tip }
    }
}
let shell = Shell()

signal(SIGPIPE, SIG_IGN)   // writing to a judge that has just exited must be an error, not the end of the app
let app = NSApplication.shared
let g = Guard()
if !shell.launch() { exit(0) }
app.delegate = g
app.setActivationPolicy(.regular)
app.run()
