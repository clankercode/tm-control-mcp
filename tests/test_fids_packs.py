"""Execute production pack policy and handlers with stock AS and public-API mocks.

The shared runner compiles both complete production files. These tests cover
ownership, path/confirmation/mode guards and native-call fault outcomes, but do
not prove Openplanet compilation, engine lifetime semantics or real pack loading.
"""
from pathlib import Path
import subprocess

from test_pack_updates import as_runner  # noqa: F401


ROOT = Path(__file__).resolve().parents[1]


MOCKS = r'''
namespace Json {
    enum Type { Null, Object, Boolean, String, Number }
    class Value {
        Type kind = Type::Null;
        string text;
        bool flag = false;
        int number = 0;
        string[] keys;
        Value@[] values;
        Type GetType() const { return kind; }
        bool HasKey(const string &in key) const { return keys.Find(key) >= 0; }
        Value@ opIndex(const string &in key) {
            int i = keys.Find(key);
            if (i >= 0) return values[i];
            keys.InsertLast(key); values.InsertLast(Value());
            return values[values.Length - 1];
        }
        Value &opAssign(const string &in v) { kind = Type::String; text = v; return this; }
        Value &opAssign(bool v) { kind = Type::Boolean; flag = v; return this; }
        Value &opAssign(int v) { kind = Type::Number; number = v; return this; }
        Value &opAssign(uint v) { kind = Type::Number; number = int(v); return this; }
        Value &opAssign(const Value &in v) {
            kind = v.kind; text = v.text; flag = v.flag; number = v.number;
            keys = v.keys; values = v.values; return this;
        }
        string opConv() const { return text; }
        bool opConv() const { return flag; }
        int opConv() const { return number; }
    }
    Value Object() { Value v; v.kind = Type::Object; return v; }
}

class CMwNod {
    int refs = 0;
    uint adds = 0, releases = 0;
    void MwAddRef() { refs++; adds++; }
    void MwRelease() { Check(refs > 0, "balanced engine references"); refs--; releases++; }
}
class CSystemFidsFolder : CMwNod {
    string DirName;
    CSystemFidsFolder@ ParentFolder;
    CSystemFidsFolder@[] Trees;
    CSystemFidFile@[] Leaves;
}
class CSystemFidFile : CMwNod {
    string FileName;
    CSystemFidsFolder@ ParentFolder;
    CMwNod@ Nod;
    CSystemFidFile@ Container;
}
uint folderReads = 0, fileReads = 0;
CSystemFidsFolder@ userRoot = CSystemFidsFolder();
namespace Fids {
    CSystemFidsFolder@ GetFidsFolder(CSystemFidsFolder@ parent, const string &in name) {
        folderReads++;
        if (parent is null) return null;
        for (uint i=0; i<parent.Trees.Length; i++)
            if (parent.Trees[i].DirName == name) return parent.Trees[i];
        return null;
    }
    CSystemFidsFolder@ GetUserFolder(const string &in path) {
        folderReads++;
        CSystemFidsFolder@ f = userRoot;
        if (path == "") return f;
        auto parts = path.Split("/");
        for (uint i=0; i<parts.Length; i++) @f = GetFidsFolder(f, parts[i]);
        return f;
    }
    CSystemFidFile@ GetFidsFile(CSystemFidsFolder@ parent, const string &in name) {
        fileReads++;
        if (parent is null) return null;
        for (uint i=0; i<parent.Leaves.Length; i++)
            if (parent.Leaves[i].FileName == name) return parent.Leaves[i];
        return null;
    }
}
class CPlugFilePack : CMwNod {
    CSystemFidsFolder@ Location;
    CSystemFidFile@ backing;
    uint NbFiles = 2, NbFolders = 1;
    uint installs = 0, uninstalls = 0;
    bool installNoop = false, uninstallNoop = false;
    bool installThrows = false, throwAfterInstall = false, uninstallThrows = false, throwAfterUninstall = false;
    bool wrongTarget = false;
    void UiInstallFidsInSubFolder() {
        installs++;
        if (installThrows) { Check(false, "private native exception"); return; }
        if (installNoop) return;
        @Location = Fids::GetFidsFolder(backing.ParentFolder, backing.FileName);
        if (Location is null) {
            @Location = CSystemFidsFolder();
            Location.DirName = backing.FileName;
            @Location.ParentFolder = backing.ParentFolder;
            backing.ParentFolder.Trees.InsertLast(Location);
        }
        if (wrongTarget) Location.DirName = "Other";
        if (throwAfterInstall) Check(false, "private exception after mount");
    }
    void UninstallAndDeleteFids() {
        uninstalls++;
        if (uninstallThrows) { Check(false, "private native exception"); return; }
        if (!uninstallNoop) @Location = null;
        if (throwAfterUninstall) Check(false, "private exception after unmount");
    }
}
string gameMode = "Menu";
namespace TmMcp {
    string DetectGameModeName() { return gameMode; }
    Json::Value@ MakeError(const string &in message, const string &in code) {
        auto v = Json::Object(); v["success"] = false;
        v["error"] = message; v["code"] = code; return v;
    }
    Json::Value@ MakeSuccess(Json::Value &in output) {
        auto v = Json::Object(); v["success"] = true; v["output"] = output; return v;
    }
}
Json::Value Input(const string &in path = "Media/Example.Pack.Gbx") {
    auto v = Json::Object(); v["drive"] = "user"; v["path"] = path; v["confirm"] = true; return v;
}
CSystemFidsFolder@ AddFolder(CSystemFidsFolder@ parent, const string &in name) {
    auto f = CSystemFidsFolder(); f.DirName = name; @f.ParentFolder = parent;
    parent.Trees.InsertLast(f); return f;
}
CPlugFilePack@ AddPack(const string &in name = "Example.Pack.Gbx", CSystemFidsFolder@ parent = null) {
    if (parent is null) @parent = Fids::GetUserFolder("Media");
    if (parent is null) @parent = AddFolder(userRoot, "Media");
    auto f = CSystemFidFile(); f.FileName = name; @f.ParentFolder = parent;
    auto p = CPlugFilePack(); @p.backing = f; @f.Nod = p;
    parent.Leaves.InsertLast(f); return p;
}
void Code(Json::Value@ result, const string &in code) {
    Check(!bool(result["success"]) && string(result["code"]) == code, "expected error " + code);
}
void Good(Json::Value@ result) { Check(bool(result["success"]), "expected success: " + string(result["code"])); }
'''


def run_as(as_runner, tmp_path, body):
    case = tmp_path / "case.as"
    case.write_text(MOCKS + "\nvoid RunTests() {\n" + body + "\n}\n")
    result = subprocess.run(
        [str(as_runner), str(ROOT / "src/FidsPackPolicy.as"), str(ROOT / "src/FidsPacks.as"), str(case)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_raw_paths_and_typed_input_guards(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    string[] valid = {"Example.Pack.Gbx", "Media/Example.Pack.Gbx", "Media/Plain Pack-1_2.Pack.Gbx"};
    for (uint i=0; i<valid.Length; i++) Check(IsFidsPackPath(valid[i]), "valid relative path");
    string[] invalid = {"", "/Media/a", "C:/Media/a", "//server/a", "\\\\server\\a", "Media\\a",
        "../a", "Media/../a", "Media/./a", "Media//a", "Media/a/", "Media/a\n", "Media/a\t",
        "Media/a\r", "Media/..hidden", "~/a", "Media/a:stream", "Media/%2e%2e/a", "Media/a.",
        "Media/a ", "Media/ a", "Media/NUL.Pack.Gbx", "Media/COM1.Pack.Gbx", "Media/a\x7f",
        "Media/nul .Pack.Gbx", "Media/cOm1  .Pack.Gbx", "Media/prn .Pack.Gbx"};
    for (uint i=0; i<invalid.Length; i++) {
        Check(!IsFidsPackPath(invalid[i]), "invalid raw path");
        auto input = Input(invalid[i]); Code(FidsActionPackStatus(input), "BAD_PATH");
    }
    Check(fileReads == 0 && folderReads == 0, "bad paths rejected before resolution");
    auto p = AddPack(); auto input = Input();
    input["confirm"] = "true"; Code(FidsActionMountPack(input), "CONFIRM_REQUIRED");
    input["confirm"] = 1; Code(FidsActionMountPack(input), "CONFIRM_REQUIRED");
    input["confirm"] = false; Code(FidsActionMountPack(input), "CONFIRM_REQUIRED");
    auto absent = Json::Object(); absent["drive"] = "user"; absent["path"] = "Media/Example.Pack.Gbx";
    Code(FidsActionMountPack(absent), "CONFIRM_REQUIRED");
    Good(FidsActionPackStatus(absent));
    input["drive"] = "game"; Code(FidsActionPackStatus(input), "USER_ONLY");
    input["drive"] = true; Code(FidsActionPackStatus(input), "USER_ONLY");
    input = Input(); input["path"] = true; Code(FidsActionPackStatus(input), "BAD_PATH");
    Check(p.installs == 0 && p.uninstalls == 0, "invalid requests cannot mutate");
    gameMode = "Race"; input = Input();
    Good(FidsActionPackStatus(input));
    Code(FidsActionMountPack(input), "MENU_ONLY"); Code(FidsActionUnmountPack(input), "MENU_ONLY");
    gameMode = "Loading"; Code(FidsActionMountPack(input), "MENU_ONLY");
    gameMode = "MapEditor"; Code(FidsActionMountPack(input), "MENU_ONLY");
    Check(p.installs == 0, "all non-menu mutations refused");
    ''')


def test_ownership_idempotency_and_cleanup_without_backing_file(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto p = AddPack(); auto input = Input();
    auto status = FidsActionPackStatus(input); Good(status);
    Check(!bool(status["output"]["owned"]) && p.refs == 0 && p.installs == 0, "status has no lifetime/mount side effects");
    Good(FidsActionMountPack(input)); auto mount = p.Location;
    Check(p.refs == 1 && mount.refs == 1 && p.backing.ParentFolder.refs == 1, "retain ownership identities");
    Good(FidsActionMountPack(input));
    Check(p.installs == 1, "repeat owned mount is idempotent");
    auto owned = FidsActionPackStatus(input); Good(owned);
    Check(bool(owned["output"]["owned"]) && bool(owned["output"]["mounted"]), "positive ownership reported");
    p.backing.ParentFolder.Leaves.RemoveAt(0); @p.backing.Nod = null;
    Good(FidsActionUnmountPack(input));
    Check(p.uninstalls == 1 && p.Location is null && p.refs == 0 && mount.refs == 0, "owned unmount needs no backing FID");
    Code(FidsActionUnmountPack(input), "NOT_OWNED");
    auto q = AddPack("Second.Pack.Gbx"); auto second = Input("Media/Second.Pack.Gbx");
    Good(FidsActionMountPack(second)); auto secondMount = q.Location;
    q.backing.ParentFolder.Leaves.RemoveAt(0);
    FidsPacksShutdown(); FidsPacksShutdown();
    Check(q.uninstalls == 1 && q.refs == 0 && secondMount.refs == 0, "shutdown unmounts once and releases handles");
    ''')


def test_foreign_mounts_collisions_and_lost_identity(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto p = AddPack(); auto input = Input();
    @p.Location = AddFolder(p.backing.ParentFolder, p.backing.FileName);
    Code(FidsActionMountPack(input), "NOT_OWNED"); Code(FidsActionUnmountPack(input), "NOT_OWNED");
    auto foreign = FidsActionPackStatus(input); Good(foreign);
    Check(!bool(foreign["output"]["owned"]) && bool(foreign["output"]["mounted"]), "foreign mount observable only");
    FidsPacksShutdown(); Check(p.uninstalls == 0, "never adopt after reload");
    @p.Location = null;
    auto target = Fids::GetFidsFolder(p.backing.ParentFolder, p.backing.FileName);
    auto leftover = AddFolder(target, "Leftover");
    Code(FidsActionMountPack(input), "MOUNT_COLLISION");
    target.Trees.RemoveAt(0); auto leaf = CSystemFidFile(); target.Leaves.InsertLast(leaf);
    Code(FidsActionMountPack(input), "MOUNT_COLLISION");
    target.Leaves.RemoveAt(0); Good(FidsActionMountPack(input));
    auto originalMount = p.Location;
    @p.Location = AddFolder(p.backing.ParentFolder, "Foreign");
    Code(FidsActionUnmountPack(input), "OWNERSHIP_LOST");
    Code(FidsActionMountPack(input), "OWNERSHIP_LOST");
    FidsPacksShutdown();
    Check(p.uninstalls == 0 && p.refs == 0 && originalMount.refs == 0, "identity drift never deletes foreign state");
    ''')


def test_limits_and_noncreating_typed_resolution(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    string a, b;
    for (uint i=0; i<255; i++) a += "a";
    for (uint i=0; i<254; i++) b += "b";
    Check(IsFidsPackPath(a + "/x/" + b), "exact 512-byte path");
    Check(!IsFidsPackPath(a + "/x/" + b + "b"), "513-byte path rejected");
    Check(!IsFidsPackPath(a + "a"), "component limit");
    string deep = "a";
    for (uint i=1; i<16; i++) deep += "/a";
    Check(IsFidsPackPath(deep) && !IsFidsPackPath(deep + "/a"), "depth bounded");
    string nul = "Media/a "; nul[7] = 0;
    Check(!IsFidsPackPath(nul) && !IsFidsPackPath("Media/Média.Pack.Gbx"), "NUL and non-ASCII refused");
    auto input = Input(); Code(FidsActionPackStatus(input), "NOT_FOUND");
    Check(userRoot.Trees.Length == 0 && userRoot.Leaves.Length == 0, "missing folder never created");
    auto p = AddPack();
    auto missing = Input("Media/Missing.Pack.Gbx"); Code(FidsActionPackStatus(missing), "NOT_FOUND");
    Check(p.backing.ParentFolder.Leaves.Length == 1, "missing file never created");
    @p.backing.Nod = null; Code(FidsActionPackStatus(input), "NOT_LOADED");
    @p.backing.Nod = CMwNod(); Code(FidsActionMountPack(input), "NOT_PACK");
    @p.backing.Nod = p; @p.backing.Container = CSystemFidFile();
    Code(FidsActionMountPack(input), "FID_IDENTITY"); @p.backing.Container = null;
    p.backing.FileName = "Alias.Pack.Gbx";
    Code(FidsActionPackStatus(input), "NOT_FOUND");
    p.backing.FileName = "Example.Pack.Gbx";
    @p.backing.ParentFolder = userRoot;
    Code(FidsActionMountPack(input), "FID_IDENTITY");
    Check(p.installs == 0 && p.refs == 0, "only correctly parented preloaded public pack accepted");
    auto rootPack = AddPack("Root.Pack.Gbx", userRoot); auto rootInput = Input("Root.Pack.Gbx");
    Good(FidsActionMountPack(rootInput)); Good(FidsActionUnmountPack(rootInput));
    Json::Value scalar; scalar = true;
    Code(FidsActionPackStatus(scalar), "BAD_INPUT");
    ''')


def test_fault_results_references_and_retained_exact_mount(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto p = AddPack(); auto input = Input(); auto parent = p.backing.ParentFolder;
    p.installThrows = true;
    auto result = FidsActionMountPack(input); Code(result, "PACK_CALL_FAILED");
    Check(bool(result["output"]["methodInvoked"]) && p.refs == 0 && parent.refs == 0 && g_FidsPackOwners.Length == 0,
          "throw before mutation releases reservation");
    Check(string(result["error"]).IndexOf("private") < 0, "native exceptions never echoed");
    p.installThrows = false; p.installNoop = true;
    Code(FidsActionMountPack(input), "MOUNT_UNVERIFIED");
    Check(p.refs == 0 && p.Location is null, "no-op install not acknowledged");
    p.installNoop = false; p.throwAfterInstall = true;
    Code(FidsActionMountPack(input), "PACK_CALL_FAILED");
    Check(p.refs == 1 && g_FidsPackOwners.Length == 1, "exact post-exception mount remains owned for cleanup");
    auto mount = p.Location;
    p.uninstallThrows = true; Code(FidsActionUnmountPack(input), "PACK_CALL_FAILED");
    Check(p.refs == 1 && p.Location is mount, "failed unmount preserves owner for retry");
    p.uninstallThrows = false; p.uninstallNoop = true;
    Code(FidsActionUnmountPack(input), "UNMOUNT_UNVERIFIED");
    Check(p.refs == 1 && mount.refs == 1, "unobserved unmount cannot release owner");
    p.uninstallNoop = false; p.throwAfterUninstall = true;
    Code(FidsActionUnmountPack(input), "PACK_CALL_FAILED");
    Check(p.refs == 0 && mount.refs == 0 && parent.refs == 0 && g_FidsPackOwners.Length == 0,
          "post-exception observed unmount releases all identities once");
    Check(p.adds == p.releases && mount.adds == mount.releases && parent.adds == parent.releases, "all engine references balanced");
    auto q = AddPack("Wrong.Pack.Gbx"); q.wrongTarget = true;
    auto wrong = Input("Media/Wrong.Pack.Gbx"); Code(FidsActionMountPack(wrong), "MOUNT_UNVERIFIED");
    Check(q.refs == 0 && q.uninstalls == 0 && g_FidsPackOwners.Length == 0, "never unmount unexpected target");
    FidsPacksShutdown(); Check(q.uninstalls == 0, "unexpected target remains foreign on shutdown");
    ''')


def test_shutdown_menu_guard_and_fault_isolation(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto p = AddPack(); auto input = Input(); Good(FidsActionMountPack(input));
    auto mount = p.Location; gameMode = "Race";
    FidsPacksShutdown();
    Check(p.uninstalls == 0 && p.refs == 0 && mount.refs == 0 && g_FidsPackOwners.Length == 0,
          "shutdown in Race makes no game mutation and releases references");
    gameMode = "Menu";
    Code(FidsActionMountPack(input), "NOT_OWNED"); Code(FidsActionUnmountPack(input), "NOT_OWNED");
    auto q = AddPack("Second.Pack.Gbx"); auto second = Input("Media/Second.Pack.Gbx"); Good(FidsActionMountPack(second));
    auto r = AddPack("Third.Pack.Gbx"); auto third = Input("Media/Third.Pack.Gbx"); Good(FidsActionMountPack(third));
    r.uninstallThrows = true;
    FidsPacksShutdown(); FidsPacksShutdown();
    Check(q.uninstalls == 1 && r.uninstalls == 1 && q.refs == 0 && r.refs == 0 && r.Location.refs == 0,
          "one shutdown failure cannot prevent another owner's cleanup; references always released");
    Code(FidsActionUnmountPack(third), "NOT_OWNED");
    ''')


def test_owner_limit_counts_and_read_only_status(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    CPlugFilePack@[] packs;
    for (uint i=0; i<FIDS_PACK_OWNER_MAX; i++) {
        string name = "Pack" + i + ".Pack.Gbx";
        auto p = AddPack(name); packs.InsertLast(p); auto input = Input("Media/" + name);
        Good(FidsActionMountPack(input));
    }
    auto excess = AddPack("Excess.Pack.Gbx"); auto excessInput = Input("Media/Excess.Pack.Gbx");
    Code(FidsActionMountPack(excessInput), "OWNER_LIMIT");
    Check(excess.installs == 0 && excess.refs == 0 && g_FidsPackOwners.Length == FIDS_PACK_OWNER_MAX, "capacity checked before native mutation");
    auto first = Input("Media/Pack0.Pack.Gbx"); Good(FidsActionMountPack(first));
    Check(packs[0].installs == 1, "idempotent owned mount works at capacity");
    packs[0].NbFiles = 0xffffffff; packs[0].NbFolders = 0xffffffff;
    auto status = FidsActionPackStatus(first); Good(status);
    Check(int(status["output"]["nbFiles"]) == 1000000 && int(status["output"]["nbFolders"]) == 1000000
          && bool(status["output"]["countsCapped"]), "bounded unsigned counts do not overflow");
    Check(status["output"].keys.Length <= 16 && !status["output"].HasKey("source") && !status["output"].HasKey("fullPath"), "bounded summary only");
    Check(packs[0].adds == 1 && packs[0].uninstalls == 0, "status adds no ownership and makes no native changes");
    Good(FidsActionUnmountPack(first)); Good(FidsActionMountPack(excessInput));
    FidsPacksShutdown();
    for (uint i=0; i<packs.Length; i++) Check(packs[i].refs == 0 && packs[i].uninstalls == 1, "each original pack released exactly once");
    Check(excess.refs == 0 && excess.uninstalls == 1, "capacity slot reusable after clean unmount");
    ''')


def test_mount_identity_includes_folder_hierarchy(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto p = AddPack(); auto input = Input(); Good(FidsActionMountPack(input));
    auto mount = p.Location; auto parent = p.backing.ParentFolder;
    // Same pack.Location, but the canonical parent slot was replaced.
    parent.Trees.RemoveAt(0); auto replacement = AddFolder(parent, p.backing.FileName);
    Code(FidsActionUnmountPack(input), "OWNERSHIP_LOST");
    FidsPacksShutdown(); Check(p.uninstalls == 0 && p.refs == 0 && mount.refs == 0, "replaced folder slot never deleted");
    auto q = AddPack("Other.Pack.Gbx"); auto other = Input("Media/Other.Pack.Gbx"); Good(FidsActionMountPack(other));
    @parent.ParentFolder = CSystemFidsFolder();
    Code(FidsActionUnmountPack(other), "OWNERSHIP_LOST");
    FidsPacksShutdown(); Check(q.uninstalls == 0 && q.refs == 0, "reparented USER hierarchy never deleted");
    ''')


def test_external_unmount_and_overlapping_namespace_are_conservative(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto p = AddPack(); auto input = Input(); Good(FidsActionMountPack(input));
    auto mount = p.Location;
    // A direct USER FID under an owned mount still cannot acquire an overlapping
    // namespace. A real nested pack member is refused earlier by Container.
    auto child = AddPack("Child.Pack.Gbx", mount);
    auto nested = Input("Media/Example.Pack.Gbx/Child.Pack.Gbx");
    Code(FidsActionMountPack(nested), "MOUNT_COLLISION");
    Check(child.installs == 0 && child.refs == 0, "overlap refused before mutation");
    @p.Location = null;
    auto status = FidsActionPackStatus(input); Good(status);
    Check(!bool(status["output"]["owned"]) && bool(status["output"]["tracked"]) && p.refs == 1,
          "status observes lost mount without changing retained state");
    Code(FidsActionMountPack(input), "OWNERSHIP_LOST");
    Good(FidsActionUnmountPack(input));
    Check(p.uninstalls == 0 && p.refs == 0 && mount.refs == 0, "externally unmounted owner releases without another native call");
    // The surviving hierarchy is not pruned to make remount succeed.
    Code(FidsActionMountPack(input), "MOUNT_COLLISION");
    Check(mount.Leaves.Length == 1 && p.installs == 1, "foreign hierarchy preserved");
    ''')


def test_replaced_ancestor_slot_loses_ownership(as_runner, tmp_path):
    run_as(as_runner, tmp_path, r'''
    using namespace TmMcp;
    auto p = AddPack(); auto input = Input();
    Good(FidsActionMountPack(input));
    auto retainedMedia = p.backing.ParentFolder;
    auto retainedMount = p.Location;
    // Keep parent links and objects alive while replacing the root child slot.
    userRoot.Trees.RemoveAt(0);
    auto replacement = AddFolder(userRoot, "Media");
    Check(retainedMedia.ParentFolder is userRoot && replacement !is retainedMedia, "stale parent link fixture");
    auto status = FidsActionPackStatus(input); Good(status);
    Check(!bool(status["output"]["owned"]) && string(status["output"]["state"]) == "ownershipLost", "canonical ancestor identity required");
    Code(FidsActionUnmountPack(input), "OWNERSHIP_LOST");
    Code(FidsActionMountPack(input), "OWNERSHIP_LOST");
    FidsPacksShutdown();
    Check(p.uninstalls == 0 && p.refs == 0 && retainedMedia.refs == 0 && retainedMount.refs == 0, "never delete through stale ancestors");
    ''')
