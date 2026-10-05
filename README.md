# Shell

## 单入口项目

统一入口为 `debiankit.sh`，保留 DebianKit 的颜色、两位编号和执行后返回菜单的操作方式。功能按模块组织：

```text
debiankit.sh              主菜单、命令分发、本项目远程启动
lib/common.sh             日志、颜色、root 检查
modules/debian.sh         原有 Debian 配置和软件安装功能
modules/reinstall.sh      独立系统重装实现
tests/                   本地验证
```

将完整项目放到目标服务器，然后运行：

```bash
sudo bash debiankit.sh
```

菜单保留原来的 `01–08`、`99. Install All`、`00. Exit` 和 `reset`，并追加：

```text
09. Reinstall Debian 13
10. Reinstall Windows 10 IoT Enterprise LTSC 2021 (x64)
11. Cancel Pending Reinstallation
```

基础包初始化只在选择 Debian 配置功能时执行；查看菜单、退出及进入重装不会触发该初始化。选择 `09` 或 `10` 后会选择系统语言，直接回车默认美国英文。`99. Install All` 仍运行原有配置组件；检测到待执行重装时，会提醒其清盘影响并跳过普通重启询问。

可用命令行子命令调用同一套模块：

```bash
bash debiankit.sh --menu
sudo bash debiankit.sh debian docker
sudo bash debiankit.sh reinstall debian13
bash debiankit.sh reinstall --dry-run windows10-iot-ltsc
```

远程使用保留原命令（需先将此次项目改动发布到仓库）：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/planet756/Shell/main/debiankit.sh)"
```

远程入口会将**本项目**的共享脚本和模块下载到临时目录，检查语法后执行，退出时清理。完整项目本地运行时使用本地模块。只下载一个入口文件再运行，不会自动拼接本地文件和远程模块。

## 独立系统重装脚本

重装逻辑位于 `modules/reinstall.sh`，通过统一入口 `debiankit.sh` 的 `09–11` 选项或 `reinstall` 子命令调用。系统检测、安装配置生成、引导配置、重装及取消流程均由本项目实现。目前提供两个预设：

| 预设 | 系统 | 安装方式 |
| --- | --- | --- |
| `debian13` | Debian 13，默认美国英文，语言可选 | 官方 Debian 网络安装器 + 本地生成的 preseed |
| `windows10-iot-ltsc` | Windows 10 IoT Enterprise LTSC 2021 x64，默认美国英文 | Alpine 内存环境 + IoT Windows ISO + 本地生成的 WinPE/无人值守配置 |

### 运行

将完整项目放到**需要重装的 Linux 服务器**，使用 root 权限运行：

```bash
sudo bash debiankit.sh
# 或直接指定系统
sudo bash debiankit.sh reinstall debian13
sudo bash debiankit.sh reinstall windows10-iot-ltsc
```

旧名称 `windows10-ltsc` 作为兼容别名保留，指向同一个 IoT 安装预设。

没有发布本地修改前，不应使用远程仓库的旧版本。入口支持完整项目本地运行，以及保留终端输入的远程 `bash -c` 启动方式。

### 实际流程

1. 选择系统和语言，检查机器、GRUB、磁盘和 IPv4 网络。显示将清除的磁盘，以及静态地址（如果适用）。
2. 输入 `REINSTALL debian13` 或 `REINSTALL windows10-iot-ltsc` 确认，再输入至少 12 个字符的登录密码。Debian 使用 `root`；Windows 使用内置管理员账号，美国英文下名称为 `Administrator`，其他语言的显示名称可能不同。
3. 获取安装介质，生成本地安装配置及 initramfs，添加一次性 GRUB 启动项。这里已经修改当前系统的引导配置，但尚未清盘。
4. 手动执行 `sudo reboot`，开始安装。**目标磁盘全部分区和数据将被清除。**

Debian 直接进入官方安装器，按原分区表 ID 确认目标磁盘后自动分区和安装，配置 SSH，然后重启进入新系统。

Windows 先进入 Alpine 内存环境，开启 SSH 供检查安装日志，使用 QEMU 的 HTTPS 块设备读取完整 ISO 并验证 SHA-256。然后生成 WinPE 安装环境、核对目标磁盘原分区表 ID 和大小，再清盘。BIOS 使用 MBR；UEFI 使用 GPT。安装介质放在 12 GiB 的 NTFS 分区中，Windows 系统位于独立分区。UEFI 的初始启动分区为 2 GiB，以容纳临时 WinPE 文件。随后自动重启进入 Windows Setup，校验新磁盘 ID、安装系统，并在首次启动时恢复网络、开启 RDP、清理包含密码的安装文件。

Windows 安装期间需保持 ISO 镜像源支持 HTTPS 字节范围读取。ISO 会被完整读取进行校验，再读取安装文件，流量通常大于单个 ISO 的大小。当前版本保留安装介质分区，不自动合并到系统盘。

### Windows ISO 自动获取

默认使用 [NTriver](https://ntriver.org/download-windows-ltsc) 的 API，根据固定文件名取得临时下载直链。API 返回的文件名和 SHA-256 必须与登记值一致，直链必须支持 HTTPS 范围读取。安装环境在重启后再次生成直链，以减少过期风险；清盘前仍完整读取 ISO 并检查 SHA-256。美国英文 IoT LTSC 2021 对应：

```text
en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso
SHA-256: a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160
```

文件 SHA-256 来自 [Microsoft 介质信息公开索引](https://awuctl.github.io/mvs/)，并与 NTriver API 返回值核对。NTriver 不可用时停止；不会自动切换其他站点。可以用 `--iso` 或同义参数 `--url` 指定自己的 HTTPS 直链：

```bash
sudo bash debiankit.sh reinstall windows10-iot-ltsc --iso 'https://example.com/original-ltsc-2021.iso'
# 同义参数
sudo bash debiankit.sh reinstall windows10-iot-ltsc --url 'https://example.com/original-ltsc-2021.iso'
```

指定自定义地址会跳过 NTriver。未传校验值时，仍要求文件与上述美国英文 IoT 原版一致。其他 IoT 介质可以通过 `--iso-sha256` 指定你已核实的 SHA-256；安装环境还会核对 `IoTEnterpriseS`、x64 和所选语言，普通 Enterprise LTSC 不会作为 IoT 安装。URL 和其中的访问凭据不会显示在预览或错误信息中。不会执行下载站提供的脚本，也不包含系统激活操作。

```bash
sudo bash debiankit.sh reinstall windows10-iot-ltsc \
  --url 'https://example.com/custom-iot-ltsc-2021.iso' \
  --iso-sha256 '替换为你核实的64位SHA256值'
```

### 系统语言

未指定 `--lang` 时，交互式重装会显示可用语言；直接回车默认 `en-us`，`00` 取消。指定 `--lang` 时跳过语言询问。`--dry-run` 不询问语言，默认展示美国英文。

Debian 保留以下 8 种语言。当前 NTriver 和公开索引只确认了美国英文的 IoT LTSC 2021 原版，因此 Windows 默认下载仅提供美国英文；其他语言需提供包含该语言的 IoT ISO 地址和 `--iso-sha256`，此时语言菜单会开放对应选择。

| 编号 | 参数 | 语言 |
| --- | --- | --- |
| 01 | `en-us` | 美国英文（默认） |
| 02 | `zh-cn` | 简体中文 |
| 03 | `zh-tw` | 繁体中文 |
| 04 | `ja-jp` | 日语 |
| 05 | `ko-kr` | 韩语 |
| 06 | `de-de` | 德语 |
| 07 | `fr-fr` | 法语 |
| 08 | `es-es` | 西班牙语 |

```bash
bash debiankit.sh reinstall --languages
sudo bash debiankit.sh reinstall debian13 --lang en-us
sudo bash debiankit.sh reinstall windows10-iot-ltsc --lang en-us
# 自备包含简体中文的 IoT ISO 时：
sudo bash debiankit.sh reinstall windows10-iot-ltsc --lang zh-cn \
  --iso 'https://example.com/zh-cn-iot-ltsc-2021.iso' \
  --iso-sha256 '替换为你核实的64位SHA256值'
```

Debian 同步设置 locale 和该语言的键盘布局；Windows 同步设置安装界面、系统界面、用户区域和输入配置，并验证 IoT 映像的语言。语言清单及已知介质映射集中在 `modules/reinstall.sh` 的 `OS_LANGUAGES`。

### 网络与参数

默认根据当前 IPv4 地址是否标记为动态地址选择 DHCP 或静态配置。静态配置保留当前 IP、前缀、网关和 DNS；也可明确指定：

```bash
sudo bash debiankit.sh reinstall debian13 --network dhcp --ssh-port 2222
sudo bash debiankit.sh reinstall debian13 --network static --address 192.0.2.10/24 --gateway 192.0.2.1 --dns 1.1.1.1,8.8.8.8
sudo bash debiankit.sh reinstall debian13 --ssh-key /root/id_ed25519.pub
sudo bash debiankit.sh reinstall windows10-iot-ltsc --rdp-port 3389 --hostname windows-ltsc
```

新系统的时区默认 UTC，系统语言及键盘默认美国英文，可通过语言选择修改。密码不接受命令行参数，也不会打印。阶段配置文件以受限权限保存；Windows 安装环境中的 SSH 使用同一登录密码或指定公钥，日志位于 `/var/log/reinstall-stage.log`。

### 适用范围

- 当前版本支持 x86_64 Linux 原系统，BIOS 或 UEFI，Secure Boot 关闭。
- 当前系统必须已有 GRUB 一次性启动支持。GRUB 配置及环境文件须位于普通 ext2/ext3/ext4 分区，安装目标必须包含该引导分区。脚本不会替换当前系统的引导器。
- 不支持 WSL、容器原系统、跨多个磁盘的根文件系统自动选盘。其他原系统引导方式及 ARM 尚未实现。
- 需要 `curl`、`python3`、`cpio`、`gzip`、`openssl`、`ip`、`lsblk`、`blkid`、`findmnt`、`sha256sum`、`ssh-keygen` 和 GRUB 工具。缺少依赖会停止并指出缺少的命令，不自动安装宿主系统软件。
- Debian 至少 512 MiB 内存 / 4 GiB 磁盘；Windows 至少 2 GiB 内存 / 48 GiB 磁盘。
- 当前网络支持单物理网卡的 IPv4 DHCP，或网关位于同一子网的静态配置。多物理网卡、桥接、bond、VLAN、静态 `/31`、`/32`、子网外网关、纯 IPv6 等尚未实现，会在准备阶段拒绝。
- Windows 自动驱动适配范围为 KVM VirtIO 和原版 ISO 内置驱动。AWS、Google 和 Xen 专用驱动尚未实现，这些设备会被拒绝。

### 预览与取消

```bash
bash debiankit.sh reinstall --list
bash debiankit.sh reinstall --dry-run debian13
bash debiankit.sh reinstall --dry-run windows10-iot-ltsc
# 仅在重启前取消已准备的安装
sudo bash debiankit.sh reinstall reset
```

预览不下载、无需 root、不修改系统。取消只移除本脚本的启动项和生成文件。安装开始并清盘后，`reset` 无法恢复数据。

### 后续增加系统

预设集中在 `modules/reinstall.sh` 顶部的 `OS_PRESETS`。同类 Debian 版本可使用现有网络安装后端；增加 Windows 版本时，需要同时登记对应原版 ISO 文件名、校验值和 WIM 映像名称。新增不同安装方式时，应实现本地安装后端，再在 `main` 中登记，不能调用第三方重装脚本。

### 本地验证

```bash
bash -n debiankit.sh
bash -n lib/common.sh
bash -n modules/debian.sh
bash -n modules/reinstall.sh
python3 -B -m unittest discover -s tests -v
```

测试检查参数、配置生成、initramfs 打包、ISO 查找、阶段校验和引导回滚；系统工具和下载使用模拟实现。完整的 BIOS/UEFI 清盘重装需要在可丢弃虚拟机或目标服务器验证。当前测试不证明真实 Windows 安装及远程网络恢复已经成功。

模块通过独立 Bash 子进程执行，重装模块的严格模式、变量和失败清理不会污染主菜单。
