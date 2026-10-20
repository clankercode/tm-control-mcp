# USER pack mounts

`ControlFids` exposes three actions for an existing, already preloaded USER
`CPlugFilePack`. These actions use the public typed pack API and do not create
FIDs, preload files or members, read source content, or enumerate pack members.

```json
{"action":"packStatus","drive":"user","path":"Media/Example.Pack.Gbx"}
{"action":"mountPack","drive":"user","path":"Media/Example.Pack.Gbx","confirm":true}
{"action":"unmountPack","drive":"user","path":"Media/Example.Pack.Gbx","confirm":true}
```

The FID must already be present in the USER tree and its `Nod` must be a
`CPlugFilePack`. Preload separately using the existing `ControlFids` preload
action. A pack member inside another pack is refused. `packStatus` performs
only noncreating public lookups and observations; it works outside Menu and
requires no confirmation.

Both mutations require **Menu** and a JSON boolean `confirm:true`. Strings,
numbers, false and omitted confirmation are refused. Race, loading, editors and
unknown modes are refused before the pack mutation. A repeated mount is a
successful no-op only while this plugin instance still owns the exact mount.

## Paths and targets

Paths are validated directly from the input, before any generic FID path
normalization. Only `drive:"user"` is accepted. Supply the canonical case of
each USER folder and filename, including each current ancestor child slot
through noncreating lookups. Retained parent pointers alone never establish
canonical ownership. The path must be relative, at most 512 ASCII
bytes and 16 components, with each component at most 255 bytes. Allowed
characters are letters, digits, spaces inside components, `_`, `-`, `.`, and
the `/` separator.

Absolute paths, drive prefixes, backslashes, control characters, non-ASCII,
empty components, `..` anywhere, components beginning with `.`, leading or
trailing spaces, trailing dots, and Windows device names are refused. Nothing
is trimmed, decoded, or repaired to turn an invalid path into a valid one.

`UiInstallFidsInSubFolder()` chooses the mount location. The only accepted
result is the pack FID's exact parent child folder named **the full pack
filename**, with the same canonical USER hierarchy. Callers cannot supply an
alternate mount target. A target folder must be absent or completely empty:
any file or child folder is a collision. Overlapping tracked mount namespaces
and aliases of a tracked pack are refused.

Public unmount can leave the directory hierarchy behind. Remount is deliberately
conservative: an empty leaf target can be reused; a target containing even empty
child folders is refused. These actions do not prune leftover hierarchy or
automatically make a colliding folder reusable.

## Ownership and cleanup

The current plugin instance tracks at most **8** pack owners. Before invoking
mount, it reserves an owner slot and retains the pack and its parent using
explicit engine references. It claims the mount only after observing the exact
expected folder, and retains that folder identity too. Exceptions after a
verified exact mount preserve its ownership for later cleanup. A no-op or an
unexpected mount result is an error, and an unexpected target is never deleted.

An existing mount is foreign even if it occupies the expected folder. Mount and
unmount refuse it. Ownership is never reconstructed from paths or locations
after reload. A tracked pack whose location, parent hierarchy, or canonical
folder slot changes is refused as `OWNERSHIP_LOST`; it is not adopted again.

Owned status and unmount use the retained pack and folder identities, so the
backing file or its FID need not remain available. A successful observed unmount
releases the owner and its engine references. A failed/no-op unmount keeps the
owner available for retry. Unmount of an unowned path is refused, including a
second unmount after successful cleanup.

`FidsPacksShutdown()` synchronously attempts `UninstallAndDeleteFids()` only in
Menu and only for positively owned, still exact mounts. It never yields,
re-resolves the backing file, or touches a mismatched/foreign mount. It releases
all retained references afterward, including when a public call throws or fails
to unmount. Outside Menu it releases references without mutating mounts. Any
mounts left after cleanup are foreign to a later instance; automatic recovery
or adoption is intentionally unavailable.

Ownership uses public object identity and current hierarchy. It cannot detect
an external unmount/remount that restores all the same object identities between
observations. Engine reference semantics and native failure behavior still need
verification in Openplanet before claiming runtime lifecycle correctness.

## Results

Results contain the validated USER-relative `path`, fixed action/drive names,
boolean observations, owner counts, and bounded file/folder counts. They contain
no absolute paths, pointers, pack identity strings, member listings, source
values, or native exception text. File/folder counts saturate at 1,000,000 with
`countsCapped:true`; the summary has constant size apart from the bounded path.

`mounted` means `pack.Location` is non-null. `owned` additionally verifies the
captured mount identity and canonical folder slot. `tracked` only means an
owner/reference record exists; it does not assert ownership of the current
location. `state` is `unmounted`, `owned`, `foreign`, or `ownershipLost`.
`methodInvoked` reports whether a public mutation method was called, not whether
it completed. A raised exception is always reported as failure even when the
resulting state was observed; inspect status before retrying.

## Integration hooks

In `ControlFids`, dispatch the following actions with the **original input**
before calling `FidsNormPath`, `FidsBadDriveOrPath`, or generic file resolution:

```angelscript
if (action == "packStatus") return FidsActionPackStatus(input);
if (action == "mountPack") return FidsActionMountPack(input);
if (action == "unmountPack") return FidsActionUnmountPack(input);
```

Add the canonical action spellings to `FidsNormAction` and the existing
`ControlFids` schema/description; declare `confirm` as a boolean. These handlers
run synchronously without yielding inside the existing server request
coroutine. No additional exported tool or asynchronous worker is required.

Call `TmMcp::FidsPacksShutdown();` from the plugin's central `Shutdown()` after
stopping new tool calls and before other resources are torn down. Repeated
shutdown calls are safe. There is no initialization hook.

## Local verification

```sh
TCM_REQUIRE_ANGELSCRIPT=1 pytest -q tests/test_fids_packs.py
```

The tests reuse `test_pack_updates.py`'s `as_runner` fixture, compiling and
executing both complete production AS files with mocked public FIDs, packs,
JSON, and mode observations. They cover validation, missing/unloaded/wrong-type
files, ownership, exact targets, collisions, capacity, idempotency, backing-file
loss, reference balance, native no-ops/exceptions, and shutdown restrictions.
They do not load a real pack, deploy/reload the plugin, or establish in-game
compile and lifecycle acceptance.
