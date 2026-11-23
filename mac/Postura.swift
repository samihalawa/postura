// Postura: camera posture guard for macOS. Clearly bad posture (or, once taught, no glasses) makes a glowing front close in
// over every display; when it has covered the screen, mouse, keyboard, Cmd-Tab and Force Quit are blocked until the posture
// is fixed. The judgement (p = 0..1 bad, why) comes from postura-eye.py; this app owns the camera, the timing and the screens.
// Out of frame, far away, turned away, screen locked or on a call: never blocks. Everything runs on the Mac; no images are saved.
import AppKit
import AVFoundation
import Quartz
import Carbon.HIToolbox

let fm = FileManager.default
let supportDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Postura")
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
/// The posture judge runs in a Python venv: $POSTURA_PYTHON, the per-user install, or the system-wide (strict) install.
let pythonPath: String = {
    if let p = ProcessInfo.processInfo.environment["POSTURA_PYTHON"] { return p }
    let user = supportDir.appendingPathComponent("venv/bin/python3").path
    return fm.isExecutableFile(atPath: user) ? user : "/usr/local/libexec/postura/venv/bin/python3"
}()
func f2(_ x: Double) -> String { String(format: "%.2f", x) }

// p is smoothed over ~1.2 s. Bad for GRACE s starts the liquid; it takes FILL s to cover the screen; good drains it in DRAIN s.
let BLOCK = 0.65, RELEASE = 0.40, GRACE = 1.0, FILL = 3.5, DRAIN = 1.0, FIXES_PER_DAY = 5, HOLD = 90.0

final class Eye {
    var input: FileHandle?, busy = false
    var onSample: (([String: Any]) -> Void)?
    let root = Bundle.main.resourceURL!
    func start() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [root.appendingPathComponent("postura-eye.py").path]
        p.environment = ["POSTURA_MODELS": root.appendingPathComponent("models").path, "GLOG_minloglevel": "2", "TF_CPP_MIN_LOG_LEVEL": "2",
                         "HOME": NSHomeDirectory(), "POSTURA_LANG": spanish ? "es" : "en"]
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        var buf = Data()
        o.fileHandleForReading.readabilityHandler = { h in
            buf.append(h.availableData)
            while let nl = buf.firstIndex(of: 10) {
                let line = buf[buf.startIndex..<nl]; buf.removeSubrange(buf.startIndex...nl)
                self.busy = false
                if let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if let e = j["error"] { log("eye error \(e)") } else { self.onSample?(j) }
                }
            }
        }
        p.terminationHandler = { _ in log("eye exited, restarting"); DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() } }
        try? p.run(); input = i.fileHandleForWriting; busy = false
    }
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
/// One centred line of text whose characters arrive and leave one by one: each fades, rises 0.55 em and sharpens from a
/// 0.14 em blur (MagicInterview's kinetic captions). A new string swaps only the characters that changed when the length
/// is the same (the clock), otherwise the old line drifts out while the new one comes in.
final class Kinetic: NSView {
    let font: NSFont, color: NSColor
    private(set) var text = "", visible = false
    private var glyphs: [CALayer] = []
    static let ease = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    init(_ parent: NSView, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1, digits: Bool = false) {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : f; color = NSColor.white.withAlphaComponent(alpha)
        super.init(frame: NSRect(x: 0, y: y, width: parent.bounds.width, height: ceil(size * 1.32)))
        wantsLayer = true; layerUsesCoreImageFilters = true
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.22; layer?.shadowRadius = 10; layer?.shadowOffset = .zero
        parent.addSubview(self)
    }
    required init?(coder: NSCoder) { nil }
    private func build(_ s: String) -> [CALayer] {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]), line = CTLineCreateWithAttributedString(a)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), x0 = (bounds.width - width) / 2
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, ns = s as NSString
        var out: [CALayer] = [], i = 0
        while i < ns.length {
            let r = ns.rangeOfComposedCharacterSequence(at: i), ch = ns.substring(with: r)
            let xa = CTLineGetOffsetForStringIndex(line, r.location, nil), xb = CTLineGetOffsetForStringIndex(line, r.location + r.length, nil)
            let g = CATextLayer(); g.contentsScale = scale; g.string = NSAttributedString(string: ch, attributes: [.font: font, .foregroundColor: color])
            g.frame = CGRect(x: x0 + xa, y: 0, width: max(1, xb - xa) + font.pointSize * 0.25, height: bounds.height)
            if let b = CIFilter(name: "CIGaussianBlur") { b.name = "blur"; b.setValue(0, forKey: kCIInputRadiusKey); g.filters = [b] }
            g.opacity = 0; layer?.addSublayer(g); out.append(g); i += r.length
        }
        return out
    }
    private func run(_ g: CALayer, into on: Bool, at t: CFTimeInterval, remove: Bool = false) {
        let em = font.pointSize, dur = on ? 0.62 : 0.34
        for (k, a, b) in [("opacity", on ? 0 : 1, on ? 1 : 0), ("filters.blur.inputRadius", on ? 0.14 * em : 0, on ? 0 : 0.14 * em),
                          ("transform.translation.y", on ? -0.55 * em : 0, on ? 0 : 0.22 * em)] as [(String, CGFloat, CGFloat)] {
            let x = CABasicAnimation(keyPath: k); x.fromValue = a; x.toValue = b; x.beginTime = t; x.duration = dur
            x.timingFunction = Kinetic.ease; x.fillMode = .both; x.isRemovedOnCompletion = false; g.add(x, forKey: k)
        }
        g.opacity = on ? 1 : 0
        if remove { DispatchQueue.main.asyncAfter(deadline: .now() + (t - CACurrentMediaTime()) + dur + 0.05) { g.removeFromSuperlayer() } }
    }
    private func step(_ n: Int, _ spread: Double) -> Double { n > 1 ? min(0.028, spread / Double(n - 1)) : 0 }
    func set(_ s: String) {
        guard s != text else { return }
        let old = glyphs, oldText = text; text = s
        guard visible else { old.forEach { $0.removeFromSuperlayer() }; glyphs = build(s); return }
        if old.isEmpty {                                                       // first text while already showing: arrive normally
            glyphs = build(s); let now = CACurrentMediaTime(), d = step(glyphs.count, 0.5)
            for (i, g) in glyphs.enumerated() { run(g, into: true, at: now + d * Double(i)) }; return
        }
        let fresh = build(s), now = CACurrentMediaTime()
        if oldText.count == s.count, oldText.count == old.count, fresh.count == old.count {   // same shape: only the changed characters move
            var k = 0
            for (i, (a, b)) in zip(oldText, s).enumerated() {
                if a == b { fresh[i].removeAllAnimations(); fresh[i].opacity = 1; old[i].removeFromSuperlayer() }
                else { run(old[i], into: false, at: now + 0.04 * Double(k), remove: true); run(fresh[i], into: true, at: now + 0.12 + 0.04 * Double(k)); k += 1 }
            }
        } else {
            let a = step(old.count, 0.25), b = step(fresh.count, 0.5)
            for (i, g) in old.enumerated() { run(g, into: false, at: now + a * Double(i), remove: true) }
            for (i, g) in fresh.enumerated() { run(g, into: true, at: now + 0.2 + b * Double(i)) }
        }
        glyphs = fresh
    }
    func show(_ on: Bool, delay: Double = 0) {
        guard on != visible else { return }; visible = on
        if glyphs.isEmpty, on { glyphs = build(text) }
        let now = CACurrentMediaTime() + delay, d = step(glyphs.count, on ? 0.5 : 0.2)
        for (i, g) in (on ? glyphs : glyphs.reversed()).enumerated() { run(g, into: on, at: now + d * Double(i)) }
    }
}

/// The warning, after the Apple Intelligence edge glow: light lives on the physical screen edge and floods inward as posture
/// stays bad, with every boundary feathered (no hard line anywhere). Blur and colour follow one soft, slowly waving front;
/// correcting posture pulls it back to the edge. Locked: the whole screen is frosted and tinted, the rim breathes.
final class Liquid {
    static let palette: [NSColor] = ["BC82F3", "F5B9EA", "8D9FFF", "FF6778", "FFBA71", "C686FF"].map { h in
        let v = Int(h, radix: 16)!; return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
    let win: KeyWin, blur = NSVisualEffectView(), tint = CALayer(), rimGlow = CALayer(), frontGlow = CALayer(), bloom = CALayer()
    let frostFeather = CAShapeLayer(), bloomFeather = CAShapeLayer()
    var rings: [(mask: CAShapeLayer, width: CGFloat, rim: Bool)] = [], gradients: [CAGradientLayer] = []
    let content = NSView(), title: Kinetic, why: Kinetic, foot: Kinetic, date: Kinetic, clock: Kinetic, button = NSButton()
    let dayFmt = DateFormatter(), timeFmt = DateFormatter()
    var preview: NSView?, lastShuffle = -10.0, shown = false
    static let M: CGFloat = 180
    init(screen: NSScreen, session: AVCaptureSession, main: Bool, target: AnyObject, action: Selector) {
        let f = screen.frame, W = f.width, H = f.height
        win = KeyWin(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())); win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]; win.ignoresMouseEvents = true
        win.appearance = NSAppearance(named: .darkAqua)
        let root = win.contentView!; root.wantsLayer = true
        blur.appearance = NSAppearance(named: .aqua); blur.material = .fullScreenUI; blur.blendingMode = .behindWindow; blur.state = .active; blur.frame = root.bounds; root.addSubview(blur)
        blur.wantsLayer = true; frostFeather.frame = root.bounds; blur.layer?.mask = frostFeather
        for m in [frostFeather, bloomFeather] { m.fillColor = nil; m.shadowColor = NSColor.black.cgColor; m.shadowOpacity = 1; m.shadowOffset = .zero }
        let host = NSView(frame: root.bounds); host.wantsLayer = true; host.layerUsesCoreImageFilters = true; root.addSubview(host)
        tint.frame = host.bounds; tint.backgroundColor = NSColor(srgbRed: 0.12, green: 0.08, blue: 0.22, alpha: 1).cgColor; tint.opacity = 0; host.layer?.addSublayer(tint)
        let side = hypot(W, H) + 80
        let spin = CABasicAnimation(keyPath: "transform.rotation.z"); spin.fromValue = 0; spin.toValue = -2 * Double.pi; spin.duration = 14; spin.repeatCount = .infinity
        var grads: [CAGradientLayer] = [], rs: [(mask: CAShapeLayer, width: CGFloat, rim: Bool)] = []
        func conic(_ into: CALayer, _ o: CGFloat = 0) {
            let g = CAGradientLayer(); g.type = .conic; g.startPoint = CGPoint(x: 0.5, y: 0.5); g.endPoint = CGPoint(x: 0.5, y: 0)
            g.bounds = CGRect(x: 0, y: 0, width: side, height: side); g.position = CGPoint(x: W / 2 + o, y: H / 2 + o); g.add(spin, forKey: "spin")
            into.addSublayer(g); grads.append(g)
        }
        func blurred(_ l: CALayer, _ r: CGFloat) { if let b = CIFilter(name: "CIGaussianBlur") { b.setValue(r, forKey: kCIInputRadiusKey); l.filters = [b] } }
        // colour wash: the gradient itself, heavily blurred, shown through the same feathered region as the frost
        bloom.frame = host.bounds; host.layer?.addSublayer(bloom)
        let wash = CALayer(); wash.frame = host.bounds; blurred(wash, 70); conic(wash); bloom.addSublayer(wash)
        bloomFeather.frame = host.bounds; bloom.mask = bloomFeather
        // light: a bright rim hugging the display edge and a soft luminous wave on the front, each built from blurred strokes
        // stroke layers reach M past the screen so the blur near the edge samples light, not emptiness
        for (group, rim, layers) in [(rimGlow, true, [(CGFloat(4), CGFloat(2)), (10, 6), (22, 18), (44, 52)]),
                                     (frontGlow, false, [(CGFloat(10), CGFloat(36))])] {
            group.frame = host.bounds; host.layer?.addSublayer(group)
            for (w, r) in layers {
                let ring = CALayer(); ring.frame = host.bounds.insetBy(dx: -Liquid.M, dy: -Liquid.M); blurred(ring, r)
                let clip = CALayer(); clip.frame = ring.bounds
                let m = CAShapeLayer(); m.frame = ring.bounds; m.fillColor = nil; m.strokeColor = NSColor.white.cgColor; m.lineJoin = .round
                clip.mask = m; conic(clip, Liquid.M); ring.addSublayer(clip); group.addSublayer(ring)
                rs.append((m, w, rim))
            }
        }
        content.frame = root.bounds; root.addSubview(content)
        // one column stacked from the top like the lock screen (date, time, message, camera, action), sized to the display
        var y = H * 0.955
        func next(_ size: CGFloat, gap: CGFloat) -> CGFloat { y -= ceil(size * 1.32) + gap; return y }
        let ds = min(19, H * 0.025), cs = min(64, H * 0.078), ts = min(68, H * 0.08), ws = min(24, H * 0.03)
        date = Kinetic(content, y: next(ds, gap: 0), size: ds, weight: .semibold, alpha: 0.85)
        clock = Kinetic(content, y: next(cs, gap: -4), size: cs, weight: .semibold, digits: true)
        title = Kinetic(content, y: next(ts, gap: H * 0.035), size: ts, weight: .semibold)
        why = Kinetic(content, y: next(ws, gap: 2), size: ws, weight: .medium, alpha: 0.9)
        foot = Kinetic(content, y: H * 0.04, size: 14, weight: .regular, alpha: 0.7)
        let ph = min(300, y - H * 0.04 - 44 - 26 - 30 - 22), pw = ph * 4 / 3, top = y - 22
        dayFmt.locale = Locale(identifier: spanish ? "es_ES" : "en_US"); dayFmt.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        timeFmt.locale = Locale.current; timeFmt.dateFormat = (DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current) ?? "H:mm")
            .replacingOccurrences(of: "a", with: "").replacingOccurrences(of: "\u{202F}", with: "").trimmingCharacters(in: .whitespaces)
        gradients = grads; rings = rs
        if main {
            let pv = NSView(frame: NSRect(x: (W - pw) / 2, y: top - ph, width: pw, height: ph)); pv.wantsLayer = true
            let pl = AVCaptureVideoPreviewLayer(session: session); pl.frame = pv.bounds; pl.videoGravity = .resizeAspectFill
            pl.connection?.automaticallyAdjustsVideoMirroring = false; pl.connection?.isVideoMirrored = true
            pv.layer?.addSublayer(pl)
            let soft = CAShapeLayer(); soft.frame = pv.bounds; soft.fillColor = nil    // feathered edge: the mask is the soft shadow of an inset rounded rect
            soft.shadowPath = CGPath(roundedRect: pv.bounds.insetBy(dx: 14, dy: 14), cornerWidth: 30, cornerHeight: 30, transform: nil)
            soft.shadowColor = NSColor.black.cgColor; soft.shadowOpacity = 1; soft.shadowOffset = .zero; soft.shadowRadius = 9; pv.layer?.mask = soft
            content.addSubview(pv); preview = pv
            button.frame = NSRect(x: (W - 460) / 2, y: top - ph - 26 - 44, width: 460, height: 44); button.bezelStyle = .rounded; button.controlSize = .large
            button.font = .systemFont(ofSize: 17, weight: .medium); button.focusRingType = .none
            button.target = target; button.action = action; content.addSubview(button)
        }
        content.wantsLayer = true; content.layerUsesCoreImageFilters = true
        for v in content.subviews where !(v is Kinetic) { v.wantsLayer = true; v.layer?.opacity = 0 }
        shuffle(animated: false)
    }
    /// New random stop positions, eased over 1.2 s, so the colours drift around the edge.
    func shuffle(animated: Bool) {
        let stops = Liquid.palette.map { ($0.cgColor, Double.random(in: 0...1)) }.sorted { $0.1 < $1.1 }
        let colors = stops.map { $0.0 } + [stops[0].0], locs = stops.map { NSNumber(value: $0.1) } + [1]   // closes the circle with no seam
        CATransaction.begin(); CATransaction.setAnimationDuration(animated ? 1.2 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut)); CATransaction.setDisableActions(!animated)
        for g in gradients { g.colors = colors; g.locations = locs }
        CATransaction.commit()
    }
    /// A living superellipse centred on the screen with half-size (a, b) and exponent n, plus three slow travelling waves on its rim.
    /// `reverse` walks it the other way so it cuts a hole in a rectangle under the non-zero rule (shadow paths have no even-odd).
    func blob(_ a: CGFloat, _ b: CGFloat, n: Double, amp: CGFloat, t: Double, reverse: Bool = false, into p: CGMutablePath = CGMutablePath()) -> CGMutablePath {
        let c = CGPoint(x: bloom.bounds.midX, y: bloom.bounds.midY), steps = 240, e = 2.0 / n
        for i in 0...steps {
            let th = Double(reverse ? steps - i : i) / Double(steps) * 2 * .pi, ct = cos(th), st = sin(th)
            let x = CGFloat(copysign(pow(abs(ct), e), ct)) * a, y = CGFloat(copysign(pow(abs(st), e), st)) * b
            let wave = 0.55 * sin(3 * th + 0.45 * t) + 0.30 * sin(5 * th - 0.70 * t + 1.3) + 0.15 * sin(9 * th + 1.10 * t + 2.1)
            let len = max(1, hypot(x, y)), k = 1 + amp * CGFloat(wave) / len
            let pt = CGPoint(x: c.x + x * k, y: c.y + y * k)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath(); return p
    }
    /// Apple-style text transition: each element arrives from a blur, fades and settles a few points, one after another;
    /// it leaves the same way, faster and in reverse order.
    func reveal(_ on: Bool) {
        guard on != shown else { return }; shown = on
        let lines = [date, clock, title, why, foot]                                // text: character by character, top to bottom
        for (i, k) in (on ? lines : lines.reversed()).enumerated() { k.show(on, delay: on ? [0, 0.08, 0.25, 0.45, 0.9][i] : 0.03 * Double(i)) }
        let order: [NSView] = [preview, button.superview == nil ? nil : button].compactMap { $0 }
        let now = CACurrentMediaTime() + (on ? 0.6 : 0), ease = Kinetic.ease
        for (i, v) in (on ? order : order.reversed()).enumerated() {
            guard let l = v.layer else { continue }
            if l.filters == nil, let b = CIFilter(name: "CIGaussianBlur") { b.name = "blur"; b.setValue(0, forKey: kCIInputRadiusKey); l.filters = [b] }
            let start = now + Double(i) * (on ? 0.08 : 0.025), dur = on ? 0.6 : 0.3
            for (key, from, to) in [("opacity", on ? 0.0 : 1.0, on ? 1.0 : 0.0), ("filters.blur.inputRadius", on ? 16.0 : 0.0, on ? 0.0 : 10.0),
                                    ("transform.translation.y", on ? -12.0 : 0.0, on ? 0.0 : -6.0)] {
                let a = CABasicAnimation(keyPath: key); a.fromValue = from; a.toValue = to; a.beginTime = start; a.duration = dur
                a.timingFunction = ease; a.fillMode = .both; a.isRemovedOnCompletion = false; l.add(a, forKey: key)
            }
            l.opacity = on ? 1 : 0
        }
    }
    func draw(level: Double, t: Double) {
        if t - lastShuffle > 0.9 { lastShuffle = t; shuffle(animated: true) }
        let bw = bloom.bounds.width, bh = bloom.bounds.height, short = min(bw, bh)
        let s = CGFloat(min(1, max(0, level))), ease = s * s * (3 - 2 * s), breathe = CGFloat(0.5 + 0.5 * sin(1.3 * t))
        let locked = CGFloat(min(1, max(0, (level - 0.88) / 0.12)))
        let fade = min(1, 6 * s)                                                     // everything eases in from nothing and back out
        let soft = 30 + 110 * ease                                                   // feather radius grows as the light moves in
        let d = ease * (short / 2 + 1.15 * soft)                                     // how far the front has travelled; closes only at the end
        let a = bw / 2 + soft - d, b = bh / 2 + soft - d
        // region between the screen edge and the front, holed by the wavy front; empty hole once it has closed
        let region = CGMutablePath(); region.addRect(bloom.bounds.insetBy(dx: -300, dy: -300))
        let front: CGMutablePath? = a > 4 && b > 4 ? blob(a, b, n: 4, amp: min(14 + 30 * ease, 0.12 * min(a, b)), t: t) : nil
        if front != nil { _ = blob(a, b, n: 4, amp: min(14 + 30 * ease, 0.12 * min(a, b)), t: t, reverse: true, into: region) }
        let rim = blob(bw / 2, bh / 2, n: 14, amp: 4 + 8 * breathe * (0.4 + 0.6 * locked), t: t * 0.8 + 7)   // hugs the display edge
        var shift = CGAffineTransform(translationX: Liquid.M, y: Liquid.M)
        let rimPath = rim.copy(using: &shift), frontPath = front?.copy(using: &shift)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for m in [frostFeather, bloomFeather] { m.shadowPath = region; m.shadowRadius = soft }
        bloom.opacity = Float(fade * (0.25 + 0.35 * ease + 0.10 * locked * breathe)); blur.alphaValue = fade
        for (m, w, isRim) in rings {
            if isRim { m.path = rimPath; m.lineWidth = 2 * w * (0.7 + 0.45 * ease + 0.2 * locked * breathe) }
            else { m.path = frontPath; m.lineWidth = 2 * w * (0.8 + 0.4 * ease) }
        }
        rimGlow.opacity = Float(fade * min(1, 0.6 + 2.5 * s) * (0.85 + 0.15 * breathe))
        frontGlow.opacity = Float(0.45 * min(1, 4 * s) * (1 - locked))   // a faint luminous edge on the front, never a line
        tint.opacity = Float(0.30 * locked)                                          // depth behind the message, not a grey dim
        CATransaction.commit()
        let today = Date(); date.set(dayFmt.string(from: today)); clock.set(timeFmt.string(from: today))
        reveal(level >= 0.93)
    }
    /// The button's label changes with a quick blur through, never a jump.
    func setButton(_ s: String, enabled: Bool) {
        guard button.title != s || button.isEnabled != enabled else { return }
        guard shown, let l = button.layer, !button.title.isEmpty else { button.title = s; button.isEnabled = enabled; return }
        if l.filters == nil, let b = CIFilter(name: "CIGaussianBlur") { b.name = "blur"; b.setValue(0, forKey: kCIInputRadiusKey); l.filters = [b] }
        let now = CACurrentMediaTime()
        for (k, a, b) in [("opacity", 1.0, 0.0), ("filters.blur.inputRadius", 0.0, 8.0)] {
            let x = CABasicAnimation(keyPath: k); x.fromValue = a; x.toValue = b; x.beginTime = now; x.duration = 0.18; x.autoreverses = true
            x.timingFunction = Kinetic.ease; l.add(x, forKey: k + "swap")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.button.title = s; self.button.isEnabled = enabled }
    }
}

final class Guard: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession(), queue = DispatchQueue(label: "postura.camera"), eye = Eye()
    var lastFrame = Date.distantPast, lastProcessed = Date.distantPast, lastSampleAt = Date.distantPast, lastSeen = Date.distantPast
    var pBar = 0.0, badSince: Date?, graceUntil = Date.distantPast, lastFaceAt = Date.distantPast
    var level = 0.0, blocked = false, lastAnim = Date(), t0 = Date()
    var present = false, dodging = false, training = "", reason = "", reasonKind = "", note = "", noteUntil = Date.distantPast, lastSample: [String: Any] = [:]
    var camera = true, inCall = false, locked = false, poweringOff = false
    var liquids: [Liquid] = [], hud: NSWindow?, hudText: NSTextField?, keyMonitor: Any?
    var blockedSeconds = 0.0

    func applicationDidFinishLaunching(_ n: Notification) {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in self.poweringOff = true }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {   // lid opened / display woke: the camera stops while asleep
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in log("wake"); self.reset("wake"); self.restartCamera() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in self.dropLiquids() }
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { _ in log("camera runtime error"); self.restartCamera() }
        log("start")
        eye.onSample = { s in DispatchQueue.main.async { self.handle(s, Date()) } }
        eye.start()
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { if ok { self.startCamera() } else { self.camera = false; log("camera denied") } } }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in self.animate() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in self.tick() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in self.checkCall() }
        checkCall(); showHUD(); installHotkeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in   // while blocked this app has the keyboard: plain G corrects it
            if self.blocked, e.charactersIgnoringModifiers?.lowercased() == "g" { self.teach("good") }
            return nil
        }
    }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply { poweringOff ? .terminateNow : .terminateCancel }

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
        queue.async { self.session.startRunning() }
        camera = true; log("camera \(dev.localizedName)")
    }
    func restartCamera() {
        guard camera else { return }
        queue.async { if self.session.inputs.isEmpty { DispatchQueue.main.async { self.startCamera() } } else if !self.session.isRunning { self.session.startRunning() } }
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        let now = Date()  // 2.5 frames/s while all is well, 6/s while something looks wrong
        guard now.timeIntervalSince(lastProcessed) > (level == 0 && pBar < RELEASE && training.isEmpty ? 0.4 : 0.16), let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastProcessed = now
        eye.send(pb)
    }

    // MARK: judgement -> smoothed p
    func reset(_ why: String) { if level > 0 || blocked { log("clear: \(why)") }; pBar = 0; badSince = nil }
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
        let bad = (present || dodging) && !locked && pBar >= BLOCK && badSince != nil && now.timeIntervalSince(badSince!) >= GRACE && now >= graceUntil
        let good = (!present && !dodging) || locked || pBar < RELEASE || now < graceUntil
        let cap = inCall ? 0.22 : 1.0     // on a call only a thin edge glow shows, it never blocks
        if bad { level = min(cap, level + dt / FILL) } else if good { level = max(0, level - dt / DRAIN) }
        if level > cap { level = max(cap, level - dt / DRAIN) }
        if level >= 1, !blocked { setBlocked(true) } else if level < 0.97, blocked { setBlocked(false) }
        if blocked { blockedSeconds += dt }
        if level <= 0 { if !liquids.isEmpty { dropLiquids() }; return }
        if liquids.isEmpty {
            liquids = NSScreen.screens.map { Liquid(screen: $0, session: session, main: $0 == NSScreen.main || NSScreen.screens.count == 1, target: self, action: #selector(fixClicked)) }
            liquids.forEach { $0.win.orderFrontRegardless() }
        }
        let t = now.timeIntervalSince(t0)
        for l in liquids { l.draw(level: level, t: t) }
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
        for l in liquids {
            l.title.set(head); l.why.set(line)
            l.setButton(left > 0 ? (glasses ? L("Las llevo puestas — pulsa G o haz clic (quedan \(left) hoy)", "I'm wearing them — press G or click (\(left) left today)")
                                            : L("Estoy bien sentado — pulsa G o haz clic (quedan \(left) hoy)", "I'm sitting fine — press G or click (\(left) left today)"))
                                 : L("Sin correcciones por hoy", "No corrections left today"), enabled: left > 0)
            l.foot.set(L("Todo sigue funcionando por detrás.", "Everything keeps running in the background."))
        }
        if blocked { NSApp.activate(ignoringOtherApps: true); liquids.forEach { $0.win.orderFrontRegardless() }; (liquids.first { $0.preview != nil } ?? liquids.first)?.win.makeKey() }
        var text = "", color = NSColor.systemGreen
        if now < noteUntil { text = note; color = .systemYellow }
        else if !camera { text = L("Postura: sin cámara (Ajustes → Privacidad → Cámara)", "Postura: no camera (Settings → Privacy → Camera)"); color = .systemOrange }
        else if !present { text = L("Postura: no te veo, no hago nada", "Postura: can't see you, doing nothing"); color = .systemGray }
        else if pBar >= BLOCK { text = "● \(L("MAL", "BAD")) \(Int(pBar * 100))% · \(reason)"; color = .systemRed }
        else if pBar >= RELEASE { text = "● \(L("dudoso", "unsure")) \(Int(pBar * 100))% · \(reason)"; color = .systemYellow }
        else { text = "● \(L("bien", "good")) \(Int(pBar * 100))%   " + L("⌃⌥⌘B = esto es malo · ⌃⌥⌘G = esto es bueno", "⌃⌥⌘B = this is bad · ⌃⌥⌘G = this is good") }
        if let h = hudText, h.stringValue != text || h.textColor != color {
            let x = CATransition(); x.type = .fade; x.duration = 0.35; x.timingFunction = Kinetic.ease; h.layer?.add(x, forKey: "swap")
            h.stringValue = text; h.textColor = color
        }
        hud?.orderFrontRegardless()
        let st: [String: Any] = ["mode": blocked ? "blocked" : level > 0 ? "filling" : "off", "level": level, "reason": reason, "p": pBar, "present": present,
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

let app = NSApplication.shared
let g = Guard()
app.delegate = g
app.setActivationPolicy(.accessory)
app.run()
