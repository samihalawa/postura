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
let BLOCK = 0.65, RELEASE = 0.40, GRACE = 1.0, FILL = 3.5, DRAIN = 0.7, FIXES_PER_DAY = 5

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
func text(_ v: NSView, _ y: CGFloat, _ h: CGFloat, _ size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1) -> NSTextField {
    let t = NSTextField(labelWithString: "")
    t.frame = NSRect(x: 0, y: y, width: v.frame.width, height: h); t.alignment = .center
    t.font = .systemFont(ofSize: size, weight: weight); t.textColor = NSColor.white.withAlphaComponent(alpha)
    t.shadow = { let s = NSShadow(); s.shadowBlurRadius = 14; s.shadowColor = NSColor.black.withAlphaComponent(0.22); return s }()   // lifts text off the glow, as on the lock screen
    v.addSubview(t); return t
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
    let content = NSView(), title: NSTextField, why: NSTextField, foot: NSTextField, button = NSButton()
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
        // one column stacked from the top, sized to the display so nothing overlaps on small screens
        let ts = min(76, H * 0.085), top = H * 0.74, ph = min(315, H * 0.36), pw = ph * 4 / 3
        title = text(content, top, ts * 1.3, ts, weight: .semibold); why = text(content, top - 42, 36, min(26, H * 0.032), weight: .medium, alpha: 0.9)
        foot = text(content, H * 0.055, 24, 15, alpha: 0.7)
        gradients = grads; rings = rs
        if main {
            let pv = NSView(frame: NSRect(x: (W - pw) / 2, y: top - 66 - ph, width: pw, height: ph)); pv.wantsLayer = true
            let pl = AVCaptureVideoPreviewLayer(session: session); pl.frame = pv.bounds; pl.videoGravity = .resizeAspectFill
            pl.connection?.automaticallyAdjustsVideoMirroring = false; pl.connection?.isVideoMirrored = true
            pv.layer?.addSublayer(pl); pv.layer?.cornerRadius = 22; pv.layer?.masksToBounds = true
            pv.layer?.borderWidth = 1; pv.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            content.addSubview(pv); preview = pv
            button.frame = NSRect(x: (W - 460) / 2, y: top - 66 - ph - 28 - 44, width: 460, height: 44); button.bezelStyle = .rounded; button.controlSize = .large
            button.font = .systemFont(ofSize: 17, weight: .medium); button.focusRingType = .none
            button.target = target; button.action = action; content.addSubview(button)
        }
        content.wantsLayer = true; content.layerUsesCoreImageFilters = true
        for v in content.subviews { v.wantsLayer = true; v.layer?.opacity = 0 }
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
        let order: [NSView] = [title, why, preview, button.superview == nil ? nil : button, foot].compactMap { $0 }
        let now = CACurrentMediaTime(), ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
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
        reveal(level >= 0.93)
    }
}

final class Guard: NSObject, NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession(), queue = DispatchQueue(label: "postura.camera"), eye = Eye()
    var lastFrame = Date.distantPast, lastProcessed = Date.distantPast, lastSampleAt = Date.distantPast, lastSeen = Date.distantPast
    var pBar = 0.0, badSince: Date?, graceUntil = Date.distantPast
    var level = 0.0, blocked = false, lastAnim = Date(), t0 = Date()
    var present = false, training = "", reason = "", reasonKind = "", note = "", noteUntil = Date.distantPast, lastSample: [String: Any] = [:]
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
        let seen = (s["face"] as? Bool) == true
        if seen { lastSeen = now }
        present = now.timeIntervalSince(lastSeen) < 2.5   // a missed frame or two is not "gone": hold the current state
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
        let bad = present && !locked && pBar >= BLOCK && badSince != nil && now.timeIntervalSince(badSince!) >= GRACE && now >= graceUntil
        let good = !present || locked || pBar < RELEASE || now < graceUntil
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
            if reasonKind == "glasses" { label = "gafas" }      // "I do have my glasses on"
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
        let w = NSWindow(contentRect: NSRect(x: f.minX + 10, y: f.minY + 10, width: 430, height: 24), styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .statusBar; w.isOpaque = false; w.backgroundColor = NSColor.black.withAlphaComponent(0.55); w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let t = NSTextField(labelWithString: ""); t.frame = NSRect(x: 8, y: 3, width: 414, height: 18); t.font = .systemFont(ofSize: 12); w.contentView!.addSubview(t)
        w.orderFrontRegardless(); hud = w; hudText = t
    }
    func tick() {
        let now = Date()
        locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let stale = now.timeIntervalSince(lastFrame)
        if stale > 6 { present = false; reset("no frames") }
        if stale > 12, camera, !locked { restartCamera() }                       // lid was closed, camera taken away, etc.
        let glasses = reasonKind == "glasses", left = fixesLeft()
        for l in liquids {
            l.title.stringValue = glasses ? L("Ponte las gafas", "Put your glasses on") : L("Siéntate bien", "Sit up straight")
            l.why.stringValue = glasses ? L("No llevas las gafas · se quita en cuanto te las pongas", "No glasses · this clears as soon as you put them on")
                                        : "\(reason) · " + L("se quita en cuanto corrijas la postura", "this clears as soon as you fix your posture")
            l.button.title = left > 0 ? (glasses ? L("Las llevo puestas — pulsa G o haz clic (quedan \(left) hoy)", "I'm wearing them — press G or click (\(left) left today)")
                                                 : L("Estoy bien sentado — pulsa G o haz clic (quedan \(left) hoy)", "I'm sitting fine — press G or click (\(left) left today)"))
                                      : L("Sin correcciones por hoy", "No corrections left today")
            l.button.isEnabled = left > 0
            l.foot.stringValue = L("Todo sigue funcionando por detrás.", "Everything keeps running in the background.")
        }
        if blocked { NSApp.activate(ignoringOtherApps: true); liquids.forEach { $0.win.orderFrontRegardless() }; (liquids.first { $0.preview != nil } ?? liquids.first)?.win.makeKey() }
        var text = "", color = NSColor.systemGreen
        if now < noteUntil { text = note; color = .systemYellow }
        else if !camera { text = L("Postura: sin cámara (Ajustes → Privacidad → Cámara)", "Postura: no camera (Settings → Privacy → Camera)"); color = .systemOrange }
        else if !present { text = L("Postura: no te veo, no hago nada", "Postura: can't see you, doing nothing"); color = .systemGray }
        else if pBar >= BLOCK { text = "● \(L("MAL", "BAD")) \(Int(pBar * 100))% · \(reason)"; color = .systemRed }
        else if pBar >= RELEASE { text = "● \(L("dudoso", "unsure")) \(Int(pBar * 100))% · \(reason)"; color = .systemYellow }
        else { text = "● \(L("bien", "good")) \(Int(pBar * 100))%   " + L("⌃⌥⌘B = esto es malo · ⌃⌥⌘G = esto es bueno", "⌃⌥⌘B = this is bad · ⌃⌥⌘G = this is good") }
        hudText?.stringValue = text; hudText?.textColor = color; hud?.orderFrontRegardless()
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
