# postura-eye: posture judge for Postura.app (Google AI Edge MediaPipe Pose + Face Landmarker).
# Reads BGRA frames from stdin ("W H\n" + W*H*4 bytes), prints one JSON line per frame: measurements, p (0..1 bad), why.
# p = general rules for clearly bad posture, overridden by the user's own labelled examples when the current
# measurements are close to them (newest labels win). Stores numbers only, never images.
#   --video FILE   print one row per sampled frame (offline analysis and tests)
import sys, json, math, os, time, collections
import numpy as np
import mediapipe as mp

M = os.environ.get("POSTURA_MODELS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "models"))
SUP = os.environ.get("POSTURA_HOME", os.path.expanduser("~/Library/Application Support/Postura"))
EX, TRAIN = f"{SUP}/examples.jsonl", f"{SUP}/train"
TELE = os.environ.get("POSTURA_TELEMETRY", os.path.expanduser("~/Library/Logs/postura-features.jsonl"))
OFFLINE = "--video" in sys.argv
ES = os.environ.get("POSTURA_LANG", "en") == "es"
TXT = {"far": ("lejos", "far away"), "side": ("de lado", "turned away"), "roll": ("cabeza muy inclinada", "head tilted"),
       "slouch": ("encorvado: cabeza hundida y adelantada", "slouching: head sunk and forward"), "shoulders": ("hombros torcidos", "shoulders tilted"),
       "examples": ("como tus ejemplos de mala postura", "like your bad-posture examples"), "glasses": ("sin gafas", "no glasses"),
       "sunglasses": ("gafas de sol", "sunglasses")}
W = lambda k: TXT[k][0 if ES else 1]
V = mp.tasks.vision
RM = V.RunningMode.IMAGE if OFFLINE else V.RunningMode.VIDEO
pose = V.PoseLandmarker.create_from_options(V.PoseLandmarkerOptions(
    base_options=mp.tasks.BaseOptions(model_asset_path=f"{M}/pose_landmarker_full.task"), running_mode=RM, num_poses=2))
face = V.FaceLandmarker.create_from_options(V.FaceLandmarkerOptions(
    base_options=mp.tasks.BaseOptions(model_asset_path=f"{M}/face_landmarker.task"), running_mode=RM, num_faces=3,
    output_facial_transformation_matrixes=True))
embedder = V.ImageEmbedder.create_from_options(V.ImageEmbedderOptions(
    base_options=mp.tasks.BaseOptions(model_asset_path=f"{M}/mobilenet_v3_small.tflite"), l2_normalize=True))
GL = {"yes": f"{SUP}/glasses_yes.npy", "no": f"{SUP}/glasses_no.npy"}

def measure(rgb, ts):
    img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
    pr = pose.detect(img) if OFFLINE else pose.detect_for_video(img, ts)
    fr = face.detect(img) if OFFLINE else face.detect_for_video(img, ts)
    m = {"face": False, "body": False, "person": bool(pr.pose_landmarks)}
    if fr.face_landmarks:
        eyes = lambda l: math.hypot((l[263].x - l[33].x) * 640, (l[263].y - l[33].y) * 480)
        i = max(range(len(fr.face_landmarks)), key=lambda j: eyes(fr.face_landmarks[j]))  # nearest person = biggest face
        T = np.array(fr.facial_transformation_matrixes[i]); R = T[:3, :3]; lm = fr.face_landmarks[i]
        m["eyePx"] = eyes(lm); m["faces"] = len(fr.face_landmarks)
        if abs(math.degrees(math.asin(max(-1, min(1, -R[2][0]))))) < 30 and m["eyePx"] >= 60: m["_emb"] = eye_embedding(rgb, lm)
        if m["eyePx"] >= 40: m["shade"] = shade(rgb, lm)
        m.update(face=True, person=True, pitch=math.degrees(math.atan2(R[2][1], R[2][2])),      # + = face turned below the camera
                 yaw=math.degrees(math.asin(max(-1, min(1, -R[2][0])))), roll=math.degrees(math.atan2(R[1][0], R[0][0])),
                 dist=-T[2][3], noseY=lm[1].y, noseX=lm[1].x)
    if m["face"] and pr.pose_landmarks:
        j = min(range(len(pr.pose_landmarks)), key=lambda k: math.hypot(pr.pose_landmarks[k][0].x - m["noseX"], pr.pose_landmarks[k][0].y - m["noseY"]))
        n, w = pr.pose_landmarks[j], pr.pose_world_landmarks[j]  # the body that belongs to that face
        if math.hypot(n[0].x - m["noseX"], n[0].y - m["noseY"]) > 0.15: return m
        if all(n[i].visibility > 0.5 and 0 <= n[i].y <= 1.05 for i in (11, 12)):
            ear = [(getattr(w[7], a) + getattr(w[8], a)) / 2 for a in "xyz"]
            sh = [(getattr(w[11], a) + getattr(w[12], a)) / 2 for a in "xyz"]
            sw = math.dist([w[11].x, w[11].y, w[11].z], [w[12].x, w[12].y, w[12].z])
            dx, dy = (n[11].x - n[12].x) * 4 / 3, n[11].y - n[12].y; sw2 = math.hypot(dx, dy) + 1e-6
            shY = (n[11].y + n[12].y) / 2
            m.update(body=True, neck=(sh[1] - ear[1]) / sw,            # ears above shoulders, in shoulder widths (3D)
                     fwd=(sh[2] - ear[2]) / sw,                        # ears in front of shoulders (3D)
                     shY=shY, shTilt=math.degrees(math.atan2(dy, abs(dx) + 1e-6)), sw2=sw2,
                     neck2=(shY - m["noseY"]) / sw2, lat=(m["noseX"] - (n[11].x + n[12].x) / 2) * 4 / 3 / sw2)
    return m

def shade(rgb, lm):  # eye area brightness / cheek brightness: ~1 bare eyes or clear glasses, ~0.4 dark lenses
    H, W = rgb.shape[:2]; P = lambda i: np.array([lm[i].x * W, lm[i].y * H]); r = []
    def med(c, w, h):
        x0, x1, y0, y1 = int(max(0, c[0] - w / 2)), int(min(W, c[0] + w / 2)), int(max(0, c[1] - h / 2)), int(min(H, c[1] + h / 2))
        px = rgb[y0:y1, x0:x1].astype(np.float32); return float(np.median(px @ np.float32([0.299, 0.587, 0.114]))) if px.size else float("nan")
    for a, b, cheek in ((33, 133, 50), (263, 362, 280)):
        w = float(np.linalg.norm(P(a) - P(b))); r.append(med((P(a) + P(b)) / 2, w * 1.5, w * 0.9) / (med(P(cheek), w * 0.5, w * 0.5) + 1e-6))
    return float(np.nanmean(r))

def eye_embedding(rgb, lm):  # aligned eye-region crop -> image features (kept as numbers, the crop is discarded)
    import cv2
    a = np.array([lm[33].x * rgb.shape[1], lm[33].y * rgb.shape[0]]); b = np.array([lm[263].x * rgb.shape[1], lm[263].y * rgb.shape[0]])
    c = (a + b) / 2; d = float(np.linalg.norm(b - a)) + 1e-6
    A = cv2.getRotationMatrix2D((float(c[0]), float(c[1])), math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])), 160 / d)
    A[0, 2] += 128 - c[0]; A[1, 2] += 56 - c[1]
    crop = np.ascontiguousarray(cv2.warpAffine(rgb, A, (256, 112)))
    return np.array(embedder.embed(mp.Image(image_format=mp.ImageFormat.SRGB, data=crop)).embeddings[0].embedding, np.float32)
gl_mem, gl_stamp = None, None
def glasses(m):  # > 0 looks like the user with glasses, < 0 without; None when it cannot tell
    global gl_mem, gl_stamp
    st = tuple(os.path.getmtime(f) if os.path.exists(f) else 0 for f in GL.values())
    if st != gl_stamp: gl_stamp = st; gl_mem = tuple(np.load(f) for f in GL.values()) if all(st) else None
    if gl_mem is None or "_emb" not in m: return None
    return float((gl_mem[0] @ m["_emb"]).max() - (gl_mem[1] @ m["_emb"]).max())

# ---- judgement ----
sig = lambda z: 1 / (1 + math.exp(-max(-30, min(30, z))))
def rules(m):  # general knowledge: only clearly bad posture scores high
    if not m["face"]: return 0.0, ""
    if m["dist"] > 85: return 0.0, W("far")
    if abs(m["yaw"]) > 40: return 0.0, W("side")   # turned away (second screen, talking to someone): not judged
    c = [(W("roll"), sig((abs(m["roll"]) - 22) / 2))]
    if m["body"]:
        # slouch: ears sink towards the shoulders and the head moves in front of them (typical good: neck .41-.56, fwd .10-.27)
        c += [(W("slouch"), sig((0.40 - m["neck"]) / 0.03 + (m["fwd"] - 0.27) / 0.04)),
              (W("shoulders"), sig((abs(m["shTilt"]) - 16) / 2))]
    why, top = max(c, key=lambda x: x[1]); keep = 1.0
    for _, v in c: keep *= 1 - v
    return 1 - keep, why

KM = ["pitch", "neck", "fwd", "noseY", "shY", "roll"]; SCALE = np.array([6, 0.05, 0.06, 0.06, 0.05, 6]); RADIUS, K = 0.8, 9
mem, mem_stamp = None, None
def load_mem():
    global mem, mem_stamp
    st = os.path.getmtime(EX) if os.path.exists(EX) else 0
    if st == mem_stamp: return
    mem_stamp = st; rows = []
    if st:
        for l in open(EX):
            try: r = json.loads(l)
            except ValueError: continue
            if all(k in r for k in KM): rows.append(([r[k] for k in KM], 1.0 if r["label"] == "bad" else 0.0, r.get("t", 0)))
    mem = (np.array([r[0] for r in rows]), np.array([r[1] for r in rows]), np.array([r[2] for r in rows], float)) if rows else None
def judge(m):
    p, why = rules(m)
    if why in (W("far"), W("side")): m["kind"] = "unjudged"
    if why in (W("far"), W("side")) or not m["face"]: return p, why
    load_mem()
    if mem is not None and all(k in m for k in KM):
        X, y, T = mem; d = np.sqrt((((X - np.array([m[k] for k in KM])) / SCALE) ** 2).mean(1))
        near = np.flatnonzero(d < RADIUS); near = near[np.lexsort((d[near], -T[near]))][:K]  # newest labels first, then closest
        if len(near):
            pm = float(y[near].mean()); p = (len(near) * pm + 2 * p) / (len(near) + 2)
            if pm > 0.5 and p >= 0.5: why = W("examples")
    # glasses: dark lenses never count; otherwise the user's own glasses / no-glasses examples decide
    pg, gk = 0.0, ""
    if os.environ.get("POSTURA_GLASSES", "1") == "0": return p, why   # glasses not required (app setting)
    g = glasses(m)
    # dark lenses read ~0.4; clear glasses against a bright window read ~0.55-0.65, so only clearly dark counts,
    # and never when the eyes look like the user's own taught glasses
    if m.get("shade", 1) < 0.55 and not (g is not None and g > 0.0): pg, gk = sig((0.45 - m["shade"]) / 0.03), "sunglasses"
    if g is not None:
        m["glasses"] = g; q = sig((-0.10 - g) / 0.03)   # only clearly "no glasses" counts
        if q > pg: pg, gk = q, "glasses"
    if pg >= 0.5 and p >= 0.5: p, why, m["kind"] = max(p, pg), f"{why} · {W(gk)}", "both"
    elif pg > p: p, why, m["kind"] = pg, W(gk), gk
    return p, why

# ---- labelling: SUP/train holds "bad" or "good" -> the last 4 s and the next 6 s of measurements become examples ----
recent, forward = collections.deque(maxlen=80), None
def save(label, t, m, src="live"):
    with open(EX, "a") as fh: fh.write(json.dumps({"label": label, "t": round(t, 1), "src": src, **{k: (round(float(v), 4) if isinstance(v, (float, np.floating)) else v) for k, v in m.items() if k[0] != "_"}}, default=float) + "\n")
def learn(t, m):
    global forward
    if os.path.exists(TRAIN):
        label = open(TRAIN).read().split()[0] if os.path.getsize(TRAIN) else ""; os.remove(TRAIN)
        if label in ("gafas", "singafas"):
            E = [mm["_emb"] for tt, mm in recent if tt >= t - 4 and "_emb" in mm][::3]
            if E:
                f = GL["yes" if label == "gafas" else "no"]; np.save(f, np.vstack([np.load(f)] + E) if os.path.exists(f) else np.vstack(E))
        if label in ("bad", "good"):
            for tt, mm in recent:
                if tt >= t - 4 and mm["body"]: save(label, tt, mm)
            forward = (label, t + 6)
    if forward and t > forward[1]: forward = None
    usable = m["face"] and m["body"]
    if forward and usable: save(forward[0], t, m)
    if m["face"]: recent.append((t, dict(m)))   # a copy: the caller pops _emb from m after judging
    return forward[0] if forward else ""

last_tele = 0
def telemetry(t, m):
    global last_tele
    if t - last_tele < 1: return
    last_tele = t
    try:
        if os.path.exists(TELE) and os.path.getsize(TELE) > 8e6: os.replace(TELE, TELE + ".1")
        with open(TELE, "a") as fh: fh.write(json.dumps({"t": round(t, 1), **{k: (round(float(v), 3) if isinstance(v, (float, np.floating)) else v) for k, v in m.items() if k[0] != "_"}}, default=float) + "\n")
    except OSError: pass

def main():
    if OFFLINE:
        import cv2
        cap = cv2.VideoCapture(sys.argv[sys.argv.index("--video") + 1]); fps = cap.get(cv2.CAP_PROP_FPS) or 30; i = 0
        while True:
            ok, b = cap.read()
            if not ok: break
            i += 1
            if i % max(1, round(fps / 5)): continue
            m = measure(np.ascontiguousarray(cv2.resize(b, (640, 480))[:, :, ::-1]), 0)
            m["p"], m["why"] = judge(m); m["t"] = round(i / fps, 2); m.pop("_emb", None)
            print(json.dumps(m, default=float), flush=True)
        return
    inp, t0 = sys.stdin.buffer, time.time()
    while True:
        h = inp.readline()
        if not h: break
        W, H = map(int, h.split()); buf = inp.read(W * H * 4)
        if len(buf) < W * H * 4: break
        rgb = np.ascontiguousarray(np.frombuffer(buf, np.uint8).reshape(H, W, 4)[:, :, [2, 1, 0]])
        try:
            t = time.time(); m = measure(rgb, int((t - t0) * 1000))
            m["training"] = learn(t, m); m["p"], m["why"] = judge(m); telemetry(t, m); m.pop("_emb", None)
            print(json.dumps(m, default=float), flush=True)
        except Exception as e:
            print(json.dumps({"error": str(e)}), flush=True)

if __name__ == "__main__": main()
