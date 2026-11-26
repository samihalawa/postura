"""On-device visibility model. Its teaching data consists of geometry and timing only."""
import json
import math
import os
from statistics import median
from collections import deque

# Labeled scale exemplars, expressed as fractions of the frame width.
# Face width and shoulder span have separate calibrations.
DISTANCE_EXAMPLES = {
    "face": {"background": (0.04, 0.07), "nearby": (0.09, 0.12), "close": (0.15, 0.20)},
    "torso": {"background": (0.09, 0.15), "nearby": (0.20, 0.26), "close": (0.32, 0.40)},
    "box": {"background": (0.08, 0.16), "nearby": (0.24, 0.34), "close": (0.41, 0.65)},
}
# Labeled durations of continuous attention and stillness, in seconds.
BEHAVIOR_EXAMPLES = {"gaze": (0.2, 1.2), "still": (0.35, 2.0)}
# Timing tolerance for intermittent landmark misses, independent of the learned decision.
DROPOUT = 0.65
NEARBY_STABILITY = 0.45
FEATURES = ("scale", "facing", "gaze", "still")
FEATURE_SCALES = (0.11, 0.35, 1.2, 1.8)


def people_from_landmarks(faces, matrices, poses, aspect):
    people = []
    for lm, matrix in zip(faces, matrices):
        width = math.hypot(lm[454].x - lm[234].x, (lm[454].y - lm[234].y) / aspect)
        yaw = math.asin(max(-1, min(1, -matrix[2][0])))
        pitch = math.atan2(matrix[2][1], matrix[2][2])
        people.append(dict(face=width, x=lm[1].x, y=lm[1].y,
                           facing=max(0, math.cos(yaw) * math.cos(pitch)) ** 8))
    matched = set()
    for lm in poses:
        a, b = lm[11], lm[12]
        if min(a.visibility, b.visibility) < 0.4:
            continue
        span = math.hypot(a.x - b.x, (a.y - b.y) / aspect)
        x, y = (a.x + b.x) / 2, (a.y + b.y) / 2
        nose = lm[0]
        nearest = min((i for i in range(len(faces)) if i not in matched),
                      key=lambda i: math.hypot(nose.x - people[i]["x"], nose.y - people[i]["y"]),
                      default=None)
        if nearest is not None and math.hypot(nose.x - people[nearest]["x"], nose.y - people[nearest]["y"]) < span / 2:
            people[nearest].update(torso=span)
            matched.add(nearest)
        else:
            people.append(dict(torso=span, x=x, y=y, facing=0))
    return people


class Privacy:
    def __init__(self, directory):
        self.path = os.path.join(directory, "privacy-examples.jsonl")
        self.stamp = None
        self.rows = []
        self.bounds = {}
        self.tracks = []
        self.recent = deque()
        self.camera_time = -math.inf
        self.last_qualified = (-math.inf, "clear")
        self.reload()

    def reload(self):
        try:
            stamp = os.stat(self.path).st_mtime_ns
        except FileNotFoundError:
            stamp = 0
        if stamp == self.stamp:
            return
        rows = []
        if stamp:
            with open(self.path) as file:
                for line in file:
                    try:
                        row = json.loads(line)
                        if (row.get("label") in ("hide", "reveal", "background", "nearby", "close")
                                and row.get("channel") in DISTANCE_EXAMPLES
                                and all(math.isfinite(row[k]) for k in FEATURES)):
                            rows.append(row)
                    except (ValueError, TypeError, KeyError, AttributeError):
                        continue
        self.stamp, self.rows = stamp, rows[-2000:]
        for channel, bands in DISTANCE_EXAMPLES.items():
            means = []
            for band, seeds in bands.items():
                data = [r["scale"] for r in self.rows if r["channel"] == channel and r["label"] == band][-100:]
                group = data or seeds
                means.append(median(group))
            if means != sorted(means) or len(set(means)) != 3:
                means = [sum(seeds) / len(seeds) for seeds in bands.values()]
            far, near, close = means
            self.bounds[channel] = ((far + near) / 2, (near + close) / 2)

    def geometry(self, people, now):
        self.tracks = [track for track in self.tracks if now - track["at"] <= DROPOUT]
        candidates = []
        available = list(self.tracks)
        for person in people:
            channels = [channel for channel in DISTANCE_EXAMPLES if channel in person]
            # Prefer a close face, then a close torso. A sideways face looks smaller
            # while the shoulders still supply proximity evidence.
            channel = next((c for c in channels if person[c] >= self.bounds[c][1]), channels[0])
            scale = person[channel]
            point = (person["x"], person["y"])
            track = min(available, key=lambda t: math.dist(t["point"], point), default=None)
            gaze, still = 0.0, 0.0
            if track is not None and math.dist(track["point"], point) <= max(scale, track["scale"]):
                available.remove(track)
                self.tracks.remove(track)
                elapsed = now - track["at"]
                if person["facing"] >= 0.55 and track["facing"] >= 0.55:
                    gaze = min(3, track["gaze"] + elapsed)
                if math.dist(track["point"], point) <= 0.15 * scale:
                    still = min(3, track["still"] + elapsed)
            row = dict(point=point, at=now, channel=channel, scale=scale,
                       facing=person["facing"], gaze=gaze, still=still)
            self.tracks.append(row)
            candidates.append({k: row[k] for k in (*FEATURES, "channel")})
        return candidates

    def decide(self, candidates):
        eligible = []
        for row in candidates:
            far, close = self.bounds[row["channel"]]
            if row["scale"] < far:
                continue
            if row["scale"] >= close:
                reason = "close"
            elif row["gaze"] >= sum(BEHAVIOR_EXAMPLES["gaze"]) / 2:
                reason = "gaze"
            elif row["still"] >= sum(BEHAVIOR_EXAMPLES["still"]) / 2:
                reason = "still"
            else:
                reason = "clear"

            # A correction applies only to similar observations of a nearby person.
            # A recent explicit label wins when corrections have comparable distances.
            def distance(example):
                return math.sqrt(sum(((row[k] - example[k]) / scale) ** 2
                                     for k, scale in zip(FEATURES, FEATURE_SCALES)) / len(FEATURES))

            matches = ((distance(ex), i, ex["label"]) for i, ex in enumerate(self.rows)
                       if ex["channel"] == row["channel"] and ex["label"] in ("hide", "reveal"))
            match = min((item for item in matches if item[0] <= 0.45),
                        key=lambda item: (int(item[0] * 10), -item[1]), default=None)
            if match:
                reason = "learned" if match[2] == "hide" else "corrected"
            eligible.append((reason, row))
        return eligible

    def close_geometry(self, people):
        return any(value >= self.bounds[channel][1]
                   for person in people for channel, value in person.items() if channel in self.bounds)

    def update(self, people, now):
        self.camera_time = now
        if not people:
            self.tracks.clear()
            self.recent.clear()
            self.last_qualified = (-math.inf, "clear")
            return {"hide": False, "reason": "empty", "candidates": []}
        candidates = self.geometry(people, now)
        decisions = self.decide(candidates)
        if decisions:
            self.recent.append((now, decisions))
        else:
            self.recent.clear()
        while self.recent and self.recent[0][0] < now - 0.85:
            self.recent.popleft()
        reason = next((r for r, _ in decisions if r not in ("clear", "corrected")), "clear")
        if reason != "clear":
            self.last_qualified = (now, reason)
        elif (len(decisions) == 1 and decisions[0][0] == "clear"
              and now - self.last_qualified[0] <= NEARBY_STABILITY):
            # Damp borderline changes only while one person is still measured
            # nearby. Empty, distant-only, and corrected frames clear normally.
            reason = self.last_qualified[1]
        else:
            self.last_qualified = (-math.inf, "clear")
        return {"hide": reason != "clear", "reason": reason, "candidates": candidates}

    def save(self, label, rows):
        if not rows:
            return 0
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "a") as file:
            file.write("".join(json.dumps({**row, "label": label}, allow_nan=False) + "\n" for row in rows))
        return len(rows)

    def teach(self, label):
        # Only teach a scene with one eligible person. Avoid applying one correction
        # to every person in a group or to an empty or stale frame.
        if not self.recent or self.camera_time - self.recent[-1][0] > 0.45:
            return 0
        if any(len(decisions) != 1 for _, decisions in self.recent):
            return 0
        return self.save(label, [decisions[0][1] for _, decisions in self.recent])
