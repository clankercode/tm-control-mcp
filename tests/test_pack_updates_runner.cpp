// Minimal stock AngelScript runner for the actual pure production policy.
// Adapters only map Openplanet string spellings; no policy is reimplemented.
#include <angelscript.h>
#include <scriptstdstring.h>
#include <scriptarray.h>
#include <fstream>
#include <sstream>
#include <iostream>
#include <string>
#include <stdexcept>
#include <cassert>

static unsigned Length(const std::string& s) { return unsigned(s.size()); }
static std::string Trim(const std::string& s) {
    auto a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    return s.substr(a, s.find_last_not_of(" \t\r\n") - a + 1);
}
static std::string SubStr(unsigned start, unsigned count, const std::string& s) {
    return start >= s.size() ? "" : s.substr(start, count);
}
static bool StartsWith(const std::string& prefix, const std::string& s) { return s.rfind(prefix, 0) == 0; }
static int IndexOf(const std::string& needle, const std::string& s) {
    auto i = s.find(needle); return i == std::string::npos ? -1 : int(i);
}
static CScriptArray* Split(const std::string& delim, const std::string& s) {
    auto* type = asGetActiveContext()->GetEngine()->GetTypeInfoByDecl("array<string>");
    auto* arr = CScriptArray::Create(type);
    size_t a = 0, b;
    while ((b = s.find(delim, a)) != std::string::npos) {
        auto part = s.substr(a, b-a); arr->InsertLast(&part); a = b + delim.size();
    }
    auto part = s.substr(a); arr->InsertLast(&part); return arr;
}
static void Check(bool ok, const std::string& message) {
    if (!ok) asGetActiveContext()->SetException(message.c_str());
}
static void Message(const asSMessageInfo* m, void*) {
    std::cerr << m->section << ':' << m->row << ':' << m->col << ' ' << m->message << '\n';
}
int main(int argc, char** argv) {
    auto* e = asCreateScriptEngine();
    e->SetMessageCallback(asFUNCTION(Message), nullptr, asCALL_CDECL);
    e->SetEngineProperty(asEP_PROPERTY_ACCESSOR_MODE, 2);
    RegisterStdString(e); RegisterScriptArray(e, true);
    assert(e->RegisterObjectMethod("array<T>", "uint get_Length() const property", asMETHOD(CScriptArray, GetSize), asCALL_THISCALL) >= 0);
    assert(e->RegisterObjectMethod("string", "uint get_Length() const property", asFUNCTION(Length), asCALL_CDECL_OBJLAST) >= 0);
    assert(e->RegisterObjectMethod("string", "string Trim() const", asFUNCTION(Trim), asCALL_CDECL_OBJLAST) >= 0);
    assert(e->RegisterObjectMethod("string", "string SubStr(uint, uint = 0xffffffff) const", asFUNCTION(SubStr), asCALL_CDECL_OBJLAST) >= 0);
    assert(e->RegisterObjectMethod("string", "bool StartsWith(const string &in) const", asFUNCTION(StartsWith), asCALL_CDECL_OBJLAST) >= 0);
    assert(e->RegisterObjectMethod("string", "int IndexOf(const string &in) const", asFUNCTION(IndexOf), asCALL_CDECL_OBJLAST) >= 0);
    assert(e->RegisterObjectMethod("string", "array<string>@ Split(const string &in) const", asFUNCTION(Split), asCALL_CDECL_OBJLAST) >= 0);
    assert(e->RegisterGlobalFunction("void Check(bool, const string &in)", asFUNCTION(Check), asCALL_CDECL) >= 0);
    auto* m = e->GetModule("policy", asGM_ALWAYS_CREATE);
    for (int i = 1; i < argc; ++i) {
        std::ifstream f(argv[i]); std::stringstream text; text << f.rdbuf();
        auto s = text.str(); m->AddScriptSection(argv[i], s.c_str(), s.size());
    }
    if (m->Build() < 0) return 2;
    auto* c = e->CreateContext(); c->Prepare(m->GetFunctionByDecl("void RunTests()"));
    int result = c->Execute();
    if (result != asEXECUTION_FINISHED) {
        std::cerr << c->GetExceptionString() << " at line " << c->GetExceptionLineNumber() << '\n'; return 1;
    }
    c->Release(); e->ShutDownAndRelease();
    std::cout << "AngelScript policy assertions passed\n";
}
