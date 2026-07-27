# Cleanup Decision Matrix

Use this reference after the audit identifies a large path. Size alone is never evidence that deletion is safe.

| Pattern or evidence | Classification | Preferred action | Key warning |
|---|---|---|---|
| `AppData\Local\Temp\<child>` containing `.vsix`, `.msi`, `.cab`, or installer payloads | Temporary installer extraction | Close the installer; remove the exact child after approval | Do not clear a pending install or the whole Temp root |
| `CrashDumps\*.dmp` | Crash diagnostics | Delete contents after approval | Historical debugging evidence is lost |
| Browser `Cache`, `Code Cache`, `GPUCache`, shader caches | Regenerable browser cache | Use browser cleanup or clear exact cache contents | Preserve passwords, bookmarks, extensions, and profile databases |
| Browser or Electron `Service Worker\CacheStorage` | Web resource/offline cache | Prefer app-native cleanup; otherwise clear exact contents after approval | May remove offline web resources and cause re-downloads |
| Feishu/Lark `profile_explorer\Service Worker\CacheStorage` | Feishu web cache | Use Feishu storage cleanup or clear exact contents after closing Feishu | Do not delete the account profile, IndexedDB, or all `users` data |
| WPS version folders with one older than the registered/current version | Old application version | Prefer WPS updater/repair cleanup; remove only the verified older version after approval | Preserve the current version and WPS cloud/account data |
| WPS `backup` | Document recovery copies | Review in WPS Backup Center | May be the only recoverable copy of unsaved work |
| WPS `cache` or `log` | Regenerable cache/log | Use WPS cleanup or clear exact contents | Close WPS and cloud services first |
| `Downloads\*.exe` or `*.msi` and matching software is installed | Installer copy | Delete the exact file after approval | Offline reinstall/rollback will require re-download |
| Installer inside WeChat/chat attachments and software is already installed | Chat attachment installer | Delete exact attachment after approval | Verify it is not the only offline installer |
| Same filename and byte length in multiple locations | Possible duplicate | Compute SHA-256 for every candidate | Do not delete based on name/size alone |
| Same SHA-256 across files | Confirmed duplicate | Keep one named copy; delete only approved copies | State which copy remains |
| `*-updater\installer.exe` | Application update payload | Finish or abandon the update, close the app, then delete exact payload | A currently pending update may need it |
| pip cache or npm cache | Download cache | Preserve for offline rebuilds or use package-manager cleanup | Not installed dependencies, but useful offline |
| `.conda\pkgs` | Conda package store | Run `conda clean --all --dry-run --json` | Do not manually delete when dry-run reports zero |
| `.conda\envs`, `.venv`, `node_modules` | Runtime dependencies | Keep or remove via environment/package workflow | Deletion can break programs |
| JetBrains `index`, `caches`, `python_stubs`, logs | Regenerable IDE data | Prefer IDE cache invalidation | Re-indexing can be slow; not project dependencies |
| WeChat, cloud-drive, Lark account roots | Personal or synced application data | Use app storage manager and verify backup/sync | May include unique attachments or unsynced files |
| `Program Files` application folder | Installed software | Use Windows or vendor uninstaller | Never delete the folder just because it is large |
| `ProgramData\Adobe\ARM` update packages | Vendor update cache/pending update | Complete update or uninstall first | Packages may still be pending or needed for repair |
| `ProgramData\Package Cache` | Installer repair cache | Keep | Manual deletion may break repair/uninstall |
| `Windows\Installer` | Windows Installer cache | Keep | Manual deletion may break patching and uninstall |
| `WinSxS` | Component store with hard links | Analyze with elevated DISM | Apparent size is not reclaimable size |
| `pagefile.sys`, `swapfile.sys`, `hiberfil.sys` | Windows-managed storage | Change only through Windows settings after separate approval | Performance, crash dump, sleep, or hibernation tradeoffs |

## Risk Labels

- `low`: exact regenerable cache, crash dump, or verified redundant installer; still requires approval.
- `medium`: app-managed data, old version, update payload, or cache that affects offline behavior.
- `high`: personal data, account data, sync data, development environment, unknown mixed folder, or system-managed area.
- `forbidden`: broad/system path that must not be manually deleted.

## Evidence Priorities

1. Exact path and file type.
2. Installed/current application version.
3. App-native cleanup support.
4. Last-write or usage evidence, treated only as a clue.
5. Hash equality for duplicates.
6. Package-manager dry-run output.
7. Post-clean residual and free-space verification.
