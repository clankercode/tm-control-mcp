# `@clankercode/tm-control-mcp`

This package is a small launcher for the Rust MCP adapter. The platform
optional dependencies contain the executable for Linux x64 and Windows x64.

```bash
npm install -g @clankercode/tm-control-mcp
tm-control-mcp --help
```

The launcher passes arguments, standard streams, signals, and the child exit
status through to the platform executable. It never downloads or builds a
binary during installation. If npm skips the optional dependency for a
platform that is not published yet, the launcher reports the package that is
missing and how to install it.
