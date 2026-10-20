# Confirmed text replacement

`ControlFids {action:"setText", drive:"user", path:"Scripts/EditorPlugins/Example.Script.txt", find:"old", replace:"new", confirm:true}`
changes only a loaded user editor-script cache in an idle `MapEditor`. It refuses
native game/title scripts, race scripts, driving/test/validation modes, loading,
lightmap computation and an observed script crash. The native setter may recompile
the script; this tool does not save the file, reload editor plugins, or prove that
the script compiled or ran.

`PatchLayerXml {layerIndex:0, find:"old", replace:"new", confirm:true}`
uses the same replacement planner on a menu layer. It requires `Menu`, refuses an
observed script crash, and never patches a driving or editor-testing page.

Both replace the first exact match unless `replaceAll:true`. Confirmation must be
a JSON boolean. Empty needles and wrong input types are rejected. Source/result
text is limited to 256 KiB, each find/replacement to 64 KiB, and replacement work
to 4096 matches. No match or an identical result causes no setter call. The result
contains counts and assignment/readback flags, without text snippets or source.
A failed or mismatching readback is `READBACK_UNCONFIRMED`, with `written:true`
preserving the assignment attempt. Inspect state before retrying; the tool does
not blindly roll back or claim compilation success.
