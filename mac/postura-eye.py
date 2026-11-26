# postura-eye: posture judge for Postura.app (Google AI Edge MediaPipe Pose + Face Landmarker).
# Reads BGRA frames from stdin ("W H\n" + W*H*4 bytes), prints one JSON line per frame: measurements, p (0..1 bad), why.
# p = general rules for clearly bad posture, overridden by the user's own labelled examples when the current
# measurements are close to them (newest labels win). Stores numbers only, never images.
#   --video FILE   print one row per sampled frame (offline analysis and tests)
import sys, json, math, os, time, tempfile
import numpy as np
import mediapipe as mp

M = os.environ.get("POSTURA_MODELS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "models"))
SUP = os.environ.get("POSTURA_HOME", os.path.expanduser("~/Library/Application Support/Postura"))
EX, TRAIN = f"{SUP}/examples.jsonl", f"{SUP}/train"
TELE = os.environ.get("POSTURA_TELEMETRY", os.path.expanduser("~/Library/Logs/postura-features.jsonl"))
OFFLINE = "--video" in sys.argv
if len(sys.argv) > 1 and not OFFLINE:
    raise SystemExit("Usage: postura-eye.py [--video FILE]")
ES = os.environ.get("POSTURA_LANG", "en") == "es"
TXT = {"far": ("lejos", "far away"), "side": ("de lado", "turned away"), "roll": ("cabeza muy inclinada", "head tilted"),
       "slouch": ("encorvado: cabeza hundida y adelantada", "slouching: head sunk and forward"), "shoulders": ("hombros torcidos", "shoulders tilted"),
       "examples": ("como tus ejemplos de mala postura", "like your bad-posture examples"),
       "glasses": ("sin gafas", "no glasses"), "sunglasses": ("gafas de sol", "sunglasses")}
W = lambda k: TXT[k][0 if ES else 1]
V = mp.tasks.vision
RM = V.RunningMode.VIDEO
pose = V.PoseLandmarker.create_from_options(V.PoseLandmarkerOptions(
    base_options=mp.tasks.BaseOptions(model_asset_path=f"{M}/pose_landmarker_full.task"), running_mode=RM, num_poses=2))
face = V.FaceLandmarker.create_from_options(V.FaceLandmarkerOptions(
    base_options=mp.tasks.BaseOptions(model_asset_path=f"{M}/face_landmarker.task"), running_mode=RM, num_faces=3,
    output_facial_transformation_matrixes=True))
CHECK_GLASSES = os.environ.get("POSTURA_GLASSES") == "1"
GL = {"gafas": f"{SUP}/glasses_yes.npy", "singafas": f"{SUP}/glasses_no.npy"}
embedder = V.ImageEmbedder.create_from_options(V.ImageEmbedderOptions(
    base_options=mp.tasks.BaseOptions(model_asset_path=f"{M}/mobilenet_v3_small.tflite"),
    l2_normalize=True)) if CHECK_GLASSES else None

OWNER_FILE = f"{SUP}/owner-face-sface.npy"
OWNER_MODEL = f"{M}/face_recognition_sface_2021dec_int8.onnx"
OWNER_MIN_SIMILARITY = 0.52
owner_model, owner_refs, owner_stamp = None, None, None

def owner_vector(rgb, lm):
    import cv2
    global owner_model
    if owner_model is None:
        owner_model = cv2.FaceRecognizerSF.create(OWNER_MODEL, "")
    h, w = rgb.shape[:2]
    def point(i):
        return np.array([lm[i].x * w, lm[i].y * h], dtype=np.float32)
    right_eye = (point(33) + point(133)) / 2
    left_eye = (point(263) + point(362)) / 2
    geometry = np.zeros(15, np.float32)
    geometry[4:14] = np.concatenate([right_eye, left_eye, point(1), point(61), point(291)])
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    feature = owner_model.feature(owner_model.alignCrop(bgr, geometry)).reshape(-1)
    return feature / max(float(np.linalg.norm(feature)), 1e-6)

def owner_face(rgb, lm):
    global owner_refs, owner_stamp
    try:
        stamp = os.stat(OWNER_FILE).st_mtime_ns
        if stamp != owner_stamp:
            refs = np.load(OWNER_FILE, allow_pickle=False)
            owner_refs = refs if refs.ndim == 2 and refs.shape[1] == 128 and np.isfinite(refs).all() else None
            owner_stamp = stamp
        if owner_refs is None or not owner_refs.size:
            return None
        if float((owner_refs @ owner_vector(rgb, lm)).max()) < OWNER_MIN_SIMILARITY:
            return None
    except (OSError, ValueError, RuntimeError):
        return None
    jaw = lm[152].y
    forehead = lm[10].y
    height = min(0.78, max(0.24, (jaw - forehead) * 1.50))
    return [float((lm[234].x + lm[454].x) / 2), float((forehead + jaw) / 2), float(height)]

def measure(rgb, ts, preview=False):
    img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
    pr = pose.detect_for_video(img, ts)
    fr = face.detect_for_video(img, ts)
    m = {"face": False, "body": False, "person": bool(pr.pose_landmarks)}
    if fr.face_landmarks:
        eyes = lambda l: math.hypot((l[263].x - l[33].x) * 640, (l[263].y - l[33].y) * 480)
        i = max(range(len(fr.face_landmarks)), key=lambda j: eyes(fr.face_landmarks[j]))  # nearest person = biggest face
        T = np.array(fr.facial_transformation_matrixes[i]); R = T[:3, :3]; lm = fr.face_landmarks[i]
        m["eyePx"] = eyes(lm); m["faces"] = len(fr.face_landmarks)
        if preview and m["faces"] == 1 and len(pr.pose_landmarks) <= 1 and m["eyePx"] >= 52:
            try:
                crop = owner_face(rgb, lm)
                if crop is not None:
                    m["ownerCrop"] = crop
            except Exception:
                # A failed optional recognition pass must never enable video or interrupt posture detection.
                pass
        if CHECK_GLASSES and m["eyePx"] >= 60 and abs(R[2][0]) < 0.5:
            m["_emb"] = eye_embedding(rgb, lm)
            m["shade"] = shade(rgb, lm)
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
    valid = [v for v in r if math.isfinite(v)]
    return sum(valid) / len(valid) if valid else 1.0

def eye_embedding(rgb, lm):  # aligned eye-region crop -> image features (kept as numbers, the crop is discarded)
    import cv2
    a = np.array([lm[33].x * rgb.shape[1], lm[33].y * rgb.shape[0]]); b = np.array([lm[263].x * rgb.shape[1], lm[263].y * rgb.shape[0]])
    c = (a + b) / 2; d = float(np.linalg.norm(b - a)) + 1e-6
    A = cv2.getRotationMatrix2D((float(c[0]), float(c[1])), math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])), 160 / d)
    A[0, 2] += 128 - c[0]; A[1, 2] += 56 - c[1]
    crop = np.ascontiguousarray(cv2.warpAffine(rgb, A, (256, 112)))
    return np.array(embedder.embed(mp.Image(image_format=mp.ImageFormat.SRGB, data=crop)).embeddings[0].embedding, np.float32)
gl_mem, gl_stamp = None, None

def glasses_reference():
    global gl_mem, gl_stamp
    try:
        stamp = tuple(os.stat(f).st_mtime_ns for f in GL.values())
        if stamp != gl_stamp:
            gl_mem = tuple(np.load(f, allow_pickle=False) for f in GL.values())
            gl_stamp = stamp
    except (OSError, ValueError):
        gl_mem, gl_stamp = None, None
    return gl_mem

def glasses_score(m):
    refs = glasses_reference()
    if refs is None or "_emb" not in m:
        return 0.0, ""
    with_glasses, without_glasses = refs
    if any(rows.ndim != 2 or not len(rows) or rows.shape[1] != len(m["_emb"]) for rows in refs):
        return 0.0, ""
    similarity = float((with_glasses @ m["_emb"]).max() - (without_glasses @ m["_emb"]).max())
    if m.get("shade", 1) < 0.55 and similarity <= 0:
        return sig((0.45 - m["shade"]) / 0.03), "sunglasses"
    return sig((-0.10 - similarity) / 0.03), "glasses"

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

# shTilt is part of the match: without it, dropped-shoulder examples also caught upright poses with level shoulders
KM = ["pitch", "neck", "fwd", "noseY", "shY", "roll", "shTilt"]; SCALE = np.array([6, 0.05, 0.06, 0.06, 0.05, 6, 5]); RADIUS, K = 0.8, 9
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
    if why in (W("far"), W("side")):
        m["kind"] = "unjudged"
        m["postureUnjudged"] = "far" if why == W("far") else "side"
        return p, why
    if not m["face"]: return p, why
    load_mem()
    if mem is not None and all(k in m for k in KM):
        X, y, T = mem; d = np.sqrt((((X - np.array([m[k] for k in KM])) / SCALE) ** 2).mean(1))
        near = np.flatnonzero(d < RADIUS); near = near[np.lexsort((-T[near], d[near] // 0.2))][:K]  # closest first; among equally close ones the newest wins
        if len(near):
            pm = float(y[near].mean()); p = (len(near) * pm + 2 * p) / (len(near) + 2)
            if pm > 0.5 and p >= 0.5: why = W("examples")
    if CHECK_GLASSES:
        missing, kind = glasses_score(m)
        m["glassesReady"] = glasses_reference() is not None
        if missing >= .5 and p >= .5:
            m["kind"] = "both"
            return max(p, missing), f"{why} · {W(kind)}"
        if missing > p:
            m["kind"] = kind
            return missing, W(kind)
    return p, why

# A button labels the next six seconds of measurable camera frames.
TRAIN_SECONDS = 6
forward = None

def save_posture(label, t, m):
    row = {"label": label, "t": round(t, 1), "src": "live"}
    row.update({k: v for k, v in m.items() if not k.startswith("_")})
    with open(EX, "a") as fh:
        fh.write(json.dumps(row, default=float) + "\n")

def save_glasses(label, collected):
    if not collected:
        return
    path = GL[label]
    try:
        older = np.load(path, allow_pickle=False)
        if older.ndim == 2 and older.shape[1] == len(collected[0]):
            collected = np.vstack([older, collected])
    except (OSError, ValueError):
        pass
    with tempfile.NamedTemporaryFile(dir=SUP, delete=False) as fh:
        pending = fh.name
        try:
            np.save(fh, np.asarray(collected))
            fh.close()
            os.replace(pending, path)
        finally:
            if os.path.exists(pending):
                os.unlink(pending)

def learn(t, m):
    global forward
    if forward and t >= forward["end"]:
        label = forward["label"]
        if label in GL:
            save_glasses(label, forward["eyes"])
        m["trainingSaved"] = forward["count"]
        m["trainingFinished"] = label
        forward = None
    try:
        pending = TRAIN + ".reading"
        os.replace(TRAIN, pending)
    except FileNotFoundError:
        pass
    else:
        with open(pending) as fh:
            label = fh.read().strip()
        os.unlink(pending)
        if forward is None and (label in ("bad", "good") or (CHECK_GLASSES and label in GL)):
            forward = {"label": label, "end": t + TRAIN_SECONDS, "count": 0, "eyes": []}
    if not forward:
        return
    label = forward["label"]
    if label in GL and "_emb" in m:
        forward["eyes"].append(m["_emb"])
        forward["count"] += 1
    elif label in ("good", "bad") and m["face"] and m["body"] and m["dist"] <= 85 and abs(m["yaw"]) <= 40:
        save_posture(label, t, m)
        forward["count"] += 1
    m["training"] = label
    m["trainingRemaining"] = round(forward["end"] - t, 2)


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
        cap = cv2.VideoCapture(sys.argv[sys.argv.index("--video") + 1])
        if not cap.isOpened():
            raise SystemExit("Could not open video")
        fps, i = cap.get(cv2.CAP_PROP_FPS) or 30, 0
        while True:
            ok, b = cap.read()
            if not ok: break
            seconds = i / fps
            i += 1
            if (i - 1) % max(1, round(fps / 5)): continue
            m = measure(cv2.cvtColor(cv2.resize(b, (640, 480)), cv2.COLOR_BGR2RGB), round(seconds * 1000))
            m["p"], m["why"] = judge(m); m["t"] = round(seconds, 3)
            m.pop("_emb", None)
            print(json.dumps(m, default=float, allow_nan=False), flush=True)
        return
    inp, t0 = sys.stdin.buffer, time.monotonic()
    while True:
        h = inp.readline()
        if not h: break
        fields = h.split()
        W, H = map(int, fields[:2]); buf = inp.read(W * H * 4)
        preview = len(fields) == 3 and fields[2] == b"owner"
        if len(buf) < W * H * 4: break
        rgb = np.ascontiguousarray(np.frombuffer(buf, np.uint8).reshape(H, W, 4)[:, :, [2, 1, 0]])
        try:
            t = time.time(); m = measure(rgb, int((time.monotonic() - t0) * 1000), preview)
            learn(t, m); m["p"], m["why"] = judge(m); telemetry(t, m)
            m.pop("_emb", None)
            print(json.dumps(m, default=float, allow_nan=False), flush=True)
        except Exception as e:
            print(json.dumps({"error": str(e)}), flush=True)

if __name__ == "__main__": main()
