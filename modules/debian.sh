#!/usr/bin/env bash
# Debian configuration module. Invoked by the project entrypoint.

DEBIAN_MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
source "$DEBIAN_MODULE_DIR/../lib/common.sh"

# Install common packages
install_common_packages() {
    log "INFO" "Checking common packages..."

    local packages_to_install=()
    local common_packages=("ca-certificates" "curl" "vim" "sudo" "gnupg")

    # Check each package
    for pkg in "${common_packages[@]}"; do
        if ! dpkg -l 2>/dev/null | grep -q "^ii  $pkg "; then
            packages_to_install+=("$pkg")
        fi
    done

    # Install missing packages
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        log "INFO" "Installing missing packages: ${packages_to_install[*]}"

        # Update package list
        apt-get update > /dev/null 2>&1

        # Install packages with retry logic
        local max_retries=3
        local retry_count=0

        while [[ $retry_count -lt $max_retries ]]; do
            if apt-get install -y "${packages_to_install[@]}" > /dev/null 2>&1; then
                log "SUCCESS" "Missing packages installed successfully"
                return 0
            else
                retry_count=$((retry_count + 1))
                if [[ $retry_count -lt $max_retries ]]; then
                    log "WARN" "Installation failed, retrying ($retry_count/$max_retries)..."
                    sleep 2
                fi
            fi
        done

        log "ERROR" "Failed to install missing packages after $max_retries attempts"
        return 1
    else
        log "SUCCESS" "All common packages are already installed"
        return 0
    fi
}

# Initialize system on first run
initialize_system() {
    local init_marker="/var/lib/debiankit/.initialized"

    # Check if this is first run
    if [[ ! -f "$init_marker" ]]; then
        log "INFO" "First run detected, installing essential packages..."

        # Only install common packages, do NOT update sources automatically
        if install_common_packages; then
            # Create marker directory and file
            mkdir -p "$(dirname "$init_marker")"
            touch "$init_marker"
            log "SUCCESS" "System initialized successfully"
        else
            log "WARN" "Package installation failed, but continuing..."
        fi
        echo ""
    fi
}

# Remove Debian archive entries while retaining third-party repositories.
filter_debian_sources() {
    awk -v format="${1##*.}" -v origins="${2:-}" -v probe="${3:-no}" '
    function archive_uri(uri, suites, components) {
        if (uri ~ /^cdrom:/) return 1
        if (uri ~ /:\/\/([^\/[:space:]]+\.)?debian\.org([\/:[:space:]]|$)/) return 1
        return verified[uri]
    }
    function archive(uris, suites, components, items, size, k) {
        size=split(uris, items, /[[:space:]]+/)
        for (k=1; k<=size; k++) if (archive_uri(items[k], suites, components)) return 1
        return 0
    }
    function describe(types, uris, suites, components, architectures, options, urls, n, k) {
        n=split(uris, urls, /[[:space:]]+/)
        for (k=1; k<=n; k++) {
            if (urls[k] != "" && archive_uri(urls[k], suites, components))
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", types, urls[k], suites, components, architectures, options
        }
    }
    function candidates(uris, suites, components, urls, releases, n, m, u, s) {
        n=split(uris, urls, /[[:space:]]+/); m=split(suites, releases, /[[:space:]]+/)
        if (components !~ /(^|[[:space:]])main([[:space:]]|$)/) return
        for (u=1; u<=n; u++) {
            if (archive_uri(urls[u], suites, components) || urls[u] !~ /^https?:\/\/.*\/(debian|debian-security)\/?$/) continue
            for (s=1; s<=m; s++) {
                if (releases[s] ~ /^(buster|bullseye|bookworm|trixie|stable|oldstable|oldoldstable)(-(security|updates|backports|proposed-updates))?$/) {
                    printf "%s\t%s\n", urls[u], releases[s]; break
                }
            }
        }
    }
    BEGIN {
        while (origins != "" && (getline uri < origins) > 0) verified[uri]=1
        if (origins != "") close(origins)
        RS = format == "sources" ? "" : "\n"; ORS = format == "sources" ? "\n\n" : "\n"
    }
    format != "sources" {
        if ($0 == "# DebianKit official repositories") { changed=1; next }
        if ($1 == "deb" || $1 == "deb-src") {
            i=2; options=""; architectures=""
            if ($i ~ /^\[/) {
                while (i <= NF) { options=options " " $i; if ($i ~ /\]$/) break; i++ }
                i++
                if (match(options, /arch=[^] ]+/)) architectures=substr(options, RSTART+5, RLENGTH-5)
            }
            components=""
            for (j=i+2; j<=NF && $j !~ /^#/; j++) components=components " " $j
            if (probe == "check") { describe($1, $i, $(i+1), components, architectures, options); next }
            if (probe == "yes") { candidates($i, $(i+1), components); next }
            if (archive($i, $(i+1), components)) { changed=1; next }
        }
        if (probe == "yes" || probe == "check") next
        print; next
    }
    {
        count=split($0, lines, "\n"); field=""
        uris=""; suites=""; components=""; enabled="yes"; types=""; architectures=""; options=""
        for (i=1; i<=count; i++) {
            line=lines[i]
            if (line ~ /^[[:space:]]*#/) continue
            if (line !~ /^[[:space:]]/) {
                colon=index(line, ":")
                field=tolower(substr(line, 1, colon-1)); line=substr(line, colon+1)
            }
            if (field == "uris") uris=uris " " line
            else if (field == "suites") suites=suites " " line
            else if (field == "components") components=components " " line
            else if (field == "enabled") { enabled=tolower(line); gsub(/[[:space:]]/, "", enabled) }
            else if (field == "types") types=types " " line
            else if (field == "architectures") architectures=architectures " " line
            else if (field == "trusted") options=options " trusted=" line
        }
        if (probe == "check") { if (enabled != "no") describe(types, uris, suites, components, architectures, options); next }
        if (probe == "yes") { if (enabled != "no") candidates(uris, suites, components); next }
        if (enabled != "no" && archive(uris, suites, components)) {
            count=split(uris, urls, /[[:space:]]+/); foreign=0
            for (i=1; i<=count; i++) if (urls[i] != "" && !archive(urls[i], suites, components)) foreign=1
            if (foreign) { invalid=1; exit 4 }
            changed=1; next
        }
        print
    }
    END { if (invalid) exit 4; if (probe == "no" && !changed) exit 3 }
    ' "$1"
}

# Compare repository meaning, across both source formats, without changing files.
debian_sources_are_current() {
    local codename="$1" version="$2" origins="$3" metadata native path
    shift 3
    native=$(dpkg --print-architecture) || return 1
    metadata=$(
        for path in "$@"; do
            [[ -f "$path" ]] || continue
            filter_debian_sources "$path" "$origins" check || exit 1
        done
    ) || return 1
    awk -F '\t' -v codename="$codename" -v version="$version" -v native="$native" '
    NF {
        uri=$2
        if (uri !~ /^https?:\/\// || uri !~ /\/(debian|debian-security)\/?$/) invalid=1
        sub(/^https?:\/\//, "", uri); sub(/\/+$/, "", uri)
        if ($6 ~ /trusted=[[:space:]]*yes/) invalid=1
        arch=$5; gsub(/,/, " ", arch)
        applicable=(arch ~ /^[[:space:]]*$/ || " " arch " " ~ "[[:space:]]" native "[[:space:]]")
        types_count=split($1, types, /[[:space:]]+/)
        suites_count=split($3, suites, /[[:space:]]+/)
        components_count=split($4, components, /[[:space:]]+/)
        for (s=1; s<=suites_count; s++) {
            suite=suites[s]; if (suite == "") continue
            if (suite != codename && suite != codename "-updates" && suite != codename "-security" &&
                suite != codename "-backports" && suite != codename "-proposed-updates") invalid=1
            if (suite ~ /-security$/ && uri !~ /\/debian-security$/) invalid=1
            if (suite !~ /-security$/ && uri !~ /\/debian$/) invalid=1
            for (c=1; c<=components_count; c++) {
                component=components[c]; if (component == "") continue
                if (component != "main" && component != "contrib" && component != "non-free" &&
                    !(version != "11" && component == "non-free-firmware")) invalid=1
                for (t=1; t<=types_count; t++) {
                    type=types[t]; if (type == "") continue
                    if (type != "deb" && type != "deb-src") invalid=1
                    if (type == "deb" && !applicable) continue
                    key=type SUBSEP uri SUBSEP suite SUBSEP component
                    if (seen[key]++) invalid=1
                    if (type == "deb" && component == "main") present[suite]=1
                }
            }
        }
    }
    END { exit (invalid || !present[codename] || !present[codename "-updates"] || !present[codename "-security"]) }
    ' <<< "$metadata"
}

refresh_debian_package_lists() {
    local output
    output=$(mktemp "${TMPDIR:-/tmp}/debiankit-apt-update.XXXXXX") || return 1
    if ! apt-get -o APT::Update::Error-Mode=any update > "$output" 2>&1; then
        log ERROR "Failed to update package lists. Source files were kept. See $output"
        return 1
    fi
    rm -f "$output"
    log SUCCESS 'Package lists updated successfully'
}

# Select the running Debian release; stage and back up all affected source files.
update_debian_sources() (
    local release_info os_id version codename components apt_dir=/etc/apt
    local transaction='' committed=no path relative temporary='' status index restore_failed=no uri suite
    local -a changed=() installed=()
    # shellcheck disable=SC1091 # Read the target systems release metadata.
    if ! release_info=$(ID=''; VERSION_ID=''; . /etc/os-release && printf '%s|%s' "${ID:-}" "${VERSION_ID:-}"); then
        log ERROR 'Cannot read the current system version.'
        return 1
    fi
    IFS='|' read -r os_id version <<< "$release_info"
    [[ "$os_id" == debian ]] || { log ERROR 'Update Debian Sources supports Debian 11, 12 and 13 only.'; return 1; }
    case "$version" in
        11) codename=bullseye; components='main contrib non-free' ;;
        12) codename=bookworm; components='main contrib non-free non-free-firmware' ;;
        13) codename=trixie; components='main contrib non-free non-free-firmware' ;;
        *) log ERROR 'Update Debian Sources supports Debian 11, 12 and 13 only.'; return 1 ;;
    esac
    log INFO "Updating official sources for Debian $version ($codename)..."
    transaction=$(mktemp -d "$apt_dir/debiankit-sources-backup.XXXXXX") || return 1
    mkdir -p "$transaction/new/sources.list.d" "$transaction/backup/sources.list.d" || return 1
    # shellcheck disable=SC2329 # Invoked by the EXIT trap.
    rollback_debian_sources() {
        local result=$?
        trap - EXIT INT TERM
        [[ -z "$temporary" ]] || rm -f -- "$temporary"
        if [[ "$committed" != yes ]]; then
            for ((index=${#installed[@]}-1; index>=0; index--)); do
                relative="${installed[index]}"
                path="$apt_dir/$relative"
                if [[ -f "$transaction/backup/$relative" ]]; then
                    temporary=$(mktemp "${path}.debiankit.XXXXXX") || { restore_failed=yes; continue; }
                    if ! cp -p "$transaction/backup/$relative" "$temporary" || ! mv -f "$temporary" "$path"; then
                        restore_failed=yes
                    fi
                    rm -f -- "$temporary"
                else
                    rm -f -- "$path" || restore_failed=yes
                fi
            done
            if [[ "$restore_failed" == yes ]]; then
                log ERROR "Source rollback could not finish. Restore the backups in $transaction/backup"
            elif (( ${#installed[@]} > 0 )); then
                log WARN 'Previous APT source files were restored.'
            fi
        fi
        rm -rf -- "$transaction/new"
        return "$result"
    }
    trap rollback_debian_sources EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # A /debian URL can be a vendor repository. Verify custom mirror provenance first.
    : > "$transaction/origins" || return 1
    for path in "$apt_dir/sources.list" "$apt_dir"/sources.list.d/*.list "$apt_dir"/sources.list.d/*.sources; do
        [[ -f "$path" ]] || continue
        filter_debian_sources "$path" "$transaction/origins" yes > "$transaction/candidates" || return 1
        while IFS=$'\t' read -r uri suite; do
            [[ -n "$uri" ]] || continue
            if /usr/lib/apt/apt-helper -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 \
                -o Acquire::ForceIPv4=true -o Acquire::Retries=0 \
                download-file "${uri%/}/dists/$suite/InRelease" "$transaction/probe-release" > /dev/null 2>&1 &&
                gpgv --keyring /usr/share/keyrings/debian-archive-keyring.gpg "$transaction/probe-release" > /dev/null 2>&1 &&
                grep -Fxq 'Origin: Debian' "$transaction/probe-release"; then
                printf '%s\n' "$uri" >> "$transaction/origins" || return 1
            fi
            rm -f "$transaction/probe-release" || return 1
        done < "$transaction/candidates"
    done
    if debian_sources_are_current "$codename" "$version" "$transaction/origins" \
        "$apt_dir/sources.list" "$apt_dir"/sources.list.d/*.list "$apt_dir"/sources.list.d/*.sources; then
        committed=yes
        rm -rf -- "$transaction" || return 1
        log INFO "Official sources already match Debian $version ($codename). Keeping the existing configuration."
        refresh_debian_package_lists
        return $?
    fi
    for path in "$apt_dir/sources.list" "$apt_dir"/sources.list.d/*.list "$apt_dir"/sources.list.d/*.sources; do
        relative="${path#"$apt_dir/"}"
        if [[ -e "$path" || -L "$path" ]]; then
            [[ -f "$path" ]] || { log ERROR 'APT source paths must be regular files.'; return 1; }
            if filter_debian_sources "$path" "$transaction/origins" > "$transaction/new/$relative"; then
                status=0
            else
                status=$?
                if [[ "$status" == 4 ]]; then
                    log ERROR "A source stanza mixes Debian and third-party URLs. Split it before updating: $path"
                    return 1
                fi
                [[ "$status" == 3 ]] || { log ERROR 'Cannot read the existing APT sources.'; return 1; }
            fi
            if [[ "$relative" != sources.list && "$status" == 3 ]]; then continue; fi
            [[ ! -L "$path" ]] || { log ERROR "Cannot replace a source file symlink: $path"; return 1; }
            cp -p "$path" "$transaction/backup/$relative" || return 1
        elif [[ "$relative" != sources.list ]]; then continue; fi
        changed+=("$relative")
    done
    if ! cat >> "$transaction/new/sources.list" <<EOF
# DebianKit official repositories
deb http://deb.debian.org/debian $codename $components
deb http://deb.debian.org/debian $codename-updates $components
deb http://security.debian.org/debian-security $codename-security $components
EOF
    then return 1; fi
    for relative in "${changed[@]}"; do
        path="$apt_dir/$relative"
        temporary=$(mktemp "${path}.debiankit.XXXXXX") || return 1
        if [[ -f "$transaction/backup/$relative" ]]; then
            cp -p "$transaction/backup/$relative" "$temporary" || return 1
            cat "$transaction/new/$relative" > "$temporary" || return 1
        else
            install -m 0644 "$transaction/new/$relative" "$temporary" || return 1
        fi
        installed+=("$relative")
        mv -f "$temporary" "$path" || return 1
        temporary=''
    done
    log INFO "Original source files backed up to $transaction/backup"
    if ! apt-get -o APT::Update::Error-Mode=any update > "$transaction/apt-update.log" 2>&1; then
        log ERROR "Failed to update package lists. See $transaction/apt-update.log"
        return 1
    fi
    committed=yes
    log SUCCESS "Debian $version ($codename) official sources updated successfully"
)

# Initialize user
init_user() {
    log "INFO" "Initialize user setup..."

    # Get username
    read -p "Enter username: " username
    if [[ -z "$username" ]]; then
        log "ERROR" "Username cannot be empty"
        return 1
    fi

    # Validate username format
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log "ERROR" "Invalid username format. Use lowercase letters, numbers, underscore, and hyphen only"
        return 1
    fi

    # Create user if not exists
    if ! id "$username" &>/dev/null; then
        log "INFO" "Creating user '$username'..."
        if useradd --create-home --shell /bin/bash "$username"; then
            log "SUCCESS" "User '$username' created"

            # Set password
            log "INFO" "Please set password for user '$username':"
            if passwd "$username"; then
                log "SUCCESS" "Password set successfully"
            else
                log "ERROR" "Failed to set password"
                return 1
            fi
        else
            log "ERROR" "Failed to create user"
            return 1
        fi
    else
        log "INFO" "User '$username' already exists"
    fi

    # Add to sudo group
    if usermod -aG sudo "$username" 2>/dev/null; then
        log "SUCCESS" "User '$username' added to sudo group"
    else
        log "ERROR" "Failed to add user to sudo group"
        return 1
    fi

    # Show user info
    echo ""
    log "INFO" "User information:"
    id "$username"

    return 0
}

# Install BBR
install_bbr() {
    log "INFO" "Installing BBR (TCP Congestion Control)..."

    # Check if already enabled
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$current_cc" == "bbr" ]]; then
        log "SUCCESS" "BBR is already enabled"
        sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null || true
        return 0
    fi

    # Check kernel version
    local kernel_version=$(uname -r | cut -d. -f1-2)
    local kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    local kernel_minor=$(echo "$kernel_version" | cut -d. -f2)

    log "INFO" "Current kernel version: $(uname -r)"

    if [[ $kernel_major -lt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -lt 9 ]]; then
        log "ERROR" "Kernel $(uname -r) does not support BBR (requires 4.9+)"
        return 1
    fi

    # Load BBR module
    log "INFO" "Loading tcp_bbr module..."
    if modprobe tcp_bbr 2>/dev/null; then
        log "SUCCESS" "tcp_bbr module loaded"
    else
        log "ERROR" "Failed to load tcp_bbr module"
        return 1
    fi

    # Ensure module loads on boot
    if ! grep -q "^tcp_bbr$" /etc/modules 2>/dev/null; then
        echo "tcp_bbr" >> /etc/modules
        log "INFO" "Added tcp_bbr to /etc/modules"
    fi

    # Configure sysctl
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        log "INFO" "Configuring sysctl settings..."
        cat >> /etc/sysctl.conf << 'EOF'

# BBR TCP Congestion Control Configuration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
        log "SUCCESS" "BBR configuration written to /etc/sysctl.conf"
    else
        log "INFO" "BBR configuration already exists in /etc/sysctl.conf"
    fi

    # Apply settings
    if sysctl -p > /dev/null 2>&1; then
        log "SUCCESS" "Sysctl settings applied"
    else
        log "WARN" "Failed to apply some sysctl settings"
    fi

    # Verify installation
    sleep 1
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$current_cc" == "bbr" ]]; then
        log "SUCCESS" "BBR installed and enabled successfully"
        log "INFO" "Available congestion control algorithms:"
        sysctl net.ipv4.tcp_available_congestion_control
        return 0
    else
        log "ERROR" "BBR installation completed but not active (current: $current_cc)"
        return 1
    fi
}

# Install or update Docker
install_docker() {
    log "INFO" "Setting up Docker..."

    local docker_package=""
    local docker_version=""
    local previous_version=""
    local update_docker=""
    local apply_docker_config=""
    local docker_restart_required="no"
    local docker_installed="no"
    local source_file="/etc/apt/sources.list.d/docker.sources"
    local legacy_source_file="/etc/apt/sources.list.d/docker.list"
    local key_file="/etc/apt/keyrings/docker.asc"
    local debian_version=""

    if command -v docker &> /dev/null; then
        docker_installed="yes"
        docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1)
        previous_version="$docker_version"
        log "SUCCESS" "Docker is already installed (version: $docker_version)"

        if dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q "install ok installed"; then
            docker_package="docker-ce"
        elif dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q "install ok installed"; then
            docker_package="docker.io"
        else
            log "WARN" "Unsupported Docker installation; skipping"
            return 0
        fi
    fi

    # Docker CE uses the official repository; keep its release in sync with Debian.
    if [[ "$docker_installed" == "no" || "$docker_package" == "docker-ce" ]]; then
        if [[ ! -r /etc/os-release ]]; then
            log "ERROR" "Cannot determine the current Debian release"
            return 1
        fi

        debian_version=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
        if [[ -z "$debian_version" ]]; then
            log "ERROR" "Cannot determine the current Debian codename"
            return 1
        fi

        install -m 0755 -d /etc/apt/keyrings

        if [[ -e "$legacy_source_file" ]]; then
            if [[ ! -f "$legacy_source_file" ]]; then
                log "ERROR" "$legacy_source_file exists but is not a regular file"
                return 1
            fi

            if rm -f "$legacy_source_file"; then
                log "SUCCESS" "Removed legacy Docker repository"
            else
                log "ERROR" "Failed to remove legacy Docker repository"
                return 1
            fi
        fi

        if [[ ! -f "$key_file" ]]; then
            log "INFO" "Adding Docker GPG key..."
            if curl -fsSL https://download.docker.com/linux/debian/gpg -o "$key_file" 2>/dev/null; then
                chmod a+r "$key_file"
                log "SUCCESS" "Docker GPG key added"
            else
                log "ERROR" "Failed to download Docker GPG key"
                return 1
            fi
        fi

        if [[ -f "$source_file" ]] &&
           grep -Fxq "Types: deb" "$source_file" &&
           grep -Fxq "URIs: https://download.docker.com/linux/debian" "$source_file" &&
           grep -Fxq "Suites: $debian_version" "$source_file" &&
           grep -Fxq "Components: stable" "$source_file" &&
           grep -Fxq "Signed-By: $key_file" "$source_file"; then
            log "INFO" "Docker repository already matches Debian $debian_version"
        else
            if [[ -e "$source_file" && ! -f "$source_file" ]]; then
                log "ERROR" "$source_file exists but is not a regular file"
                return 1
            fi

            if [[ -f "$source_file" ]]; then
                log "INFO" "Docker repository does not match Debian $debian_version; replacing..."
                if ! rm -f "$source_file"; then
                    log "ERROR" "Failed to remove the previous Docker repository"
                    return 1
                fi
            else
                log "INFO" "Adding Docker repository for Debian $debian_version..."
            fi

            cat > "$source_file" << EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $debian_version
Components: stable
Signed-By: $key_file
EOF
            log "SUCCESS" "Docker repository configured for Debian $debian_version"
        fi
    fi

    if [[ "$docker_installed" == "yes" ]]; then
        while true; do
            read -r -p "Update Docker? [Y/n]: " update_docker
            case "$update_docker" in
                ""|[Yy])
                    update_docker="yes"
                    break
                    ;;
                [Nn])
                    update_docker="no"
                    break
                    ;;
                *)
                    log "WARN" "Please enter y or n"
                    ;;
            esac
        done

        if [[ "$update_docker" == "yes" ]]; then
            log "INFO" "Updating package list..."
            apt-get update > /dev/null 2>&1 || {
                log "ERROR" "Failed to update package list"
                return 1
            }

            log "INFO" "Updating Docker..."
            if [[ "$docker_package" == "docker-ce" ]]; then
                apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras > /dev/null 2>&1 || {
                    log "ERROR" "Failed to update Docker"
                    return 1
                }
            else
                apt-get install -y --only-upgrade docker.io > /dev/null 2>&1 || {
                    log "ERROR" "Failed to update Docker"
                    return 1
                }
            fi

            docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1)
            if [[ "$docker_version" == "$previous_version" ]]; then
                log "SUCCESS" "Docker is up to date"
            else
                log "SUCCESS" "Docker updated (version: $docker_version)"
            fi
        else
            log "INFO" "Docker update skipped"
        fi
    else
        # Update package list
        log "INFO" "Updating package list..."
        apt-get update > /dev/null 2>&1 || {
            log "ERROR" "Failed to update package list"
            return 1
        }

        # Install Docker packages
        log "INFO" "Installing Docker packages (this may take a few minutes)..."
        if apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1; then
            log "SUCCESS" "Docker packages installed"
        else
            log "ERROR" "Failed to install Docker packages"
            return 1
        fi
    fi

    # Configure Docker daemon
    log "INFO" "Configuring Docker..."
    install -m 0755 -d /etc/docker

    if [[ -f /etc/docker/daemon.json ]]; then
        log "WARN" "Docker configuration already exists; skipping"
    elif [[ -e /etc/docker/daemon.json ]]; then
        log "ERROR" "/etc/docker/daemon.json exists but is not a regular file"
        return 1
    else
        while true; do
            read -r -p "Apply Docker configuration? [Y/n]: " apply_docker_config
            case "$apply_docker_config" in
                ""|[Yy])
                    apply_docker_config="yes"
                    break
                    ;;
                [Nn])
                    apply_docker_config="no"
                    break
                    ;;
                *)
                    log "WARN" "Please enter y or n"
                    ;;
            esac
        done

        if [[ "$apply_docker_config" == "yes" ]]; then
            cat > /etc/docker/daemon.json << 'EOF'
{
  "live-restore": true,
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5",
    "compress": "true"
  }
}
EOF
            chmod 0644 /etc/docker/daemon.json

            if dockerd --validate --config-file=/etc/docker/daemon.json > /dev/null 2>&1; then
                docker_restart_required="yes"
                log "SUCCESS" "Docker configured"
            else
                rm -f /etc/docker/daemon.json
                log "ERROR" "Docker configuration validation failed"
                return 1
            fi
        else
            log "INFO" "Docker configuration skipped"
        fi
    fi

    # Start and enable Docker service
    systemctl enable docker > /dev/null 2>&1 || {
        log "ERROR" "Failed to enable Docker service"
        return 1
    }

    if [[ "$docker_restart_required" == "yes" ]]; then
        log "INFO" "Restarting Docker service..."
        systemctl restart docker > /dev/null 2>&1 || {
            log "ERROR" "Failed to restart Docker service"
            return 1
        }
    elif ! systemctl is-active --quiet docker; then
        log "INFO" "Starting Docker service..."
        systemctl start docker > /dev/null 2>&1 || {
            log "ERROR" "Failed to start Docker service"
            return 1
        }
    fi

    # Wait for Docker to be ready
    sleep 2

    # Verify installation
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1)
        log "SUCCESS" "Docker is ready (version: $docker_version)"
    else
        log "ERROR" "Docker verification failed"
        return 1
    fi

    # Ask about adding user to docker group
    echo ""
    read -p "Add a user to docker group? Enter username (or press Enter to skip): " docker_user
    if [[ -n "$docker_user" ]]; then
        if id "$docker_user" &>/dev/null; then
            if usermod -aG docker "$docker_user" 2>/dev/null; then
                log "SUCCESS" "User '$docker_user' added to docker group"
                log "INFO" "User needs to log out and back in for changes to take effect"
            else
                log "ERROR" "Failed to add user to docker group"
            fi
        else
            log "ERROR" "User '$docker_user' does not exist"
        fi
    fi

    return 0
}

# Install Node.js from official binary
install_node_archive() (
    # Keep changes to Node-owned paths in one transaction; other /usr/local files stay intact.
    set -euo pipefail
    umask 022
    local archive="$1" archive_dir="$2" install_prefix="$3" expected_version="$4"
    local transaction='' committed=no relative source target backup index rollback_failed=no actual_version
    local -a installed=() originals=() paths=()
    mkdir -p "$install_prefix" || return 1
    transaction=$(mktemp -d "$install_prefix/.node-install.XXXXXX") || return 1
    # shellcheck disable=SC2329 # Invoked by the EXIT trap.
    rollback_node_install() {
        local status=$?
        trap - EXIT INT TERM
        if [[ "$committed" != yes ]]; then
            for ((index=${#installed[@]}-1; index>=0; index--)); do
                rm -rf -- "${install_prefix:?}/${installed[index]:?}" || rollback_failed=yes
            done
            for ((index=${#originals[@]}-1; index>=0; index--)); do
                relative="${originals[index]}"
                backup="$transaction/backup/$relative"
                if [[ -e "$backup" || -L "$backup" ]]; then
                    if ! mv -T -- "$backup" "$install_prefix/$relative"; then rollback_failed=yes; fi
                fi
            done
        fi
        if [[ "$rollback_failed" == yes ]]; then
            log ERROR "Node.js rollback could not finish. Backups retained at $transaction/backup"
        else
            rm -rf -- "$transaction" || log WARN "Could not remove Node.js staging files at $transaction"
        fi
        return "$status"
    }
    trap rollback_node_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p "$transaction/new" "$transaction/backup" || return 1
    tar -xJf "$archive" --no-same-owner --strip-components=1 -C "$transaction/new" \
        "$archive_dir/bin" "$archive_dir/lib" "$archive_dir/include" "$archive_dir/share" || return 1
    [[ -x "$transaction/new/bin/node" && -x "$transaction/new/bin/npm" && -x "$transaction/new/bin/npx" ]] || {
        log ERROR 'The extracted Node.js installation is incomplete.'; return 1;
    }
    actual_version=$("$transaction/new/bin/node" --version) || return 1
    [[ "$actual_version" == "$expected_version" ]] || {
        log ERROR 'The extracted Node.js version does not match the requested version.'; return 1;
    }
    PATH="$transaction/new/bin:$PATH" "$transaction/new/bin/npm" --version >/dev/null || return 1
    PATH="$transaction/new/bin:$PATH" "$transaction/new/bin/npx" --version >/dev/null || return 1
    # Recurse into shared directories; replace only each package's own files/directories.
    find "$transaction/new" -mindepth 1 \
        \( -path "$transaction/new/bin" -o -path "$transaction/new/lib" -o -path "$transaction/new/lib/node_modules" \
        -o -path "$transaction/new/include" -o -path "$transaction/new/share" -o -path "$transaction/new/share/doc" \
        -o -path "$transaction/new/share/man" -o -path "$transaction/new/share/man/man[1-9]" \
        -o -path "$transaction/new/share/systemtap" -o -path "$transaction/new/share/systemtap/tapset" \) \
        -type d -o -print0 -prune > "$transaction/paths" || return 1
    mapfile -d '' -t paths < "$transaction/paths" || return 1
    for source in "${paths[@]}"; do
        relative="${source#"$transaction/new/"}"
        target="$install_prefix/$relative"
        backup="$transaction/backup/$relative"
        mkdir -p -- "${target%/*}" "${backup%/*}" || return 1
        if [[ -e "$target" || -L "$target" ]]; then
            originals+=("$relative")
            mv -T -- "$target" "$backup" || return 1
        fi
        installed+=("$relative")
        mv -T -- "$source" "$target" || return 1
    done
    actual_version=$("$install_prefix/bin/node" --version) || return 1
    [[ "$actual_version" == "$expected_version" ]] || {
        log ERROR 'Installed Node.js validation failed; restoring the previous installation.'; return 1;
    }
    PATH="$install_prefix/bin:$PATH" "$install_prefix/bin/npm" --version >/dev/null || return 1
    PATH="$install_prefix/bin:$PATH" "$install_prefix/bin/npx" --version >/dev/null || return 1
    committed=yes
)

install_nodejs() {
    log "INFO" "Installing Node.js from official binary..."

    local node_version
    local node_arch
    local archive_name
    local archive_dir
    local install_prefix="/usr/local"
    local current_version=""
    local temp_dir
    local release_index
    local release_line
    local expected_checksum
    local actual_checksum

    read -p "Enter Node.js version (e.g. 22.17.0, press Enter for latest LTS): " node_version

    if [[ -z "$node_version" ]]; then
        log "INFO" "Detecting latest Node.js LTS version..."
        if ! release_index=$(curl -fsSL \
            --retry 5 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 15 \
            https://nodejs.org/dist/index.json); then
            log "ERROR" "Failed to retrieve Node.js release information"
            return 1
        fi

        release_line=$(printf '%s\n' "$release_index" | grep -m1 -E '"lts"[[:space:]]*:[[:space:]]*"[^"]+"')
        node_version=$(printf '%s\n' "$release_line" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        if [[ -z "$node_version" ]]; then
            log "ERROR" "Failed to detect the latest Node.js LTS version"
            return 1
        fi
    fi

    node_version="${node_version#v}"
    if ! [[ "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR" "Invalid Node.js version: $node_version"
        return 1
    fi
    node_version="v$node_version"

    case "$(uname -m)" in
        x86_64|amd64)
            node_arch="x64"
            ;;
        aarch64|arm64)
            node_arch="arm64"
            ;;
        armv7l)
            node_arch="armv7l"
            ;;
        *)
            log "ERROR" "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac

    archive_name="node-${node_version}-linux-${node_arch}.tar.xz"
    archive_dir="${archive_name%.tar.xz}"

    if [[ -x "$install_prefix/bin/node" && ! -L "$install_prefix/bin/node" ]]; then
        current_version=$("$install_prefix/bin/node" --version 2>/dev/null || true)
    fi

    if [[ "$current_version" == "$node_version" && -x "$install_prefix/bin/npm" ]]; then
        log "INFO" "Node.js $node_version is already installed in $install_prefix"
    else
        if ! command -v xz &> /dev/null; then
            log "INFO" "Installing xz-utils..."
            if ! apt-get update > /dev/null 2>&1 || ! apt-get install -y xz-utils > /dev/null 2>&1; then
                log "ERROR" "Failed to install xz-utils"
                return 1
            fi
        fi

        temp_dir=$(mktemp -d) || {
            log "ERROR" "Failed to create temporary directory"
            return 1
        }

        log "INFO" "Downloading Node.js checksums..."
        if ! curl -fsSL \
            --retry 5 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 15 \
            "https://nodejs.org/dist/${node_version}/SHASUMS256.txt" \
            -o "${temp_dir}/SHASUMS256.txt"; then
            log "ERROR" "Failed to download Node.js checksums after retries"
            rm -rf "$temp_dir"
            return 1
        fi

        expected_checksum=$(awk -v archive="$archive_name" '$2 == archive { print $1 }' "${temp_dir}/SHASUMS256.txt")
        if [[ -z "$expected_checksum" ]]; then
            log "ERROR" "Node.js binary is not listed in the official checksums: $archive_name"
            rm -rf "$temp_dir"
            return 1
        fi

        log "INFO" "Downloading Node.js $node_version for linux-$node_arch..."
        if ! curl -fsSL \
            --retry 5 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 15 \
            "https://nodejs.org/dist/${node_version}/${archive_name}" \
            -o "${temp_dir}/${archive_name}"; then
            log "ERROR" "Failed to download Node.js binary after retries"
            rm -rf "$temp_dir"
            return 1
        fi

        actual_checksum=$(sha256sum "${temp_dir}/${archive_name}" | awk '{ print $1 }')
        if [[ "$actual_checksum" != "$expected_checksum" ]]; then
            log "ERROR" "Node.js checksum verification failed"
            rm -rf "$temp_dir"
            return 1
        fi
        log "SUCCESS" "Node.js checksum verified"

        if ! install_node_archive "${temp_dir}/${archive_name}" "$archive_dir" "$install_prefix" "$node_version"; then
            log "ERROR" "Failed to install Node.js to $install_prefix"
            rm -rf "$temp_dir"
            return 1
        fi

        rm -rf "$temp_dir"
        log "SUCCESS" "Node.js $node_version installed to $install_prefix"
    fi

    local default_user=""
    local target_user
    local target_home
    local target_group
    local profile_file

    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && id "$SUDO_USER" &> /dev/null; then
        default_user="$SUDO_USER"
        read -p "Configure npm for user [$default_user] (enter 'skip' to skip): " target_user
        target_user="${target_user:-$default_user}"
    else
        read -p "Enter username to configure npm (press Enter to skip): " target_user
    fi

    if [[ -z "$target_user" || "${target_user,,}" == "skip" ]]; then
        log "INFO" "Skipped per-user npm configuration"
    else
        if [[ "$target_user" == "root" ]]; then
            log "ERROR" "npm user configuration must use a non-root user"
            return 1
        fi
        if ! id "$target_user" &> /dev/null; then
            log "ERROR" "User '$target_user' does not exist"
            return 1
        fi

        target_home=$(getent passwd "$target_user" | cut -d: -f6)
        target_group=$(id -gn "$target_user")
        if [[ -z "$target_home" || ! -d "$target_home" ]]; then
            log "ERROR" "Home directory for user '$target_user' does not exist"
            return 1
        fi

        install -d -m 0755 -o "$target_user" -g "$target_group" "$target_home/.local"

        if ! sudo -u "$target_user" env \
            HOME="$target_home" \
            PATH="/usr/local/bin:/usr/bin:/bin" \
            /bin/sh -c 'cd / && exec /usr/local/bin/npm config set prefix "$1" --location=user' \
            sh "$target_home/.local"; then
            log "ERROR" "Failed to configure npm prefix for user '$target_user'"
            return 1
        fi

        profile_file="$target_home/.profile"
        if ! sudo -u "$target_user" touch "$profile_file"; then
            log "ERROR" "Failed to create $profile_file"
            return 1
        fi

        if ! grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$profile_file"; then
            if ! printf '\n# User-installed npm packages\nexport PATH="$HOME/.local/bin:$PATH"\n' \
                | sudo -u "$target_user" tee -a "$profile_file" > /dev/null; then
                log "ERROR" "Failed to update PATH for user '$target_user'"
                return 1
            fi
        fi

        log "SUCCESS" "npm global prefix configured for user '$target_user': $target_home/.local"
        log "INFO" "If npm commands are not found, run 'source ~/.profile'"
    fi

    if [[ -x /usr/local/bin/node && -x /usr/local/bin/npm ]]; then
        local installed_node_version
        local installed_npm_version

        if ! installed_node_version=$(/usr/local/bin/node --version); then
            log "ERROR" "Failed to verify Node.js version"
            return 1
        fi

        if ! installed_npm_version=$(cd / && \
            NPM_CONFIG_USERCONFIG=/dev/null \
            PATH="/usr/local/bin:/usr/bin:/bin" \
            /usr/local/bin/npm --version); then
            log "ERROR" "Failed to verify npm version"
            return 1
        fi

        log "SUCCESS" "Node.js installation verified"
        log "INFO" "Node.js version: $installed_node_version"
        log "INFO" "npm version: $installed_npm_version"
        return 0
    fi

    log "ERROR" "Node.js installation verification failed"
    return 1
}

# Install Go from official binary
install_go() {
    log "INFO" "Installing Go from official binary..."

    local go_version
    local go_arch
    local archive_name
    local install_prefix="/usr/local"
    local go_root="/usr/local/go"
    local current_version=""
    local version_response
    local release_metadata
    local expected_checksum
    local actual_checksum
    local temp_dir
    local staging_dir
    local backup_dir=""
    local staged_version

    read -p "Enter Go version (e.g. 1.26.5, press Enter for latest stable): " go_version

    if [[ -z "$go_version" ]]; then
        log "INFO" "Detecting latest stable Go version..."
        if ! version_response=$(curl -fsSL \
            --retry 5 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 15 \
            'https://go.dev/VERSION?m=text'); then
            log "ERROR" "Failed to retrieve the latest Go version"
            return 1
        fi
        go_version=$(printf '%s\n' "$version_response" | sed -n '1p')
    fi

    go_version="${go_version#go}"
    if ! [[ "$go_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR" "Invalid Go version: $go_version"
        return 1
    fi
    go_version="go$go_version"

    case "$(uname -m)" in
        x86_64|amd64)
            go_arch="amd64"
            ;;
        aarch64|arm64)
            go_arch="arm64"
            ;;
        armv6l|armv7l)
            go_arch="armv6l"
            ;;
        i386|i486|i586|i686)
            go_arch="386"
            ;;
        ppc64)
            go_arch="ppc64"
            ;;
        ppc64le)
            go_arch="ppc64le"
            ;;
        riscv64)
            go_arch="riscv64"
            ;;
        s390x)
            go_arch="s390x"
            ;;
        loongarch64|loong64)
            go_arch="loong64"
            ;;
        *)
            log "ERROR" "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac

    archive_name="${go_version}.linux-${go_arch}.tar.gz"

    if [[ -x "$go_root/bin/go" ]]; then
        current_version=$("$go_root/bin/go" version 2>/dev/null | awk '{ print $3 }')
    fi

    if [[ "$current_version" == "$go_version" && -x "$go_root/bin/gofmt" ]]; then
        log "INFO" "Go $go_version is already installed in $go_root"
    else
        log "INFO" "Retrieving official Go download metadata..."
        if ! release_metadata=$(curl -fsSL \
            --retry 5 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 15 \
            'https://go.dev/dl/?mode=json'); then
            log "ERROR" "Failed to retrieve Go download metadata"
            return 1
        fi

        expected_checksum=$(printf '%s\n' "$release_metadata" | awk -F'"' -v archive="$archive_name" '
            $2 == "filename" && $4 == archive { found = 1; next }
            found && $2 == "sha256" { print $4; exit }
        ')

        if [[ -z "$expected_checksum" ]]; then
            log "INFO" "Searching archived Go releases..."
            if ! release_metadata=$(curl -fsSL \
                --retry 5 \
                --retry-delay 2 \
                --retry-all-errors \
                --connect-timeout 15 \
                'https://go.dev/dl/?mode=json&include=all'); then
                log "ERROR" "Failed to retrieve archived Go download metadata"
                return 1
            fi

            expected_checksum=$(printf '%s\n' "$release_metadata" | awk -F'"' -v archive="$archive_name" '
                $2 == "filename" && $4 == archive { found = 1; next }
                found && $2 == "sha256" { print $4; exit }
            ')
        fi

        if ! [[ "$expected_checksum" =~ ^[a-f0-9]{64}$ ]]; then
            log "ERROR" "Go binary is not listed in the official download metadata: $archive_name"
            return 1
        fi

        temp_dir=$(mktemp -d) || {
            log "ERROR" "Failed to create temporary directory"
            return 1
        }

        log "INFO" "Downloading Go $go_version for linux-$go_arch..."
        if ! curl -fsSL \
            --retry 5 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 15 \
            "https://go.dev/dl/${archive_name}" \
            -o "${temp_dir}/${archive_name}"; then
            log "ERROR" "Failed to download Go binary after retries"
            rm -rf "$temp_dir"
            return 1
        fi

        actual_checksum=$(sha256sum "${temp_dir}/${archive_name}" | awk '{ print $1 }')
        if [[ "$actual_checksum" != "$expected_checksum" ]]; then
            log "ERROR" "Go checksum verification failed"
            rm -rf "$temp_dir"
            return 1
        fi
        log "SUCCESS" "Go checksum verified"

        staging_dir=$(mktemp -d "${install_prefix}/.go-install.XXXXXX") || {
            log "ERROR" "Failed to create Go staging directory"
            rm -rf "$temp_dir"
            return 1
        }

        if ! tar -xzf "${temp_dir}/${archive_name}" \
            --no-same-owner \
            -C "$staging_dir"; then
            log "ERROR" "Failed to extract Go binary"
            rm -rf "$temp_dir" "$staging_dir"
            return 1
        fi

        if [[ ! -x "$staging_dir/go/bin/go" ]]; then
            log "ERROR" "Extracted Go binary is missing"
            rm -rf "$temp_dir" "$staging_dir"
            return 1
        fi

        staged_version=$("$staging_dir/go/bin/go" version 2>/dev/null | awk '{ print $3 }')
        if [[ "$staged_version" != "$go_version" ]]; then
            log "ERROR" "Extracted Go version does not match the requested version"
            rm -rf "$temp_dir" "$staging_dir"
            return 1
        fi

        if [[ -e "$go_root" || -L "$go_root" ]]; then
            backup_dir=$(mktemp -d "${install_prefix}/.go-backup.XXXXXX") || {
                log "ERROR" "Failed to create Go backup path"
                rm -rf "$temp_dir" "$staging_dir"
                return 1
            }
            if ! rmdir "$backup_dir"; then
                log "ERROR" "Failed to prepare Go backup path"
                rm -rf "$temp_dir" "$staging_dir" "$backup_dir"
                return 1
            fi

            if ! mv "$go_root" "$backup_dir"; then
                log "ERROR" "Failed to back up the existing Go installation"
                rm -rf "$temp_dir" "$staging_dir"
                return 1
            fi
        fi

        if ! mv "$staging_dir/go" "$go_root"; then
            log "ERROR" "Failed to install Go to $go_root"
            if [[ -n "$backup_dir" && -e "$backup_dir" ]]; then
                mv "$backup_dir" "$go_root" 2>/dev/null || true
            fi
            rm -rf "$temp_dir" "$staging_dir"
            return 1
        fi

        chown -R root:root "$go_root"
        chmod -R a+rX "$go_root"
        rm -rf "$temp_dir" "$staging_dir"

        current_version=$("$go_root/bin/go" version 2>/dev/null | awk '{ print $3 }')
        if [[ "$current_version" != "$go_version" ]]; then
            log "ERROR" "Go installation verification failed; restoring previous version"
            rm -rf "$go_root"
            if [[ -n "$backup_dir" && -e "$backup_dir" ]]; then
                mv "$backup_dir" "$go_root" 2>/dev/null || true
            fi
            return 1
        fi

        if [[ -n "$backup_dir" && -e "$backup_dir" ]]; then
            rm -rf "$backup_dir"
        fi
        log "SUCCESS" "Go $go_version installed to $go_root"
    fi

    mkdir -p "$install_prefix/bin"
    if ! ln -sfn "$go_root/bin/go" "$install_prefix/bin/go" || \
       ! ln -sfn "$go_root/bin/gofmt" "$install_prefix/bin/gofmt"; then
        log "ERROR" "Failed to create Go command links in $install_prefix/bin"
        return 1
    fi

    local default_user=""
    local target_user
    local target_home
    local target_group
    local target_gopath
    local configured_gopath=""
    local profile_file

    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && id "$SUDO_USER" &> /dev/null; then
        default_user="$SUDO_USER"
        read -p "Configure GOPATH for user [$default_user] (enter 'skip' to skip): " target_user
        target_user="${target_user:-$default_user}"
    else
        read -p "Enter username to configure GOPATH (press Enter to skip): " target_user
    fi

    if [[ -z "$target_user" || "${target_user,,}" == "skip" ]]; then
        log "INFO" "Skipped per-user GOPATH configuration"
    else
        if [[ "$target_user" == "root" ]]; then
            log "ERROR" "GOPATH user configuration must use a non-root user"
            return 1
        fi
        if ! id "$target_user" &> /dev/null; then
            log "ERROR" "User '$target_user' does not exist"
            return 1
        fi

        target_home=$(getent passwd "$target_user" | cut -d: -f6)
        target_group=$(id -gn "$target_user")
        if [[ -z "$target_home" || ! -d "$target_home" ]]; then
            log "ERROR" "Home directory for user '$target_user' does not exist"
            return 1
        fi

        target_gopath="$target_home/.local/go"
        install -d -m 0755 -o "$target_user" -g "$target_group" "$target_gopath"

        if ! sudo -u "$target_user" env \
            -u GOPATH \
            -u GOROOT \
            HOME="$target_home" \
            PATH="/usr/local/bin:/usr/bin:/bin" \
            /bin/sh -c 'cd / && exec /usr/local/bin/go env -w GOPATH="$1"' \
            sh "$target_gopath"; then
            log "ERROR" "Failed to configure GOPATH for user '$target_user'"
            return 1
        fi

        profile_file="$target_home/.profile"
        if ! sudo -u "$target_user" touch "$profile_file"; then
            log "ERROR" "Failed to create $profile_file"
            return 1
        fi

        if ! grep -Fqx 'export PATH="$HOME/.local/go/bin:$PATH"' "$profile_file"; then
            if ! printf '\n# User-installed Go commands\nexport PATH="$HOME/.local/go/bin:$PATH"\n' \
                | sudo -u "$target_user" tee -a "$profile_file" > /dev/null; then
                log "ERROR" "Failed to update Go PATH for user '$target_user'"
                return 1
            fi
        fi

        if ! configured_gopath=$(sudo -u "$target_user" env \
            -u GOPATH \
            -u GOROOT \
            HOME="$target_home" \
            PATH="/usr/local/bin:/usr/bin:/bin" \
            /bin/sh -c 'cd / && exec /usr/local/bin/go env GOPATH'); then
            log "ERROR" "Failed to verify GOPATH for user '$target_user'"
            return 1
        fi

        if [[ "$configured_gopath" != "$target_gopath" ]]; then
            log "ERROR" "GOPATH verification failed for user '$target_user'"
            return 1
        fi

        log "SUCCESS" "GOPATH configured for user '$target_user': $configured_gopath"
        log "INFO" "If Go-installed commands are not found, run 'source ~/.profile' as user '$target_user'"
    fi

    if [[ -x "$install_prefix/bin/go" && -x "$install_prefix/bin/gofmt" ]]; then
        local installed_go_version
        local installed_goroot

        if ! installed_go_version=$("$install_prefix/bin/go" version 2>/dev/null | awk '{ print $3 }'); then
            log "ERROR" "Failed to verify Go version"
            return 1
        fi

        if ! installed_goroot=$(cd / && \
            GOROOT= \
            GOENV=off \
            PATH="/usr/local/bin:/usr/bin:/bin" \
            "$install_prefix/bin/go" env GOROOT); then
            log "ERROR" "Failed to verify GOROOT"
            return 1
        fi

        log "SUCCESS" "Go installation verified"
        log "INFO" "Go version: $installed_go_version"
        log "INFO" "GOROOT: $installed_goroot"
        return 0
    fi

    log "ERROR" "Go installation verification failed"
    return 1
}

# Install or update Telegraf
install_telegraf() {
    log "INFO" "Setting up Telegraf..."

    local source_file="/etc/apt/sources.list.d/influxdata.sources"
    local legacy_source_file="/etc/apt/sources.list.d/influxdata.list"
    local key_file="/etc/apt/keyrings/influxdata-archive.gpg"
    local legacy_key_file="/etc/apt/trusted.gpg.d/influxdata-archive.gpg"
    local key_fingerprint="24C975CBA61A024EE1B631787C3D57159FC2F927"
    local key_download=""
    local key_temp=""
    local key_valid="no"
    local source_temp=""
    local expected_source=""
    local current_source=""
    local telegraf_version=""
    local previous_package_version=""
    local current_package_version=""
    local update_telegraf=""
    local telegraf_installed="no"
    local telegraf_restart_required="no"

    if command -v telegraf &> /dev/null; then
        telegraf_installed="yes"
        telegraf_version=$(telegraf version 2>/dev/null | head -n1 || echo "unknown")
        log "SUCCESS" "Telegraf is already installed ($telegraf_version)"

        if ! dpkg-query -W -f='${Status}' telegraf 2>/dev/null | grep -q "install ok installed"; then
            log "WARN" "Unsupported Telegraf installation; skipping"
            return 0
        fi
    fi

    install -m 0755 -d /etc/apt/keyrings /etc/apt/sources.list.d

    if [[ -e "$legacy_source_file" ]]; then
        if [[ ! -f "$legacy_source_file" ]]; then
            log "ERROR" "$legacy_source_file exists but is not a regular file"
            return 1
        fi

        if rm -f "$legacy_source_file"; then
            log "SUCCESS" "Removed legacy InfluxData repository"
        else
            log "ERROR" "Failed to remove legacy InfluxData repository"
            return 1
        fi
    fi

    if [[ -e "$key_file" && ! -f "$key_file" ]]; then
        log "ERROR" "$key_file exists but is not a regular file"
        return 1
    fi

    if [[ -f "$key_file" ]] &&
       gpg --show-keys --with-fingerprint --with-colons "$key_file" 2>/dev/null |
           awk -F: -v expected="$key_fingerprint" \
               '$1 == "fpr" && $10 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
        key_valid="yes"
    fi

    if [[ "$key_valid" == "no" ]]; then
        if [[ -f "$key_file" ]]; then
            log "WARN" "InfluxData GPG key is invalid; replacing..."
        else
            log "INFO" "Adding InfluxData GPG key..."
        fi

        key_download=$(mktemp /tmp/influxdata-archive.key.XXXXXX) || {
            log "ERROR" "Failed to create temporary GPG key file"
            return 1
        }

        if ! curl -fsSL \
            --retry 5 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 15 \
            -o "$key_download" \
            https://repos.influxdata.com/influxdata-archive.key; then
            log "ERROR" "Failed to download InfluxData GPG key"
            rm -f "$key_download"
            return 1
        fi

        if gpg --show-keys --with-fingerprint --with-colons "$key_download" 2>/dev/null |
           awk -F: -v expected="$key_fingerprint" \
               '$1 == "fpr" && $10 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
            log "SUCCESS" "InfluxData GPG key verified"
        else
            log "ERROR" "GPG key fingerprint verification failed"
            rm -f "$key_download"
            return 1
        fi

        key_temp=$(mktemp /etc/apt/keyrings/influxdata-archive.gpg.XXXXXX) || {
            log "ERROR" "Failed to create temporary keyring"
            rm -f "$key_download"
            return 1
        }

        if ! gpg --dearmor --yes --output "$key_temp" "$key_download" > /dev/null 2>&1; then
            log "ERROR" "Failed to create InfluxData keyring"
            rm -f "$key_download" "$key_temp"
            return 1
        fi

        chmod 0644 "$key_temp"
        if ! mv -f "$key_temp" "$key_file"; then
            log "ERROR" "Failed to install InfluxData keyring"
            rm -f "$key_download" "$key_temp"
            return 1
        fi

        rm -f "$key_download"
        log "SUCCESS" "InfluxData GPG key configured"
    fi

    expected_source=$(cat << EOF
Types: deb
URIs: https://repos.influxdata.com/debian
Suites: stable
Components: main
Signed-By: $key_file
EOF
)

    if [[ -f "$source_file" ]]; then
        current_source=$(<"$source_file")
    elif [[ -e "$source_file" ]]; then
        log "ERROR" "$source_file exists but is not a regular file"
        return 1
    fi

    if [[ "$current_source" == "$expected_source" ]]; then
        log "INFO" "InfluxData repository is already up to date"
    else
        if [[ -f "$source_file" ]]; then
            log "INFO" "Replacing outdated InfluxData repository..."
        else
            log "INFO" "Adding InfluxData repository..."
        fi

        source_temp=$(mktemp /etc/apt/sources.list.d/influxdata.sources.XXXXXX) || {
            log "ERROR" "Failed to create temporary repository file"
            return 1
        }

        if ! printf '%s\n' "$expected_source" > "$source_temp"; then
            log "ERROR" "Failed to write InfluxData repository"
            rm -f "$source_temp"
            return 1
        fi

        chmod 0644 "$source_temp"
        if ! mv -f "$source_temp" "$source_file"; then
            log "ERROR" "Failed to install InfluxData repository"
            rm -f "$source_temp"
            return 1
        fi

        log "SUCCESS" "InfluxData repository configured"
    fi

    if [[ -e "$legacy_key_file" ]]; then
        if [[ ! -f "$legacy_key_file" ]]; then
            log "ERROR" "$legacy_key_file exists but is not a regular file"
            return 1
        fi

        if rm -f "$legacy_key_file"; then
            log "SUCCESS" "Removed legacy InfluxData GPG key"
        else
            log "ERROR" "Failed to remove legacy InfluxData GPG key"
            return 1
        fi
    fi

    if [[ "$telegraf_installed" == "yes" ]]; then
        while true; do
            read -r -p "Update Telegraf? [Y/n]: " update_telegraf
            case "$update_telegraf" in
                ""|[Yy])
                    update_telegraf="yes"
                    break
                    ;;
                [Nn])
                    update_telegraf="no"
                    break
                    ;;
                *)
                    log "WARN" "Please enter y or n"
                    ;;
            esac
        done

        if [[ "$update_telegraf" == "yes" ]]; then
            previous_package_version=$(dpkg-query -W -f='${Version}' telegraf 2>/dev/null)

            log "INFO" "Updating package list..."
            apt-get update > /dev/null 2>&1 || {
                log "ERROR" "Failed to update package list"
                return 1
            }

            log "INFO" "Updating Telegraf..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
                -o Dpkg::Options::="--force-confold" telegraf > /dev/null 2>&1 || {
                log "ERROR" "Failed to update Telegraf"
                return 1
            }

            current_package_version=$(dpkg-query -W -f='${Version}' telegraf 2>/dev/null)
            if [[ "$current_package_version" == "$previous_package_version" ]]; then
                log "SUCCESS" "Telegraf is up to date"
            else
                telegraf_restart_required="yes"
                log "SUCCESS" "Telegraf updated"
            fi
        else
            log "INFO" "Telegraf update skipped"
        fi
    else
        log "INFO" "Updating package list..."
        apt-get update > /dev/null 2>&1 || {
            log "ERROR" "Failed to update package list"
            return 1
        }

        log "INFO" "Installing Telegraf..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y telegraf > /dev/null 2>&1 || {
            log "ERROR" "Failed to install Telegraf"
            return 1
        }

        log "SUCCESS" "Telegraf installed"
    fi

    systemctl enable telegraf > /dev/null 2>&1 || {
        log "ERROR" "Failed to enable Telegraf service"
        return 1
    }

    if [[ "$telegraf_restart_required" == "yes" ]]; then
        systemctl restart telegraf > /dev/null 2>&1 || {
            log "ERROR" "Failed to restart Telegraf service"
            return 1
        }
    elif ! systemctl is-active --quiet telegraf; then
        systemctl start telegraf > /dev/null 2>&1 || {
            log "ERROR" "Failed to start Telegraf service"
            return 1
        }
    fi

    if systemctl is-active --quiet telegraf; then
        telegraf_version=$(telegraf version 2>/dev/null | head -n1 || echo "unknown")
        log "SUCCESS" "Telegraf is ready ($telegraf_version)"
        return 0
    fi

    log "ERROR" "Telegraf verification failed"
    return 1
}

# Install or update Komari Agent (Non-Root)
install_komari_agent() {
    log "INFO" "Setting up Komari Agent..."

    local target_user="komari"
    local target_home="/home/$target_user"
    local target_dir="${target_home}/.komari"
    local target_file="${target_dir}/komari-agent"
    local config_file="${target_dir}/komari-agent.conf"
    local traffic_file="${target_dir}/net_static.json"
    local is_update=false
    local update_agent=""
    local komari_arch=""
    local download_url=""
    local temp_file=""
    local config_temp=""
    local backup_file=""
    local traffic_backup=""
    local run_params=""
    local original_run_params=""
    local rollback_run_params=""
    local update_config="n"
    local reset_traffic="n"
    local write_config="no"
    local config_existed="no"
    local agent_was_running="no"
    local server_url=""
    local token=""
    local additional_params=""

    if id "$target_user" &>/dev/null; then
        log "INFO" "User '$target_user' exists"
    else
        log "INFO" "Creating user '$target_user'..."
        useradd --uid 5774 --create-home --shell /usr/sbin/nologin "$target_user" 2>/dev/null || \
        useradd --create-home --shell /usr/sbin/nologin "$target_user" || {
            log "ERROR" "Failed to create user"
            return 1
        }
        echo "${target_user}:$(openssl rand -base64 32)" | chpasswd 2>/dev/null
        log "SUCCESS" "User '$target_user' created"
    fi

    if [[ ! -d "$target_dir" ]]; then
        mkdir -p "$target_dir"
        chown "$target_user:$target_user" "$target_dir"
    fi

    if [[ -f "${target_home}/net_static.json" && ! -f "$traffic_file" ]]; then
        mv "${target_home}/net_static.json" "$traffic_file"
        chown "$target_user:$target_user" "$traffic_file"
    fi

    if [[ -f "$config_file" ]]; then
        config_existed="yes"
        original_run_params=$(cat "$config_file")
    fi

    if [[ -f "$target_file" ]]; then
        is_update=true
        log "SUCCESS" "Komari Agent is already installed"

        while true; do
            read -r -p "Update Komari Agent? [Y/n]: " update_agent
            case "$update_agent" in
                ""|[Yy])
                    update_agent="yes"
                    break
                    ;;
                [Nn])
                    update_agent="no"
                    break
                    ;;
                *)
                    log "WARN" "Please enter y or n"
                    ;;
            esac
        done

        if [[ "$update_agent" == "no" ]]; then
            log "INFO" "Komari Agent update skipped"
            return 0
        fi
    fi

    case $(uname -m) in
        x86_64)    komari_arch="amd64" ;;
        i386|i686) komari_arch="386" ;;
        aarch64)   komari_arch="arm64" ;;
        riscv64)   komari_arch="riscv64" ;;
        *)
            log "ERROR" "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac

    download_url="https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-linux-${komari_arch}"
    temp_file=$(mktemp "${target_dir}/.komari-agent.XXXXXX") || {
        log "ERROR" "Failed to create temporary file"
        return 1
    }

    log "INFO" "Downloading Komari Agent..."
    if ! curl -fsSL \
        --retry 5 \
        --retry-delay 2 \
        --retry-all-errors \
        --connect-timeout 15 \
        -o "$temp_file" \
        "$download_url"; then
        rm -f "$temp_file"
        log "ERROR" "Download failed"
        return 1
    fi

    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        log "ERROR" "Downloaded file is empty"
        return 1
    fi

    chown "$target_user:$target_user" "$temp_file"
    chmod 0755 "$temp_file"

    if $is_update; then
        echo ""
        read -p "Update configuration? [y/N]: " update_config

        if [[ "${update_config,,}" == "y" ]]; then
            read -p "Server URL (-e): " server_url
            read -p "Token (-t): " token
            if [[ -z "$server_url" || -z "$token" ]]; then
                rm -f "$temp_file"
                log "ERROR" "Server URL and Token required"
                return 1
            fi
            read -p "Additional parameters (optional): " additional_params
            run_params="-e ${server_url} -t ${token} ${additional_params}"
            write_config="yes"

            read -p "Reset traffic statistics? [y/N]: " reset_traffic
        elif [[ "$config_existed" == "yes" ]]; then
            run_params="$original_run_params"
        else
            rm -f "$temp_file"
            log "WARN" "Komari Agent update skipped"
            return 0
        fi
    else
        echo ""
        read -p "Server URL (-e): " server_url
        read -p "Token (-t): " token
        if [[ -z "$server_url" || -z "$token" ]]; then
            rm -f "$temp_file"
            log "ERROR" "Server URL and Token required"
            return 1
        fi
        read -p "Additional parameters (optional): " additional_params
        run_params="-e ${server_url} -t ${token} ${additional_params}"
        write_config="yes"
    fi

    rollback_run_params="$original_run_params"
    [[ -z "$rollback_run_params" ]] && rollback_run_params="$run_params"

    if [[ "$write_config" == "yes" ]]; then
        config_temp=$(mktemp "${target_dir}/.komari-agent.conf.XXXXXX") || {
            rm -f "$temp_file"
            log "ERROR" "Failed to create temporary configuration"
            return 1
        }
        if ! printf '%s\n' "$run_params" > "$config_temp"; then
            rm -f "$temp_file" "$config_temp"
            log "ERROR" "Failed to write configuration"
            return 1
        fi
        chown "$target_user:$target_user" "$config_temp"
        chmod 0600 "$config_temp"
    fi

    if ! command -v screen &>/dev/null; then
        if ! apt-get update -qq || ! apt-get install -y -qq screen; then
            rm -f "$temp_file" "$config_temp"
            log "ERROR" "Failed to install screen"
            return 1
        fi
    fi

    if [[ "${reset_traffic,,}" == "y" && -f "$traffic_file" ]]; then
        traffic_backup=$(mktemp "${target_dir}/.net_static.backup.XXXXXX") || {
            rm -f "$temp_file" "$config_temp"
            log "ERROR" "Failed to create traffic backup"
            return 1
        }
        rm -f "$traffic_backup"
    fi

    if $is_update; then
        backup_file=$(mktemp "${target_dir}/.komari-agent.backup.XXXXXX") || {
            rm -f "$temp_file" "$config_temp"
            log "ERROR" "Failed to create backup file"
            return 1
        }
        if ! cp -p "$target_file" "$backup_file"; then
            rm -f "$temp_file" "$config_temp" "$backup_file"
            log "ERROR" "Failed to back up Komari Agent"
            return 1
        fi

        if sudo -u "$target_user" screen -ls 2>/dev/null | grep -q "komari"; then
            agent_was_running="yes"
            sudo -u "$target_user" screen -S komari -p 0 -X stuff $'\003'
            sleep 3
            sudo -u "$target_user" screen -S komari -X quit 2>/dev/null
            sleep 1
        fi

        if [[ -n "$traffic_backup" ]] && ! mv "$traffic_file" "$traffic_backup"; then
            rm -f "$temp_file" "$config_temp" "$backup_file" "$traffic_backup"
            if [[ "$agent_was_running" == "yes" ]]; then
                sudo -u "$target_user" bash -c "cd '$target_dir' && screen -dmS komari ./komari-agent $rollback_run_params"
            fi
            log "ERROR" "Failed to reset traffic statistics"
            return 1
        fi
    fi

    if ! mv -f "$temp_file" "$target_file"; then
        [[ -n "$traffic_backup" ]] && mv -f "$traffic_backup" "$traffic_file"
        if [[ "$agent_was_running" == "yes" ]]; then
            sudo -u "$target_user" bash -c "cd '$target_dir' && screen -dmS komari ./komari-agent $rollback_run_params"
        fi
        rm -f "$temp_file" "$config_temp" "$backup_file"
        log "ERROR" "Failed to install Komari Agent"
        return 1
    fi

    if [[ -n "$config_temp" ]]; then
        if ! mv -f "$config_temp" "$config_file"; then
            if $is_update && [[ -f "$backup_file" ]]; then
                mv -f "$backup_file" "$target_file"
                [[ -n "$traffic_backup" ]] && mv -f "$traffic_backup" "$traffic_file"
                if [[ "$agent_was_running" == "yes" ]]; then
                    sudo -u "$target_user" bash -c "cd '$target_dir' && screen -dmS komari ./komari-agent $rollback_run_params"
                fi
            else
                rm -f "$target_file"
            fi
            rm -f "$config_temp"
            log "ERROR" "Failed to install configuration"
            return 1
        fi
    fi

    sudo -u "$target_user" screen -S komari -X quit 2>/dev/null
    if ! sudo -u "$target_user" bash -c "cd '$target_dir' && screen -dmS komari ./komari-agent $run_params"; then
        if $is_update && [[ -f "$backup_file" ]]; then
            mv -f "$backup_file" "$target_file"
            if [[ "$write_config" == "yes" ]]; then
                if [[ "$config_existed" == "yes" ]]; then
                    printf '%s\n' "$original_run_params" > "$config_file"
                    chown "$target_user:$target_user" "$config_file"
                    chmod 0600 "$config_file"
                else
                    rm -f "$config_file"
                fi
            fi
            [[ -n "$traffic_backup" ]] && mv -f "$traffic_backup" "$traffic_file"
            if [[ "$agent_was_running" == "yes" ]]; then
                sudo -u "$target_user" bash -c "cd '$target_dir' && screen -dmS komari ./komari-agent $rollback_run_params"
            fi
        fi
        log "ERROR" "Failed to start agent"
        return 1
    fi

    sleep 1
    if ! sudo -u "$target_user" screen -ls 2>/dev/null | grep -q "komari"; then
        sudo -u "$target_user" screen -S komari -X quit 2>/dev/null
        if $is_update && [[ -f "$backup_file" ]]; then
            mv -f "$backup_file" "$target_file"
            if [[ "$write_config" == "yes" ]]; then
                if [[ "$config_existed" == "yes" ]]; then
                    printf '%s\n' "$original_run_params" > "$config_file"
                    chown "$target_user:$target_user" "$config_file"
                    chmod 0600 "$config_file"
                else
                    rm -f "$config_file"
                fi
            fi
            [[ -n "$traffic_backup" ]] && mv -f "$traffic_backup" "$traffic_file"
            if [[ "$agent_was_running" == "yes" ]]; then
                sudo -u "$target_user" bash -c "cd '$target_dir' && screen -dmS komari ./komari-agent $rollback_run_params"
            fi
        fi
        log "ERROR" "Agent failed to start"
        return 1
    fi

    rm -f "$backup_file" "$traffic_backup"

    if $is_update; then
        log "SUCCESS" "Komari Agent updated"
    else
        log "SUCCESS" "Komari Agent started"
    fi
}

debian_main() {
    local action="${1:-}" handler
    [[ $# -eq 1 ]] || error_exit 'Choose one Debian configuration action.'
    case "$action" in
        sources) handler=update_debian_sources ;;
        user) handler=init_user ;;
        bbr) handler=install_bbr ;;
        docker) handler=install_docker ;;
        telegraf) handler=install_telegraf ;;
        komari) handler=install_komari_agent ;;
        nodejs) handler=install_nodejs ;;
        go) handler=install_go ;;
        reset-init) handler='' ;;
        *) error_exit 'Unknown Debian configuration action.' ;;
    esac
    check_root
    if [[ "$action" == reset-init ]]; then
        log "INFO" "Resetting initialization marker..."
        if rm -f /var/lib/debiankit/.initialized 2>/dev/null; then
            log "SUCCESS" "Initialization reset. Script will re-initialize on next run"
        else
            log "WARN" "Could not reset the initialization marker"
            return 1
        fi
        return 0
    fi
    # Repair sources before any package initialization uses the old repositories.
    if [[ "$action" == sources ]]; then
        "$handler"
        return $?
    fi
    initialize_system
    "$handler"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    debian_main "$@"
fi
