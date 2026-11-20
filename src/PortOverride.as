namespace TmMcp {
    const int PORT_FALLBACK_SPAN = 100;

    // Same read and validation for the listener and display record binding.
    // On success retain the trimmed marker text for existing record hashes.
    int ReadPortOverride(string &out mark, string &out why) {
        mark = "";
        why = "";
        string path = IO::FromStorageFolder("port.override");
        try {
            if (!IO::FileExists(path)) return 0;
            IO::File f(path, IO::FileMode::Read);
            mark = f.ReadToEnd().Trim();
            f.Close();
        } catch {
            why = "port.override is unreadable: " + getExceptionInfo();
            return 0;
        }
        if (mark.Length == 0 || mark.Length > 64) {
            why = "port.override is empty or too long";
            return 0;
        }
        int port = 0;
        for (uint i = 0; i < uint(mark.Length); i++) {
            uint8 c = mark[i];
            if (c < 48 || c > 57) { why = "port.override must be a decimal port"; return 0; }
            port = port * 10 + int(c - 48);
            if (port > 65535 - PORT_FALLBACK_SPAN) { why = "port.override is out of range"; return 0; }
        }
        if (port == 0) why = "port.override is out of range";
        return port;
    }

    bool _PortMark(string &out mark, string &out why) {
        if (ReadPortOverride(mark, why) != 0) return true;
        if (why.Length == 0) why = "no port.override in plugin storage";
        return false;
    }
}
