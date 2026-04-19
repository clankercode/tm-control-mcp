# Trackmania Editor Orbital Camera Maths

Validated empirically by `tests/test_camera_math.py`, `tests/test_focus_camera.py`, and `tests/test_autofocus.py`.

## Convention

The orbital camera is defined by four values:

| Field | Type | Description |
|---|---|---|
| `CameraTargetPosition` | `vec3` | World-space point the camera orbits |
| `CameraToTargetDistance` | `float` | Distance from camera to target |
| `CameraHAngle` | `float` | Horizontal angle (yaw), radians |
| `CameraVAngle` | `float` | Vertical angle (pitch), radians |

### Look direction

The unit vector from camera toward target:

```
look_dir(h, v) = (cos(v) * sin(h),  -sin(v),  cos(v) * cos(h))
```

- `h = 0, v = 0` → camera sits behind target on the −Z axis, looking in +Z
- Positive `h` rotates the camera clockwise around Y (toward +X)
- Positive `v` tilts the camera **above** the target (looks **down**); negative `v` puts it below (looks up)

### Camera world position

```
cam_pos = target − distance * look_dir(h, v)
```

### Inverse: direction → angles

Given a desired look direction `d` (unit vector from camera to target):

```
h = atan2(d.x, d.z)
v = −asin(d.y)
```

Use `Math::Atan2` and `Math::Asin(Math::Clamp(d.y, −1, 1))` in AngelScript.

> **Warning — `Editor::DirToLookUv` is wrong at steep pitches.**  
> It omits `asin` and scales by `/PI×2`, so it approximates the direction linearly.  
> The error is ~0 at shallow angles but grows to ~25° at ±65° pitch.  
> Use `LookDirToOrbitalAngles` in `McpTools.as` instead.

## Autofocus behaviour

`AutofocusCameraOn(pos, distance)` targets `pos` from a high angle:

1. Compute horizontal direction from `pos` toward the current camera (`orbital.Pos − pos`, XZ only, normalised). This is `horiz`.
2. Build a look direction at 65° below horizontal, on the camera-side of the target:
   ```
   lookDir = −horiz * cos(65°) + (0, −sin(65°), 0)
   ```
3. Convert to angles with `LookDirToOrbitalAngles(lookDir)`.
4. Animate to `(h, v), pos, distance`.

Result: camera ends up above and on the same horizontal side as it started, looking steeply down at the block. The yaw matches `atan2(pos.x − cam.x, pos.z − cam.z)` so the animation sweeps naturally from the user's previous viewpoint.

## Map bounds

`CameraTargetPosition` is clamped to the current map's playable volume by the engine. On a 48×40×48 map the Y ceiling is 256 m. Setting a target above this will silently clamp it; the resulting camera position will not match angle-derived predictions.
