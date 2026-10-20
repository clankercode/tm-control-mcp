namespace TmMcp {
    // Openplanet Fids:: — the five game file drives and the operations on
    // CSystemFidFile / CSystemFidsFolder. Used internally by EditNewMap
    // (decoration preload + SwapDecoHack) and ListMapDecorations; this tool
    // is the general surface.
    //
    // Documented API (Openplanet 1.29 OpenplanetCore.json): Get{Drive},
    // Get{Drive}Folder, Preload, Extract, GetFullPath, UpdateTree,
    // GetFidsFile, GetFidsFolder. GetFidFromNod is a global.

    const int FIDS_LIST_DEFAULT = 80;
    const int FIDS_LIST_MAX = 400;

    string FidsNormAction(const string &in raw) {
        string a = raw.ToLower().Replace("_", "").Replace("-", "");
        if (a == "updatetree") return "updateTree";
        if (a == "getfullpath" || a == "fullpath") return "getFullPath";
        if (a == "fromnod" || a == "from") return "fromNod";
        if (a == "stat") return "get";
        if (a == "ls") return "list";
        if (a == "load") return "preload";
        if (a == "packstatus") return "packStatus";
        if (a == "mountpack") return "mountPack";
        if (a == "unmountpack") return "unmountPack";
        if (a == "gettext" || a == "readtext") return "getText";
        if (a == "settext" || a == "writetext" || a == "patchtext") return "setText";
        return a;
    }

    string FidsNormDrive(const string &in raw) {
        string d = raw.ToLower();
        if (d == "game") return "game";
        if (d == "user") return "user";
        if (d == "fake") return "fake";
        if (d == "resource" || d == "resources") return "resource";
        if (d == "programdata" || d == "progdata" || d == "pd") return "programData";
        return "";
    }

    string FidsNormPath(const string &in raw) {
        string p = raw.Replace("\\", "/");
        while (p.StartsWith("/")) p = p.SubStr(1);
        while (p.EndsWith("/") && p.Length > 1) p = p.SubStr(0, p.Length - 1);
        if (p == "/") p = "";
        return p;
    }

    CSystemFidFile@ FidsGetFile(const string &in drive, const string &in path) {
        if (drive == "game") return Fids::GetGame(path);
        if (drive == "user") return Fids::GetUser(path);
        if (drive == "fake") return Fids::GetFake(path);
        if (drive == "resource") return Fids::GetResource(path);
        if (drive == "programData") return Fids::GetProgramData(path);
        return null;
    }

    CSystemFidsFolder@ FidsGetFolder(const string &in drive, const string &in path) {
        if (drive == "game") return Fids::GetGameFolder(path);
        if (drive == "user") return Fids::GetUserFolder(path);
        if (drive == "fake") return Fids::GetFakeFolder(path);
        if (drive == "resource") return Fids::GetResourceFolder(path);
        if (drive == "programData") return Fids::GetProgramDataFolder(path);
        return null;
    }

    bool FidsNeedDrive(const string &in inputDrive, string &out drive, string &out err) {
        if (inputDrive.Length == 0) {
            err = "drive required (game|user|fake|resource|programData)";
            return false;
        }
        drive = FidsNormDrive(inputDrive);
        if (drive.Length == 0) {
            err = "unknown drive '" + inputDrive + "' (expected game|user|fake|resource|programData)";
            return false;
        }
        return true;
    }

    void FidsLocation(CSystemFidsFolder@ start, const string &in fileName, string &out drive, string &out path) {
        drive = "";
        path = "";
        if (start is null) {
            path = fileName;
            return;
        }
        array<string> parts;
        CSystemFidsFolder@ cur = start;
        while (cur !is null && cur.ParentFolder !is null) {
            string name = string(cur.DirName);
            if (name.Length > 0) parts.InsertLast(name);
            @cur = cur.ParentFolder;
        }
        string[] names = { "game", "user", "fake", "resource", "programData" };
        for (uint i = 0; i < names.Length; i++) {
            auto root = FidsGetFolder(names[i], "");
            if (root !is null && cur is root) {
                drive = names[i];
                break;
            }
        }
        for (int i = int(parts.Length) - 1; i >= 0; i--) {
            if (path.Length > 0) path += "/";
            path += parts[i];
        }
        if (fileName.Length > 0) {
            if (path.Length > 0) path += "/";
            path += fileName;
        }
    }

    void FidsStampLocation(Json::Value@ o, CSystemFidsFolder@ folder, const string &in fileName) {
        if (o is null) return;
        string drive = "";
        string path = "";
        FidsLocation(folder, fileName, drive, path);
        if (drive.Length > 0) o["drive"] = drive;
        o["path"] = path;
    }

    // Scratch page interpreted as a nod so we can SetOffset/GetOffsetNod a
    // raw pointer. Same trick as Dev_GetArbitraryNodAt in sibling plugins;
    // Openplanet has no GetNodFromPointer. 64 bytes, plugin lifetime.
    uint64 g_FidsScratch = 0;
    CMwNod@ g_FidsScratchAsNod = null;

    bool FidsEnsureScratch() {
        if (g_FidsScratchAsNod !is null) return true;
        g_FidsScratch = Dev::Allocate(0x40, false);
        if (g_FidsScratch == 0) return false;
        auto host = CMwNod();
        uint64 saved = Dev::GetOffsetUint64(host, 0);
        Dev::SetOffset(host, 0, g_FidsScratch);
        @g_FidsScratchAsNod = Dev::GetOffsetNod(host, 0);
        Dev::SetOffset(host, 0, saved);
        return g_FidsScratchAsNod !is null;
    }

    bool FidsPtrPlausible(uint64 ptr) {
        if (ptr == 0) return false;
        if ((ptr & 7) != 0) return false;
        if (ptr < 0x10000) return false;
        uint64 top = ptr >> 48;
        if (top != 0 && top != 0xFFFF) return false;
        // Readable 8+4 is not enough: vis+0x20 can be 0x3F80000000000001
        // (float 1.0). The high dword 0x3F800000 is 8-aligned and mapped;
        // wrapping it as a nod AVs Openplanet (LogCrash_EA180000000CBBE0).
        // A real CMwNod vtable lives in the game image.
        try {
            uint64 vt = Dev::SafeReadUInt64(ptr);
            Dev::SafeReadUInt32(ptr + 8);
            uint64 base = Dev::BaseAddress();
            if (vt < base || vt >= base + 0x3000000) return false;
            return true;
        } catch {
            return false;
        }
    }

    uint64 FidsPointerOfNod(CMwNod@ nod) {
        if (nod is null || !FidsEnsureScratch()) return 0;
        Dev::SetOffset(g_FidsScratchAsNod, 0, nod);
        return Dev::GetOffsetUint64(g_FidsScratchAsNod, 0);
    }

    CMwNod@ FidsNodFromPtr(uint64 ptr) {
        if (!FidsPtrPlausible(ptr) || !FidsEnsureScratch()) return null;
        Dev::SetOffset(g_FidsScratchAsNod, 0, ptr);
        CMwNod@ nod = null;
        try {
            @nod = Dev::GetOffsetNod(g_FidsScratchAsNod, 0);
        } catch {
            return null;
        }
        return nod;
    }

    Json::Value FidsNodBrief(CMwNod@ nod) {
        Json::Value o = Json::Object();
        o["loaded"] = nod !is null;
        if (nod is null) return o;
        o["idName"] = string(nod.IdName);
        uint64 ptr = FidsPointerOfNod(nod);
        if (ptr != 0) o["ptr"] = PtrToHex(ptr);
        auto ty = Reflection::TypeOf(nod);
        if (ty !is null) {
            o["className"] = string(ty.Name);
            o["classId"] = int(ty.ID);
            o["classIdHex"] = TypeInfoHex32(ty.ID);
        }
        return o;
    }

    Json::Value FidsFileJson(CSystemFidFile@ fid, bool includeNod) {
        Json::Value o = Json::Object();
        o["kind"] = "file";
        if (fid is null) return o;
        o["fileName"] = string(fid.FileName);
        o["shortFileName"] = string(fid.ShortFileName);
        o["fullFileName"] = string(fid.FullFileName);
        o["byteSize"] = int(fid.ByteSize);
        o["compressed"] = fid.Compressed;
        o["text"] = fid.Text;
        o["isReadOnly"] = fid.IsReadOnly;
        string tw = string(fid.TimeWrite);
        if (tw.Length > 0) o["timeWrite"] = tw;
        if (fid.ParentFolder !is null) o["parentDirName"] = string(fid.ParentFolder.DirName);
        if (fid.Container !is null) o["containerFileName"] = string(fid.Container.FileName);
        string full = Fids::GetFullPath(fid);
        if (full.Length > 0) o["fullPath"] = full;
        o["existsOnDisk"] = fid.OSCheckIfExists();
        o["nodLoaded"] = fid.Nod !is null;
        FidsStampLocation(o, fid.ParentFolder, string(fid.FileName));
        if (includeNod) o["nod"] = FidsNodBrief(fid.Nod);
        return o;
    }

    Json::Value FidsFolderJson(CSystemFidsFolder@ folder, bool includeCounts) {
        Json::Value o = Json::Object();
        o["kind"] = "folder";
        if (folder is null) return o;
        o["dirName"] = string(folder.DirName);
        o["fullDirName"] = string(folder.FullDirName);
        o["byteSize"] = int(folder.ByteSize);
        if (folder.ParentFolder !is null) o["parentDirName"] = string(folder.ParentFolder.DirName);
        if (includeCounts) {
            o["childFolderCount"] = int(folder.Trees.Length);
            o["childFileCount"] = int(folder.Leaves.Length);
        }
        FidsStampLocation(o, folder, "");
        return o;
    }

    bool FidsNameMatches(const string &in name, const string &in queryLower) {
        if (queryLower.Length == 0) return true;
        return name.ToLower().Contains(queryLower);
    }

    bool FidsDestOk(const string &in dest, string &out err) {
        if (dest.Length == 0) {
            err = "empty dest";
            return false;
        }
        if (dest.Contains("..")) {
            err = "dest must not contain ..";
            return false;
        }
        if (dest.Contains(":") || dest.StartsWith("/") || dest.StartsWith("\\")) {
            err = "dest must be a relative filename (CSystemFidFile.CopyToFileRelative)";
            return false;
        }
        return true;
    }

    int FidsClampLimit(Json::Value &in input) {
        int limit = FIDS_LIST_DEFAULT;
        if (input.HasKey("limit")) limit = int(input["limit"]);
        if (limit < 1) limit = 1;
        if (limit > FIDS_LIST_MAX) limit = FIDS_LIST_MAX;
        return limit;
    }

    Json::Value@ FidsBadDriveOrPath(Json::Value &in input, string &out drive, string &out path) {
        drive = "";
        path = "";
        string err = "";
        string rawDrive = input.HasKey("drive") ? string(input["drive"]) : "";
        if (!FidsNeedDrive(rawDrive, drive, err)) {
            return MakeError(err, "BAD_DRIVE", false, "", "game|user|fake|resource|programData");
        }
        path = input.HasKey("path") ? FidsNormPath(string(input["path"])) : "";
        return null;
    }

    Json::Value@ FidsActionDrives() {
        string[] names = { "game", "user", "fake", "resource", "programData" };
        Json::Value output = Json::Object();
        output["action"] = "drives";
        Json::Value arr = Json::Array();
        for (uint i = 0; i < names.Length; i++) {
            auto root = FidsGetFolder(names[i], "");
            Json::Value d = FidsFolderJson(root, true);
            d["drive"] = names[i];
            d["found"] = root !is null;
            arr.Add(d);
        }
        output["drives"] = arr;
        return MakeSuccess(output);
    }

    Json::Value@ FidsResolveForGet(const string &in drive, const string &in path, const string &in kind, CSystemFidFile@ &out file, CSystemFidsFolder@ &out folder) {
        @file = null;
        @folder = null;
        string k = kind.ToLower();
        if (k == "auto" || k.Length == 0) {
            if (path.Length == 0) k = "folder";
            else k = "auto";
        }
        if (k == "file") {
            @file = FidsGetFile(drive, path);
            if (file is null) {
                return MakeError("fid file not found: " + drive + ":" + path, "NOT_FOUND", false, "",
                    "Use action=list on the parent folder; drive-relative path, e.g. GameData/Stadium/...");
            }
            return null;
        }
        if (k == "folder") {
            @folder = FidsGetFolder(drive, path);
            if (folder is null) {
                return MakeError("fid folder not found: " + drive + ":" + path, "NOT_FOUND", false, "",
                    "Empty path is the drive root. action=drives lists roots.");
            }
            return null;
        }
        @file = FidsGetFile(drive, path);
        if (file !is null) return null;
        @folder = FidsGetFolder(drive, path);
        if (folder !is null) return null;
        return MakeError("fid not found: " + drive + ":" + path, "NOT_FOUND", false, "",
            "Tried file then folder. action=list / action=drives to browse.");
    }

    Json::Value@ FidsNeedFile(Json::Value &in input, const string &in action, CSystemFidFile@ &out file) {
        @file = null;
        string drive = "";
        string path = "";
        Json::Value@ bad = FidsBadDriveOrPath(input, drive, path);
        if (bad !is null) return bad;
        if (path.Length == 0) {
            return MakeError("path required for " + action, "BAD_PATH", false, "",
                "Drive-relative file path, e.g. GameData/Stadium/GameCtnDecoration/Base48x48Screen155Day.Decoration.Gbx");
        }
        @file = FidsGetFile(drive, path);
        if (file is null) {
            return MakeError("fid file not found: " + drive + ":" + path, "NOT_FOUND", false, "",
                "UpdateTree the parent if the file is new on disk.");
        }
        return null;
    }

    Json::Value@ FidsActionGet(Json::Value &in input) {
        string drive = "";
        string path = "";
        Json::Value@ bad = FidsBadDriveOrPath(input, drive, path);
        if (bad !is null) return bad;
        string kind = input.HasKey("kind") ? string(input["kind"]) : "auto";
        CSystemFidFile@ file;
        CSystemFidsFolder@ folder;
        Json::Value@ miss = FidsResolveForGet(drive, path, kind, file, folder);
        if (miss !is null) return miss;
        bool includeNod = input.HasKey("includeNod") && bool(input["includeNod"]);
        Json::Value output = Json::Object();
        output["action"] = "get";
        output["drive"] = drive;
        output["path"] = path;
        if (file !is null) {
            output["fid"] = FidsFileJson(file, includeNod);
        } else {
            output["fid"] = FidsFolderJson(folder, true);
        }
        return MakeSuccess(output);
    }

    Json::Value@ FidsActionList(Json::Value &in input) {
        string drive = "";
        string path = "";
        Json::Value@ bad = FidsBadDriveOrPath(input, drive, path);
        if (bad !is null) return bad;
        auto folder = FidsGetFolder(drive, path);
        if (folder is null) {
            return MakeError("fid folder not found: " + drive + ":" + path, "NOT_FOUND", false, "",
                "Empty path is the drive root. action=drives lists roots.");
        }
        string kind = input.HasKey("kind") ? string(input["kind"]).ToLower() : "";
        bool wantFolders = false;
        bool wantFiles = false;
        if (kind.Length == 0 || kind == "all" || kind == "auto") {
            wantFolders = true;
            wantFiles = true;
        } else if (kind == "folder" || kind == "folders") {
            wantFolders = true;
        } else if (kind == "file" || kind == "files") {
            wantFiles = true;
        } else {
            return MakeError("unknown kind '" + kind + "' (expected file|folder|auto)", "BAD_KIND", false, "",
                "list treats auto/omitted as both folders and files.");
        }
        string queryLower = input.HasKey("query") ? string(input["query"]).ToLower() : "";
        int limit = FidsClampLimit(input);
        int offset = input.HasKey("offset") ? int(input["offset"]) : 0;
        if (offset < 0) offset = 0;
        bool includeNod = input.HasKey("includeNod") && bool(input["includeNod"]);

        Json::Value entries = Json::Array();
        int matched = 0;
        int skipped = 0;

        if (wantFolders) {
            for (uint i = 0; i < folder.Trees.Length; i++) {
                auto child = folder.Trees[i];
                if (child is null) continue;
                if (!FidsNameMatches(string(child.DirName), queryLower)) continue;
                matched++;
                if (skipped < offset) { skipped++; continue; }
                if (int(entries.Length) >= limit) continue;
                entries.Add(FidsFolderJson(child, true));
            }
        }
        if (wantFiles) {
            for (uint i = 0; i < folder.Leaves.Length; i++) {
                auto leaf = folder.Leaves[i];
                if (leaf is null) continue;
                if (!FidsNameMatches(string(leaf.FileName), queryLower)
                    && !FidsNameMatches(string(leaf.ShortFileName), queryLower)) continue;
                matched++;
                if (skipped < offset) { skipped++; continue; }
                if (int(entries.Length) >= limit) continue;
                entries.Add(FidsFileJson(leaf, includeNod));
            }
        }

        Json::Value output = Json::Object();
        output["action"] = "list";
        output["drive"] = drive;
        output["path"] = path;
        output["folder"] = FidsFolderJson(folder, true);
        output["entries"] = entries;
        output["matched"] = matched;
        output["returned"] = int(entries.Length);
        output["offset"] = offset;
        output["limit"] = limit;
        output["truncated"] = matched > offset + int(entries.Length);
        return MakeSuccess(output);
    }

    Json::Value@ FidsActionPreload(Json::Value &in input) {
        CSystemFidFile@ file;
        Json::Value@ miss = FidsNeedFile(input, "preload", file);
        if (miss !is null) return miss;
        bool already = file.Nod !is null;
        CMwNod@ nod = null;
        try {
            @nod = Fids::Preload(file);
        } catch {
            return MakeError("Preload threw: " + getExceptionInfo(), "PRELOAD_FAILED", true, "",
                "Some fids are not preloadable (missing pack, wrong type).");
        }
        if (nod is null && file.Nod !is null) @nod = file.Nod;
        Json::Value output = Json::Object();
        output["action"] = "preload";
        output["alreadyLoaded"] = already;
        output["fid"] = FidsFileJson(file, true);
        output["nod"] = FidsNodBrief(nod);
        if (nod is null) {
            Json::Value@ fail = MakeError("Preload returned null", "PRELOAD_FAILED", true, "",
                "Fid exists but the nod did not load. Check fullFileName / container.");
            fail["output"] = output;
            return fail;
        }
        return MakeSuccess(output);
    }

    Json::Value@ FidsActionUpdateTree(Json::Value &in input) {
        string drive = "";
        string path = "";
        Json::Value@ bad = FidsBadDriveOrPath(input, drive, path);
        if (bad !is null) return bad;
        bool force = input.HasKey("force") && bool(input["force"]);
        if (drive == "game" && path.Length == 0 && !force) {
            return MakeError(
                "refusing UpdateTree on the entire game drive (very slow). Pass a subfolder or force:true.",
                "TREE_TOO_BROAD",
                false,
                "",
                "e.g. path='GameData/Stadium' or path='Items'"
            );
        }
        auto folder = FidsGetFolder(drive, path);
        if (folder is null) {
            return MakeError("fid folder not found: " + drive + ":" + path, "NOT_FOUND");
        }
        bool withFiles = !(input.HasKey("withFiles") && !bool(input["withFiles"]));
        uint beforeFolders = folder.Trees.Length;
        uint beforeFiles = folder.Leaves.Length;
        Fids::UpdateTree(folder, withFiles);
        Json::Value output = Json::Object();
        output["action"] = "updateTree";
        output["drive"] = drive;
        output["path"] = path;
        output["withFiles"] = withFiles;
        output["folder"] = FidsFolderJson(folder, true);
        output["beforeChildFolderCount"] = int(beforeFolders);
        output["beforeChildFileCount"] = int(beforeFiles);
        output["childFolderDelta"] = int(folder.Trees.Length) - int(beforeFolders);
        output["childFileDelta"] = int(folder.Leaves.Length) - int(beforeFiles);
        return MakeSuccess(output);
    }

    Json::Value@ FidsActionExtract(Json::Value &in input) {
        CSystemFidFile@ file;
        Json::Value@ miss = FidsNeedFile(input, "extract", file);
        if (miss !is null) return miss;
        string dest = input.HasKey("dest") ? string(input["dest"]) : "";
        bool hookMethod = input.HasKey("hookMethod") && bool(input["hookMethod"]);
        bool failIfExists = !(input.HasKey("failIfExists") && !bool(input["failIfExists"]));
        bool extracted = false;
        string method = "Extract";
        if (dest.Length > 0) {
            string destErr = "";
            if (!FidsDestOk(dest, destErr)) {
                return MakeError(destErr, "BAD_DEST", false, "",
                    "Relative filename only, no .. or absolute paths.");
            }
            method = "CopyToFileRelative";
            try {
                file.CopyToFileRelative(dest, failIfExists);
                extracted = true;
            } catch {
                return MakeError("CopyToFileRelative threw: " + getExceptionInfo(), "EXTRACT_FAILED", true, "",
                    "failIfExists=" + (failIfExists ? "true" : "false") + "; dest='" + dest + "'");
            }
        } else {
            try {
                extracted = Fids::Extract(file, hookMethod);
            } catch {
                return MakeError("Extract threw: " + getExceptionInfo(), "EXTRACT_FAILED", true, "",
                    "hookMethod defaults false; leave it off.");
            }
        }
        bool doUpdate = dest.Length > 0 || (input.HasKey("updateTree") && bool(input["updateTree"]));
        if (doUpdate && file.ParentFolder !is null) {
            Fids::UpdateTree(file.ParentFolder, true);
        }
        Json::Value output = Json::Object();
        output["action"] = "extract";
        output["method"] = method;
        output["extracted"] = extracted;
        if (method == "Extract") output["hookMethod"] = hookMethod;
        if (dest.Length > 0) output["dest"] = dest;
        output["fid"] = FidsFileJson(file, false);
        output["existsOnDisk"] = file.OSCheckIfExists();
        if (dest.Length > 0 && file.ParentFolder !is null) {
            auto destFid = Fids::GetFidsFile(file.ParentFolder, dest);
            if (destFid !is null) {
                output["destFid"] = FidsFileJson(destFid, false);
                output["existsOnDisk"] = destFid.OSCheckIfExists();
            }
        }
        if (!extracted && dest.Length == 0) {
            Json::Value@ fail = MakeError("Extract returned false", "EXTRACT_FAILED", true, "",
                "Packed/zipped fids usually extract next to the pack; check destFid / existsOnDisk.");
            fail["output"] = output;
            return fail;
        }
        return MakeSuccess(output);
    }

    Json::Value@ FidsActionGetFullPath(Json::Value &in input) {
        CSystemFidFile@ file;
        Json::Value@ miss = FidsNeedFile(input, "getFullPath", file);
        if (miss !is null) return miss;
        Json::Value output = Json::Object();
        output["action"] = "getFullPath";
        output["fullPath"] = Fids::GetFullPath(file);
        output["fid"] = FidsFileJson(file, false);
        return MakeSuccess(output);
    }

    Json::Value@ FidsActionFromNod(Json::Value &in input) {
        uint64 ptr = 0;
        bool have = false;
        if (input.HasKey("from_ptr")) have = TryParsePtr(input["from_ptr"], ptr);
        else if (input.HasKey("fromPtr")) have = TryParsePtr(input["fromPtr"], ptr);
        if (!have) {
            return MakeError(
                "from_ptr required for fromNod",
                "BAD_PTR",
                false,
                "",
                "Hex string (0x...) or integer nod pointer from preload/get includeNod, or another tool. from=app|editor|challenge was removed."
            );
        }
        if (ptr == 0) {
            return MakeError("from_ptr is null", "BAD_PTR");
        }
        Json::Value output = Json::Object();
        output["action"] = "fromNod";
        output["from_ptr"] = PtrToHex(ptr);
        if (!FidsPtrPlausible(ptr)) {
            return MakeError(
                "from_ptr is not a plausible nod address",
                "BAD_PTR",
                false,
                "",
                "Need an 8-byte-aligned readable pointer (vtable + refcount). Garbage pointers are refused rather than wrapped."
            );
        }
        CMwNod@ nod = FidsNodFromPtr(ptr);
        if (nod is null) {
            return MakeError("could not wrap from_ptr as a nod", "BAD_PTR", true, "",
                "Pointer passed the probe but GetOffsetNod returned null.");
        }
        output["nod"] = FidsNodBrief(nod);
        CSystemFidFile@ fid = null;
        try {
            @fid = GetFidFromNod(nod);
        } catch {
            return MakeError("GetFidFromNod threw: " + getExceptionInfo(), "NO_FID", true);
        }
        output["hasFid"] = fid !is null;
        if (fid is null) {
            Json::Value@ fail = MakeError("GetFidFromNod returned null", "NO_FID", false, "",
                "Not every live nod is backed by a fid (in-memory-only objects).");
            fail["output"] = output;
            return fail;
        }
        bool includeNod = !(input.HasKey("includeNod") && !bool(input["includeNod"]));
        output["fid"] = FidsFileJson(fid, includeNod);
        return MakeSuccess(output);
    }

    const int FIDS_TEXT_SLICE_DEFAULT = 2048;
    const int FIDS_TEXT_SLICE_MAX = 65536;
    const int FIDS_TEXT_FIND_CTX_DEFAULT = 120;
    const int FIDS_TEXT_FIND_MAX_HITS = 20;

    CPlugFileTextScript@ FidsNeedTextScript(CSystemFidFile@ file, string &out err) {
        err = "";
        if (file is null) { err = "fid is null"; return null; }
        CMwNod@ nod = file.Nod;
        if (nod is null) {
            try { @nod = Fids::Preload(file); } catch {
                err = "Preload threw: " + getExceptionInfo();
                return null;
            }
        }
        if (nod is null) { err = "preload returned null"; return null; }
        auto script = cast<CPlugFileTextScript>(nod);
        if (script is null) {
            auto ty = Reflection::TypeOf(nod);
            err = "nod is not CPlugFileTextScript (got " + (ty is null ? "?" : string(ty.Name)) + ")";
            return null;
        }
        return script;
    }

    Json::Value FidsTextGrep(const string &in src, const string &in needle, int ctx, int maxHits, bool caseInsensitive) {
        Json::Value hits = Json::Array();
        if (needle.Length == 0) return hits;
        string hay = caseInsensitive ? src.ToLower() : src;
        string need = caseInsensitive ? needle.ToLower() : needle;
        int pos = 0;
        int count = 0;
        while (count < maxHits) {
            string tail = hay.SubStr(uint(pos));
            int rel = tail.IndexOf(need);
            if (rel < 0) break;
            int abs = pos + rel;
            int start = abs - ctx; if (start < 0) start = 0;
            int endRaw = abs + int(needle.Length) + ctx;
            if (endRaw > int(src.Length)) endRaw = int(src.Length);
            Json::Value h = Json::Object();
            h["offset"] = abs;
            h["snippet"] = src.SubStr(uint(start), uint(endRaw - start));
            hits.Add(h);
            pos = abs + int(needle.Length);
            count++;
        }
        return hits;
    }

    Json::Value@ FidsActionGetText(Json::Value &in input) {
        CSystemFidFile@ file;
        Json::Value@ miss = FidsNeedFile(input, "getText", file);
        if (miss !is null) return miss;
        string err;
        auto script = FidsNeedTextScript(file, err);
        if (script is null) return MakeError(err, "NOT_TEXT_SCRIPT");
        string src = "";
        try { src = script.Text; } catch {
            return MakeError("CPlugFileTextScript.Text threw: " + getExceptionInfo(), "TEXT_READ_FAILED", true);
        }
        Json::Value output = Json::Object();
        output["action"] = "getText";
        output["fid"] = FidsFileJson(file, true);
        output["textLength"] = int(src.Length);

        if (input.HasKey("find")) {
            string needle = string(input["find"]);
            int ctx = input.HasKey("context") ? int(input["context"]) : FIDS_TEXT_FIND_CTX_DEFAULT;
            if (ctx < 0) ctx = 0;
            if (ctx > 1024) ctx = 1024;
            int maxHits = input.HasKey("maxHits") ? int(input["maxHits"]) : FIDS_TEXT_FIND_MAX_HITS;
            if (maxHits < 1) maxHits = 1;
            if (maxHits > 64) maxHits = 64;
            bool caseInsensitive = input.HasKey("caseInsensitive") && bool(input["caseInsensitive"]);
            auto hits = FidsTextGrep(src, needle, ctx, maxHits, caseInsensitive);
            output["find"] = needle;
            output["hits"] = hits;
            output["count"] = int(hits.Length);
            return MakeSuccess(output);
        }

        int offset = input.HasKey("offset") ? int(input["offset"]) : 0;
        int length = input.HasKey("length") ? int(input["length"]) : FIDS_TEXT_SLICE_DEFAULT;
        if (offset < 0) offset = 0;
        if (offset > int(src.Length)) offset = int(src.Length);
        if (length < 0) length = 0;
        if (length > FIDS_TEXT_SLICE_MAX) length = FIDS_TEXT_SLICE_MAX;
        int endRaw = offset + length;
        if (endRaw > int(src.Length)) endRaw = int(src.Length);
        output["offset"] = offset;
        output["slice"] = src.SubStr(uint(offset), uint(endRaw - offset));
        return MakeSuccess(output);
    }

    Json::Value@ ControlFids(Json::Value &in input) {
        string raw = input.HasKey("action") ? string(input["action"]) : "";
        if (raw.Length == 0) {
            return MakeError(
                "action required",
                "BAD_ACTION",
                false,
                "",
                "drives|get|list|preload|updateTree|extract|getFullPath|fromNod|getText|setText|packStatus|mountPack|unmountPack"
            );
        }
        string action = FidsNormAction(raw);
        if (action == "packStatus") return FidsActionPackStatus(input);
        if (action == "mountPack") return FidsActionMountPack(input);
        if (action == "unmountPack") return FidsActionUnmountPack(input);
        if (action == "drives") return FidsActionDrives();
        if (action == "get") return FidsActionGet(input);
        if (action == "list") return FidsActionList(input);
        if (action == "preload") return FidsActionPreload(input);
        if (action == "updateTree") return FidsActionUpdateTree(input);
        if (action == "extract") return FidsActionExtract(input);
        if (action == "getFullPath") return FidsActionGetFullPath(input);
        if (action == "fromNod") return FidsActionFromNod(input);
        if (action == "getText") return FidsActionGetText(input);
        if (action == "setText") return FidsActionSetText(input);
        return MakeError(
            "unknown action '" + raw + "' (expected drives|get|list|preload|updateTree|extract|getFullPath|fromNod|getText|setText|packStatus|mountPack|unmountPack)",
            "BAD_ACTION"
        );
    }
    // Member offset by reflection (E++ Dev.as pattern).
    uint16 FidsMemberOffset(CMwNod@ obj, const string &in memberName) {
        if (obj is null) throw("null nod for member " + memberName);
        auto ty = Reflection::TypeOf(obj);
        if (ty is null) throw("could not find a type for object");
        auto memberTy = ty.GetMember(memberName);
        if (memberTy is null) throw(ty.Name + " does not have a member called " + memberName);
        if (memberTy.Offset == 0xFFFF) throw("invalid offset for " + memberName);
        return memberTy.Offset;
    }

    // Scan .Item.Gbx leaves of a fid folder for prefab ents whose Model is an
    // NPlugDyna_SKinematicConstraint, and dump each KC's Trans/Rot anim funcs
    // plus the ShaderTc (TransSubTexture) state. Read-only; Fids::Preload
    // resolves pack-backed items (default GameData/Stadium/Items).
    Json::Value@ ScanKinematicItems(Json::Value &in input) {
        string rawDrive = input.HasKey("drive") ? string(input["drive"]) : "game";
        string drive = "";
        string err = "";
        if (!FidsNeedDrive(rawDrive, drive, err)) return MakeError(err, "BAD_DRIVE");
        string path = FidsNormPath(input.HasKey("path") ? string(input["path"]) : "GameData/Stadium/Items");
        string query = input.HasKey("query") ? string(input["query"]).ToLower() : "";
        int limit = input.HasKey("limit") ? int(input["limit"]) : 200;
        if (limit < 1) limit = 1;
        if (limit > 1000) limit = 1000;
        int offset = input.HasKey("offset") ? int(input["offset"]) : 0;
        if (offset < 0) offset = 0;
        bool includeWithoutKc = input.HasKey("includeWithoutKc") && bool(input["includeWithoutKc"]);
        bool includeEnts = input.HasKey("includeEnts") && bool(input["includeEnts"]);

        auto folder = FidsGetFolder(drive, path);
        if (folder is null) return MakeError("folder not found: " + path, "NOT_FOUND");
        Json::Value output = Json::Object();
        output["path"] = path;
        Json::Value items = Json::Array();
        int scanned = 0;
        int withKc = 0;
        int skipped = 0;
        int failures = 0;
        for (uint i = 0; i < folder.Leaves.Length; i++) {
            auto leaf = folder.Leaves[i];
            if (leaf is null) continue;
            string fn = leaf.FileName;
            if (!fn.ToLower().EndsWith(".item.gbx")) continue;
            if (query.Length > 0 && fn.ToLower().IndexOf(query) < 0) continue;
            if (offset > 0) { offset--; continue; }
            if (scanned >= limit) break;
            scanned++;
            Json::Value itemEntry = Json::Object();
            itemEntry["fileName"] = fn;
            auto itemModel = cast<CGameItemModel>(Fids::Preload(leaf));
            if (itemModel is null) {
                failures++;
                itemEntry["error"] = "preload failed or not a CGameItemModel";
                items.Add(itemEntry);
                continue;
            }
            itemEntry["idName"] = string(itemModel.IdName);
            auto prefab = cast<CPlugPrefab>(itemModel.EntityModel);
            if (includeEnts && prefab !is null) {
                Json::Value ents = Json::Array();
                for (uint e = 0; e < prefab.Ents.Length; e++) {
                    auto model = prefab.Ents[e].Model;
                    Json::Value ent = Json::Object();
                    ent["modelClass"] = model is null ? "(null)" : Reflection::TypeOf(model).Name;
                    auto dyna = cast<CPlugDynaObjectModel>(model);
                    if (dyna !is null) {
                        Json::Value la = Json::Object();
                        la["isStatic"] = dyna.IsStatic;
                        la["dynamizeOnSpawn"] = dyna.DynamizeOnSpawn;
                        la["locAnimIsPhysical"] = dyna.LocAnimIsPhysical;
                        auto anim = dyna.LocAnim;
                        if (anim !is null) {
                            la["axis"] = anim.Axis;
                            la["rotPeriod"] = anim.RotPeriod;
                            la["rotPeriodMax"] = anim.RotPeriodMax;
                            la["rotAngle"] = anim.RotAngle;
                            la["rotFunc"] = tostring(anim.RotFunc);
                            la["transPeriod"] = anim.TransPeriod;
                            la["transPeriodMax"] = anim.TransPeriodMax;
                            la["transY"] = anim.TransY;
                            la["nightOnly"] = anim.NightOnly;
                        }
                        ent["dynaLocAnim"] = la;
                    }
                    ents.Add(ent);
                }
                itemEntry["entModelClasses"] = ents;
            }
            Json::Value kcs = Json::Array();
            if (prefab !is null) {
                for (uint e = 0; e < prefab.Ents.Length; e++) {
                    auto kc = cast<NPlugDyna_SKinematicConstraint>(prefab.Ents[e].Model);
                    if (kc is null) continue;
                    kcs.Add(KinematicConstraintToJson(kc));
                }
            }
            if (kcs.Length > 0) withKc++;
            else if (!includeWithoutKc) { skipped++; continue; }
            itemEntry["kcCount"] = int(kcs.Length);
            itemEntry["kcs"] = kcs;
            items.Add(itemEntry);
        }
        output["scanned"] = scanned;
        output["withKc"] = withKc;
        output["skippedNoKc"] = skipped;
        output["failures"] = failures;
        output["items"] = items;
        return MakeSuccess(output);
    }

    Json::Value KinematicConstraintToJson(NPlugDyna_SKinematicConstraint@ kc) {
        Json::Value o = Json::Object();
        uint64 ptr = FidsPointerOfNod(kc);
        if (ptr != 0) o["ptr"] = PtrToHex(ptr);
        o["shaderTcType"] = tostring(kc.ShaderTcType);
        o["shaderTcTypeInt"] = int(kc.ShaderTcType);
        Json::Value nat = Json::Object();
        uint16 natOff = FidsMemberOffset(kc, "ShaderTcAnimFunc");
        uint natLen = Dev::GetOffsetUint32(kc, natOff);
        nat["subFuncCount"] = natLen;
        Json::Value natKeys = Json::Array();
        uint natTotal = 0;
        for (uint k = 0; k < natLen && k < 12; k++) {
            uint sf = natOff + 0x4 + k * 0x8;
            uint dur = Dev::GetOffsetUint32(kc, sf);
            uint val = Dev::GetOffsetUint32(kc, sf + 0x4);
            natTotal += dur;
            Json::Value key = Json::Object();
            key["durationMs"] = dur;
            key["value"] = val;
            natKeys.Add(key);
        }
        nat["totalDurationMs"] = natTotal;
        nat["subFuncs"] = natKeys;
        o["shaderTcAnimFunc"] = nat;
        Json::Value transSub = Json::Object();
        uint16 tsOff = FidsMemberOffset(kc, "ShaderTcData_TransSub");
        transSub["nbSubTexture"] = Dev::GetOffsetUint32(kc, tsOff);
        transSub["nbSubTexturePerLine"] = Dev::GetOffsetUint32(kc, tsOff + 0x4);
        transSub["nbSubTexturePerColumn"] = Dev::GetOffsetUint32(kc, tsOff + 0x8);
        o["shaderTcDataTransSub"] = transSub;
        Json::Value trans = Json::Object();
        trans["axis"] = tostring(kc.TransAxis);
        trans["minM"] = kc.TransMin;
        trans["maxM"] = kc.TransMax;
        uint16 tOff = FidsMemberOffset(kc, "TransAnimFunc");
        uint tLen = Dev::GetOffsetUint32(kc, tOff);
        uint tTotal = 0;
        for (uint k = 0; k < tLen && k < 4; k++) tTotal += Dev::GetOffsetUint32(kc, tOff + 0x4 + k * 0x8 + 0x4);
        trans["subFuncCount"] = tLen;
        trans["totalDurationMs"] = tTotal;
        o["trans"] = trans;
        Json::Value rot = Json::Object();
        rot["axis"] = tostring(kc.RotAxis);
        rot["minDeg"] = kc.AngleMinDeg;
        rot["maxDeg"] = kc.AngleMaxDeg;
        uint16 rOff = FidsMemberOffset(kc, "RotAnimFunc");
        uint rLen = Dev::GetOffsetUint32(kc, rOff);
        uint rTotal = 0;
        for (uint k = 0; k < rLen && k < 4; k++) rTotal += Dev::GetOffsetUint32(kc, rOff + 0x4 + k * 0x8 + 0x4);
        rot["subFuncCount"] = rLen;
        rot["totalDurationMs"] = rTotal;
        o["rot"] = rot;
        return o;
    }
}
