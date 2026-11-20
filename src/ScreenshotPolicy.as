namespace TmMcp {
    bool ScreenshotFileChanged(bool existed, uint64 oldSize, int64 oldModified,
        bool exists, uint64 size, int64 modified) {
        return exists && size > 0 && (!existed || size != oldSize || modified != oldModified);
    }
}
