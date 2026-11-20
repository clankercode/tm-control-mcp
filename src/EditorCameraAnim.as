namespace TmMcp {
    // Smooth editor camera animations: a keyframed path, an orbit around a
    // point, or following the editor cursor / a moving point. One animation
    // runs at a time; a per-frame coroutine writes the same orbital camera
    // fields SetEditorCamera writes. It ends as:
    //   completed   - a finite animation reached its end
    //   stopped     - AnimateEditorCamera {action:"stop"}
    //   interrupted - another camera tool (CameraAnimInterrupt), a new
    //                 animation, the camera moved by something else (mouse,
    //                 another plugin), or the editor left edit mode
    //   failed      - the editor went away / an exception
    // WaitEditorCamera waits for that end; only "completed" is success.
    // Pure maths and rules: EditorCameraAnimPolicy.as.

    const float CAM_DRIFT_TOL_POS = 0.05;     // meters (writes read back exactly)
    const float CAM_DRIFT_TOL_ANGLE = 0.002;  // radians
    const uint CAM_ANIM_HISTORY = 16;
    const uint CAM_PATH_MAX_KEYS = 64;

    class CameraAnim {
        uint id;
        string kind;
        string state = "running";
        string reason;
        string interruptedBy;
        uint64 startedAt;
        uint64 endedAt = 0;
        int durationMs = -1;      // -1: runs until stopped or interrupted
        string ease = "inOut";
        CGameCtnEditorFree@ editor;
        float vMin = 0.0785398;
        float vMax = 1.49226;
        array<string> warnings;

        // Blend from the camera as it was at start into the animation.
        int blendMs = 0;
        bool blendSeeded = false;
        vec3 s0Target;
        float s0Dist, s0H, s0V;

        // path: one channel per orbital value, h unwrapped.
        array<float> kx, ky, kz, kd, kh, kv;
        array<int> segMs;
        bool spline = true;

        // orbit
        vec3 center;
        float oH0, oDeg, oRate, oD0, oD1, oV0, oV1;

        // follow
        string follow;            // "cursor" | "point"
        vec3 goal;
        vec3 cur;
        float fDist, fH, fV, lagMs, spin;
        uint64 lastTick = 0;

        // last write, for drift detection
        bool hasWritten = false;
        vec3 wT;
        float wD, wH, wV;
        uint frames = 0;
    }

    array<CameraAnim@> g_camAnims;    // newest last, capped at CAM_ANIM_HISTORY
    CameraAnim@ g_camAnimActive;
    uint g_camAnimNextId = 1;
    bool g_camAnimLoopRunning = false;

    CameraAnim@ CameraAnimFind(uint id) {
        for (int i = int(g_camAnims.Length) - 1; i >= 0; i--) {
            if (g_camAnims[i].id == id) return g_camAnims[i];
        }
        return null;
    }

    void CameraAnimEnd(CameraAnim@ a, const string &in state, const string &in reason, const string &in by = "") {
        if (a is null || a.state != "running") return;
        a.state = state;
        a.reason = reason;
        a.interruptedBy = by;
        a.endedAt = Time::Now;
        @a.editor = null;
        if (g_camAnimActive is a) @g_camAnimActive = null;
    }

    // Called by every tool that moves the editor camera, before it moves it.
    void CameraAnimInterrupt(const string &in by) {
        if (g_camAnimActive is null) return;
        CameraAnimEnd(g_camAnimActive, "interrupted", "interrupted by " + by, by);
    }

    Json::Value CameraAnimToJson(CameraAnim@ a) {
        Json::Value o = Json::Object();
        o["id"] = int(a.id);
        o["kind"] = a.kind;
        o["state"] = a.state;
        uint64 end = a.endedAt > 0 ? a.endedAt : Time::Now;
        o["elapsedMs"] = int(end - a.startedAt);
        if (a.durationMs >= 0) {
            o["durationMs"] = a.durationMs;
            o["progress"] = a.durationMs > 0 ? CamClamp01(float(end - a.startedAt) / float(a.durationMs)) : 1.0;
        } else {
            o["untilStopped"] = true;
        }
        o["frames"] = int(a.frames);
        if (a.reason.Length > 0) o["reason"] = a.reason;
        if (a.interruptedBy.Length > 0) o["interruptedBy"] = a.interruptedBy;
        if (a.warnings.Length > 0) {
            Json::Value w = Json::Array();
            for (uint i = 0; i < a.warnings.Length; i++) w.Add(a.warnings[i]);
            o["warnings"] = w;
        }
        return o;
    }

    // ---- input helpers ----

    bool CamReadVec3(Json::Value@ v, vec3 &out result) {
        result = vec3();
        if (v is null || v.GetType() != Json::Type::Object) return false;
        if (!v.HasKey("x") || !v.HasKey("y") || !v.HasKey("z")) return false;
        if (v["x"].GetType() != Json::Type::Number || v["y"].GetType() != Json::Type::Number || v["z"].GetType() != Json::Type::Number) return false;
        result = vec3(float(v["x"]), float(v["y"]), float(v["z"]));
        return true;
    }

    float CamNum(Json::Value@ v, const string &in key, float fallback) {
        if (v is null || !v.HasKey(key) || v[key].GetType() != Json::Type::Number) return fallback;
        return float(v[key]);
    }

    // Camera world position for an orbital state (CameraMaths.md).
    vec3 CamOrbitalPos(const vec3 &in target, float dist, float h, float v) {
        vec3 look = vec3(Math::Cos(v) * Math::Sin(h), -Math::Sin(v), Math::Cos(v) * Math::Cos(h));
        return target - look * dist;
    }

    float CamClampV(CameraAnim@ a, float v, const string &in what) {
        if (v >= a.vMin && v <= a.vMax) return v;
        string w = what + " vAngle " + int(Math::Round(Math::ToDeg(v))) + "deg is outside the editor's "
            + Text::Format("%.1f", Math::ToDeg(a.vMin)) + ".." + Text::Format("%.1f", Math::ToDeg(a.vMax)) + "deg range; clamped";
        if (a.warnings.Find(w) < 0 && a.warnings.Length < 8) a.warnings.InsertLast(w);
        return Math::Clamp(v, a.vMin, a.vMax);
    }

    // Running keyframe values: each key starts from the previous one.
    class CamKey {
        vec3 t;
        float d, h, v;
    }

    // Parse one path keyframe on top of the previous key's values (in key).
    // Returns "" or an error.
    string CamParseKey(CameraAnim@ a, Json::Value@ k, uint index, CamKey@ key) {
        if (k is null || k.GetType() != Json::Type::Object) return "keyframes[" + index + "] must be an object";
        bool hasPos = k.HasKey("position"), hasLook = k.HasKey("lookAt");
        if (hasPos || hasLook) {
            vec3 pos, look;
            if (!CamReadVec3(k["position"], pos) || !CamReadVec3(k["lookAt"], look))
                return "keyframes[" + index + "]: position and lookAt go together, each {x,y,z}";
            if (k.HasKey("x") || k.HasKey("distance") || k.HasKey("hAngle") || k.HasKey("vAngle"))
                return "keyframes[" + index + "]: use either position+lookAt or x,y,z/distance/hAngle/vAngle, not both";
            vec3 dir = look - pos;
            if (dir.Length() < 0.5) return "keyframes[" + index + "]: position and lookAt must be at least 0.5 m apart";
            vec2 ang = LookDirToOrbitalAngles(dir);
            key.t = look;
            key.d = dir.Length();
            key.h = ang.x;
            key.v = CamClampV(a, ang.y, "keyframes[" + index + "]");
            return "";
        }
        bool anyXyz = k.HasKey("x") || k.HasKey("y") || k.HasKey("z");
        if (anyXyz) {
            vec3 p;
            if (!CamReadVec3(k, p)) return "keyframes[" + index + "]: x, y, z go together (the point the camera looks at)";
            key.t = p;
        }
        if (k.HasKey("distance")) {
            key.d = CamNum(k, "distance", key.d);
            if (key.d < 0.5) return "keyframes[" + index + "]: distance must be >= 0.5";
        }
        if (k.HasKey("hAngle")) key.h = Math::ToRad(CamNum(k, "hAngle", 0.0));
        if (k.HasKey("vAngle")) key.v = CamClampV(a, Math::ToRad(CamNum(k, "vAngle", 0.0)), "keyframes[" + index + "]");
        return "";
    }

    // ---- per-frame evaluation ----

    // Desired camera at elapsed ms (h continuous, v unclamped for orbit/
    // follow until the final clamp).
    void CamDesired(CameraAnim@ a, float tMs, float dtMs, vec3 &out target, float &out dist, float &out h, float &out v) {
        target = vec3(); dist = 0; h = 0; v = 0;
        if (a.kind == "path") {
            float total = float(a.durationMs);
            float p = total > 0.0 ? CamEase(a.ease, tMs / total) * total : total;
            uint seg; float lt;
            CamPathLocate(a.segMs, p, seg, lt);
            target = vec3(CamSampleChannel(a.kx, seg, lt, a.spline), CamSampleChannel(a.ky, seg, lt, a.spline), CamSampleChannel(a.kz, seg, lt, a.spline));
            dist = Math::Max(0.5, CamSampleChannel(a.kd, seg, lt, a.spline));
            h = CamSampleChannel(a.kh, seg, lt, a.spline);
            v = CamSampleChannel(a.kv, seg, lt, a.spline);
        } else if (a.kind == "orbit") {
            target = a.center;
            if (a.durationMs < 0) {
                h = a.oH0 + Math::ToRad(a.oRate) * tMs / 1000.0;
                dist = a.oD0;
                v = a.oV0;
            } else {
                float p = a.durationMs > 0 ? CamEase(a.ease, tMs / float(a.durationMs)) : 1.0;
                h = a.oH0 + Math::ToRad(a.oDeg) * p;
                dist = a.oD0 + (a.oD1 - a.oD0) * p;
                v = a.oV0 + (a.oV1 - a.oV0) * p;
            }
        } else {
            if (a.follow == "cursor" && a.editor !is null && a.editor.PluginMapType !is null) {
                nat3 c = a.editor.PluginMapType.CursorCoord;
                a.goal = vec3(float(c.x) * 32.0 + 16.0, (float(c.y) - 8.0) * 8.0 + 4.0, float(c.z) * 32.0 + 16.0);
            }
            float k = a.lagMs <= 0.0 ? 1.0 : 1.0 - Math::Exp(-dtMs / a.lagMs);
            a.cur = a.cur + (a.goal - a.cur) * k;
            target = a.cur;
            dist = a.fDist;
            h = a.fH + Math::ToRad(a.spin) * tMs / 1000.0;
            v = a.fV;
        }
    }

    void CamWrite(CameraAnim@ a, const vec3 &in target, float dist, float h, float v) {
        auto pmt = a.editor.PluginMapType;
        pmt.CameraTargetPosition = target;
        pmt.CameraToTargetDistance = dist;
        pmt.CameraHAngle = h;
        pmt.CameraVAngle = v;
        if (a.editor.OrbitalCameraControl !is null) {
            a.editor.OrbitalCameraControl.m_TargetedPosition = target;
            a.editor.OrbitalCameraControl.m_CameraToTargetDistance = dist;
        }
        a.hasWritten = true;
        a.wT = target; a.wD = dist; a.wH = CamWrapAngle(h); a.wV = v;
        a.frames++;
    }

    // One frame. Returns false once the animation has ended.
    bool CameraAnimTick(CameraAnim@ a) {
        if (a.state != "running") return false;
        auto editor = GetEditor();
        if (editor is null || editor !is a.editor || editor.PluginMapType is null) {
            CameraAnimEnd(a, "interrupted", "the map editor closed or changed", "editor");
            return false;
        }
        string block = EditorCameraBlockReason(EditorCameraMode(editor));
        if (block.Length > 0) {
            CameraAnimEnd(a, "interrupted", "left edit mode: " + block, "mode");
            return false;
        }
        auto pmt = editor.PluginMapType;
        if (a.hasWritten) {
            vec3 rt = pmt.CameraTargetPosition;
            string drift = CamDriftReason(a.wT.x, a.wT.y, a.wT.z, a.wD, a.wH, a.wV,
                                          rt.x, rt.y, rt.z, pmt.CameraToTargetDistance, pmt.CameraHAngle, pmt.CameraVAngle,
                                          CAM_DRIFT_TOL_POS, CAM_DRIFT_TOL_ANGLE);
            if (drift.Length > 0) {
                CameraAnimEnd(a, "interrupted", "the camera was moved by something else (" + drift
                              + " changed: mouse/keyboard input, another plugin, or an editor camera action)", "external");
                return false;
            }
        }
        uint64 now = Time::Now;
        float dtMs = a.lastTick == 0 ? 16.0 : Math::Min(200.0, float(now - a.lastTick));
        a.lastTick = now;
        float tMs = float(now - a.startedAt);
        bool done = a.durationMs >= 0 && tMs >= float(a.durationMs);
        if (done) tMs = float(a.durationMs);

        vec3 target; float dist, h, v;
        CamDesired(a, tMs, dtMs, target, dist, h, v);
        if (a.blendMs > 0) {
            if (!a.blendSeeded) {
                a.s0H = CamUnwrapNear(a.s0H, h);
                a.blendSeeded = true;
            }
            if (tMs < float(a.blendMs) && !done) {
                float w = CamEase("inOut", tMs / float(a.blendMs));
                target = a.s0Target + (target - a.s0Target) * w;
                dist = a.s0Dist + (dist - a.s0Dist) * w;
                h = a.s0H + (h - a.s0H) * w;
                v = a.s0V + (v - a.s0V) * w;
            }
        }
        v = Math::Clamp(v, a.vMin, a.vMax);
        CamWrite(a, target, dist, h, v);
        if (done) {
            CameraAnimEnd(a, "completed", "");
            return false;
        }
        return true;
    }

    void CameraAnimLoop() {
        while (g_camAnimActive !is null) {
            auto a = g_camAnimActive;
            try {
                CameraAnimTick(a);
            } catch {
                CameraAnimEnd(a, "failed", "camera write failed: " + getExceptionInfo());
            }
            if (g_camAnimActive is null) break;
            yield();
        }
        g_camAnimLoopRunning = false;
    }

    // ---- tool entry points ----

    Json::Value@ CameraAnimBadInput(const string &in msg) {
        return MakeError(msg, "INVALID_INPUT", false, "",
            "See the AnimateEditorCamera description; e.g. {kind:'orbit', degrees:360, durationMs:12000} or {kind:'path', keyframes:[{x,y,z,distance,hAngle,vAngle}, ...], durationMs:6000}");
    }

    Json::Value@ AnimateEditorCamera(Json::Value &in input) {
        string action = input.HasKey("action") ? string(input["action"]) : "start";
        if (action == "status") {
            auto output = Json::Object();
            output["running"] = g_camAnimActive !is null;
            if (g_camAnimActive !is null) output["active"] = CameraAnimToJson(g_camAnimActive);
            if (g_camAnims.Length > 0) output["latest"] = CameraAnimToJson(g_camAnims[g_camAnims.Length - 1]);
            return MakeSuccess(output);
        }
        if (action == "stop") {
            auto output = Json::Object();
            output["stopped"] = g_camAnimActive !is null;
            if (g_camAnimActive !is null) {
                auto a = g_camAnimActive;
                CameraAnimEnd(a, "stopped", "stopped by AnimateEditorCamera {action:'stop'}", "stop");
                output["animation"] = CameraAnimToJson(a);
            }
            return MakeSuccess(output);
        }
        if (action == "retarget") {
            auto a = g_camAnimActive;
            if (a is null || a.kind != "follow" || a.follow != "point")
                return MakeError("retarget needs a running follow:'point' animation", "NOT_FOUND");
            vec3 p;
            if (!CamReadVec3(input, p)) return CameraAnimBadInput("retarget needs x, y, z");
            a.goal = p;
            auto output = CameraAnimToJson(a);
            output["goal"] = Vec3ToJson(p);
            return MakeSuccess(output);
        }
        if (action != "start") return CameraAnimBadInput("action must be start, stop, status or retarget");

        auto editor = GetEditor();
        if (editor is null || editor.PluginMapType is null) return MakeError("editor not available", "NOT_IN_EDITOR", true, "Editor");
        auto modeError = EditorCameraModeError(editor);
        if (modeError !is null) return modeError;
        auto pmt = editor.PluginMapType;

        string kind = input.HasKey("kind") ? string(input["kind"]) : "";
        auto a = CameraAnim();
        a.kind = kind;
        @a.editor = editor;
        if (editor.OrbitalCameraControl !is null) {
            a.vMin = editor.OrbitalCameraControl.m_MinVAngle;
            a.vMax = editor.OrbitalCameraControl.m_MaxVAngle;
        }
        a.ease = input.HasKey("ease") ? string(input["ease"]) : (kind == "follow" ? "linear" : "inOut");
        if (!CamEaseKnown(a.ease)) return CameraAnimBadInput("ease must be linear, in, out or inOut");
        a.s0Target = pmt.CameraTargetPosition;
        a.s0Dist = pmt.CameraToTargetDistance;
        a.s0H = pmt.CameraHAngle;
        a.s0V = pmt.CameraVAngle;
        int durationIn = input.HasKey("durationMs") ? int(input["durationMs"]) : -1;
        if (input.HasKey("durationMs") && (durationIn < 0 || durationIn > CAM_ANIM_MAX_MS))
            return CameraAnimBadInput("durationMs must be 0.." + CAM_ANIM_MAX_MS);

        if (kind == "path") {
            if (!input.HasKey("keyframes") || input["keyframes"].GetType() != Json::Type::Array || input["keyframes"].Length == 0)
                return CameraAnimBadInput("path needs keyframes: a non-empty array");
            auto keys = input["keyframes"];
            if (keys.Length > CAM_PATH_MAX_KEYS) return CameraAnimBadInput("at most " + CAM_PATH_MAX_KEYS + " keyframes");
            bool fromCurrent = input.HasKey("fromCurrent") ? bool(input["fromCurrent"]) : true;
            a.spline = input.HasKey("spline") ? bool(input["spline"]) : true;
            auto key = CamKey();
            key.t = a.s0Target; key.d = a.s0Dist; key.h = a.s0H; key.v = Math::Clamp(a.s0V, a.vMin, a.vMax);
            if (fromCurrent) {
                a.kx.InsertLast(key.t.x); a.ky.InsertLast(key.t.y); a.kz.InsertLast(key.t.z);
                a.kd.InsertLast(key.d); a.kh.InsertLast(key.h); a.kv.InsertLast(key.v);
            }
            uint withMs = 0;
            array<int> keyMs;
            for (uint i = 0; i < keys.Length; i++) {
                string err = CamParseKey(a, keys[i], i, key);
                if (err.Length > 0) return CameraAnimBadInput(err);
                a.kx.InsertLast(key.t.x); a.ky.InsertLast(key.t.y); a.kz.InsertLast(key.t.z);
                a.kd.InsertLast(key.d); a.kh.InsertLast(key.h); a.kv.InsertLast(key.v);
                int ms = -1;
                if (keys[i].HasKey("ms")) {
                    ms = int(keys[i]["ms"]);
                    if (ms < 0 || ms > CAM_ANIM_MAX_MS) return CameraAnimBadInput("keyframes[" + i + "].ms must be 0.." + CAM_ANIM_MAX_MS);
                    withMs++;
                }
                keyMs.InsertLast(ms);
            }
            CamUnwrapChannel(a.kh);
            uint segs = a.kx.Length - 1;
            if (segs == 0) {
                // One key and fromCurrent:false: hold it (a jump) for durationMs.
                a.kx.InsertLast(key.t.x); a.ky.InsertLast(key.t.y); a.kz.InsertLast(key.t.z);
                a.kd.InsertLast(key.d); a.kh.InsertLast(a.kh[0]); a.kv.InsertLast(key.v);
                segs = 1;
                keyMs.InsertLast(-1);
            }
            // Segment i ends at key i+1; with fromCurrent that is keyframes[i],
            // else keyframes[i+1] (keyframes[0].ms is then ignored).
            uint first = fromCurrent ? 0 : 1;
            uint segWithMs = 0;
            for (uint i = 0; i < segs; i++) if (first + i < keyMs.Length && keyMs[first + i] >= 0) segWithMs++;
            if (segWithMs > 0 && segWithMs < segs)
                return CameraAnimBadInput("give ms on every keyframe that ends a segment, or on none (then durationMs is split by travel distance)");
            if (segWithMs == segs) {
                if (input.HasKey("durationMs")) return CameraAnimBadInput("give either per-keyframe ms or durationMs, not both");
                for (uint i = 0; i < segs; i++) a.segMs.InsertLast(keyMs[first + i]);
            } else {
                array<float> weights;
                for (uint i = 0; i < segs; i++) {
                    vec3 t0 = vec3(a.kx[i], a.ky[i], a.kz[i]), t1 = vec3(a.kx[i + 1], a.ky[i + 1], a.kz[i + 1]);
                    vec3 c0 = CamOrbitalPos(t0, a.kd[i], a.kh[i], a.kv[i]), c1 = CamOrbitalPos(t1, a.kd[i + 1], a.kh[i + 1], a.kv[i + 1]);
                    weights.InsertLast((t1 - t0).Length() + (c1 - c0).Length());
                }
                a.segMs = CamSplitDuration(durationIn >= 0 ? durationIn : 3000 * int(segs), weights);
            }
            a.durationMs = CamPathTotalMs(a.segMs);
            if (a.durationMs > CAM_ANIM_MAX_MS) return CameraAnimBadInput("path is longer than " + CAM_ANIM_MAX_MS + " ms");
            a.blendMs = 0;
        } else if (kind == "orbit") {
            vec3 c = a.s0Target;
            if (input.HasKey("center") && !CamReadVec3(input["center"], c)) return CameraAnimBadInput("center must be {x,y,z}");
            a.center = c;
            a.oD0 = CamNum(input, "distance", a.s0Dist);
            a.oD1 = CamNum(input, "endDistance", a.oD0);
            if (a.oD0 < 0.5 || a.oD1 < 0.5) return CameraAnimBadInput("distance must be >= 0.5");
            a.oV0 = input.HasKey("vAngle") ? CamClampV(a, Math::ToRad(CamNum(input, "vAngle", 0)), "orbit") : Math::Clamp(a.s0V, a.vMin, a.vMax);
            a.oV1 = input.HasKey("endVAngle") ? CamClampV(a, Math::ToRad(CamNum(input, "endVAngle", 0)), "orbit end") : a.oV0;
            if (input.HasKey("hAngle")) {
                a.oH0 = Math::ToRad(CamNum(input, "hAngle", 0));
            } else if ((c - a.s0Target).Length() < 0.5) {
                a.oH0 = a.s0H;
            } else {
                // Start on the camera's side of the new center.
                vec3 dir = c - CamOrbitalPos(a.s0Target, a.s0Dist, a.s0H, a.s0V);
                a.oH0 = (dir.x * dir.x + dir.z * dir.z) > 1.0e-6 ? Math::Atan2(dir.x, dir.z) : a.s0H;
            }
            bool forever = input.HasKey("untilStopped") && bool(input["untilStopped"]);
            if (forever) {
                if (input.HasKey("degrees") || input.HasKey("durationMs") || input.HasKey("endDistance") || input.HasKey("endVAngle"))
                    return CameraAnimBadInput("untilStopped orbits at degreesPerSecond; degrees/durationMs/endDistance/endVAngle need a finite orbit");
                a.oRate = CamNum(input, "degreesPerSecond", 20.0);
                if (Math::Abs(a.oRate) < 0.01) return CameraAnimBadInput("degreesPerSecond must be non-zero");
                a.durationMs = -1;
            } else {
                a.oDeg = CamNum(input, "degrees", 360.0);
                if (durationIn >= 0) a.durationMs = durationIn;
                else {
                    float rate = Math::Abs(CamNum(input, "degreesPerSecond", 30.0));
                    if (rate < 0.01) return CameraAnimBadInput("degreesPerSecond must be non-zero");
                    a.durationMs = int(Math::Abs(a.oDeg) / rate * 1000.0);
                }
                if (a.durationMs > CAM_ANIM_MAX_MS) return CameraAnimBadInput("orbit is longer than " + CAM_ANIM_MAX_MS + " ms");
            }
            a.blendMs = input.HasKey("blendMs") ? Math::Max(0, int(input["blendMs"])) : 1000;
        } else if (kind == "follow") {
            a.follow = input.HasKey("follow") ? string(input["follow"]) : "cursor";
            if (a.follow == "point") {
                vec3 p;
                if (!CamReadVec3(input["target"], p)) return CameraAnimBadInput("follow:'point' needs target {x,y,z}; move it with {action:'retarget', x, y, z}");
                a.goal = p;
            } else if (a.follow != "cursor") {
                return CameraAnimBadInput("follow must be 'cursor' or 'point'");
            }
            a.cur = a.s0Target;
            a.fDist = CamNum(input, "distance", a.s0Dist);
            if (a.fDist < 0.5) return CameraAnimBadInput("distance must be >= 0.5");
            a.fH = input.HasKey("hAngle") ? Math::ToRad(CamNum(input, "hAngle", 0)) : a.s0H;
            a.fV = input.HasKey("vAngle") ? CamClampV(a, Math::ToRad(CamNum(input, "vAngle", 0)), "follow") : Math::Clamp(a.s0V, a.vMin, a.vMax);
            a.lagMs = Math::Max(0.0, CamNum(input, "lagMs", 400.0));
            a.spin = CamNum(input, "degreesPerSecond", 0.0);
            a.durationMs = durationIn;
            a.blendMs = input.HasKey("blendMs") ? Math::Max(0, int(input["blendMs"])) : 1000;
        } else {
            return CameraAnimBadInput("kind must be path, orbit or follow");
        }

        a.id = g_camAnimNextId++;
        Json::Value output = Json::Object();
        if (g_camAnimActive !is null) {
            output["replaced"] = int(g_camAnimActive.id);
            CameraAnimEnd(g_camAnimActive, "interrupted", "replaced by camera animation #" + a.id, "AnimateEditorCamera");
        }
        a.startedAt = Time::Now;
        g_camAnims.InsertLast(a);
        if (g_camAnims.Length > CAM_ANIM_HISTORY) g_camAnims.RemoveAt(0);
        @g_camAnimActive = a;
        if (!g_camAnimLoopRunning) {
            // Set before startnew: the coroutine body does not run inline, so
            // a second start in the same frame must see the loop as running.
            g_camAnimLoopRunning = true;
            startnew(CoroutineFunc(CameraAnimLoop));
        }
        auto info = CameraAnimToJson(a);
        auto keys = info.GetKeys();
        for (uint i = 0; i < keys.Length; i++) output[keys[i]] = info[keys[i]];
        output["note"] = "Runs in the background. WaitEditorCamera {id:" + a.id + "} returns when it ends: success when it completes, an error with the reason if it is stopped or interrupted"
            + " (another camera tool, a new animation, the camera moved by the mouse or another plugin, or leaving edit mode).";
        return MakeSuccess(output);
    }

    Json::Value@ WaitEditorCamera(Json::Value &in input) {
        CameraAnim@ a = null;
        if (input.HasKey("id")) {
            @a = CameraAnimFind(uint(Math::Max(0, int(input["id"]))));
            if (a is null) return MakeError("no camera animation #" + int(input["id"]) + " (only the last " + CAM_ANIM_HISTORY + " are kept)", "NOT_FOUND");
        } else if (g_camAnims.Length > 0) {
            @a = g_camAnims[g_camAnims.Length - 1];
        } else {
            return MakeError("no camera animation has been started; AnimateEditorCamera starts one", "NOT_FOUND");
        }
        uint64 t0 = Time::Now;
        int remaining = a.durationMs >= 0 ? a.durationMs - int(t0 - a.startedAt) : 0;
        int timeoutMs = CamWaitTimeoutMs(input.HasKey("timeoutMs"), input.HasKey("timeoutMs") ? int(input["timeoutMs"]) : 0,
                                         a.durationMs >= 0, remaining);
        while (a.state == "running" && Time::Now - t0 < uint64(timeoutMs)) yield();

        auto info = CameraAnimToJson(a);
        info["waitedMs"] = int(Time::Now - t0);
        info["timeoutMs"] = timeoutMs;
        auto editor = GetEditor();
        if (editor !is null && editor.PluginMapType !is null) info["camera"] = CameraToJson(editor);
        if (a.state == "running") {
            info["timedOut"] = true;
            return MakeSuccess(info);
        }
        info["timedOut"] = false;
        if (CamAnimStateOk(a.state)) return MakeSuccess(info);
        string code = a.state == "interrupted" ? "CAMERA_ANIM_INTERRUPTED" : (a.state == "stopped" ? "CAMERA_ANIM_STOPPED" : "CAMERA_ANIM_FAILED");
        auto err = MakeError("camera animation #" + a.id + " " + a.state + ": " + a.reason, code);
        err["output"] = info;
        return err;
    }
}
