# cclean-skill

## 功能范围

`cclean-skill` 用于安全扫描和清理 Windows C 盘用户目录，重点检查：

- `C:\Users` 下占用空间较大的文件夹
- `Downloads` 里的安装包，例如 `.exe`、`.msi`
- WPS 云盘、本地缓存和离线文件
- 微信 / xwechat 聊天文件、图片、视频和缓存
- `AppData` 临时文件、软件缓存、崩溃日志
- conda、pip、npm 等开发工具缓存和环境

默认只做只读扫描。任何删除动作都必须先展示路径、大小、风险和可能丢失的内容，并在用户明确同意后才能执行。

## 安装命令

在 PowerShell 中运行：

```powershell
python "$env:USERPROFILE\.codex\skills\.system\skill-installer\scripts\install-skill-from-github.py" --repo Grace-han52/cclean-skill --path . --name cclean-skill
```

安装后重启 Codex。

## 调用方式

推荐调用：

```text
$cclean-skill
```

也可以输入：

```text
/ccs
```

说明：`/ccs` 是写在 skill 里的短别名。如果 Codex 客户端把未知斜杠命令拦截了，就使用 `$cclean-skill`。
