"""Execute native registration policy with the stock AngelScript harness.

JSON/Meta are adapters, not Openplanet runtime proof. JSON assignment deliberately
shares child handles; round-trip cloning must explicitly detach them.
"""
from pathlib import Path
import subprocess
from as_json_mocks import JSON_MOCKS
from test_pack_updates import as_runner

ROOT = Path(__file__).resolve().parents[1]

MOCKS = JSON_MOCKS.replace('        void Add(const string &in value)', '''        void Add(Value@ value) { auto row = Value(); row = value; values.InsertLast(row); }
        void Add(const string &in value)''') + r'''
namespace Json {
    array<Value@> serialized;
    uint writes = 0;
    Value@ DeepCopy(Value@ value) {
        if (value is null) return null;
        auto copy = Value(); copy.kind = value.kind; copy.text = value.text;
        copy.flag = value.flag; copy.number = value.number; copy.keys = value.keys;
        for (uint i=0; i<value.values.Length; i++) copy.values.InsertLast(DeepCopy(value.values[i]));
        return copy;
    }
    string Write(Value@ value) {
        writes++; serialized.InsertLast(DeepCopy(value)); return "json-" + (serialized.Length - 1);
    }
    Value@ Parse(const string &in text) {
        for (uint i=0; i<serialized.Length; i++) if (text == "json-" + i) return DeepCopy(serialized[i]);
        Check(false, "malformed fixture JSON"); return null;
    }
}
namespace Math {
    double Floor(double v) { return double(int64(v)); }
    uint Min(uint a, uint b) { return a < b ? a : b; }
}
namespace Meta {
    class Plugin { string ID; bool Enabled = true; }
    array<Plugin@> plugins;
    Plugin@ caller;
    Plugin@ GetPluginFromID(const string &in id) {
        for (uint i=0; i<plugins.Length; i++) if (plugins[i].ID == id) return plugins[i];
        return null;
    }
    Plugin@ ExecutingPlugin() { return caller; }
}
void trace(const string &in) {}
void warn(const string &in) {}
string getExceptionInfo() { return "fixture exception"; }
namespace TmMcp {
    const uint UPDATE_URL_LIMIT = 1024;
    bool fixtureWorkerDead = false;
    bool IsPackGenerationRunning(const string &in generation) {
        if (fixtureWorkerDead) return false;
        for (uint i=0; i<g_Packs.Length; i++) if (g_Packs[i].generation == generation && g_Packs[i].running > 0) return true;
        for (uint i=0; i<g_RetiredPacks.Length; i++) if (g_RetiredPacks[i].generation == generation && g_RetiredPacks[i].running > 0) return true;
        return false;
    }
    uint64 revision = 1;
    Meta::Plugin@ SelfPlugin() { return Meta::GetPluginFromID("host"); }
    void InvalidateToolList() { revision++; }
    Json::Value@ CloneJsonValue(Json::Value@ value) { return Json::Parse(Json::Write(value)); }
    string PackUpdateUrlError(const string &in) { return ""; }
    void AppendPackUpdateStatus(Json::Value@, const string &in, const string &in) {}
    Json::Value@ BridgeUpdateStatus() { return Json::Object(); }
    Json::Value@ GetToolList() { auto tools = Json::Array(); AppendPackTools(tools); return tools; }
    Json::Value@ MakeSuccess(Json::Value &in output) {
        auto value = Json::Object(); value["success"] = true; value["output"] = output; return value;
    }
    Json::Value@ MakeError(const string &in message, const string &in code, bool retryable=false) {
        auto value = Json::Object(); value["success"] = false; value["error"] = message; value["code"] = code; return value;
    }
}
Json::Value@ Dispatch(const string &in, Json::Value &in input) { return TmMcp::MakeSuccess(input); }
void Caller(const string &in id) {
    auto plugin = Meta::GetPluginFromID(id);
    if (plugin is null) { @plugin = Meta::Plugin(); plugin.ID=id; Meta::plugins.InsertLast(plugin); }
    @Meta::caller=plugin;
}
Json::Value@ Schema() {
    auto value=Json::Object(); value["type"]="object";
    value["properties"]=Json::Object(); value["additionalProperties"]=false; return value;
}
TmMcp::ToolPackBuilder@ Builder(const string &in id, const string &in name="Ping", const string &in description="initial") {
    auto b=TmMcp::ToolPackBuilder(id); b.AddTool(name,description,Json::Write(Schema())); b.SetDispatch(Dispatch); return b;
}
void Good(Json::Value@ value) { Check(value !is null && bool(value["success"]), "operation succeeds"); }
void Error(Json::Value@ value, const string &in code) {
    Check(value !is null && !bool(value["success"]) && string(value["code"])==code, "error " + code);
}
'''


def run_native(as_runner, tmp_path, body, cache=False):
    mocks = MOCKS
    catalog = ""
    if cache:
        mocks = mocks.replace('    void InvalidateToolList() { revision++; }', '')
        mocks = mocks.replace('    Json::Value@ CloneJsonValue(Json::Value@ value) { return Json::Parse(Json::Write(value)); }', '')
        mocks = mocks.replace('    Json::Value@ GetToolList() { auto tools = Json::Array(); AppendPackTools(tools); return tools; }', '')
        mocks += r'''namespace TmMcp {
            string g_ToolCallInstance = "bridge-fixture";
            Json::Value@ BuildToolList() {
                auto tools=Json::Array(); auto builtin=Json::Object();
                builtin["name"]="Zulu"; builtin["description"]="builtin";
                builtin["input_schema"]=Schema(); tools.Add(builtin); AppendPackTools(tools); return tools;
            }
        }'''
        source = (ROOT / 'src/McpTools.as').read_text()
        start = source.index('    // Tool-list cache.')
        end = source.index('    Json::Value@ BuildToolList()', start)
        catalog = 'namespace TmMcp {\n' + source[start:end] + '\n}'
    files = []
    for name, text in [
        ('mocks.as', mocks),
        ('catalog.as', catalog),
        ('shared.as', (ROOT / 'src/ToolPackShared.as').read_text().replace('shared ', '')),
        ('validation.as', (ROOT / 'src/ToolInputValidation.as').read_text()),
        ('packs.as', (ROOT / 'src/ToolPacks.as').read_text()),
        ('case.as', 'void RunTests() {\n' + body + '\n}'),
    ]:
        path = tmp_path / name
        path.write_text(text.replace('.Resize(', '.resize('))
        files.append(str(path))
    result = subprocess.run([str(as_runner), *files], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr


def test_atomic_owner_replacement_and_metadata(as_runner, tmp_path):
    run_native(as_runner, tmp_path, r'''
    Caller("owner");
    auto original=TmMcp::RegisterToolPack(Builder("Pack")); Good(original);
    auto generation=string(original["output"]["generation"]);
    Check(TmMcp::revision==2, "register advances revision once");
    auto options=Json::Object(); options["replace"]=true; options["expectedGeneration"]=generation;
    auto metadata=Json::Object(); metadata["annotations"]=Json::Object();
    metadata["annotations"]["readOnlyHint"]=true; metadata["output_schema"]=Schema();
    options["tools"]=Json::Object(); options["tools"]["Ping"]=metadata;
    Caller("foreign");
    Error(TmMcp::RegisterToolPackEx(Builder("Pack"),options),"pack_not_owner");
    Caller("owner"); options["expectedGeneration"]="stale";
    Error(TmMcp::RegisterToolPackEx(Builder("Pack"),options),"stale_generation");
    options["expectedGeneration"]=generation;
    auto invalid=Builder("Pack"); invalid.AddTool("bad name","",Json::Write(Schema()));
    Error(TmMcp::RegisterToolPackEx(invalid,options),"pack_bad_tool_name");
    metadata["annotations"]["readOnlyHint"]="false";
    Error(TmMcp::RegisterToolPackEx(Builder("Pack"),options),"pack_bad_metadata");
    metadata["annotations"]["readOnlyHint"]=true;
    Check(TmMcp::revision==2 && TmMcp::g_Packs[0].generation==generation, "all failed replacements preserve original");
    auto replacement=TmMcp::RegisterToolPackEx(Builder("Pack","Ping","description only"),options); Good(replacement);
    Check(TmMcp::revision==3 && TmMcp::g_Packs[0].generation!=generation, "one atomic commit with new generation");
    metadata["annotations"]["readOnlyHint"]=false;
    auto tools=TmMcp::GetToolList();
    Check(string(tools[0]["description"])=="description only", "replacement description published");
    Check(bool(tools[0]["annotations"]["readOnlyHint"]), "metadata detached from caller");
    Check(string(tools[0]["output_schema"]["type"])=="object", "output schema preserved");
    Good(TmMcp::UnregisterToolPack("Pack"));
    Check(TmMcp::revision==4 && TmMcp::FindSchema("Pack.Ping")<0, "unregister advances once and removes schema");
    ''')


def test_owner_cleanup_liveness_and_bad_names(as_runner, tmp_path):
    run_native(as_runner, tmp_path, r'''
    Caller("Owner"); Good(TmMcp::RegisterToolPack(Builder("Owner"))); Good(TmMcp::RegisterToolPack(Builder("Extra")));
    auto before=TmMcp::revision; Good(TmMcp::UnregisterToolPack("Owner"));
    Check(TmMcp::revision==before+1 && TmMcp::g_Packs.Length==0, "owner bulk cleanup commits once");
    Caller("foreign"); Good(TmMcp::RegisterToolPack(Builder("Owner")));
    Caller("Owner"); Good(TmMcp::RegisterToolPack(Builder("Extra")));
    Good(TmMcp::UnregisterToolPack("Owner"));
    Check(TmMcp::g_Packs.Length==1 && TmMcp::g_Packs[0].pluginId=="foreign", "owner id never deletes foreign colliding prefix");
    before=TmMcp::revision; Meta::GetPluginFromID("foreign").Enabled=false; TmMcp::SweepDeadPacks();
    Check(TmMcp::revision==before+1 && TmMcp::g_Packs.Length==0, "dead pack removed once");
    TmMcp::SweepDeadPacks(); Check(TmMcp::revision==before+1,"unchanged sweep stable");
    string[] invalid={"bad name","bad/name","bad.name","bad\nname"};
    for(uint i=0;i<invalid.Length;i++) Error(TmMcp::RegisterToolPack(Builder("Pack",invalid[i])),"pack_bad_tool_name");
    string huge="x"; for(uint i=0;i<8;i++) huge+=huge;
    Error(TmMcp::RegisterToolPack(Builder("Pack",huge)),"pack_bad_tool_name");
    ''')


def test_union_and_additional_properties_validation(as_runner, tmp_path):
    run_native(as_runner, tmp_path, r'''
    auto schema=Schema(); auto prop=Json::Object(); auto types=Json::Array();
    types.Add("string"); types.Add("integer"); types.Add("null"); prop["type"]=types;
    schema["properties"]["value"]=prop;
    string err; Check(TmMcp::RegisterToolSchema("Union",schema,err),"union registers");
    auto input=Json::Object(); input["value"]="text";
    Check(TmMcp::ValidateToolInput("Union",input)=="","string accepted");
    input["value"]=42; Check(TmMcp::ValidateToolInput("Union",input)=="","integer accepted");
    input["value"]=Json::Value(); Check(TmMcp::ValidateToolInput("Union",input)=="","null accepted explicitly");
    input["value"]=0.5; Check(TmMcp::ValidateToolInput("Union",input)!="","fractional integer rejected");
    input["value"]=false; Check(TmMcp::ValidateToolInput("Union",input)!="","bool rejected by union");
    input=Json::Object(); input["extra"]=true;
    Check(TmMcp::ValidateToolInput("Union",input)!="","closed schema rejects extras");
    auto open=Json::Object(); open["type"]="object";
    Check(TmMcp::RegisterToolSchema("Open",open,err),"open schema registers");
    Check(TmMcp::ValidateToolInput("Open",input)=="","default permits extras");
    open["additionalProperties"]=Json::Object(); open["additionalProperties"]["type"]="integer";
    Check(TmMcp::RegisterToolSchema("TypedExtra",open,err),"typed additional properties register");
    Check(TmMcp::ValidateToolInput("TypedExtra",input)!="","additional type enforced");
    input["extra"]=10; Check(TmMcp::ValidateToolInput("TypedExtra",input)=="","additional integer admitted");
    types.Add("invalid"); prop["type"]=types; schema["properties"]["value"]=prop;
    Check(!TmMcp::RegisterToolSchema("Invalid",schema,err),"invalid union rejected at registration");
    auto huge=Json::Array(); for(uint i=0;i<9;i++) huge.Add("string"); prop["type"]=huge;
    Check(!TmMcp::RegisterToolSchema("Huge",schema,err),"union bound enforced");
    auto many=Json::Object(); for(uint i=0;i<1025;i++) many["key"+i]=i;
    Check(TmMcp::ValidateToolInput("Open",many)!="","input key bound enforced");
    ''')


def test_cached_serialization_detachment_order_and_liveness(as_runner, tmp_path):
    run_native(as_runner, tmp_path, r'''
    Caller("owner"); Good(TmMcp::RegisterToolPack(Builder("Pack")));
    auto list=TmMcp::GetToolList(); uint writes=Json::writes;
    Check(string(list[0]["name"])=="Zulu","legacy declaration order retained");
    list[1]["input_schema"]["type"]="poison";
    auto again=TmMcp::GetToolList();
    Check(Json::writes==writes,"warm list reads never serialize");
    Check(string(again[1]["input_schema"]["type"])=="object","list nested schema detached");
    auto catalog=TmMcp::GetToolCatalog(); writes=Json::writes;
    Check(string(catalog["tools"][0]["name"])=="Pack.Ping","catalog sorts canonical names");
    Check(string(catalog["tools"][1]["pack"])=="","builtin pack normalized");
    catalog["tools"][0]["input_schema"]["type"]="poison";
    auto second=TmMcp::GetToolCatalog();
    Check(Json::writes==writes,"warm catalog never serializes");
    Check(string(second["tools"][0]["input_schema"]["type"])=="object","catalog nested schema detached");
    auto identity=TmMcp::ToolCatalogIdentity();
    Check(string(identity["instance"])=="bridge-fixture" && Json::writes==writes,"identity is cheap and shares bridge instance");
    Meta::GetPluginFromID("owner").Enabled=false;
    auto dead=TmMcp::GetToolCatalog();
    Check(dead["tools"].Length==1,"warm catalog reconciles owner disappearance");
    Check(string(dead["revision"])!=string(second["revision"]),"dead owner advances revision");
    auto before=Json::writes; TmMcp::GetToolCatalog(); TmMcp::GetToolList();
    Check(Json::writes==before,"unchanged reads stay cached after eviction");
    ''', cache=True)


def test_retired_and_running_generations(as_runner, tmp_path):
    run_native(as_runner, tmp_path, r'''
    Caller("owner"); auto registered=TmMcp::RegisterToolPack(Builder("Pack")); Good(registered);
    auto old=TmMcp::g_Packs[0]; old.running=1;
    auto options=Json::Object(); options["replace"]=true; options["expectedGeneration"]=old.generation;
    Error(TmMcp::RegisterToolPackEx(Builder("Pack"),options),"pack_busy");
    Good(TmMcp::UnregisterToolPack("Pack"));
    Check(old.retired && TmMcp::g_RetiredPacks.Length==1,"running generation retained as retired");
    Error(TmMcp::RegisterToolPack(Builder("Pack")),"pack_busy");
    old.running=0; Good(TmMcp::RegisterToolPack(Builder("Pack")));
    Check(TmMcp::g_Packs[0].generation!=old.generation,"replacement only after retired worker stops");
    auto dead=TmMcp::g_Packs[0]; dead.running=1; Good(TmMcp::UnregisterToolPack("Pack"));
    TmMcp::fixtureWorkerDead=true;
    Good(TmMcp::RegisterToolPack(Builder("Pack")));
    Check(TmMcp::g_RetiredPacks.Length==0,"VM-aborted worker cannot leak retired reservation forever");
    ''')
