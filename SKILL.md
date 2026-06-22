---
name: cclean-skill
description: Safely scan and clean Windows C drive user storage, especially C:\Users, Downloads installers, WPS Cloud Files, WeChat/xwechat files, AppData caches, conda/pip/npm caches, and other large user folders. Use when a user types /ccs, asks to free disk space, find what occupies C drive, decide what can be deleted, or clean C:\Users while requiring explicit user confirmation before deleting any file or folder.
---

# Cclean Skill

## Core Rules

Treat this as a safety-first cleanup workflow for Windows user storage.

- If the user types `/ccs`, treat it as a request to run this skill's C drive cleanup scan.
- Default to read-only scanning. Do not delete, move, rename, or empty folders during discovery.
- Show the user which folders or file groups are large, their size in GB, what they likely contain, whether direct deletion is appropriate, and the safer cleanup method.
- Ask for explicit confirmation before every deletion action. The user must name or clearly approve the exact path or file group to delete in the current conversation.
- Warn before deleting anything that may contain personal files, chat attachments, cloud sync data, unsynced files, development environments, browser profiles, or app configuration.
- Prefer app-native cleanup commands for app-managed data: WeChat storage manager, WPS cloud cache cleanup, Baidu Netdisk cleanup, browser cache settings, `conda clean --all`, `conda env remove -n <env>`, `pip cache purge`, and `npm cache clean --force`.
- Never directly delete broad system or profile folders such as `C:\Users`, a whole user profile, `AppData`, `AppData\Local\Microsoft`, `AppData\Local\Packages`, `ProgramData`, `All Users`, `Default`, `Default User`, `Public`, `Documents`, `Desktop`, `Pictures`, or `Videos`.

## Workflow

1. Identify the target root. Use `C:\Users` by default, or the path the user gives.
2. Run the bundled read-only scanner:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\scan-c-users.ps1" -Root "C:\Users" -MinGB 0.1
```

3. If the user is focused on a specific folder, inspect that folder before recommending deletion:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-dir>\scripts\scan-c-users.ps1" -Root "C:\Users\Lenovo\WPS Cloud Files\.306382235" -MinGB 0.01
```

4. Present a concise table with:

- path or group
- size in GB
- likely contents
- direct delete: yes, contents only, no, or app cleanup preferred
- risk level
- recommended action

5. Ask the user what to delete. For medium or high risk targets, ask about backup/sync status first.
6. Delete only after explicit approval. If deletion is approved, close related apps first when relevant and prefer deleting contents of cache folders over deleting parent account or profile folders.
7. Re-scan after cleanup and report space recovered.

## Common Decisions

Use these defaults when explaining recommendations:

- `Downloads` installers (`*.exe`, `*.msi`): usually safe after the software is installed and the installer is no longer needed. Ask first.
- `AppData\Local\Temp`: usually safe to delete contents after closing apps. Do not delete the `Temp` folder itself.
- `CrashDumps`: safe to delete if the user does not need crash logs.
- `pip`, `npm-cache`, `.conda\pkgs`: cache data. Prefer package-manager cleanup commands.
- `.conda\envs`: development environments. Do not delete directly; ask which environments are still needed and prefer `conda env remove`.
- `Documents\xwechat_files` and `AppData\Roaming\Tencent\xwechat`: WeChat files and data. Use WeChat storage management first; do not delete whole folders without explicit confirmation and backup awareness.
- `WPSDrive` and `WPS Cloud Files`: cloud sync/offline files and cache. Use WPS cleanup first. Inspect hidden account folders before acting. Deleting a `cachedata` subfolder may be reasonable after WPS is closed and sync is complete; deleting an entire account folder is not the first choice.
- Baidu Netdisk, Lark/Feishu, DingTalk, Tencent Meeting, browser folders, JetBrains folders: app data and caches. Prefer app-native cache cleanup or targeted cache folders, not entire app data folders.

## Deletion Confirmation Standard

Before any delete command, state:

- the exact path or file group
- estimated size
- why it appears safe or risky
- what may be lost
- whether the app should be closed first

Proceed only if the user replies with clear consent such as "delete this path", "delete these installers", or "yes, delete cachedata".

If the user gives broad approval such as "clean everything", do another confirmation listing the exact proposed targets before deleting.
