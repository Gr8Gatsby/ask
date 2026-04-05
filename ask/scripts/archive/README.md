Archived scripts live here intentionally.

`ScriptManager` and `ScriptUpdateService` only scan direct child folders under the active scripts root for `manifest.json`, so nested folders in `archive/` are ignored.

Use this folder for scripts that should remain in the repository but should not be discovered, launched, or updated by the app.
