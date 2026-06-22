# cclean-skill

`cclean-skill` is a Codex skill for safely scanning and cleaning Windows C drive user storage.

It focuses on `C:\Users`, Downloads installers, WPS Cloud Files, WeChat/xwechat files, AppData caches, conda/pip/npm caches, and other large user folders.

## What it does

- Scans large folders and reports size in GB.
- Explains what each folder likely contains.
- Marks whether a folder can be deleted directly, should be cleaned through an app, or should not be deleted.
- Requires explicit user confirmation before deleting any file or folder.
- Prefers safe cleanup commands such as `conda clean --all`, `pip cache purge`, and `npm cache clean --force`.

## Usage

After installing the skill, invoke it with:

```text
$cclean-skill
```

This skill also treats `/ccs` as a short alias when Codex receives it as a normal message:

```text
/ccs
```

Note: `/ccs` is a model-level alias in the skill instructions, not a registered Codex client slash command. If the Codex client blocks unknown slash commands before sending them, use `$cclean-skill` instead.

## Safety policy

The skill is read-only during discovery. It must ask before deleting anything.

It should not directly delete broad system or profile folders such as:

- `C:\Users`
- a whole user profile
- `AppData`
- `AppData\Local\Microsoft`
- `AppData\Local\Packages`
- `ProgramData`
- `All Users`
- `Default`
- `Default User`
- `Public`
- `Documents`
- `Desktop`
- `Pictures`
- `Videos`

For WeChat, WPS Cloud Files, cloud drives, conda environments, and personal folders, the skill warns about possible unsynced or unbacked-up files before asking for confirmation.

## Included files

- `SKILL.md`: Codex skill instructions and safety workflow.
- `agents/openai.yaml`: UI metadata and default prompt.
- `scripts/scan-c-users.ps1`: read-only PowerShell scanner for large Windows user folders.
