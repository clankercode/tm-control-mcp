namespace TmMcp {
    // No ownership is inferred from existing locations, even after reload.
    // Script handles alone do not retain native nods: each stored identity has
    // one explicit engine reference, released on unmount or synchronous shutdown.
    class FidsPackOwner {
        string path, parentPath, fileName;
        CPlugFilePack@ pack;
        CSystemFidsFolder@ parent;
        CSystemFidsFolder@ mount;
        bool ownsMount = false;

        void Retain(CPlugFilePack@ value, CSystemFidsFolder@ folder) {
            value.MwAddRef(); @pack = value;
            folder.MwAddRef(); @parent = folder;
        }
        void CaptureMount(CSystemFidsFolder@ folder) {
            folder.MwAddRef(); @mount = folder;
            ownsMount = true;
        }
        void Release() {
            ownsMount = false;
            auto savedMount = mount; @mount = null;
            auto savedPack = pack; @pack = null;
            auto savedParent = parent; @parent = null;
            // Independent releases keep a failed cleanup from leaking the rest.
            try { if (savedPack !is null) savedPack.MwRelease(); } catch { }
            try { if (savedMount !is null) savedMount.MwRelease(); } catch { }
            try { if (savedParent !is null) savedParent.MwRelease(); } catch { }
        }
        ~FidsPackOwner() { Release(); }
    }

    array<FidsPackOwner@> g_FidsPackOwners;

    int FidsPackOwnerIndex(const string &in path) {
        for (uint i = 0; i < g_FidsPackOwners.Length; i++)
            if (g_FidsPackOwners[i].path == path) return int(i);
        return -1;
    }

    void FidsPackForget(uint index) {
        auto owner = g_FidsPackOwners[index];
        g_FidsPackOwners.RemoveAt(index);
        owner.Release();
    }

    bool FidsPackParentMatches(CSystemFidsFolder@ parent, const string &in parentPath) {
        // Compare the bounded canonical hierarchy to the USER root. Refuse
        // case aliases and folders whose parents have changed since mounting.
        auto root = Fids::GetUserFolder("");
        if (root is null || parent is null) return false;
        if (parentPath.Length == 0) return parent is root;
        auto parts = parentPath.Split("/");
        CSystemFidsFolder@ cur = parent;
        for (int i = int(parts.Length) - 1; i >= 0; i--) {
            if (cur is null || string(cur.DirName) != parts[i]) return false;
            @cur = cur.ParentFolder;
        }
        return cur is root;
    }

    bool FidsPackTargetMatches(FidsPackOwner@ owner) {
        if (owner is null || owner.pack is null || owner.parent is null || owner.pack.Location is null) return false;
        auto location = owner.pack.Location;
        return location.ParentFolder is owner.parent && string(location.DirName) == owner.fileName
            && Fids::GetFidsFolder(owner.parent, owner.fileName) is location
            && FidsPackParentMatches(owner.parent, owner.parentPath);
    }

    bool FidsPackOwnedExact(FidsPackOwner@ owner) {
        return owner !is null && owner.ownsMount && owner.mount !is null
            && owner.pack !is null && owner.pack.Location is owner.mount && FidsPackTargetMatches(owner);
    }

    Json::Value@ FidsPackValidate(Json::Value &in input, bool mutate, string &out path) {
        if (input.GetType() != Json::Type::Object) return MakeError("input must be an object", "BAD_INPUT");
        if (!input.HasKey("drive") || input["drive"].GetType() != Json::Type::String || string(input["drive"]) != "user")
            return MakeError("Pack operations require drive:user", "USER_ONLY");
        if (!input.HasKey("path") || input["path"].GetType() != Json::Type::String
            || !IsFidsPackPath(string(input["path"]))) return MakeError("Invalid relative USER pack path", "BAD_PATH");
        path = string(input["path"]);
        if (mutate) {
            if (!input.HasKey("confirm") || input["confirm"].GetType() != Json::Type::Boolean || !bool(input["confirm"]))
                return MakeError("Pack mutation requires confirm:true", "CONFIRM_REQUIRED");
            if (DetectGameModeName() != "Menu") return MakeError("Pack mutation requires Menu", "MENU_ONLY");
        }
        return null;
    }

    Json::Value@ FidsPackResolve(const string &in path, CSystemFidsFolder@ &out parent, CPlugFilePack@ &out pack) {
        string parentPath, fileName;
        FidsPackSplitPath(path, parentPath, fileName);
        @parent = Fids::GetUserFolder(parentPath);
        if (parent is null) return MakeError("USER pack parent folder not found", "NOT_FOUND");
        if (!FidsPackParentMatches(parent, parentPath)) return MakeError("USER folder identity differs", "FID_IDENTITY");
        // GetUser/Get{Drive} can create FIDs. Enumerate only; no preload, I/O,
        // updateTree, extraction, source reads, or pointer-based nod access.
        auto fid = Fids::GetFidsFile(parent, fileName);
        if (fid is null) return MakeError("USER pack FID not found", "NOT_FOUND");
        if (fid.ParentFolder !is parent || string(fid.FileName) != fileName || fid.Container !is null)
            return MakeError("Pack must be a direct existing USER file", "FID_IDENTITY");
        if (fid.Nod is null) return MakeError("Preload the USER pack separately first", "NOT_LOADED");
        @pack = cast<CPlugFilePack>(fid.Nod);
        if (pack is null) return MakeError("Preloaded file is not a CPlugFilePack", "NOT_PACK");
        return null;
    }

    Json::Value FidsPackSnapshot(const string &in action, const string &in path, CPlugFilePack@ pack,
                                FidsPackOwner@ owner, bool invoked) {
        bool mounted = pack.Location !is null;
        bool owned = FidsPackOwnedExact(owner);
        auto output = Json::Object();
        output["action"] = action; output["drive"] = "user"; output["path"] = path;
        output["loaded"] = true; output["mounted"] = mounted; output["owned"] = owned;
        output["tracked"] = owner !is null;
        output["state"] = owned ? "owned" : (owner !is null && mounted ? "ownershipLost" : (mounted ? "foreign" : "unmounted"));
        output["methodInvoked"] = invoked;
        output["ownerCount"] = g_FidsPackOwners.Length; output["ownerLimit"] = FIDS_PACK_OWNER_MAX;
        output["nbFiles"] = FidsPackBoundedCount(uint64(pack.NbFiles));
        output["nbFolders"] = FidsPackBoundedCount(uint64(pack.NbFolders));
        output["countsCapped"] = uint64(pack.NbFiles) > FIDS_PACK_COUNT_MAX || uint64(pack.NbFolders) > FIDS_PACK_COUNT_MAX;
        return output;
    }

    Json::Value@ FidsPackOutcome(Json::Value &in output, const string &in code) {
        if (code.Length == 0) return MakeSuccess(output);
        auto error = MakeError("Pack state not changed or not verified; inspect status before retry", code);
        error["output"] = output;
        return error;
    }

    Json::Value@ FidsPackRun(Json::Value &in input, const string &in action) {
        string path;
        auto invalid = FidsPackValidate(input, action != "packStatus", path);
        if (invalid !is null) return invalid;
        int index = FidsPackOwnerIndex(path);
        FidsPackOwner@ owner = index < 0 ? null : g_FidsPackOwners[index];
        CPlugFilePack@ pack;
        CSystemFidsFolder@ parent;
        if (owner !is null) {
            // Cleanup and status work through retained identities, even when
            // the backing file/FID has disappeared. Never reacquire ownership.
            @pack = owner.pack; @parent = owner.parent;
        } else {
            if (action == "unmountPack") return MakeError("Pack is not owned by this plugin instance", "NOT_OWNED");
            auto missing = FidsPackResolve(path, parent, pack);
            if (missing !is null) return missing;
        }
        if (action == "packStatus") return MakeSuccess(FidsPackSnapshot(action, path, pack, owner, false));

        if (action == "unmountPack") {
            if (pack.Location !is null && !FidsPackOwnedExact(owner))
                return FidsPackOutcome(FidsPackSnapshot(action, path, pack, owner, false), "OWNERSHIP_LOST");
            bool invoked = pack.Location !is null;
            bool failed = false;
            if (invoked) { try { pack.UninstallAndDeleteFids(); } catch { failed = true; } }
            if (pack.Location !is null) return FidsPackOutcome(FidsPackSnapshot(action, path, pack, owner, invoked),
                failed ? "PACK_CALL_FAILED" : "UNMOUNT_UNVERIFIED");
            // Read all native fields while the explicit reference still lives.
            auto output = FidsPackSnapshot(action, path, pack, null, invoked);
            output["ownerCount"] = g_FidsPackOwners.Length - 1;
            FidsPackForget(uint(index));
            return FidsPackOutcome(output, failed ? "PACK_CALL_FAILED" : "");
        }

        if (owner !is null) return FidsPackOutcome(FidsPackSnapshot(action, path, pack, owner, false),
            FidsPackOwnedExact(owner) ? "" : "OWNERSHIP_LOST");
        if (pack.Location !is null) return FidsPackOutcome(FidsPackSnapshot(action, path, pack, null, false), "NOT_OWNED");
        if (g_FidsPackOwners.Length >= FIDS_PACK_OWNER_MAX) return MakeError("Owned pack limit reached", "OWNER_LIMIT");
        // Refuse aliases and overlapping owned namespaces before any mutation.
        for (uint i = 0; i < g_FidsPackOwners.Length; i++) {
            auto other = g_FidsPackOwners[i];
            if (other.pack is pack || path.StartsWith(other.path + "/") || other.path.StartsWith(path + "/"))
                return MakeError("Pack identity or mount namespace is already tracked", "MOUNT_COLLISION");
        }
        string parentPath, fileName;
        FidsPackSplitPath(path, parentPath, fileName);
        auto existing = Fids::GetFidsFolder(parent, fileName);
        if (existing !is null && (existing.Leaves.Length != 0 || existing.Trees.Length != 0))
            return MakeError("Pack mount folder must be absent or completely empty", "MOUNT_COLLISION");
        @owner = FidsPackOwner();
        owner.path = path; owner.parentPath = parentPath; owner.fileName = fileName;
        owner.Retain(pack, parent);
        // Reserve capacity/reference before invoking the public method. There
        // are no yields; an exception cannot strand an untracked retained nod.
        g_FidsPackOwners.InsertLast(owner);
        bool failed = false;
        try { pack.UiInstallFidsInSubFolder(); } catch { failed = true; }
        if (FidsPackTargetMatches(owner)) owner.CaptureMount(pack.Location);
        auto output = FidsPackSnapshot(action, path, pack, owner, true);
        bool exact = FidsPackOwnedExact(owner);
        if (!exact) {
            output["tracked"] = false;
            output["state"] = pack.Location is null ? "unmounted" : "foreign";
            output["ownerCount"] = g_FidsPackOwners.Length - 1;
            FidsPackForget(g_FidsPackOwners.Length - 1);
        }
        return FidsPackOutcome(output, failed ? "PACK_CALL_FAILED" : (exact ? "" : "MOUNT_UNVERIFIED"));
    }

    // ControlFids must dispatch raw input here BEFORE FidsNormPath or other
    // generic FID resolution. Its server coroutine already supplies containment.
    Json::Value@ FidsPackDispatch(Json::Value &in input, const string &in action) {
        try { return FidsPackRun(input, action); }
        catch { return MakeError("Pack operation could not safely inspect public state", "PACK_ACCESS_FAILED"); }
    }
    Json::Value@ FidsActionPackStatus(Json::Value &in input) { return FidsPackDispatch(input, "packStatus"); }
    Json::Value@ FidsActionMountPack(Json::Value &in input) { return FidsPackDispatch(input, "mountPack"); }
    Json::Value@ FidsActionUnmountPack(Json::Value &in input) { return FidsPackDispatch(input, "unmountPack"); }

    void FidsPacksShutdown() {
        // On unload/disable there is no coroutine or yield. In a driving/loading
        // session leave mounts alone; new instances must treat leftovers as
        // foreign. Never unmount a guessed/replaced location or reacquire a FID.
        while (g_FidsPackOwners.Length > 0) {
            auto owner = g_FidsPackOwners[g_FidsPackOwners.Length - 1];
            try {
                if (DetectGameModeName() == "Menu" && FidsPackOwnedExact(owner)) owner.pack.UninstallAndDeleteFids();
            } catch { }
            FidsPackForget(g_FidsPackOwners.Length - 1);
        }
    }
}
