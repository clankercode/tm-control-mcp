# Preserved work publication decisions

Implementing owner: Codex (`codex-vermic-lumi-8amm`). Base: `a3d217a`.
Reviewed preserved snapshot: `local/preserved-work-20261020` (`90be5a0`).
Only isolated, reviewed changes are ported; the old mixed history is not merged.

| Preserved item | Decision | Public result / reason |
| --- | --- | --- |
| Native auth probe and callbacks | Fixed + merge | DEV status reports API/user availability, response/error presence and task count. It never requests, reads, decodes, exchanges or transmits credential values. Old acquisition/verifier paths remain held. No async probe means no cancellation callbacks are needed. |
| Native DLL call carrier | Still held | Its purpose is arbitrary native execution through an external DLL. Removing executable injection removes its functionality. |
| Native title registration/catalog tools | Still held | Executable allocation/vtable replacement, fixed-offset registry writes and retained native state have no safe public implementation here. A documented crash in the inventory-refresh path reinforces the exclusion. Static carrier self-tests have no independent use once the carrier is removed. |
| Native title fixture selection | Still held | Depends on the excluded native registration and can intentionally leave registration active after a transition. An ordinary installed-title navigator would be a different feature, not a safe port of this workflow. |
| Pack/menu fixture mounting | Fixed + merge | Generic preloaded user-pack status/mount/unmount using typed public bindings, explicit confirmation, menu-only mutations, mount identity and ownership checks. No dated fixture identities or contents. |
| Child pack fixture/member inspection | Fixed + merge | Same generic pack operations; existing ControlFids list/preload handles nested members explicitly. Status never preloads. Unverified fixed hash claims and private assets are omitted. |
| Editor script plugin control | Fixed + merge | Generic forced-script status and confirmed native reload with editor/map/crash guards. Private cache keys, source capture, offsets and transport assumptions are removed. |
| Dips++ metadata bridge/docs | Still held (private portion) | The fixed mailbox schema is specific to an unpublished consumer; generic settings get/set already exists. No private consumer script, metadata schema or research is published. Generic reload/recovery utilities preserve the reusable functionality. |
| Pending-value recovery helper/tests | Fixed + merge | Offline generic event-array decoder with explicit event/key, canonical base64 checks, size bounds, unique match and exclusive backup creation. No consumer defaults or private transport-page parser. |
| ControlFids setText / PatchLayerXml | Fixed + merge | Shared bounded replacement planner. FID writes are restricted to user editor scripts in idle MapEditor; page writes require Menu. Typed confirmation, empty/oversize rejection, bounded matches, no snippets or raw exceptions, truthful readback failures. Native game/title/race scripts cannot be written by the new writer. |
| Raw argument trace expansion | Fixed + merge | Zero raw argument/response characters logged. Metadata is capped at 512 characters plus marker and rotated at 2 MB. A prefix bound cannot prevent a short secret from being logged; the unused serializer is removed. |
| Personal paths/research links and sibling-plugin source claims | Fixed + merge | Generic public guidance and runtime-relative paths only; no private plugin source/scripts or unsupported sibling change claims. |
| Ten old stuck-call-stack commits | Merge (already superseded) | PR #23 on the base supplies the reviewed ownership/recovery fix. Do not reintroduce intermediate/red/reverted implementations or the old 60-second script timeout; retain 15 seconds. |
| Old checkpoint/master histories; camera work | Still held / already upstream | Old histories contain the excluded source even if later deleted. Selective ports keep it out of public ancestry. Camera work is already upstream; no vehicle/physics/input mutation is added. |

The original local preserved ref is retained unchanged in both clones. It is the
recovery source for the explicitly held portions above; it must not be pushed as
a branch or merged wholesale.
