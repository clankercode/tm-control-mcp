namespace TmMcp {
    // Pure helpers for AnimateEditorCamera / WaitEditorCamera: no game types
    // and no Math:: calls, so tests/test_editor_camera_anim.py runs them in
    // stock AngelScript. The game side is EditorCameraAnim.as.

    const float CAM_PI = 3.14159265358979;
    const float CAM_TAU = 6.28318530717959;
    const int CAM_WAIT_MAX_MS = 300000;          // WaitEditorCamera hard cap (5 min)
    const int CAM_WAIT_UNBOUNDED_MS = 20000;     // default wait on a never-ending animation
    const int CAM_WAIT_SLACK_MS = 2000;          // default wait = remaining time + slack
    const int CAM_ANIM_MAX_MS = 3600000;         // longest finite animation (1 h)

    float CamClamp01(float t) {
        return t < 0.0 ? 0.0 : (t > 1.0 ? 1.0 : t);
    }

    bool CamEaseKnown(const string &in name) {
        return name == "linear" || name == "in" || name == "out" || name == "inOut";
    }

    // Progress curve over the whole animation: inOut (default) starts and
    // ends at rest, in/out ease one end, linear is constant speed.
    float CamEase(const string &in name, float t) {
        t = CamClamp01(t);
        if (name == "linear") return t;
        if (name == "in") return t * t;
        if (name == "out") return 1.0 - (1.0 - t) * (1.0 - t);
        return t * t * (3.0 - 2.0 * t);
    }

    float CamFloor(float x) {
        int i = int(x);
        if (float(i) > x) i--;
        return float(i);
    }

    // Wrap into (-PI, PI].
    float CamWrapAngle(float a) {
        float w = a - CAM_TAU * CamFloor((a + CAM_PI) / CAM_TAU);
        if (w <= -CAM_PI) w += CAM_TAU;
        return w;
    }

    // The equivalent of `a` closest to `ref`, so interpolating ref -> result
    // takes the short way round.
    float CamUnwrapNear(float a, float ref) {
        return ref + CamWrapAngle(a - ref);
    }

    float CamAngleDelta(float a, float b) {
        float d = CamWrapAngle(a - b);
        return d < 0.0 ? -d : d;
    }

    // Uniform Catmull-Rom through p1 (t=0) and p2 (t=1).
    float CamCatmullRom(float p0, float p1, float p2, float p3, float t) {
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.5 * (2.0 * p1 + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
                      + (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3);
    }

    // Value of a keyframed channel inside segment seg (key seg -> seg+1) at
    // local t. The end keys are repeated as their own neighbours, so the
    // curve passes through every key and never overshoots past the ends.
    float CamSampleChannel(const array<float> &in keys, uint seg, float t, bool spline) {
        uint n = keys.Length;
        if (n == 0) return 0.0;
        if (n == 1 || seg + 1 >= n) return keys[n - 1];
        float p1 = keys[seg];
        float p2 = keys[seg + 1];
        if (!spline) return p1 + (p2 - p1) * t;
        float p0 = seg > 0 ? keys[seg - 1] : p1;
        float p3 = seg + 2 < n ? keys[seg + 2] : p2;
        return CamCatmullRom(p0, p1, p2, p3, t);
    }

    // Segment and local t for path time timeMs. segMs[i] is the duration of
    // segment i (key i -> key i+1). Returns false once past the end (seg and
    // t then name the final key).
    bool CamPathLocate(const array<int> &in segMs, float timeMs, uint &out seg, float &out t) {
        seg = 0;
        t = 1.0;
        if (segMs.Length == 0) return false;
        float acc = 0.0;
        for (uint i = 0; i < segMs.Length; i++) {
            float len = float(segMs[i]);
            if (timeMs < acc + len) {
                seg = i;
                t = len > 0.0 ? CamClamp01((timeMs - acc) / len) : 1.0;
                return true;
            }
            acc += len;
        }
        seg = segMs.Length - 1;
        t = 1.0;
        return false;
    }

    int CamPathTotalMs(const array<int> &in segMs) {
        int total = 0;
        for (uint i = 0; i < segMs.Length; i++) total += segMs[i];
        return total;
    }

    // Unwrap a channel of angles in place so each key is within PI of the
    // previous one: every segment turns the short way.
    void CamUnwrapChannel(array<float> &inout angles) {
        for (uint i = 1; i < angles.Length; i++) angles[i] = CamUnwrapNear(angles[i], angles[i - 1]);
    }

    // Split a path's total duration over its segments in proportion to their
    // weights (e.g. travel distance), so speed is even along the path. Each
    // segment gets at least 1 ms when weights are all zero.
    array<int> CamSplitDuration(int totalMs, const array<float> &in weights) {
        array<int> result;
        float sum = 0.0;
        for (uint i = 0; i < weights.Length; i++) sum += weights[i] > 0.0 ? weights[i] : 0.0;
        int used = 0;
        for (uint i = 0; i < weights.Length; i++) {
            int ms;
            if (i + 1 == weights.Length) ms = totalMs - used;
            else if (sum <= 0.0) ms = totalMs / int(weights.Length);
            else ms = int(float(totalMs) * (weights[i] > 0.0 ? weights[i] : 0.0) / sum);
            if (ms < 0) ms = 0;
            result.InsertLast(ms);
            used += ms;
        }
        return result;
    }

    // Something other than the animation moved the camera: compare what the
    // animation wrote last frame with what the editor reports now. Returns
    // the moved channel ("target", "distance", "angle") or "".
    string CamDriftReason(float wx, float wy, float wz, float wDist, float wH, float wV,
                          float rx, float ry, float rz, float rDist, float rH, float rV,
                          float tolPos, float tolAngle) {
        float dx = wx - rx, dy = wy - ry, dz = wz - rz;
        if (dx * dx + dy * dy + dz * dz > tolPos * tolPos) return "target";
        float dd = wDist - rDist;
        if (dd > tolPos || dd < -tolPos) return "distance";
        if (CamAngleDelta(wH, rH) > tolAngle || CamAngleDelta(wV, rV) > tolAngle) return "angle";
        return "";
    }

    // WaitEditorCamera timeout: an explicit timeoutMs is clamped to
    // 0..CAM_WAIT_MAX_MS; otherwise wait out a finite animation (plus
    // slack) and give an unbounded one CAM_WAIT_UNBOUNDED_MS.
    int CamWaitTimeoutMs(bool hasRequested, int requested, bool bounded, int remainingMs) {
        int ms;
        if (hasRequested) ms = requested;
        else if (bounded) ms = (remainingMs < 0 ? 0 : remainingMs) + CAM_WAIT_SLACK_MS;
        else ms = CAM_WAIT_UNBOUNDED_MS;
        if (ms < 0) return 0;
        return ms > CAM_WAIT_MAX_MS ? CAM_WAIT_MAX_MS : ms;
    }

    // A finished animation's state, for WaitEditorCamera: only "completed" is
    // success; stopped/interrupted/failed are errors carrying the reason.
    bool CamAnimStateOk(const string &in state) {
        return state == "completed";
    }

    bool CamAnimStateFinal(const string &in state) {
        return state == "completed" || state == "stopped" || state == "interrupted" || state == "failed";
    }
}
