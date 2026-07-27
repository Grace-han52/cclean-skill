# cclean-skill

## 功能范围

`cclean-skill` 用于检查 Windows C 盘到底被什么占满，并在你确认后安全清理。

它会重点检查：

- C 盘一级目录分别占了多少空间
- `Users`、`Windows`、`Program Files`、`ProgramData` 等大目录
- 大文件、重复文件、安装包和压缩包
- 浏览器、聊天软件、办公软件和系统产生的缓存
- CrashDumps、日志和临时文件
- Windows 组件、还原点、休眠文件和虚拟内存等系统占用
- conda、pip、npm、PyCharm 等开发环境和缓存

默认先进行只读扫描，不会边扫描边删除。扫描后会说明每项内容是什么、占多大、删除后会失去什么，以及能不能重新生成。

需要删除时，`cclean-skill` 会先列出准确路径和预计大小。只有你明确确认这一批文件后，它才会执行删除。它不会把项目目录、虚拟环境、已安装依赖或个人文件直接当成缓存。

## 安装命令

Windows 电脑里的 Codex、Claude Code、Workbuddy 等任意 Agent 工具中直接输入：

```powershell
npx.cmd -y skills add Grace-han52/cclean-skill -g --all
```

安装完成后，重启或刷新 Codex、Claude Code、Workbuddy 该 Agent 工具。

## 调用方式

推荐直接输入：

```text
$cclean-skill 完整检查 C 盘，先只扫描，不要删除
```

只想快速了解空间占用：

```text
$cclean-skill 快速扫描 C 盘，只看主要目录
```

想检查得更仔细：

```text
$cclean-skill 深度检查 C 盘的大目录、大文件、重复文件和系统占用，先不要删除
```

在 Codex CLI 或 IDE 扩展中，也可以输入 `/skills`，然后选择 `cclean-skill`。

扫描完成后，直接告诉它你想删除清单中的哪些项目。它会再次列出准确删除范围，等你确认后再执行。
