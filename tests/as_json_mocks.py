"""Minimal JSON API adapter for executing production tools in stock AngelScript."""

JSON_MOCKS = r'''
namespace Json {
    enum Type { Null, Object, Array, String, Boolean, Number }
    class Value {
        Type kind = Type::Null;
        string text;
        bool flag;
        double number;
        array<string> keys;
        array<Value@> values;
        array<string>@ GetKeys() { return keys; }
        double opConv() const { return double(number); }
        int opConv() const { return int(number); }
        bool Get(const string &in key, bool fallback) { return HasKey(key) ? bool(this[key]) : fallback; }
        Type GetType() const { return kind; }
        bool HasKey(const string &in key) const { return keys.Find(key) >= 0; }
        Value@ opIndex(const string &in key) {
            int index = keys.Find(key);
            if (index >= 0) return values[index];
            keys.InsertLast(key);
            values.InsertLast(Value());
            return values[values.Length - 1];
        }
        Value@ opIndex(uint index) { return values[index]; }
        Value &opAssign(const Value &in other) {
            kind = other.kind; text = other.text; flag = other.flag;
            number = other.number; keys = other.keys; values = other.values;
            return this;
        }
        Value &opAssign(const string &in value) { kind = Type::String; text = value; return this; }
        Value &opAssign(bool value) { kind = Type::Boolean; flag = value; return this; }
        Value &opAssign(double value) { kind = Type::Number; number = value; return this; }
        Value &opAssign(int value) { kind = Type::Number; number = value; return this; }
        Value &opAssign(uint value) { kind = Type::Number; number = value; return this; }
        bool opConv() const { Check(kind == Type::Boolean, "expected JSON boolean"); return flag; }
        string opConv() const { Check(kind == Type::String, "expected JSON string"); return text; }
        uint opConv() const { Check(kind == Type::Number, "expected JSON number"); return uint(number); }
        uint get_Length() const property { return values.Length; }
        void Add(const string &in value) {
            auto row = Value(); row = value; values.InsertLast(row);
        }
    }
    Value Object() { Value value; value.kind = Type::Object; return value; }
    Value Array() { Value value; value.kind = Type::Array; return value; }
}

'''
