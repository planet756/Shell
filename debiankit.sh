#!/bin/bash

# DebianKit - Debian Environment Setup Tool
# Version: 1.3.0
# Author: Planet
# sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/planet756/Shell/main/debiankit.sh)"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging function with colors
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "INFO")
            echo -e "${BLUE}[$timestamp]${NC} [INFO] $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[$timestamp]${NC} [SUCCESS] $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[$timestamp]${NC} [WARN] $message"
            ;;
        "ERROR")
            echo -e "${RED}[$timestamp]${NC} [ERROR] $message"
            ;;
        *)
            echo "[$timestamp] [$level] $message"
            ;;
    esac
}

# Error handler
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Check root privileges
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "Root privileges required. Usage: sudo $0"
    fi
}

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

# Update Debian sources
update_debian_sources() {
    log "INFO" "Updating Debian sources..."

    # Backup original sources.list
    if [[ -f /etc/apt/sources.list ]]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.backup
        log "INFO" "Original sources.list backed up to sources.list.backup"
    fi

    # Write new sources.list
    cat > /etc/apt/sources.list << 'EOF'
# Debian trixie Sources
deb http://deb.debian.org/debian trixie main non-free-firmware
deb http://security.debian.org/debian-security trixie-security main non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main non-free-firmware
deb http://deb.debian.org/debian/ trixie-backports main non-free-firmware
EOF

    # Update package list
    if apt-get update > /dev/null 2>&1; then
        log "SUCCESS" "Debian sources updated successfully"
        return 0
    else
        log "ERROR" "Failed to update package lists"
        return 1
    fi
}

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
        log "WARN" "Failed to add user to sudo group (may already be a member)"
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

        mkdir -p \
            "$install_prefix/bin" \
            "$install_prefix/lib" \
            "$install_prefix/include" \
            "$install_prefix/share"

        if ! tar -xJf "${temp_dir}/${archive_name}" \
            --no-same-owner \
            --strip-components=1 \
            -C "$install_prefix" \
            "${archive_dir}/bin" \
            "${archive_dir}/lib" \
            "${archive_dir}/include" \
            "${archive_dir}/share"; then
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

    local key_file="/tmp/influxdata-archive.key"
    local telegraf_version=""
    local previous_package_version=""
    local current_package_version=""
    local update_telegraf=""
    local telegraf_restart_required="no"

    if command -v telegraf &> /dev/null; then
        telegraf_version=$(telegraf version 2>/dev/null | head -n1 || echo "unknown")
        log "SUCCESS" "Telegraf is already installed ($telegraf_version)"

        if ! dpkg-query -W -f='${Status}' telegraf 2>/dev/null | grep -q "install ok installed"; then
            log "WARN" "Unsupported Telegraf installation; skipping"
            return 0
        fi

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
        log "INFO" "Adding InfluxData repository..."
        rm -f "$key_file"

        if ! curl -fsSL \
            --retry 5 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 15 \
            -o "$key_file" \
            https://repos.influxdata.com/influxdata-archive.key; then
            log "ERROR" "Failed to download InfluxData GPG key"
            return 1
        fi

        if gpg --show-keys --with-fingerprint --with-colons "$key_file" 2>&1 \
           | grep '^fpr:' | grep -q '24C975CBA61A024EE1B631787C3D57159FC2F927'; then
            log "SUCCESS" "GPG key verified"
        else
            log "ERROR" "GPG key fingerprint verification failed"
            rm -f "$key_file"
            return 1
        fi

        if gpg --dearmor --yes \
            --output /etc/apt/trusted.gpg.d/influxdata-archive.gpg \
            "$key_file" > /dev/null 2>&1; then
            log "SUCCESS" "GPG key added"
        else
            log "ERROR" "Failed to add GPG key"
            rm -f "$key_file"
            return 1
        fi

        tee /etc/apt/sources.list.d/influxdata.sources > /dev/null << EOF
Types: deb
URIs: https://repos.influxdata.com/debian
Suites: stable
Components: main
Signed-By: /etc/apt/trusted.gpg.d/influxdata-archive.gpg
EOF

        log "INFO" "Installing Telegraf..."
        if ! apt-get update > /dev/null 2>&1 || \
           ! apt-get install -y telegraf > /dev/null 2>&1; then
            log "ERROR" "Failed to install Telegraf"
            rm -f "$key_file"
            return 1
        fi

        mkdir -p /var/log/telegraf
        touch /var/log/telegraf/telegraf.log
        chown telegraf:telegraf /var/log/telegraf/telegraf.log
        chown telegraf:telegraf /var/log/telegraf
        rm -f "$key_file"
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

# Install all components
install_all() {
    log "INFO" "Starting full installation..."
    echo ""

    local failed_components=()

    # Install each component
    echo -e "${BLUE}=== Installing BBR ===${NC}"
    install_bbr || failed_components+=("BBR")
    echo ""

    echo -e "${BLUE}=== Installing Docker ===${NC}"
    install_docker || failed_components+=("Docker")
    echo ""

    echo -e "${BLUE}=== Installing Node.js ===${NC}"
    install_nodejs || failed_components+=("Node.js")
    echo ""

    echo -e "${BLUE}=== Installing Go ===${NC}"
    install_go || failed_components+=("Go")
    echo ""

    echo -e "${BLUE}=== Installing Telegraf ===${NC}"
    install_telegraf || failed_components+=("Telegraf")
    echo ""

    echo -e "${BLUE}=== Installing Komari Agent ===${NC}"
    install_komari_agent || failed_components+=("Komari Agent")
    echo ""

    # Summary
    echo -e "${BLUE}======================================${NC}"
    if [[ ${#failed_components[@]} -eq 0 ]]; then
        log "SUCCESS" "All components installed successfully!"
    else
        log "WARN" "Installation completed with some failures"
        log "WARN" "Failed components: ${failed_components[*]}"
    fi
    echo -e "${BLUE}======================================${NC}"
}

# Pause function
pause() {
    echo ""
    read -p "Press Enter to continue..." -r
}

# Show menu
show_menu() {
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "${GREEN}        DebianKit v1.3.0${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo "01. Update Debian Sources"
    echo "02. Initialize User"
    echo "03. Install BBR"
    echo "04. Install Docker"
    echo "05. Install Telegraf"
    echo "06. Install Komari Agent (Non-Root)"
    echo "07. Install Node.js (Official Binary)"
    echo "08. Install Go (Official Binary)"
    echo ""
    echo "99. Install All"
    echo "00. Exit"
    echo -e "${BLUE}======================================${NC}"
    echo -e "${YELLOW}Tip: Type 'reset' to reset initialization${NC}"
}

# Main function
main() {
    check_root
    initialize_system

    # Main loop
    while true; do
        show_menu
        echo ""
        if ! read -r -p "Select option [00-99]: " choice; then
            echo ""
            log "ERROR" "Interactive input is unavailable. Do not pipe this script directly to bash."
            exit 1
        fi
        echo ""

        case $choice in
            01)
                update_debian_sources
                ;;
            02)
                init_user
                ;;
            03)
                install_bbr
                ;;
            04)
                install_docker
                ;;
            05)
                install_telegraf
                ;;
            06)
                install_komari_agent
                ;;
            07)
                install_nodejs
                ;;
            08)
                install_go
                ;;
            99)
                install_all
                echo ""
                read -p "Reboot system now to apply all changes? (y/N): " -n 1 -r
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    log "INFO" "Rebooting in 5 seconds... (Ctrl+C to cancel)"
                    sleep 5
                    reboot
                fi
                ;;
            reset)
                log "INFO" "Resetting initialization marker..."
                if rm -f /var/lib/debiankit/.initialized 2>/dev/null; then
                    log "SUCCESS" "Initialization reset. Script will re-initialize on next run"
                else
                    log "WARN" "No initialization marker found"
                fi
                ;;
            00)
                log "INFO" "Exiting DebianKit. Goodbye!"
                exit 0
                ;;
            *)
                log "ERROR" "Invalid option: $choice"
                ;;
        esac

        pause
    done
}

# Run main function
main "$@"
