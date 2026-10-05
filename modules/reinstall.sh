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
    'en-us|English (United States)|en_US.UTF-8|us|en-US|0409:00000409|en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso|a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160'
    'zh-cn|简体中文|zh_CN.UTF-8|us|zh-CN|0804:00000804||'
    'zh-tw|繁體中文|zh_TW.UTF-8|us|zh-TW|0404:00000404||'
    'ja-jp|日本語|ja_JP.UTF-8|jp|ja-JP|0411:00000411||'
    'ko-kr|한국어|ko_KR.UTF-8|kr|ko-KR|0412:00000412||'
    'de-de|Deutsch|de_DE.UTF-8|de|de-DE|0407:00000407||'
    'fr-fr|Français|fr_FR.UTF-8|fr|fr-FR|040c:0000040c||'
    'es-es|Español|es_ES.UTF-8|es|es-ES|0c0a:0000040a||'
)
readonly DEBIAN_MIRROR='https://deb.debian.org/debian'
readonly ALPINE_BASE='https://dl-cdn.alpinelinux.org/alpine/v3.22'
readonly VIRTIO_BASE='https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio'

TARGET='' LABEL='' INSTALLER='' RELEASE='' LANGUAGE='en-US'
REQUESTED_LANGUAGE='' LANGUAGE_LABEL='English (United States)'
DEBIAN_LOCALE=en_US.UTF-8 KEYMAP=us INPUT_LOCALE=0409:00000409
WINDOWS_FILENAME='en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso'
WINDOWS_SHA256='a0334f31ea7a3e6932b9ad7206608248f0bd40698bfb8fc65f14fc5e4976c160'
DRY_RUN=no DISK='' DISK_PTUUID='' DISK_BYTES='' BOOT_MODE=''
NETWORK_MODE=auto NIC='' MAC='' ADDRESS='' GATEWAY='' DNS='' NETMASK=''
HOSTNAME_VALUE='reinstall' SSH_PORT=22 RDP_PORT=3389 SSH_KEY_FILE='' ISO_URL=''
CUSTOM_ISO_SHA256='' ISO_SOURCE=ntriver
PASSWORD_HASH='' WINDOWS_PASSWORD='' VIRTIO=no WORK_DIR='' PREPARING=no
GRUB_CONFIG='' GRUB_ENV='' GRUB_MKCONFIG='' GRUB_REBOOT='' GRUB_EDITENV='' GRUB_PROBE=''

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

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
  --lang CODE                 System language; default en-us, interactive when omitted
  --disk /dev/sda             Explicit target disk (default: current root disk)
  --network auto|dhcp|static  Default: infer from the active IPv4 interface
  --address IPv4/PREFIX       Static address (default: current address)
  --gateway IPv4             Static gateway (default: current gateway)
  --dns IPv4[,IPv4]           Default: current upstream resolvers
  --hostname NAME            Default: reinstall
  --ssh-port PORT             Debian SSH / Windows installation environment
  --ssh-key FILE              Optional local OpenSSH public key file
  --rdp-port PORT             Windows RDP port, default 3389
  --iso HTTPS_URL             Custom ISO URL; --url is an alias
  --iso-sha256 HASH           Custom ISO SHA-256 (default: original en-US IoT ISO hash)

Windows automatically downloads the original en-US IoT ISO from NTriver.
Other Windows languages require a matching custom IoT ISO URL and SHA-256.
The previous preset name windows10-ltsc remains an alias for windows10-iot-ltsc.

Run on an x86_64 Linux server with GRUB and BIOS or UEFI (Secure Boot off).
Debian uses its official network installer. Windows uses an Alpine RAM
environment, original Microsoft ISO, and Fedora VirtIO drivers when needed.
Passwords are requested interactively and are never printed.
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
        [[ -n "$filename" ]] || note=' (Windows: custom IoT ISO + SHA-256 required)'
        printf '  %-8s %s%s\n' "$id" "$label" "$note"
    done
}

apply_language() {
    local requested="${1,,}" row id label locale keymap language input filename checksum
    for row in "${OS_LANGUAGES[@]}"; do
        IFS='|' read -r id label locale keymap language input filename checksum <<< "$row"
        [[ "$id" == "$requested" ]] || continue
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
    printf '\nStandalone Reinstaller\n\n'
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

parse_args() {
    local name value
    while (( $# )); do
        case "$1" in
            -h|--help) show_help; TARGET='exit'; return ;;
            --list) list_presets; TARGET='exit'; return ;;
            --languages) list_languages; TARGET='exit'; return ;;
            --dry-run) DRY_RUN=yes; shift; continue ;;
            --disk|--network|--address|--gateway|--dns|--hostname|--ssh-port|--ssh-key|--rdp-port|--iso|--url|--iso-sha256|--lang)
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
                    --iso|--url) ISO_URL="$value"; ISO_SOURCE=custom ;;
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
    if ! valid_port "$SSH_PORT" || ! valid_port "$RDP_PORT"; then fail 'Port must be between 1 and 65535.'; fi
    [[ "$HOSTNAME_VALUE" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,14}$ && "$HOSTNAME_VALUE" != *- ]] ||
        fail 'Hostname must start with a letter, contain only letters/digits/hyphens, and have at most 15 characters.'
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

preview() {
    printf 'System: %s\nInstaller: %s (implemented locally)\n' "$LABEL" "$INSTALLER"
    printf 'Language: %s (%s)\n' "$LANGUAGE_LABEL" "$LANGUAGE"
    printf 'Disk: %s\nNetwork: %s\n' "${DISK:-detect current root disk}" "$NETWORK_MODE"
    if [[ "$INSTALLER" == windows ]]; then
        printf 'Image: %s\n' "$RELEASE"
        if [[ -n "$ISO_URL" ]]; then printf 'ISO: custom HTTPS URL (hidden)\n'
        else printf 'ISO: NTriver automatic download; verify original IoT ISO SHA-256.\n'; fi
        printf 'ISO file: %s\n' "$WINDOWS_FILENAME"
        printf 'Stages: Alpine RAM environment -> original Windows Setup -> Windows.\n'
    else
        printf 'Stages: Debian %s network installer -> Debian.\n' "$RELEASE"
    fi
    printf 'Preparation: download OS files, generate local install configuration, set one-shot GRUB entry.\n'
    printf 'Reboot: manual. No external reinstall scripts are downloaded or executed.\n'
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
    local password confirmation
    read -r -s -p 'New root / Administrator password: ' password; printf '\n'
    read -r -s -p 'Confirm password: ' confirmation; printf '\n'
    [[ "$password" == "$confirmation" && ${#password} -ge 12 ]] || fail 'Passwords must match and have at least 12 characters.'
    [[ "$password" != *[$'\r\n']* ]] || fail 'Password cannot contain line breaks.'
    if [[ "$INSTALLER" == windows ]]; then
        local categories=0
        [[ ! "$password" =~ [a-z] ]] || categories=$((categories + 1))
        [[ ! "$password" =~ [A-Z] ]] || categories=$((categories + 1))
        [[ ! "$password" =~ [0-9] ]] || categories=$((categories + 1))
        [[ ! "$password" =~ [^a-zA-Z0-9] ]] || categories=$((categories + 1))
        (( categories >= 3 && ${#password} <= 127 )) || fail 'Windows password must use at least 3 of: uppercase, lowercase, digits, symbols; maximum 127 characters.'
    fi
    PASSWORD_HASH=$(printf '%s' "$password" | openssl passwd -6 -stdin)
    if [[ "$INSTALLER" == windows ]]; then
        WINDOWS_PASSWORD=$(printf '%s' "$password" | python3 -c 'import sys,base64; print(base64.b64encode((sys.stdin.read()+"AdministratorPassword").encode("utf-16le")).decode())')
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
    printf 'Checking the %s ISO source for %s...\n' "$ISO_SOURCE" "$RELEASE"
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

write_debian_payload() {
    local directory="$1" key=''
    install -d -m 0700 "$directory/reinstall"
    [[ -z "$SSH_KEY_FILE" ]] || key=$(cat "$SSH_KEY_FILE")
    cat > "$directory/preseed.cfg" <<EOF
d-i debian-installer/locale string $DEBIAN_LOCALE
d-i keyboard-configuration/xkb-keymap select $KEYMAP
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string $HOSTNAME_VALUE
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
d-i preseed/late_command string cp /reinstall/postinstall.sh /target/root/postinstall.sh; in-target /bin/sh /root/postinstall.sh; rm -f /target/root/postinstall.sh
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
    echo 'STOPPED: target disk identity could not be verified. No disk was selected.' >/dev/console
    while :; do sleep 3600; done
fi
debconf-set partman-auto/disk "\$matched"
debconf-set grub-installer/bootdev "\$matched"
EOF
    cat > "$directory/reinstall/postinstall.sh" <<EOF
#!/bin/sh
set -eu
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
}

prepare_debian() {
    local base="$DEBIAN_MIRROR/dists/$RELEASE/main/installer-amd64/current/images" asset digest
    printf 'Downloading official Debian installer files...\n'
    download "$base/SHA256SUMS" "$WORK_DIR/SHA256SUMS"
    for asset in linux initrd.gz; do
        download "$base/netboot/debian-installer/amd64/$asset" "$WORK_DIR/$asset"
        digest=$(awk -v name="netboot/debian-installer/amd64/$asset" '$2==name || $2=="./"name {print $1}' "$WORK_DIR/SHA256SUMS")
        [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Debian checksum is missing from its official manifest.'
        check_hash "$WORK_DIR/$asset" "$digest"
    done
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
    resolve_iso
    local overlay="$WORK_DIR/overlay" payload="$WORK_DIR/apkovl" assignment
    install -d -m 0700 "$overlay" "$payload/reinstall" "$payload/sbin" "$payload/etc/apk" "$payload/etc/ssh"
    printf 'Downloading official Alpine boot files...\n'
    download "$ALPINE_BASE/releases/x86_64/netboot/vmlinuz-lts" "$BOOT_DIR/linux"
    download "$ALPINE_BASE/releases/x86_64/netboot/initramfs-lts" "$WORK_DIR/alpine-initrd"
    gzip -t "$WORK_DIR/alpine-initrd" || fail 'Alpine initramfs is invalid.'
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
    args+=" BOOTIF=01-${MAC//:/-} console=tty0 console=ttyS0,115200n8"
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
        printf 'Preparation failed; removing this script\047s pending boot entry.\n' >&2
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
    local answer
    read -r -p 'Type RESET to cancel the pending installation: ' answer
    [[ "$answer" == RESET ]] || { printf 'Cancelled.\n'; return; }
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
    printf 'Pending installation cancelled.\n'
}

main() {
    # Read-only status for the entrypoint's setup reboot prompt.
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
    if [[ "$DRY_RUN" != yes ]]; then
        check_runtime
        choose_language || return 0
    fi
    preview
    [[ "$DRY_RUN" != yes ]] || return 0
    detect_disk; detect_network
    if "$GRUB_EDITENV" "$GRUB_ENV" list | grep -q '^next_entry='; then
        fail 'Another one-shot boot is already pending; clear it before preparing this installation.'
    fi
    [[ ! -e "$GRUB_FRAGMENT" && ! -e "$STATE_DIR" && ! -e "$BOOT_DIR" ]] || fail 'An installation state already exists; run reset before preparing again.'
    printf '\nTarget disk: %s (partition-table ID %s)\n' "$DISK" "$DISK_PTUUID"
    printf 'Network: %s; interface MAC %s\n' "$NETWORK_MODE" "$MAC"
    [[ "$NETWORK_MODE" != static ]] || printf 'IPv4: %s; gateway %s; DNS %s\n' "$ADDRESS" "$GATEWAY" "$DNS"
    printf 'WARNING: After reboot, ALL partitions on the selected disk will be erased.\n'
    local answer
    read -r -p "Type REINSTALL $TARGET to prepare: " answer || return 0
    [[ "$answer" == "REINSTALL $TARGET" ]] || { printf 'Cancelled.\n'; return; }
    read_password
    WORK_DIR="$STATE_DIR/work"
    PREPARING=yes
    trap cleanup_failed_prepare EXIT
    trap 'exit 130' INT TERM
    install -d -m 0700 "$STATE_DIR" "$BOOT_DIR" "$WORK_DIR"
    case "$INSTALLER" in
        debian) prepare_debian ;;
        windows) prepare_windows ;;
        *) fail 'Unsupported installer in OS_PRESETS.' ;;
    esac
    write_grub_entry
    PREPARING=no
    unset PASSWORD_HASH WINDOWS_PASSWORD
    printf '\nInstallation prepared. Reboot manually with: sudo reboot\n'
    printf 'Cancel BEFORE reboot with: sudo bash debiankit.sh reinstall reset\n'
    printf 'Once installation starts, reset cannot restore erased data.\n'
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then main "$@"; fi
