# Shell

DebianKit：用于 Debian 服务器配置、软件安装和系统重装的多模块 Shell 工具，统一入口为 `debiankit.sh`。

## 使用

下载完整项目后，在项目目录运行：

```bash
sudo bash debiankit.sh
```

也可远程运行仓库 `main` 分支的版本：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/planet756/Shell/main/debiankit.sh)"
```

配置和安装操作需要 root 权限，按菜单提示填写参数即可。

## 菜单

```text
01. Update Debian Sources
02. Initialize User
03. Install BBR
04. Install Docker
05. Install Telegraf
06. Install Komari Agent (Non-Root)
07. Install Node.js (Official Binary)
08. Install Go (Official Binary)
09. Reinstall OS

00. Exit
```

软件源更新自动匹配 Debian 11（bullseye）、12（bookworm）、13（trixie）；配置正确时只更新索引，需要修正时备份原配置，保留第三方源。主菜单输入 `reset` 可清除基础包初始化标记。

## 常用命令

```bash
sudo bash debiankit.sh debian docker
sudo bash debiankit.sh debian nodejs
sudo bash debiankit.sh debian go
bash debiankit.sh --help
```

Debian 配置支持：`sources`、`user`、`bbr`、`docker`、`telegraf`、`komari`、`nodejs`、`go`、`reset-init`。

## 系统重装

`09. Reinstall OS` 支持 Debian 13 和 Windows 10 IoT Enterprise LTSC 2021（x64），重装逻辑由本项目独立实现。

```bash
sudo bash debiankit.sh reinstall debian13
sudo bash debiankit.sh reinstall windows10-iot-ltsc
# 仅预览
bash debiankit.sh reinstall --dry-run debian13
# 重启前取消待执行重装
sudo bash debiankit.sh reinstall reset
# 查看全部参数
bash debiankit.sh reinstall --help
```

- 内置源只提供美国英文；选择简体中文必须自行提供 `--url`，可用 `--lang zh-cn` 指定语言。
- Debian 的 `--url` 为网络安装器目录，需包含 `SHA256SUMS` 和 `netboot/debian-installer/amd64/` 文件。
- Windows 默认从第三方站点 [NTriver](https://ntriver.org/download-windows-ltsc) 获取英文 ISO，校验完整文件；自备 ISO 用 `--url` 或 `--iso`，其他语言还需提供 `--iso-sha256`。
- 手动密码只需两次一致；密码提示直接回车生成 20 位随机密码，准备成功后在终端显示一次，请保存。
- 默认保留当前系统的 hostname，可用 `--hostname` 修改；Windows 名称不兼容时需自行指定，最长 15 字符。
- Debian 首次启动按 MAC 匹配实际网卡并配置网络，成功后清理临时服务；指定 `--ssh-key` 后，安装器与新 Debian 系统的 SSH 均使用公钥认证。
- Debian 安装进度可通过 VNC／串口、SSH 和网页日志查看。SSH 使用本次重装的新密码或指定公钥，登录后自动显示与 VNC 相同的实时安装界面；按 `Ctrl+A` 再按 `D` 返回命令行，安装继续。网页默认端口 `8080`，可用 `--web-port` 修改。网络入口在安装器联网后可用，网页日志服务只在安装期间运行。
- 输入 `REINSTALL` 准备安装，成功后输入 `y` 可直接重启，回车则稍后重启；重启前可通过重装子菜单 `99` 或上述取消命令取消，需输入 `RESET` 确认。

重装需要 x86_64 Linux、GRUB、单网卡 IPv4，Secure Boot 关闭；不支持 WSL 或容器。Windows 使用 BIOS 时，目标磁盘不能超过 2 TiB，更大磁盘需使用 UEFI。

**重启进入安装后，将清除目标磁盘的全部分区和数据，请提前备份。**
