#!/usr/bin/env bash
# OS reinstallation module. All installer automation is implemented locally.
set -euo pipefail
umask 077

# id|display name|installer|release/image name|language
readonly -a OS_PRESETS=(
    'debian13|Debian 13|debian|trixie|en-us'
    'windows10-iot-ltsc|Windows 10 IoT Enterprise LTSC 2021 (x64)|windows|Windows 10 IoT Enterprise LTSC 2021|en-us'
)
readonly STATE_DIR='/var/lib/standalone-reinstall'
readonly BOOT_DIR='/boot/standalone-reinstall'
readonly GRUB_FRAGMENT='/etc/grub.d/99_standalone_reinstall'
readonly ENTRY_ID='standalone-reinstall'
# id|name|Debian locale|Debian keyboard|Windows language|Windows input|ISO|SHA-256
# Published Microsoft media hashes: https://awuctl.github.io/mvs/
readonly -a OS_LANGUAGES=(
    'en-us|English|en_US.UTF-8|us|en-US|0409:00000409|en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso|a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160'
    'zh-cn|简体中文|zh_CN.UTF-8|us|zh-CN|0804:00000804||'
)
readonly DEBIAN_MIRROR='https://deb.debian.org/debian'
readonly ALPINE_BASE='https://dl-cdn.alpinelinux.org/alpine/v3.22'
readonly VIRTIO_BASE='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio'

TARGET='' LABEL='' INSTALLER='' RELEASE='' LANGUAGE='en-US'
REQUESTED_LANGUAGE='' LANGUAGE_LABEL='English'
DEBIAN_LOCALE=en_US.UTF-8 KEYMAP=us INPUT_LOCALE=0409:00000409
WINDOWS_FILENAME='en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso'
WINDOWS_SHA256='a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160'
DRY_RUN=no DISK='' DISK_PTUUID='' DISK_BYTES='' BOOT_MODE=''
NETWORK_MODE=auto NIC='' MAC='' ADDRESS='' GATEWAY='' DNS='' NETMASK=''
HOSTNAME_VALUE='' SSH_PORT=22 RDP_PORT=3389 WEB_PORT=8080 WEB_PORT_SET=no WEB_TOKEN='' SSH_KEY_FILE='' ISO_URL=''
CUSTOM_ISO_SHA256='' ISO_SOURCE=ntriver WINDOWS_ISO_OPTION=no
PASSWORD_HASH='' WINDOWS_PASSWORD='' GENERATED_PASSWORD='' VIRTIO=no WORK_DIR='' PREPARING=no
GRUB_CONFIG='' GRUB_ENV='' GRUB_MKCONFIG='' GRUB_REBOOT='' GRUB_EDITENV='' GRUB_PROBE=''

fail() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

ui_section() {
    local color='' reset=''
    if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
        color=$'\033[1;34m'; reset=$'\033[0m'
    fi
    printf '\n%s%s%s\n%s\n' "$color" "$1" "$reset" '--------------------------------------'
}

ui_field() { printf '  %-12s %s\n' "$1" "$2"; }

progress_step() { printf '  [%s/3] %s\n' "$1" "$2"; }

login_account() {
    if [[ "$INSTALLER" == debian ]]; then printf root
    elif [[ "$LANGUAGE" == en-US ]]; then printf Administrator
    else printf 'Built-in administrator'; fi
}

show_help() {
    cat <<'EOF'
Standalone reinstaller

Usage:
  sudo bash debiankit.sh reinstall                    Interactive reinstallation menu
  sudo bash debiankit.sh reinstall debian13           Prepare Debian 13
  sudo bash debiankit.sh reinstall windows10-iot-ltsc Prepare IoT LTSC 2021 x64
  sudo bash debiankit.sh reinstall reset              Cancel BEFORE reboot
  bash debiankit.sh reinstall --list                  List presets
  bash debiankit.sh reinstall --languages             List supported languages
  bash debiankit.sh reinstall --dry-run PRESET        Preview without system changes

Options:
  --lang CODE                 Default en-us; other languages require a custom --url
  --disk /dev/sda             Explicit target disk (default: current root disk)
  --network auto|dhcp|static  Default: infer from the active IPv4 interface
  --address IPv4/PREFIX       Static address (default: current address)
  --gateway IPv4             Static gateway (default: current gateway)
  --dns IPv4[,IPv4]           Default: current upstream resolvers
  --hostname NAME            Default: keep the current system hostname
  --ssh-port PORT             Debian SSH / Windows installation environment
  --ssh-key FILE              Optional local OpenSSH public key file
  --web-port PORT             Debian installation web logs, default 8080
  --rdp-port PORT             Windows RDP port, default 3389
  --url HTTPS_URL             Debian installer directory or Windows ISO URL
  --iso HTTPS_URL             Windows ISO URL; alias of --url for Windows
  --iso-sha256 HASH           Custom ISO SHA-256 (default: original en-US IoT ISO hash)

Built-in sources only install English (United States), without a language prompt.
Custom sources allow English or Simplified Chinese; select with --lang or the menu.
Debian --url must contain SHA256SUMS and netboot/debian-installer/amd64 files.
Windows automatically downloads the original en-US IoT ISO from NTriver.
Other Windows languages require a matching custom IoT ISO URL and SHA-256.
The previous preset name windows10-ltsc remains an alias for windows10-iot-ltsc.

Run on an x86_64 Linux server with GRUB and BIOS or UEFI (Secure Boot off).
Debian uses its official network installer. Windows uses an Alpine RAM
environment, original Microsoft ISO, and Fedora VirtIO drivers when needed.
Passwords are requested interactively; Enter generates a password shown once on the terminal.
Preparation changes the boot configuration. Reboot manually to install.
Installation erases every partition on the selected disk.
EOF
}

list_presets() {
    local row id label _
    for row in "${OS_PRESETS[@]}"; do
        IFS='|' read -r id label _ <<< "$row"
        printf '  %-18s %s\n' "$id" "$label"
    done
}

select_preset() {
    local row id default_language requested="$1"
    [[ "$requested" != windows10-ltsc ]] || requested=windows10-iot-ltsc
    for row in "${OS_PRESETS[@]}"; do
        IFS='|' read -r id LABEL INSTALLER RELEASE default_language <<< "$row"
        if [[ "$id" == "$requested" ]]; then
            TARGET="$id"
            if [[ "$INSTALLER" == debian ]]; then
                (( 10#$WEB_PORT != 10#$SSH_PORT )) || fail 'SSH and web log ports must differ.'
            elif [[ "$WEB_PORT_SET" == yes ]]; then
                fail '--web-port currently applies to Debian installation logs.'
            fi
            if [[ "$INSTALLER" == debian && ( "$WINDOWS_ISO_OPTION" == yes || -n "$CUSTOM_ISO_SHA256" ) ]]; then
                fail 'Debian needs a network installer directory via --url; --iso and --iso-sha256 are Windows-only.'
            fi
            apply_language "${REQUESTED_LANGUAGE:-$default_language}"
            return
        fi
    done
    fail 'Unknown preset. Run bash debiankit.sh reinstall --list.'
}

list_languages() {
    local row id label locale keymap language input filename checksum note
    for row in "${OS_LANGUAGES[@]}"; do
        IFS='|' read -r id label locale keymap language input filename checksum <<< "$row"
        note=''
        [[ "$id" == en-us ]] || note=' (custom --url required; Windows also needs --iso-sha256)'
        printf '  %-8s %s%s\n' "$id" "$label" "$note"
    done
}

apply_language() {
    local requested="${1,,}" row id label locale keymap language input filename checksum
    for row in "${OS_LANGUAGES[@]}"; do
        IFS='|' read -r id label locale keymap language input filename checksum <<< "$row"
        [[ "$id" == "$requested" ]] || continue
        [[ "$id" == en-us || -n "$ISO_URL" ]] || fail 'Other languages require your own source: --url HTTPS_URL.'
        LANGUAGE_LABEL="$label"
        DEBIAN_LOCALE="$locale"; KEYMAP="$keymap"
        LANGUAGE="$language"; INPUT_LOCALE="$input"
        WINDOWS_FILENAME="$filename"; WINDOWS_SHA256="$checksum"
        if [[ "$INSTALLER" == windows ]]; then
            if [[ -n "$CUSTOM_ISO_SHA256" ]]; then
                WINDOWS_SHA256="${CUSTOM_ISO_SHA256,,}"
                WINDOWS_FILENAME=custom-iot-ltsc-2021.iso
            elif [[ -z "$WINDOWS_SHA256" ]]; then
                fail 'This Windows language requires a matching IoT ISO: --iso URL --iso-sha256 HASH.'
            fi
        fi
        return 0
    done
    fail 'Unsupported language. Run bash debiankit.sh reinstall --languages.'
}

choose_language() {
    [[ -z "$REQUESTED_LANGUAGE" ]] || return 0
    if [[ -z "$ISO_URL" || ( "$INSTALLER" == windows && -z "$CUSTOM_ISO_SHA256" ) ]]; then
        apply_language en-us
        return 0
    fi
    local row id label locale keymap language input filename checksum choice index=1
    printf '\nSelect system language (default: English, United States):\n'
    for row in "${OS_LANGUAGES[@]}"; do
        IFS='|' read -r id label locale keymap language input filename checksum <<< "$row"
        if [[ "$INSTALLER" == windows && -z "$filename" && -z "$CUSTOM_ISO_SHA256" ]]; then continue; fi
        printf '%02d. %s%s\n' "$index" "$label" "$([[ "$id" == en-us ]] && printf ' (default)')"
        index=$((index + 1))
    done
    printf '00. Cancel\n\n'
    while true; do
        if ! read -r -p 'Select language [Enter = 01]: ' choice; then
            printf '\nCancelled.\n'; return 1
        fi
        case "$choice" in
            '') apply_language en-us; return 0 ;;
            0|00) printf 'Cancelled.\n'; return 1 ;;
        esac
        index=1
        for row in "${OS_LANGUAGES[@]}"; do
            IFS='|' read -r id label locale keymap language input filename checksum <<< "$row"
            if [[ "$INSTALLER" == windows && -z "$filename" && -z "$CUSTOM_ISO_SHA256" ]]; then continue; fi
            if [[ "$choice" == "$index" || "$choice" == "$(printf '%02d' "$index")" || "${choice,,}" == "$id" ]]; then
                apply_language "$id"; return 0
            fi
            index=$((index + 1))
        done
        printf 'Invalid language. Select a listed number or language code.\n' >&2
    done
}

show_menu() {
    local row id label _ choice index
    printf '\nReinstall OS\n\n'
    index=1
    for row in "${OS_PRESETS[@]}"; do
        IFS='|' read -r id label _ <<< "$row"
        printf '%02d. %s\n' "$index" "$label"
        index=$((index + 1))
    done
    printf '99. Cancel pending installation\n00. Exit\n\n'
    while true; do
        read -r -p 'Select option: ' choice || fail 'Interactive input is required.'
        case "$choice" in
            0|00) TARGET='exit'; return ;;
            99) TARGET=reset; return ;;
        esac
        index=1
        for row in "${OS_PRESETS[@]}"; do
            if [[ "$choice" == "$index" || "$choice" == "$(printf '%02d' "$index")" ]]; then
                IFS='|' read -r id label _ <<< "$row"
                select_preset "$id"
                return
            fi
            index=$((index + 1))
        done
        printf 'Invalid option.\n' >&2
    done
}

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

resolve_hostname() {
    if [[ -z "$HOSTNAME_VALUE" ]]; then
        HOSTNAME_VALUE=$(uname -n) || fail 'Cannot read the current hostname. Use --hostname NAME.'
    fi
    if [[ "$INSTALLER" == windows ]]; then
        [[ "$HOSTNAME_VALUE" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,14}$ &&
           "$HOSTNAME_VALUE" != *- && ! "$HOSTNAME_VALUE" =~ ^[0-9]+$ ]] ||
            fail 'Windows hostname must contain only letters/digits/hyphens, not be all digits, and have at most 15 characters. Use --hostname NAME.'
    else
        [[ "$HOSTNAME_VALUE" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ &&
           "$HOSTNAME_VALUE" != *[-.] && "$HOSTNAME_VALUE" != *..* &&
           "$HOSTNAME_VALUE" != *.-* && "$HOSTNAME_VALUE" != *-.* ]] ||
            fail 'Debian hostname must contain valid letters/digits/hyphens or a domain name, with at most 63 characters. Use --hostname NAME.'
    fi
}

parse_args() {
    local name value
    while (( $# )); do
        case "$1" in
            -h|--help) show_help; TARGET='exit'; return ;;
            --list) list_presets; TARGET='exit'; return ;;
            --languages) list_languages; TARGET='exit'; return ;;
            --dry-run) DRY_RUN=yes; shift; continue ;;
            --disk|--network|--address|--gateway|--dns|--hostname|--ssh-port|--ssh-key|--rdp-port|--web-port|--iso|--url|--iso-sha256|--lang)
                name="$1"; shift
                (( $# )) && [[ -n "$1" && "$1" != --* ]] || fail 'Option requires a value.'
                value="$1"
                case "$name" in
                    --disk) DISK="$value" ;;
                    --network) NETWORK_MODE="$value" ;;
                    --address) ADDRESS="$value" ;;
                    --gateway) GATEWAY="$value" ;;
                    --dns) DNS="$value" ;;
                    --hostname) HOSTNAME_VALUE="$value" ;;
                    --ssh-port) SSH_PORT="$value" ;;
                    --ssh-key) SSH_KEY_FILE="$value" ;;
                    --rdp-port) RDP_PORT="$value" ;;
                    --web-port) WEB_PORT="$value"; WEB_PORT_SET=yes ;;
                    --iso) ISO_URL="$value"; ISO_SOURCE=custom; WINDOWS_ISO_OPTION=yes ;;
                    --url) ISO_URL="$value"; ISO_SOURCE=custom ;;
                    --iso-sha256) CUSTOM_ISO_SHA256="$value" ;;
                    --lang) REQUESTED_LANGUAGE="$value" ;;
                esac
                ;;
            -*) fail 'Unknown option. Run bash debiankit.sh reinstall --help.' ;;
            *) [[ -z "$TARGET" ]] || fail 'Choose one preset.'; TARGET="$1" ;;
        esac
        shift
    done
    case "$NETWORK_MODE" in auto|dhcp|static) ;; *) fail 'Invalid network mode.' ;; esac
    if ! valid_port "$SSH_PORT" || ! valid_port "$RDP_PORT" || ! valid_port "$WEB_PORT"; then fail 'Port must be between 1 and 65535.'; fi
    if [[ -n "$ISO_URL" ]]; then
        [[ "$ISO_URL" == https://* && "$ISO_URL" != *[$'\r\n']* ]] || fail 'ISO must be an HTTPS URL.'
    fi
    if [[ -n "$CUSTOM_ISO_SHA256" ]]; then
        [[ "$CUSTOM_ISO_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'ISO SHA-256 must contain exactly 64 hexadecimal characters.'
        [[ -n "$ISO_URL" ]] || fail '--iso-sha256 requires --iso or --url.'
    fi
    if [[ -n "$SSH_KEY_FILE" ]]; then
        [[ -f "$SSH_KEY_FILE" ]] || fail 'SSH public key file does not exist.'
        ssh-keygen -l -f "$SSH_KEY_FILE" >/dev/null 2>&1 || fail 'Invalid OpenSSH public key file.'
    fi
}

show_configuration() {
    local mode="$1" source disk="${DISK:-Auto (current system disk)}" boot network
    ui_field 'System:' "$LABEL"
    ui_field 'Language:' "$LANGUAGE_LABEL ($LANGUAGE)"
    if [[ -n "$ISO_URL" ]]; then source='Your custom source (URL hidden)'
    elif [[ "$INSTALLER" == windows ]]; then source='NTriver / original IoT ISO'
    else source='Debian official network installer'; fi
    ui_field 'Source:' "$source"
    if [[ "$mode" == detected ]]; then
        disk+=" ($(awk -v bytes="$DISK_BYTES" 'BEGIN { printf "%.1f GiB", bytes / 1073741824 }'))"
        if [[ "$BOOT_MODE" == efi ]]; then boot=UEFI; else boot=BIOS; fi
    else boot='Not checked'; fi
    ui_field 'Disk:' "$disk"
    ui_field 'Boot:' "$boot"
    case "$NETWORK_MODE" in
        static) network='Static IPv4' ;;
        dhcp) network='DHCP' ;;
        *) network='Auto (not checked)' ;;
    esac
    ui_field 'Network:' "$network"
    if [[ "$mode" == detected ]]; then
        ui_field 'Interface:' "${NIC:+$NIC / }$MAC"
    fi
    if [[ "$NETWORK_MODE" == static ]]; then
        ui_field 'IPv4:' "${ADDRESS:-Not specified}"
        ui_field 'Gateway:' "${GATEWAY:-Not specified}"
        ui_field 'DNS:' "${DNS:-Use current system DNS}"
    fi
    ui_field 'Hostname:' "$HOSTNAME_VALUE"
    if [[ "$INSTALLER" == windows ]]; then
        ui_field 'Login:' "$(login_account) / RDP port $RDP_PORT"
        ui_field 'ISO file:' "$WINDOWS_FILENAME"
    else
        ui_field 'Login:' "root / SSH port $SSH_PORT"
        ui_field 'Progress:' "VNC / serial, SSH, web port $WEB_PORT"
    fi
}

preview() {
    ui_section 'Reinstall OS - Preview'
    show_configuration preview
    printf '\nPreview only. Disk and network have not been checked.\n'
    printf 'Nothing is downloaded or changed. Installation requires a manual reboot.\n'
}

show_generated_password() {
    [[ -n "${GENERATED_PASSWORD:-}" ]] || return 0
    # Display once on the controlling terminal, never in redirected logs.
    printf '\n  Generated password: %s\n  Save it now. It will not be shown again.\n' "$GENERATED_PASSWORD" > /dev/tty ||
        fail 'Cannot display the generated password in the current terminal.'
    unset GENERATED_PASSWORD
}

show_ready() {
    ui_section 'Ready to reboot'
    printf 'Preparation completed. Installation has not started.\n'
    if [[ "$INSTALLER" == windows ]]; then
        printf 'The full Windows ISO will be verified after reboot, before disk erasure.\n'
    fi
    show_generated_password
    if [[ "$INSTALLER" == debian ]]; then
        local host="${ADDRESS%/*}"
        host="${host:-VPS_IP}"
        printf '\n  Progress after reboot (once the network is up):\n'
        printf '    VNC / serial: shared installer screen\n'
        printf '    SSH: ssh -p %s root@%s\n' "$SSH_PORT" "$host"
        if [[ -n "$SSH_KEY_FILE" ]]; then printf '    SSH login: your specified SSH key\n'
        else printf '    SSH login: the NEW password set for this reinstallation\n'; fi
        printf '    Installer: TERM=screen screen -x reinstall -p 1 (Ctrl+A, D to detach)\n'
        printf '    Logs: /reinstall/view-logs.sh\n'
        if [[ -t 0 && -n "$WEB_TOKEN" ]]; then
            printf '    Web logs (private link): http://%s:%s/%s\n' "$host" "$WEB_PORT" "$WEB_TOKEN" > /dev/tty ||
                fail 'Cannot show the private web log link on the terminal.'
        else
            printf '    Web logs: private link saved in %s/progress-access (mode 600)\n' "$STATE_DIR"
        fi
        printf '    Allow inbound TCP %s and %s in the VPS firewall.\n' "$SSH_PORT" "$WEB_PORT"
    fi
    printf '\n  Start installation:\n    sudo reboot\n'
    printf '\n  Cancel before reboot:\n    sudo bash debiankit.sh reinstall reset\n'
    printf '\nWARNING: Starting installation will erase ALL partitions and data on %s.\n' "$DISK"
}

find_grub() {
    local prefix
    for prefix in grub grub2; do
        if command -v "$prefix-mkconfig" >/dev/null && command -v "$prefix-reboot" >/dev/null &&
           command -v "$prefix-editenv" >/dev/null && command -v "$prefix-probe" >/dev/null; then
            GRUB_MKCONFIG="$prefix-mkconfig"; GRUB_REBOOT="$prefix-reboot"
            GRUB_EDITENV="$prefix-editenv"; GRUB_PROBE="$prefix-probe"
            break
        fi
    done
    [[ -n "$GRUB_MKCONFIG" ]] || fail 'GRUB tools are required; this script does not replace the current bootloader.'
    for GRUB_CONFIG in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
        [[ -f "$GRUB_CONFIG" ]] && break
    done
    [[ -f "$GRUB_CONFIG" && -d /etc/grub.d ]] || fail 'Unsupported GRUB configuration layout.'
    GRUB_ENV="${GRUB_CONFIG%/*}/grubenv"
    [[ -f "$GRUB_ENV" ]] || fail 'GRUB environment block is missing.'
    [[ "$(findmnt -nro FSTYPE -T "$GRUB_ENV")" == ext[234] ]] ||
        fail 'One-shot boot currently requires grubenv on ext2/ext3/ext4 (no Btrfs/RAID/LVM boot filesystem).'
    [[ "$(findmnt -nro SOURCE -T "$GRUB_ENV")" == /dev/* ]] || fail 'Unsupported boot filesystem.'
    [[ "$(lsblk -dnro TYPE "$(findmnt -nro SOURCE -T "$GRUB_ENV")")" == part ]] ||
        fail 'GRUB boot files must be on a regular partition, not LVM/RAID.'
    # The environment block must be read by grub.cfg for a one-shot entry to work.
    grep -q 'next_entry' "$GRUB_CONFIG" || fail 'Current GRUB configuration does not support one-shot entries.'
}

check_runtime() {
    [[ "$EUID" -eq 0 ]] || fail 'Run sudo bash debiankit.sh reinstall on the target server.'
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail 'Only x86_64 Linux hosts are currently supported.'
    [[ "$(</proc/sys/kernel/osrelease)" != *[Mm]icrosoft* ]] || fail 'WSL is unsupported.'
    if command -v systemd-detect-virt >/dev/null && systemd-detect-virt --container --quiet; then
        fail 'Container hosts are unsupported.'
    fi
    [[ -t 0 ]] || fail 'An interactive terminal is required; do not pipe the script to bash.'
    local command_name
    for command_name in curl python3 cpio gzip openssl ip lsblk blkid findmnt install sha256sum ssh-keygen; do
        command -v "$command_name" >/dev/null || fail "Missing required command: $command_name"
    done
    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE=efi
        if compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' >/dev/null; then
            local variable
            for variable in /sys/firmware/efi/efivars/SecureBoot-*; do
                [[ "$(od -An -tu1 -j4 -N1 "$variable" | tr -d ' ')" != 1 ]] || fail 'Disable Secure Boot before reinstalling.'
            done
        fi
    else BOOT_MODE=bios; fi
    find_grub
}

detect_disk() {
    local root_source candidate type
    if [[ -z "$DISK" ]]; then
        root_source=$(findmnt -nro SOURCE /)
        [[ "$root_source" == /dev/* ]] || fail 'Cannot determine root block device; specify --disk.'
        local -a disks=()
        while read -r candidate type; do
            [[ "$type" != disk ]] || disks+=("$candidate")
        done < <(lsblk -snrpo NAME,TYPE "$root_source")
        (( ${#disks[@]} == 1 )) || fail 'Root spans multiple disks; automatic selection is unsupported.'
        DISK="${disks[0]}"
    fi
    DISK=$(readlink -f "$DISK")
    [[ -b "$DISK" && "$(lsblk -dnro TYPE "$DISK")" == disk ]] || fail 'Target must be a whole block disk.'
    local boot_disk_count=0 boot_disk='' boot_device
    boot_device=$(findmnt -nro SOURCE -T "$GRUB_ENV")
    while read -r candidate type; do
        if [[ "$type" == disk ]]; then boot_disk="$candidate"; boot_disk_count=$((boot_disk_count + 1)); fi
    done < <(lsblk -snrpo NAME,TYPE "$boot_device")
    [[ "$boot_disk_count" -eq 1 && "$DISK" == "$boot_disk" ]] ||
        fail 'The selected disk must contain the current GRUB boot filesystem.'
    DISK_PTUUID=$(blkid -s PTUUID -o value "$DISK")
    [[ "$DISK_PTUUID" =~ ^[a-fA-F0-9-]+$ ]] || fail 'Target disk needs an existing partition-table ID.'
    DISK_BYTES=$(lsblk -bdnro SIZE "$DISK")
    local memory_kib minimum_disk minimum_memory
    memory_kib=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    if [[ "$INSTALLER" == windows ]]; then minimum_disk=51539607552; minimum_memory=2097152
    else minimum_disk=4294967296; minimum_memory=524288; fi
    (( DISK_BYTES >= minimum_disk && memory_kib >= minimum_memory )) ||
        fail 'Minimum resources: Debian 512 MiB RAM / 4 GiB disk; Windows 2 GiB RAM / 48 GiB disk.'
}

detect_network() {
    local route current_address current_gateway current_dns
    route=$(ip -4 route get 1.1.1.1)
    NIC=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route")
    [[ -n "$NIC" && -r "/sys/class/net/$NIC/address" ]] || fail 'No usable IPv4 interface found.'
    [[ -e "/sys/class/net/$NIC/device" ]] || fail 'Bridge, bond, tunnel and VLAN interfaces are not implemented.'
    local interface physical_count=0
    for interface in /sys/class/net/*; do
        [[ ! -e "$interface/device" ]] || physical_count=$((physical_count + 1))
    done
    (( physical_count == 1 )) || fail 'Multiple physical network adapters are not implemented in this version.'
    MAC=$(cat "/sys/class/net/$NIC/address")
    current_address=$(ip -4 -o addr show dev "$NIC" scope global | awk 'NR==1 {print $4}')
    current_gateway=$(ip -4 route show default dev "$NIC" | awk '/via/ {print $3; exit}')
    ADDRESS="${ADDRESS:-$current_address}"; GATEWAY="${GATEWAY:-$current_gateway}"
    if [[ "$NETWORK_MODE" == auto ]]; then
        if ip -4 -o addr show dev "$NIC" | grep -qw dynamic; then NETWORK_MODE=dhcp
        else NETWORK_MODE=static; fi
    fi
    current_dns=$(awk '$1=="nameserver" && $2 !~ /^127\./ && $2 !~ /:/ {print $2}' /etc/resolv.conf | paste -sd,)
    if [[ -z "$current_dns" ]] && command -v resolvectl >/dev/null; then
        current_dns=$(resolvectl dns "$NIC" 2>/dev/null | sed 's/^[^:]*: //' | tr ' ' ',')
    fi
    DNS="${DNS:-${current_dns:-1.1.1.1,8.8.8.8}}"
    validate_network
    local vendor_file
    for vendor_file in /sys/bus/pci/devices/*/vendor; do
        [[ -r "$vendor_file" ]] || continue
        if [[ "$(<"$vendor_file")" == 0x1af4 ]]; then VIRTIO=yes; fi
    done
    if [[ "$INSTALLER" == windows ]] && compgen -G '/sys/bus/pci/devices/*/vendor' >/dev/null; then
        if grep -l -E '0x1d0f|0x1ae0|0x5853' /sys/bus/pci/devices/*/vendor >/dev/null; then
            fail 'AWS, Google gVNIC and Xen Windows drivers are not implemented in this independent version.'
        fi
    fi
}

validate_network() {
    NETMASK=$(python3 - "$ADDRESS" "$GATEWAY" "$DNS" "$NETWORK_MODE" <<'PY'
import ipaddress, sys
try:
    addr = ipaddress.IPv4Interface(sys.argv[1])
    for dns in sys.argv[3].split(','): ipaddress.IPv4Address(dns)
    if sys.argv[4] == 'static':
        gw = ipaddress.IPv4Address(sys.argv[2])
        if gw not in addr.network or addr.network.prefixlen >= 31:
            raise ValueError('Static /31, /32 or gateway outside the subnet is not yet supported.')
    print(addr.netmask)
except ValueError as error:
    print(str(error), file=sys.stderr); sys.exit(1)
PY
    ) || fail 'Unsupported IPv4 network; check --network/--address/--gateway/--dns.'
}

read_password() {
    local password confirmation generated=no
    GENERATED_PASSWORD=''
    read -r -s -p 'New password [Enter = generate]: ' password || fail 'Password input ended; installation was not prepared.'
    printf '\n'
    if [[ -z "$password" ]]; then
        password=$(python3 - <<'PY'
import secrets, string
groups = (string.ascii_lowercase, string.ascii_uppercase, string.digits, '!@#%-_')
characters = ''.join(groups)
password = [secrets.choice(group) for group in groups]
password += [secrets.choice(characters) for _ in range(16)]
secrets.SystemRandom().shuffle(password)
print(''.join(password))
PY
        ) || fail 'Random password generation failed.'
        generated=yes
    else
        read -r -s -p 'Confirm password: ' confirmation || fail 'Password confirmation ended; installation was not prepared.'
        printf '\n'
        [[ "$password" == "$confirmation" ]] || fail 'Passwords must match.'
    fi
    [[ "$password" != *[$'\r\n']* ]] || fail 'Password cannot contain line breaks.'
    PASSWORD_HASH=$(printf '%s' "$password" | openssl passwd -6 -stdin)
    if [[ "$INSTALLER" == windows ]]; then
        WINDOWS_PASSWORD=$(printf '%s' "$password" | python3 -c 'import sys,base64; print(base64.b64encode((sys.stdin.read()+"AdministratorPassword").encode("utf-16le")).decode())')
    fi
    if [[ "$generated" == yes ]]; then
        # Verify the terminal before preparing boot files, then show the password with the result.
        { : > /dev/tty; } 2>/dev/null || fail 'A controlling terminal is required to show the generated password.'
        GENERATED_PASSWORD="$password"
    fi
    unset password confirmation
}

download() {
    local url="$1" destination="$2"
    # URLs can contain credentials; never print them or curl error output.
    curl -4 -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 \
        --retry 2 --retry-delay 2 "$url" -o "$destination" 2>/dev/null || fail 'Download failed; check network or provide a different HTTPS source.'
}

check_hash() {
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file"); actual="${actual%% *}"
    [[ "${actual,,}" == "${expected,,}" ]] || fail 'Downloaded file failed SHA-256 verification.'
}

write_windows_iso_resolver() {
    cat > "$1" <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import urlencode, urlsplit

source, value, destination, expected_hash = sys.argv[1:]
curl = ['curl', '-4', '-fLsS', '--proto', '=https', '--proto-redir', '=https',
        '--connect-timeout', '15', '--max-time', '40', '--retry', '1']
try:
    if source == 'ntriver':
        if not re.fullmatch(r'[A-Za-z0-9_.-]+\.iso', value):
            raise ValueError('Invalid NTriver ISO filename.')
        api = 'https://ntriver.org/api/drive/generate-link?' + urlencode({'filename': value})
        response = subprocess.run(curl + [api], capture_output=True, check=True)
        metadata = json.loads(response.stdout)
        if metadata.get('success') is not True or metadata.get('filename') != value:
            raise ValueError('NTriver did not return the requested ISO.')
        if str(metadata.get('sha256', '')).casefold() != expected_hash.casefold():
            raise ValueError('NTriver ISO checksum differs from the configured original hash.')
        url = metadata.get('url', '')
    elif source == 'custom':
        url = value
    else:
        raise ValueError('Unknown ISO source.')
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or '\n' in url or '\r' in url:
        raise ValueError('Source did not provide a valid HTTPS ISO URL.')
    with tempfile.TemporaryDirectory(prefix='iso-probe-') as directory:
        headers = Path(directory) / 'headers'
        body = Path(directory) / 'byte'
        subprocess.run(curl + ['--max-filesize', '1048576', '--range', '0-0', '-D', str(headers),
                              url, '-o', str(body)], capture_output=True, check=True)
        header = headers.read_text().replace('\r', '')
        if body.stat().st_size != 1 or not re.search(r'^content-range:\s*bytes 0-0/\d+\s*$', header, re.M | re.I):
            raise ValueError('ISO source does not support HTTPS byte-range access.')
    Path(destination).write_text(url + '\n')
except (ValueError, TypeError, AttributeError, KeyError, OSError, subprocess.CalledProcessError):
    # Do not expose signed URLs or server response bodies in error output.
    print('Cannot obtain a usable ISO URL from the selected source. Check NTriver or provide --iso/--url.', file=sys.stderr)
    sys.exit(1)
PY
}

resolve_iso() {
    local value="$WINDOWS_FILENAME"
    if [[ -n "$ISO_URL" ]]; then ISO_SOURCE=custom; value="$ISO_URL"; fi
    write_windows_iso_resolver "$WORK_DIR/resolve-iso.py"
    python3 "$WORK_DIR/resolve-iso.py" "$ISO_SOURCE" "$value" "$WORK_DIR/iso-url" "$WINDOWS_SHA256" ||
        fail 'ISO source check failed. No boot entry was created.'
    ISO_URL=$(cat "$WORK_DIR/iso-url")
}

pack_initrd() {
    local source="$1" overlay="$2" destination="$3"
    cp "$source" "$destination"
    (cd "$overlay" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -1) >> "$destination"
    chmod 0600 "$destination"
}

# Installer generators are defined below. All generated automation is local.

write_debian_package_tool() {
    cat > "$1" <<'PY'
import gzip
import hashlib
import io
from pathlib import Path, PurePosixPath
import posixpath
import re
import sys
import tarfile

def records(text):
    result = {}
    for block in text.split('\n\n'):
        record = {}
        key = None
        for line in block.splitlines():
            if line.startswith(' ') and key:
                record[key] += ' ' + line.strip()
            elif ': ' in line:
                key, value = line.split(': ', 1)
                record[key] = value
        if 'Package' in record:
            result[record['Package']] = record
    return result

def plan(release, index, destination):
    expected = None
    in_hashes = False
    index_name = 'main/debian-installer/binary-amd64/Packages.gz'
    for line in Path(release).read_text().splitlines():
        if not line.startswith(' '):
            in_hashes = line == 'SHA256:'
        elif in_hashes:
            fields = line.split()
            if len(fields) == 3 and fields[2] == index_name:
                expected = fields[0]
    data = Path(index).read_bytes()
    if not expected or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('Debian installer package index checksum failed.')
    packages = records(gzip.decompress(data).decode())
    selected = set()
    ordered = []
    def add(name):
        if name in selected:
            return
        if name not in packages:
            raise ValueError('Required Debian installer package is unavailable.')
        selected.add(name)
        record = packages[name]
        for dependency in record.get('Depends', '').split(','):
            if not dependency.strip():
                continue
            choices = [re.match(r'\s*([a-z0-9+.-]+)', item).group(1) for item in dependency.split('|')]
            available = next((item for item in choices if item in packages), None)
            if not available:
                raise ValueError('Required installer package dependency is unavailable.')
            add(available)
        filename = record.get('Filename', '')
        digest = record.get('SHA256', '')
        if (not re.fullmatch(r'pool/[A-Za-z0-9+._~/-]+\.udeb', filename)
                or '..' in PurePosixPath(filename).parts or not re.fullmatch('[0-9a-f]{64}', digest)):
            raise ValueError('Invalid installer package metadata.')
        ordered.append(name+'\t'+filename+'\t'+digest)
    for name in ('openssh-server-udeb', 'screen-udeb'):
        add(name)
    Path(destination).write_text('\n'.join(ordered)+'\n')

def normalized(name):
    name = name[2:] if name.startswith('./') else name
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts:
        raise ValueError('Unsafe package path.')
    if not path.parts:
        return ''
    # Debian 13's installer uses usrmerge. Keep the overlay consistent with it.
    if path.parts[0] in ('bin', 'sbin', 'lib', 'lib64'):
        path = PurePosixPath('usr') / path
    return str(path)

def extract(archive, destination):
    data = Path(archive).read_bytes()
    if not data.startswith(b'!<arch>\n'):
        raise ValueError('Invalid Debian archive.')
    offset = 8
    payload = None
    while offset + 60 <= len(data):
        header = data[offset:offset+60]
        if header[58:60] != b'`\n':
            raise ValueError('Invalid archive header.')
        name = header[:16].decode().strip().rstrip('/')
        size = int(header[48:58])
        offset += 60
        if name.startswith('data.tar.'):
            payload = data[offset:offset+size]
            break
        offset += size + size % 2
    if payload is None:
        raise ValueError('Debian archive has no data payload.')
    root = Path(destination).resolve()
    root.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:*') as package:
        for member in package:
            name = normalized(member.name)
            if not name or name == '.':
                continue
            target = root / name
            if root not in (target.resolve(), *target.resolve().parents):
                raise ValueError('Package path escapes the overlay.')
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                target.mkdir(exist_ok=True)
                target.chmod(member.mode & 0o777)
            elif member.isfile():
                if target.is_symlink():
                    target.unlink()
                target.write_bytes(package.extractfile(member).read())
                target.chmod(member.mode & 0o777)
            elif member.issym():
                if member.linkname.startswith('/'):
                    link = posixpath.relpath(normalized(member.linkname[1:]), str(PurePosixPath(name).parent))
                else:
                    link = member.linkname
                if root not in ((target.parent/link).resolve(), *(target.parent/link).resolve().parents):
                    raise ValueError('Unsafe package symlink.')
                if target.exists() or target.is_symlink():
                    target.unlink()
                target.symlink_to(link)
            else:
                raise ValueError('Unsupported package archive entry.')

try:
    if sys.argv[1] == 'plan':
        plan(*sys.argv[2:])
    elif sys.argv[1] == 'extract':
        extract(*sys.argv[2:])
    else:
        raise ValueError('Unknown installer package operation.')
except (ValueError, KeyError, OSError, tarfile.TarError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
PY
}

prepare_debian_monitor_packages() {
    local name filename digest
    write_debian_package_tool "$WORK_DIR/debian-packages.py"
    download "$DEBIAN_MIRROR/dists/$RELEASE/Release" "$WORK_DIR/debian-release"
    download "$DEBIAN_MIRROR/dists/$RELEASE/main/debian-installer/binary-amd64/Packages.gz" "$WORK_DIR/debian-packages.gz"
    python3 "$WORK_DIR/debian-packages.py" plan "$WORK_DIR/debian-release" "$WORK_DIR/debian-packages.gz" "$WORK_DIR/debian-package-plan" ||
        fail 'Cannot resolve verified Debian monitoring packages.'
    while IFS=$'\t' read -r name filename digest; do
        download "$DEBIAN_MIRROR/$filename" "$WORK_DIR/$name.udeb"
        check_hash "$WORK_DIR/$name.udeb" "$digest"
        python3 "$WORK_DIR/debian-packages.py" extract "$WORK_DIR/$name.udeb" "$WORK_DIR/overlay" ||
            fail 'Cannot extract a verified Debian monitoring package.'
    done < "$WORK_DIR/debian-package-plan"
}

write_debian_monitoring() {
    local directory="$1" key='' host="${ADDRESS%/*}"
    [[ -z "$SSH_KEY_FILE" ]] || key=$(cat "$SSH_KEY_FILE")
    WEB_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))') || fail 'Cannot generate the private web log address.'
    install -d -m 0700 "$directory/reinstall"
    chmod 0755 "$directory"
    install -d -m 0755 "$directory/usr/lib/debian-installer.d" "$directory/usr/lib/debian-installer-startup.d" "$directory/usr/sbin"
    printf 'SSH_PORT=%s\nWEB_PORT=%s\nWEB_TOKEN=%s\n' "$SSH_PORT" "$WEB_PORT" "$WEB_TOKEN" > "$directory/reinstall/progress.conf"
    printf '%s\n' "$PASSWORD_HASH" > "$directory/reinstall/password-hash"
    if [[ ! -f "$directory/reinstall/ssh-host-key" ]]; then
        ssh-keygen -q -t ed25519 -N '' -f "$directory/reinstall/ssh-host-key" </dev/null >/dev/null 2>&1 ||
            fail 'Cannot generate the installation SSH host key.'
    fi
    if [[ -n "$key" ]]; then printf '%s\n' "$key" > "$directory/reinstall/authorized_keys"; fi
    printf 'http://%s:%s/%s\n' "${host:-VPS_IP}" "$WEB_PORT" "$WEB_TOKEN" > "$WORK_DIR/../progress-access"
    chmod 0600 "$directory/reinstall/progress.conf" "$directory/reinstall/password-hash" "$WORK_DIR/../progress-access"
    cat > "$directory/reinstall/filter-logs.awk" <<'AWK'
/BEGIN .*PRIVATE KEY/ {private_key=1; next}
private_key {if ($0 ~ /END .*PRIVATE KEY/) private_key=0; next}
{ line=tolower($0) }
line !~ /password|passwd|token|secret|authorization|authorized_keys|preseed|shadow|private key/ &&
$0 !~ /\$[1256y]\$/ {
    gsub(/https?:\/\/[^[:space:]]+/, "[download URL]", $0)
    print; fflush()
}
AWK
    cat > "$directory/reinstall/view-logs.sh" <<'SH'
#!/bin/sh
tail -n 80 -f /var/log/syslog | awk -f /reinstall/filter-logs.awk
SH
    cat > "$directory/reinstall/web-request.sh" <<'SH'
#!/bin/sh
set -eu
. /reinstall/progress.conf
request_pid=$$
(sleep 10; kill -TERM "$request_pid" 2>/dev/null || true) </dev/null >/dev/null 2>&1 &
watchdog=$!
trap 'kill "$watchdog" 2>/dev/null || true' EXIT
response() {
    printf 'HTTP/1.0 %s\r\nContent-Type: %s\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n' "$1" "$2"
}
IFS=' ' read -r method path version || exit 0
lines=0
while IFS= read -r header; do
    [ "$header" != "$(printf '\r')" ] && [ -n "$header" ] || break
    lines=$((lines + 1))
    [ "$lines" -le 40 ] && [ "${#header}" -le 4096 ] || exit 0
done
if [ "$method" != GET ]; then response '405 Method Not Allowed' 'text/plain'; exit 0; fi
case "$path" in
    "/$WEB_TOKEN"|"/$WEB_TOKEN/")
        response '200 OK' 'text/html; charset=utf-8'
        cat <<'HTML'
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Debian installation progress</title>
<style>body{margin:2rem auto;max-width:1100px;padding:0 1rem;background:#111827;color:#e5e7eb;font:16px system-ui}header{display:flex;justify-content:space-between;gap:1rem;align-items:center}h1{font-size:1.4rem}#status{color:#93c5fd}pre{background:#030712;border:1px solid #374151;border-radius:8px;padding:1rem;white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.5}p{color:#9ca3af}</style>
<header><h1>Debian installation progress</h1><span id="status">Connecting...</span></header>
<p>Updates every 2 seconds. Closing this page does not stop installation. An unreachable page can mean the server is rebooting; use VNC to confirm.</p>
<pre id="log">Waiting for installer logs...</pre>
<script>
const base=location.pathname.replace(/\/$/,''),output=document.getElementById('log'),status=document.getElementById('status');
async function update(){try{const response=await fetch(base+'/logs',{cache:'no-store'});if(!response.ok)throw Error();output.textContent=await response.text();status.textContent='Updated '+new Date().toLocaleTimeString();}catch{status.textContent='Connection lost - check VNC';}finally{setTimeout(update,2000);}}update();
</script></html>
HTML
        ;;
    "/$WEB_TOKEN/logs")
        response '200 OK' 'text/plain; charset=utf-8'
        {
            if [ -r /var/log/reinstall-monitor.log ]; then tail -n 120 /var/log/reinstall-monitor.log; fi
            if [ -r /var/log/syslog ]; then tail -n 160 /var/log/syslog
            else printf 'Waiting for installer logs...\n'; fi
        } | awk -f /reinstall/filter-logs.awk
        ;;
    *) response '404 Not Found' 'text/plain'; printf 'Not found.\n' ;;
esac
SH
    cat > "$directory/reinstall/web-server.sh" <<'SH'
#!/bin/sh
set -eu
. /reinstall/progress.conf
while :; do
    # BusyBox's persistent listener forks a handler per connection, without polling gaps.
    nc -ll -p "$WEB_PORT" -e /reinstall/web-request.sh || sleep 1
done
SH
    cat > "$directory/reinstall/console-session.sh" <<'SH'
#!/bin/sh
set -eu
export TERM="${TERM:-linux}"
count=0
until screen -ls 2>/dev/null | grep -q '\.reinstall[[:space:]]'; do
    count=$((count + 1))
    if [ "$count" -eq 15 ]; then printf 'Waiting for the primary installer console...\n'; fi
    sleep 1
done
exec screen -x reinstall -p 1
SH
    cat > "$directory/usr/sbin/reopen-console" <<'SH'
#!/bin/sh
# Start the official installer once, on a usable visual console when present.
set -eu
mkdir -p /var/run /var/log
primary=''
visual=no
[ ! -d /sys/class/graphics/fb0 ] || visual=yes
for class in /sys/bus/pci/devices/*/class; do
    [ -r "$class" ] || continue
    case "$(cat "$class")" in 0x0300*) visual=yes ;; esac
done
if [ "$visual" = yes ] && [ -c /dev/tty1 ] && stty -g -F /dev/tty1 >/dev/null 2>&1; then
    primary=/dev/tty1
else
    primary=$(awk '/\([^)]*C[^)]*\)/ {print "/dev/"$1; exit}' /proc/consoles)
    [ "$primary" != /dev/tty0 ] || primary=/dev/tty1
    [ -n "$primary" ] && [ -c "$primary" ] || primary=/dev/console
fi
printf '%s\n' "$primary" > /var/run/console-preferred
printf '%s\n' "$primary" > /var/run/console-devices
tty=${primary##*/}
grep -q "^$tty::respawn:/sbin/debian-installer$" /etc/inittab ||
    printf '%s::respawn:/sbin/debian-installer\n' "$tty" >> /etc/inittab
printf 'Primary installer console: %s\n' "$primary" >> /var/log/reinstall-monitor.log
/sbin/steal-ctty "$primary" "$@"
kill -HUP 1
SH
    cat > "$directory/usr/lib/debian-installer.d/S70menu" <<'SH'
# One installer process, shared by VGA, serial consoles and SSH.
set +e
if screen -ls 2>/dev/null | grep -q '\.reinstall[[:space:]]'; then
    screen -x reinstall -p 1
else
    screen -U -S reinstall -t installer /lib/debian-installer/menu
fi
EXIT=$?
set -e
SH
    cat > "$directory/reinstall/start-monitoring.sh" <<'SH'
#!/bin/sh
set -eu
. /reinstall/progress.conf
mkdir -p /run/sshd /etc/ssh /root/.ssh /var/log
chmod 0755 /run/sshd
chmod 0700 /root /root/.ssh
hash=$(cat /reinstall/password-hash)
awk -F: 'BEGIN {OFS=FS} $1=="root" {$2="x";$6="/root";$7="/bin/sh"} {print}' /etc/passwd > /etc/passwd.reinstall
mv /etc/passwd.reinstall /etc/passwd
if [ -f /etc/shadow ]; then
    awk -F: -v hash="$hash" 'BEGIN {OFS=FS} $1=="root" {$2=hash;found=1} {print} END {if(!found) print "root",hash,1,0,99999,7,"","",""}' /etc/shadow > /etc/shadow.reinstall
else
    printf 'root:%s:1:0:99999:7:::\n' "$hash" > /etc/shadow.reinstall
fi
chmod 0600 /etc/shadow.reinstall
mv /etc/shadow.reinstall /etc/shadow
unset hash
grep -q '^sshd:' /etc/passwd || printf 'sshd:x:100:65534:sshd:/run/sshd:/bin/false\n' >> /etc/passwd
grep -q '^nogroup:' /etc/group || printf 'nogroup:x:65534:\n' >> /etc/group
cat > /etc/ssh/sshd_config <<EOF
Port $SSH_PORT
HostKey /reinstall/ssh-host-key
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PrintMotd yes
AuthorizedKeysFile /root/.ssh/authorized_keys
Subsystem sftp internal-sftp
AllowUsers root
EOF
if [ -s /reinstall/authorized_keys ]; then
    cp /reinstall/authorized_keys /root/.ssh/authorized_keys
    chmod 0600 /root/.ssh/authorized_keys
    printf 'PasswordAuthentication no\n' > /tmp/reinstall-key-sshd
    cat /etc/ssh/sshd_config >> /tmp/reinstall-key-sshd
    mv /tmp/reinstall-key-sshd /etc/ssh/sshd_config
fi
cat > /etc/motd <<'MOTD'
Reinstallation is in progress.
  Installer: TERM=screen screen -x reinstall -p 1
  Detach:    Ctrl+A, then D (installation continues)
  Logs:      /reinstall/view-logs.sh
MOTD
if ! grep -q 'reinstall/console-session.sh' /etc/inittab; then
    primary=$(awk '{print $1}' /var/run/console-preferred 2>/dev/null || true)
    for tty in tty1 ttyS0; do
        [ "/dev/$tty" != "$primary" ] || continue
        [ -c "/dev/$tty" ] || continue
        stty -g -F "/dev/$tty" >/dev/null 2>&1 || continue
        grep -q "^$tty:" /etc/inittab && continue
        printf '%s::respawn:/reinstall/console-session.sh\n' "$tty" >> /etc/inittab
    done
fi
/usr/sbin/sshd -t
if ! pidof sshd >/dev/null 2>&1; then
    /usr/sbin/sshd -D -E /var/log/reinstall-monitor.log &
    ssh_pid=$!
    sleep 1
    kill -0 "$ssh_pid" 2>/dev/null || { echo 'Installation SSH failed to start.' >&2; exit 1; }
fi
if [ ! -e /run/reinstall-web.pid ] || ! kill -0 "$(cat /run/reinstall-web.pid)" 2>/dev/null; then
    /reinstall/web-server.sh >/var/log/reinstall-web.log 2>&1 &
    echo $! >/run/reinstall-web.pid
fi
printf 'Monitoring enabled: VNC/serial, SSH port %s, web port %s.\n' "$SSH_PORT" "$WEB_PORT" >> /var/log/reinstall-monitor.log
SH
    cat > "$directory/usr/lib/debian-installer-startup.d/S34reinstall-monitor" <<'SH'
#!/bin/sh
/reinstall/start-monitoring.sh >>/var/log/reinstall-monitor.log 2>&1 ||
    logger -t reinstall 'Monitoring startup failed; installation continues. Inspect /var/log/reinstall-monitor.log from VNC.'
SH
    chmod 0755 "$directory/reinstall/"*.sh "$directory/usr/lib/debian-installer-startup.d/S34reinstall-monitor"
    chmod 0755 "$directory/usr/sbin/reopen-console"
    chmod 0644 "$directory/usr/lib/debian-installer.d/S70menu"
}

write_debian_payload() {
    local directory="$1" key=''
    install -d -m 0700 "$directory/reinstall"
    [[ -z "$SSH_KEY_FILE" ]] || key=$(cat "$SSH_KEY_FILE")
    cat > "$directory/preseed.cfg" <<EOF
d-i debian-installer/locale string $DEBIAN_LOCALE
d-i keyboard-configuration/xkb-keymap select $KEYMAP
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $HOSTNAME_VALUE
d-i netcfg/hostname string $HOSTNAME_VALUE
d-i netcfg/get_domain string local
d-i hw-detect/load_firmware boolean true
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/suite string $RELEASE
d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password-crypted password $PASSWORD_HASH
d-i clock-setup/utc boolean true
d-i time/zone string Etc/UTC
d-i clock-setup/ntp boolean true
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string openssh-server ca-certificates sudo
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean false
d-i finish-install/reboot_in_progress note
d-i partman/early_command string /bin/sh /reinstall/select-disk.sh
d-i preseed/late_command string cp /reinstall/postinstall.sh /target/root/postinstall.sh && cp /reinstall/ssh-host-key /target/etc/ssh/ssh_host_ed25519_key && cp /reinstall/ssh-host-key.pub /target/etc/ssh/ssh_host_ed25519_key.pub && in-target /bin/sh /root/postinstall.sh && rm -f /target/root/postinstall.sh
EOF
    if [[ "$NETWORK_MODE" == static ]]; then
        cat >> "$directory/preseed.cfg" <<EOF
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string ${ADDRESS%/*}
d-i netcfg/get_netmask string $NETMASK
d-i netcfg/get_gateway string $GATEWAY
d-i netcfg/get_nameservers string ${DNS//,/ }
d-i netcfg/confirm_static boolean true
EOF
    fi
    cat > "$directory/reinstall/select-disk.sh" <<EOF
#!/bin/sh
set -eu
expected='$DISK_PTUUID'
matched=''
count=0
for disk in \$(list-devices disk); do
    id=\$(blkid -s PTUUID -o value "\$disk" 2>/dev/null || true)
    if [ "\$id" = "\$expected" ]; then matched="\$disk"; count=\$((count + 1)); fi
done
if [ "\$count" != 1 ]; then
    logger -t reinstall 'STOPPED: target disk identity could not be verified. No disk was selected.'
    echo 'STOPPED: target disk identity could not be verified. No disk was selected.' >/dev/console
    while :; do sleep 3600; done
fi
logger -t reinstall "Target disk verified: \$matched. Partitioning and installation can proceed."
debconf-set partman-auto/disk "\$matched"
debconf-set grub-installer/bootdev "\$matched"
EOF
    cat > "$directory/reinstall/postinstall.sh" <<EOF
#!/bin/sh
set -eu
# Keep the exact hostname, including an FQDN that netcfg splits into host/domain.
printf '%s\n' '$HOSTNAME_VALUE' > /etc/hostname
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-reinstall.conf <<'SSH'
Port $SSH_PORT
PermitRootLogin yes
PasswordAuthentication yes
SSH
systemctl enable ssh
EOF
    if [[ -n "$key" ]]; then
        printf 'install -d -m 0700 /root/.ssh\n' >> "$directory/reinstall/postinstall.sh"
        # A fixed quoted heredoc prevents shell interpolation of key comments.
        printf "cat > /root/.ssh/authorized_keys <<'REINSTALL_PUBLIC_KEY'\n%s\nREINSTALL_PUBLIC_KEY\nchmod 0600 /root/.ssh/authorized_keys\n" "$key" >> "$directory/reinstall/postinstall.sh"
    fi
    chmod 0700 "$directory/reinstall/"*.sh
    write_debian_monitoring "$directory"
}

prepare_debian() {
    local base="${ISO_URL%/}" asset digest
    [[ -n "$base" ]] || base="$DEBIAN_MIRROR/dists/$RELEASE/main/installer-amd64/current/images"
    progress_step 1 'Download and verify Debian installer files'
    download "$base/SHA256SUMS" "$WORK_DIR/SHA256SUMS"
    for asset in linux initrd.gz; do
        download "$base/netboot/debian-installer/amd64/$asset" "$WORK_DIR/$asset"
        digest=$(awk -v name="netboot/debian-installer/amd64/$asset" '$2==name || $2=="./"name {print $1}' "$WORK_DIR/SHA256SUMS")
        [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Debian checksum is missing from the source manifest.'
        check_hash "$WORK_DIR/$asset" "$digest"
    done
    prepare_debian_monitor_packages
    progress_step 2 'Build installation configuration'
    write_debian_payload "$WORK_DIR/overlay"
    cp "$WORK_DIR/linux" "$BOOT_DIR/linux"
    pack_initrd "$WORK_DIR/initrd.gz" "$WORK_DIR/overlay" "$BOOT_DIR/initrd.gz"
    chmod 0600 "$BOOT_DIR/linux"
}

write_windows_image_selector() {
    cat > "$1" <<'PY'
import sys
import xml.etree.ElementTree as E

expected_language = sys.argv[2].casefold()
matches = []
for image in E.parse(sys.argv[1]).getroot().findall('IMAGE'):
    # Edition/architecture fields are language-independent; NAME is localized.
    if (image.findtext('WINDOWS/EDITIONID') or '').casefold() != 'iotenterprises':
        continue
    if image.findtext('WINDOWS/ARCH') != '9':
        continue
    if (image.findtext('WINDOWS/LANGUAGES/DEFAULT') or '').casefold() != expected_language:
        continue
    matches.append(image)
if len(matches) != 1:
    raise SystemExit('The selected language and x64 IoT Enterprise LTSC edition were not found uniquely.')
index = matches[0].get('INDEX', '')
if not index.isdecimal() or int(index) < 1:
    raise SystemExit('Invalid Windows image index.')
print(index)
PY
}

write_windows_unattend() {
    local destination="$1"
    # Values are passed as data to an XML serializer, never interpolated into code.
    python3 - "$destination" "$HOSTNAME_VALUE" "$WINDOWS_PASSWORD" "$BOOT_MODE" "$LANGUAGE" "$INPUT_LOCALE" <<'PY'
import sys, xml.etree.ElementTree as E
E.register_namespace('', 'urn:schemas-microsoft-com:unattend')
E.register_namespace('wcm', 'http://schemas.microsoft.com/WMIConfig/2002/State')
ns='urn:schemas-microsoft-com:unattend'; wcm='{http://schemas.microsoft.com/WMIConfig/2002/State}'
root=E.Element('{'+ns+'}unattend')
def child(parent, tag, text=None, **attrs):
    node=E.SubElement(parent, '{'+ns+'}'+tag, attrs)
    if text is not None: node.text=str(text)
    return node
def component(settings, name):
    return child(settings, 'component', name=name, processorArchitecture='amd64',
                 publicKeyToken='31bf3856ad364e35', language='neutral', versionScope='nonSxS')
def locale(parent):
    for key, value in [('InputLocale',sys.argv[6]),('SystemLocale',sys.argv[5]),('UILanguage',sys.argv[5]),('UserLocale',sys.argv[5])]:
        child(parent,key,value)
pe=child(root,'settings', **{'pass':'windowsPE'})
international=component(pe,'Microsoft-Windows-International-Core-WinPE')
locale(international)
child(child(international,'SetupUILanguage'),'UILanguage',sys.argv[5])
setup=component(pe,'Microsoft-Windows-Setup')
user=child(setup,'UserData'); child(user,'AcceptEula','true')
image=child(child(setup,'ImageInstall'),'OSImage')
install=child(image,'InstallFrom'); meta=child(install,'MetaData',**{wcm+'action':'add'})
child(meta,'Key','/IMAGE/INDEX'); child(meta,'Value','IMAGE_INDEX_PLACEHOLDER')
install_to=child(image,'InstallTo'); child(install_to,'DiskID','DISK_ID_PLACEHOLDER')
child(install_to,'PartitionID',3 if sys.argv[4]=='efi' else 2)
child(image,'WillShowUI','OnError')
diskcfg=child(setup,'DiskConfiguration'); disk=child(diskcfg,'Disk',**{wcm+'action':'add'})
child(disk,'DiskID','DISK_ID_PLACEHOLDER'); child(disk,'WillWipeDisk','false')
child(diskcfg,'WillShowUI','OnError')
drivers=component(pe,'Microsoft-Windows-PnpCustomizationsWinPE')
path=child(child(drivers,'DriverPaths'),'PathAndCredentials',**{wcm+'action':'add',wcm+'keyValue':'1'})
child(path,'Path',r'X:\reinstall-drivers')
special=child(root,'settings',**{'pass':'specialize'})
shell=component(special,'Microsoft-Windows-Shell-Setup')
child(shell,'ComputerName',sys.argv[2]); child(shell,'TimeZone','UTC')
deployment=component(special,'Microsoft-Windows-Deployment')
command=child(child(deployment,'RunSynchronous'),'RunSynchronousCommand',**{wcm+'action':'add'})
child(command,'Order',1)
# SID suffix 500 identifies the built-in account even when its name is localized.
child(command,'Path',r'''%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "Get-LocalUser | Where-Object {$_.SID.Value -like '*-500'} | Enable-LocalUser"''')
oobe=child(root,'settings',**{'pass':'oobeSystem'})
locale(component(oobe,'Microsoft-Windows-International-Core'))
shell=component(oobe,'Microsoft-Windows-Shell-Setup')
password=child(child(shell,'UserAccounts'),'AdministratorPassword')
child(password,'Value',sys.argv[3]); child(password,'PlainText','false')
options=child(shell,'OOBE')
for key,value in [('HideEULAPage','true'),('HideOnlineAccountScreens','true'),('HideWirelessSetupInOOBE','true'),
                  ('ProtectYourPC','3'),('SkipMachineOOBE','true'),('SkipUserOOBE','true')]: child(options,key,value)
E.ElementTree(root).write(sys.argv[1], encoding='utf-8', xml_declaration=True)
PY
}

write_winpe_command() {
    cat > "$1" <<'CMD'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
wpeinit
for /r X:\reinstall-drivers %%I in (*.inf) do drvload "%%I" >nul 2>&1
set "media="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  if exist %%D:\reinstall.tag if exist %%D:\setup.exe set "media=%%D:"
)
if not defined media goto failed
set /p expected=<"%media%\reinstall.tag"
set "diskid="
for /l %%D in (0,1,31) do (
  >X:\diskprobe.txt echo select disk %%D
  >>X:\diskprobe.txt echo uniqueid disk
  diskpart /s X:\diskprobe.txt >X:\diskinfo.txt
  findstr /i /c:"%expected%" X:\diskinfo.txt >nul && set "diskid=%%D"
)
if not defined diskid goto failed
>X:\unattend.xml (
  for /f "usebackq delims=" %%L in ("X:\reinstall.xml") do (
    set "line=%%L"
    echo(!line:DISK_ID_PLACEHOLDER=%diskid%!
  )
)
"%media%\setup.exe" /unattend:X:\unattend.xml
if errorlevel 1 goto failed
exit /b
:failed
echo Installation stopped: disk identity, media, or Windows Setup could not be verified.
echo Check the console. Do not select or format an arbitrary disk.
cmd.exe
CMD
}

write_windows_firstboot() {
    local directory="$1"
    mkdir -p "$directory"
    cat > "$directory/SetupComplete.cmd" <<'CMD'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\reinstall-firstboot.ps1" > "%WINDIR%\Setup\Scripts\reinstall-firstboot.log" 2>&1
del /q "%WINDIR%\Panther\unattend.xml" "%WINDIR%\Panther\Unattend\unattend.xml" >nul 2>&1
del /q "%WINDIR%\Setup\Scripts\reinstall-firstboot.ps1" >nul 2>&1
CMD
    cat > "$directory/reinstall-firstboot.ps1" <<EOF
\$ErrorActionPreference = 'Stop'
\$adapter = Get-NetAdapter | Where-Object { \$_.MacAddress -eq '${MAC//:/-}' } | Select-Object -First 1
if (-not \$adapter) { throw 'Original network adapter not found' }
EOF
    if [[ "$NETWORK_MODE" == static ]]; then
        cat >> "$directory/reinstall-firstboot.ps1" <<EOF
Set-NetIPInterface -InterfaceIndex \$adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex \$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:\$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex \$adapter.ifIndex -IPAddress '${ADDRESS%/*}' -PrefixLength '${ADDRESS#*/}' -DefaultGateway '$GATEWAY' | Out-Null
EOF
        # Generate an explicit PowerShell array rather than a single combined DNS string.
        python3 - "$directory/reinstall-firstboot.ps1" "$DNS" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_text().splitlines()
lines.append("Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @("+','.join("'"+x+"'" for x in sys.argv[2].split(','))+')')
p.write_text('\n'.join(lines)+'\n')
PY
    else
        cat >> "$directory/reinstall-firstboot.ps1" <<'PS'
Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses
PS
    fi
    cat >> "$directory/reinstall-firstboot.ps1" <<EOF
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name PortNumber -Value $RDP_PORT
New-NetFirewallRule -DisplayName 'Remote Desktop (reinstall)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $RDP_PORT | Out-Null
EOF
    cat >> "$directory/reinstall-firstboot.ps1" <<'PS'
# Remove password-bearing installation artifacts. Match only our media marker.
$expectedTag = 'STAGE_DISK_TAG_PLACEHOLDER'
Get-Volume | Where-Object DriveLetter | ForEach-Object {
    $root = "$($_.DriveLetter):\"
    if ((Test-Path ($root+'reinstall.tag')) -and ((Get-Content ($root+'reinstall.tag') -Raw).Trim() -eq $expectedTag)) {
        Remove-Item ($root+'sources\boot.wim'), ($root+'boot\winpe.cpio'), ($root+'autounattend.xml'), ($root+'reinstall.xml') -Force -ErrorAction SilentlyContinue
    }
}
# The installer ESP carries a tagged boot.wim too; remove it after Windows owns boot.
if (-not (Test-Path 'Z:\')) {
    mountvol Z: /S
    if ((Test-Path 'Z:\reinstall.tag') -and ((Get-Content 'Z:\reinstall.tag' -Raw).Trim() -eq $expectedTag)) {
        Remove-Item 'Z:\sources\boot.wim' -Force -ErrorAction SilentlyContinue
    }
    mountvol Z: /D
}
PS
}

prepare_windows() {
    progress_step 1 'Check ISO link and download boot files'
    resolve_iso
    local overlay="$WORK_DIR/overlay" payload="$WORK_DIR/apkovl" assignment
    install -d -m 0700 "$overlay" "$payload/reinstall" "$payload/sbin" "$payload/etc/apk" "$payload/etc/ssh"
    download "$ALPINE_BASE/releases/x86_64/netboot/vmlinuz-lts" "$BOOT_DIR/linux"
    download "$ALPINE_BASE/releases/x86_64/netboot/initramfs-lts" "$WORK_DIR/alpine-initrd"
    gzip -t "$WORK_DIR/alpine-initrd" || fail 'Alpine initramfs is invalid.'
    progress_step 2 'Build installation configuration'
    for assignment in \
        "DISK_PTUUID=$DISK_PTUUID" "DISK_BYTES=$DISK_BYTES" "BOOT_MODE=$BOOT_MODE" \
        "ISO_URL=$ISO_URL" "ISO_SOURCE=$ISO_SOURCE" "WINDOWS_FILENAME=$WINDOWS_FILENAME" \
        "LANGUAGE=$LANGUAGE" "MAC=$MAC" "NETWORK_MODE=$NETWORK_MODE" "ADDRESS=$ADDRESS" \
        "GATEWAY=$GATEWAY" "DNS=$DNS" "SSH_PORT=$SSH_PORT" "VIRTIO=$VIRTIO" \
        "WINDOWS_SHA256=$WINDOWS_SHA256" "ALPINE_BASE=$ALPINE_BASE" "VIRTIO_BASE=$VIRTIO_BASE"; do
        printf '%s=%q\n' "${assignment%%=*}" "${assignment#*=}" >> "$payload/reinstall/config"
    done
    write_windows_unattend "$payload/reinstall/unattend.xml"
    write_windows_image_selector "$payload/reinstall/select-image.py"
    write_windows_iso_resolver "$payload/reinstall/resolve-iso.py"
    write_winpe_command "$payload/reinstall/reinstall.cmd"
    write_windows_firstboot "$payload/reinstall/firstboot"
    write_windows_stage "$payload/reinstall/stage.sh"
    printf '%s/main\n%s/community\n' "$ALPINE_BASE" "$ALPINE_BASE" > "$payload/etc/apk/repositories"
    printf 'alpine-base\nca-certificates\nbash\ncurl\npython3\nopenssh\nqemu-img\nqemu-block-curl\nwimlib\nparted\nntfs-3g\nntfs-3g-progs\ndosfstools\nutil-linux\nlsblk\nblkid\nfindmnt\nsfdisk\nmount\nutil-linux-misc\ngrub-bios\ngrub-efi\nefibootmgr\ncpio\n' > "$payload/etc/apk/world"
    printf 'root:%s:0:0:99999:7:::\n' "$PASSWORD_HASH" > "$payload/etc/shadow"
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\nPort %s\n' "$SSH_PORT" > "$payload/etc/ssh/sshd_config"
    if [[ -n "$SSH_KEY_FILE" ]]; then
        install -d -m 0700 "$payload/root/.ssh"
        cp "$SSH_KEY_FILE" "$payload/root/.ssh/authorized_keys"
    fi
    cat > "$payload/sbin/standalone-install" <<'SH'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
/etc/init.d/devfs start
/etc/init.d/mdev start
/etc/init.d/modloop start
ssh-keygen -A
/usr/sbin/sshd
/bin/bash /reinstall/stage.sh
echo 'Installation stopped. Use the console or SSH to inspect /var/log/reinstall-stage.log.'
while :; do /bin/sh; sleep 1; done
SH
    chmod 0700 "$payload/sbin/standalone-install" "$payload/reinstall/stage.sh"
    (cd "$payload" && tar -czf "$overlay/standalone.apkovl.tar.gz" .)
    pack_initrd "$WORK_DIR/alpine-initrd" "$overlay" "$BOOT_DIR/initrd.gz"
    chmod 0600 "$BOOT_DIR/linux"
}

write_windows_stage() {
    cat > "$1" <<'STAGE'
#!/usr/bin/env bash
set -eEuo pipefail
umask 077
# shellcheck source=/dev/null
source /reinstall/config
mkdir -p /var/log
exec > >(tee -a /var/log/reinstall-stage.log) 2>&1
stage_error() {
    local status=$?
    printf 'Installation stopped (exit %s). Inspect the console or SSH; no automatic retry.\n' "$status"
    exit "$status"
}
trap stage_error ERR
stop() { printf 'STOPPED: %s\n' "$1"; exit 1; }
[[ "$(findmnt -nro FSTYPE /)" == tmpfs ]] || stop 'Windows staging must run from the Alpine RAM filesystem.'
for tool in qemu-nbd wimlib-imagex mkfs.ntfs mkfs.fat parted partprobe lsblk blkid sfdisk python3; do
    command -v "$tool" >/dev/null || stop 'Required installation tool is missing.'
done
if [[ "$BOOT_MODE" == efi ]]; then
    command -v efibootmgr >/dev/null || stop 'UEFI tools are missing.'
    if ! mountpoint -q /sys/firmware/efi/efivars; then
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars
    fi
    efibootmgr >/dev/null || stop 'Firmware boot variables are not accessible.'
else
    if ! command -v grub-install >/dev/null || ! command -v cpio >/dev/null; then stop 'BIOS boot tools are missing.'; fi
fi
modprobe nbd nbds_max=2 max_part=0
modprobe fuse
mdev -s
mkdir -p /media/windows /media/virtio /reinstall/drivers
printf 'Opening original Windows ISO over HTTPS...\n'
if [[ "$ISO_SOURCE" == ntriver ]]; then
    printf 'Refreshing NTriver temporary download URL...\n'
    python3 /reinstall/resolve-iso.py ntriver "$WINDOWS_FILENAME" /reinstall/iso-url "$WINDOWS_SHA256"
    ISO_URL=$(cat /reinstall/iso-url)
fi
qemu-nbd --fork --read-only --format raw --connect /dev/nbd0 "$ISO_URL" >/dev/null 2>&1 || stop 'ISO does not support HTTPS byte-range access.'
printf 'Verifying the entire ISO SHA-256 before modifying any physical disk...\n'
actual=$(sha256sum /dev/nbd0); actual="${actual%% *}"
[[ "$actual" == "$WINDOWS_SHA256" ]] || stop 'ISO hash differs from the configured IoT LTSC 2021 media hash.'
mount -o ro /dev/nbd0 /media/windows
image=/media/windows/sources/install.wim
[[ -f "$image" ]] || image=/media/windows/sources/install.esd
[[ -f "$image" && -f /media/windows/sources/boot.wim ]] || stop 'Windows installation files are missing.'
wimlib-imagex info "$image" --xml > /reinstall/image.xml
index=$(python3 /reinstall/select-image.py /reinstall/image.xml "$LANGUAGE")
if [[ "$VIRTIO" == yes ]]; then
    printf 'Preparing signed VirtIO storage/network drivers from Fedora...\n'
    qemu-nbd --fork --read-only --format raw --connect /dev/nbd1 "$VIRTIO_BASE/virtio-win.iso" >/dev/null 2>&1
    mount -o ro /dev/nbd1 /media/virtio
    found=no
    for family in viostor vioscsi NetKVM Balloon pvpanic viorng vioserial; do
        source_dir="/media/virtio/$family/w10/amd64"
        if [[ -d "$source_dir" ]]; then
            mkdir -p "/reinstall/drivers/$family"
            cp -a "$source_dir/." "/reinstall/drivers/$family/"
            found=yes
        fi
    done
    [[ "$found" == yes && -d /reinstall/drivers/NetKVM ]] || stop 'Compatible Windows 10 VirtIO drivers were not found.'
    umount /media/virtio
    qemu-nbd --disconnect /dev/nbd1 >/dev/null
fi
if [[ "$BOOT_MODE" == bios ]]; then
    curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 --retry 2 \
        https://github.com/ipxe/wimboot/releases/latest/download/wimboot -o /reinstall/wimboot 2>/dev/null
    [[ -s /reinstall/wimboot ]] || stop 'WinPE boot loader is missing.'
fi
# Keep all personalized WinPE files in RAM until validation is complete.
python3 - /reinstall/unattend.xml "$index" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('IMAGE_INDEX_PLACEHOLDER',sys.argv[2]))
PY
printf '[LaunchApps]\r\n%%SYSTEMROOT%%\\System32\\cmd.exe, "/c X:\\Windows\\System32\\reinstall.cmd"\r\n' > /reinstall/winpeshl.ini
cp /media/windows/sources/boot.wim /reinstall/boot.wim
wimlib-imagex update /reinstall/boot.wim 2 \
    --command 'add /reinstall/reinstall.cmd /Windows/System32/reinstall.cmd' \
    --command 'add /reinstall/winpeshl.ini /Windows/System32/winpeshl.ini' \
    --command 'add /reinstall/unattend.xml /reinstall.xml' \
    --command 'add /reinstall/drivers /reinstall-drivers'

printf 'Locating target disk by its original partition-table ID and size...\n'
disk='' matches=0
while read -r candidate type; do
    [[ "$type" == disk ]] || continue
    id=$(blkid -s PTUUID -o value "$candidate" 2>/dev/null || true)
    if [[ "$id" == "$DISK_PTUUID" && "$(lsblk -bdnro SIZE "$candidate")" == "$DISK_BYTES" ]]; then
        disk="$candidate"; matches=$((matches + 1))
    fi
done < <(lsblk -dnpo NAME,TYPE)
(( matches == 1 )) || stop 'Target disk was not identified uniquely.'
while read -r device; do
    if findmnt -rn -S "$device" >/dev/null; then stop 'A target-disk filesystem is still mounted.'; fi
done < <(lsblk -nrpo NAME "$disk")
identity=$(cat /proc/sys/kernel/random/uuid)
if [[ "$BOOT_MODE" == bios ]]; then identity="${identity:0:8}"; fi
python3 - /reinstall/firstboot/reinstall-firstboot.ps1 "$identity" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('STAGE_DISK_TAG_PLACEHOLDER',sys.argv[2]))
PY

printf 'Validation finished. Erasing selected disk %s and creating Windows partitions...\n' "$disk"
if [[ "$BOOT_MODE" == efi ]]; then
    parted -s "$disk" mklabel gpt
    parted -s "$disk" mkpart ESP fat32 1MiB 2049MiB
    parted -s "$disk" set 1 esp on
    parted -s "$disk" mkpart MSR 2049MiB 2065MiB
    parted -s "$disk" set 2 msftres on
    parted -s -- "$disk" mkpart Windows ntfs 2065MiB -12288MiB
    parted -s -- "$disk" mkpart Reinstall ntfs -12288MiB 100%
    sfdisk --disk-id "$disk" "$identity" >/dev/null
    os_partition=3; media_partition=4
else
    parted -s "$disk" mklabel msdos
    parted -s "$disk" mkpart primary ntfs 1MiB 101MiB
    parted -s "$disk" set 1 boot on
    parted -s -- "$disk" mkpart primary ntfs 101MiB -12288MiB
    parted -s -- "$disk" mkpart primary ntfs -12288MiB 100%
    sfdisk --disk-id "$disk" "0x$identity" >/dev/null
    os_partition=2; media_partition=3
fi
partprobe "$disk"
mdev -s
partition() { if [[ "$disk" == *[0-9] ]]; then printf '%sp%s' "$disk" "$1"; else printf '%s%s' "$disk" "$1"; fi; }
boot_device=$(partition 1); os_device=$(partition "$os_partition"); media_device=$(partition "$media_partition")
for _ in {1..20}; do [[ -b "$media_device" ]] && break; sleep 1; mdev -s; done
[[ -b "$media_device" ]] || stop 'New partition devices did not appear.'
if [[ "$BOOT_MODE" == efi ]]; then mkfs.fat -F32 -n REINSTALL_EFI "$boot_device"
else mkfs.ntfs -F -Q -L SYSTEM "$boot_device"; fi
mkfs.ntfs -F -Q -L Windows "$os_device"
mkfs.ntfs -F -Q -L Reinstall "$media_device"
mkdir -p /media/install /media/boot
mount -t ntfs-3g "$media_device" /media/install
printf 'Copying original setup media onto the installation partition...\n'
cp -a /media/windows/. /media/install/
cp /reinstall/boot.wim /media/install/sources/boot.wim
printf '%s\r\n' "$identity" > /media/install/reinstall.tag
# These dollar signs are literal Windows OEM directory names.
# shellcheck disable=SC2016
mkdir -p '/media/install/sources/$OEM$/$$/Setup/Scripts'
# shellcheck disable=SC2016
cp /reinstall/firstboot/* '/media/install/sources/$OEM$/$$/Setup/Scripts/'
if [[ "$BOOT_MODE" == efi ]]; then
    mount "$boot_device" /media/boot
    cp -r /media/install/efi /media/boot/efi
    cp -r /media/install/boot /media/boot/boot
    mkdir -p /media/boot/sources
    cp /reinstall/boot.wim /media/boot/sources/boot.wim
    cp /media/install/reinstall.tag /media/boot/reinstall.tag
    efibootmgr --create --disk "$disk" --part 1 --label 'Reinstall WinPE' --loader '\EFI\Boot\bootx64.efi'
    umount /media/boot
else
    cp /reinstall/wimboot /media/install/wimboot
    grub-install --target=i386-pc --boot-directory=/media/install/boot "$disk"
    mkdir -p /reinstall/winpe
    ln -s /media/install/bootmgr /reinstall/winpe/bootmgr
    ln -s /media/install/boot/BCD /reinstall/winpe/BCD
    ln -s /media/install/boot/boot.sdi /reinstall/winpe/boot.sdi
    ln -s /reinstall/boot.wim /reinstall/winpe/boot.wim
    (cd /reinstall/winpe && find . -print0 | cpio --null --dereference -o -H newc) > /media/install/boot/winpe.cpio
    media_uuid=$(blkid -s UUID -o value "$media_device")
    cat > /media/install/boot/grub/grub.cfg <<EOF
set timeout=0
menuentry 'Install Windows' {
    search --no-floppy --fs-uuid --set=root $media_uuid
    linux16 /wimboot
    initrd16 /boot/winpe.cpio
}
EOF
fi
sync
umount /media/install /media/windows
qemu-nbd --disconnect /dev/nbd0 >/dev/null
printf 'Windows Setup is ready. Rebooting into WinPE...\n'
reboot -f
STAGE
}

write_grub_entry() {
    local filesystem_uuid kernel_path initrd_path args=''
    filesystem_uuid=$($GRUB_PROBE --target=fs_uuid "$BOOT_DIR/linux")
    local boot_mount
    boot_mount=$(findmnt -nro TARGET -T "$BOOT_DIR")
    kernel_path="${BOOT_DIR#"${boot_mount%/}"}/linux"
    initrd_path="${BOOT_DIR#"${boot_mount%/}"}/initrd.gz"
    [[ "$filesystem_uuid" =~ ^[a-zA-Z0-9-]+$ ]] || fail 'Invalid boot filesystem UUID.'
    if [[ "$INSTALLER" == debian ]]; then
        args='auto=true priority=critical preseed/file=/preseed.cfg net.ifnames=0 biosdevname=0'
    else
        args="alpine_repo=$ALPINE_BASE/main modloop=$ALPINE_BASE/releases/x86_64/netboot/modloop-lts"
        args+=' apkovl=/standalone.apkovl.tar.gz modules=loop,squashfs,sd-mod,usb-storage init=/sbin/standalone-install'
        args+=' pkgs=bash,curl,python3,openssh,qemu-img,qemu-block-curl,wimlib,parted,ntfs-3g,dosfstools,grub-bios,grub-efi'
        if [[ "$NETWORK_MODE" == dhcp ]]; then args+=' ip=dhcp'
        else args+=" ip=${ADDRESS%/*}::$GATEWAY:$NETMASK:::none:${DNS%%,*}"; fi
    fi
    args+=" BOOTIF=01-${MAC//:/-}"
    if [[ "$INSTALLER" == debian ]]; then
        # The last console becomes /dev/console: keep Debian's installer on VGA/VNC.
        args+=' console=ttyS0,115200n8 console=tty0'
    else
        args+=' console=tty0 console=ttyS0,115200n8'
    fi
    cp -p "$GRUB_CONFIG" "$STATE_DIR/grub.cfg.before"
    cat > "$GRUB_FRAGMENT" <<EOF
#!/bin/sh
exec cat <<'GRUB_ENTRY'
menuentry 'Install $LABEL' --id '$ENTRY_ID' {
    search --no-floppy --fs-uuid --set=root $filesystem_uuid
    linux $kernel_path $args
    initrd $initrd_path
}
GRUB_ENTRY
EOF
    chmod 0700 "$GRUB_FRAGMENT"
    "$GRUB_MKCONFIG" -o "$GRUB_CONFIG" >/dev/null
    "$GRUB_REBOOT" "$ENTRY_ID"
    "$GRUB_EDITENV" "$GRUB_ENV" list | grep -Fxq "next_entry=$ENTRY_ID" || fail 'Failed to set the one-shot boot entry.'
}

cleanup_failed_prepare() {
    local status=$?
    if [[ "$PREPARING" == yes && "$status" -ne 0 ]]; then
        printf '\nCleanup: removing the incomplete reinstallation boot entry and files.\n' >&2
        if [[ -f "$GRUB_FRAGMENT" ]]; then
            if "$GRUB_EDITENV" "$GRUB_ENV" list | grep -Fxq "next_entry=$ENTRY_ID"; then
                "$GRUB_EDITENV" "$GRUB_ENV" unset next_entry || true
            fi
            rm -f "$GRUB_FRAGMENT"
            if [[ -f "$STATE_DIR/grub.cfg.before" ]]; then
                cp -p "$STATE_DIR/grub.cfg.before" "$GRUB_CONFIG" || true
            else
                "$GRUB_MKCONFIG" -o "$GRUB_CONFIG" >/dev/null 2>&1 || true
            fi
        fi
        rm -rf -- "$BOOT_DIR"
        rm -rf -- "$STATE_DIR"
    fi
}

reset_installation() {
    if [[ "$DRY_RUN" == yes ]]; then printf 'Remove only the standalone-reinstall GRUB entry and its generated files.\n'; return; fi
    check_runtime
    [[ -f "$GRUB_FRAGMENT" ]] || fail 'No pending installation prepared by this script was found.'
    ui_section 'Cancel pending reinstallation'
    printf 'This removes the pending boot entry and installer files.\n\n'
    local answer
    read -r -p 'Type RESET to cancel the pending installation: ' answer
    [[ "$answer" == RESET ]] || { printf '\nPending reinstallation was kept.\n'; return; }
    if "$GRUB_EDITENV" "$GRUB_ENV" list | grep -Fxq "next_entry=$ENTRY_ID"; then
        "$GRUB_EDITENV" "$GRUB_ENV" unset next_entry
    fi
    local saved_fragment="$STATE_DIR/reset-fragment"
    cp -p "$GRUB_FRAGMENT" "$saved_fragment"
    rm -f "$GRUB_FRAGMENT"
    if ! "$GRUB_MKCONFIG" -o "$GRUB_CONFIG" >/dev/null; then
        cp -p "$saved_fragment" "$GRUB_FRAGMENT"
        fail 'GRUB regeneration failed. Generated files were retained so reset can be retried.'
    fi
    rm -rf -- "$BOOT_DIR" "$STATE_DIR"
    printf '\nPending reinstallation cancelled. Installer boot entry and files removed.\n'
}

main() {
    # Read-only status for a pending reinstallation.
    if [[ "${1:-}" == --pending ]]; then
        [[ $# -eq 1 ]] || fail 'Pending status does not accept additional options.'
        if [[ -e "$STATE_DIR" || -e "$GRUB_FRAGMENT" ]]; then return 0; fi
        return 1
    fi
    parse_args "$@"
    [[ "$TARGET" != exit ]] || return 0
    if [[ -z "$TARGET" ]]; then show_menu
    elif [[ "$TARGET" != reset ]]; then select_preset "$TARGET"; fi
    [[ "$TARGET" != exit ]] || return 0
    if [[ "$TARGET" == reset ]]; then reset_installation; return; fi
    resolve_hostname
    if [[ "$DRY_RUN" == yes ]]; then preview; return 0; fi
    check_runtime
    choose_language || return 0
    detect_disk; detect_network
    if "$GRUB_EDITENV" "$GRUB_ENV" list | grep -q '^next_entry='; then
        fail 'Another one-shot boot is already pending; clear it before preparing this installation.'
    fi
    [[ ! -e "$GRUB_FRAGMENT" && ! -e "$STATE_DIR" && ! -e "$BOOT_DIR" ]] || fail 'An installation state already exists; run reset before preparing again.'
    ui_section 'Reinstall OS - Review'
    show_configuration detected
    printf '\nPreparation will update the boot configuration.\n'
    printf 'Installation starts after a manual reboot.\n'
    printf '\nWARNING: Installation will erase ALL partitions and data on %s.\n\n' "$DISK"
    local answer
    read -r -p 'Type REINSTALL to prepare [Enter = cancel]: ' answer || { printf '\nCancelled. No reinstallation was prepared.\n'; return 0; }
    [[ "$answer" == REINSTALL ]] || { printf '\nCancelled. No reinstallation was prepared.\n'; return 0; }
    ui_section 'Login password'
    ui_field 'Account:' "$(login_account)"
    read_password
    WORK_DIR="$STATE_DIR/work"
    PREPARING=yes
    trap cleanup_failed_prepare EXIT
    trap 'exit 130' INT TERM
    install -d -m 0700 "$STATE_DIR" "$BOOT_DIR" "$WORK_DIR"
    ui_section 'Preparing reinstallation'
    case "$INSTALLER" in
        debian) prepare_debian ;;
        windows) prepare_windows ;;
        *) fail 'Unsupported installer in OS_PRESETS.' ;;
    esac
    progress_step 3 'Set one-shot boot entry'
    write_grub_entry
    PREPARING=no
    unset PASSWORD_HASH WINDOWS_PASSWORD
    show_ready
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then main "$@"; fi
