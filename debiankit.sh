#!/bin/bash

# DebianKit - Debian Environment Setup Tool
# Version: 1.0.1
# Author: Planet
# curl -O https://raw.githubusercontent.com/planet756/Shell/main/debiankit.sh

# Logging function
log() {
    local level="$1"
    local message="$2"
    echo "[$level] $message"
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
# Debian Bookworm Sources
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-backports main contrib non-free non-free-firmware
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

# Install common packages
install_common_packages() {
    log "INFO" "Checking common packages..."
    
    local packages_to_install=()
    local common_packages=("ca-certificates" "curl" "vim" "sudo")
    
    # Check each package
    for pkg in "${common_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            packages_to_install+=("$pkg")
        fi
    done
    
    # Install missing packages
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        log "INFO" "Installing missing packages: ${packages_to_install[*]}"
        
        # Update package list
        apt-get update > /dev/null 2>&1
        
        # Install packages
        if apt-get install -y "${packages_to_install[@]}" > /dev/null 2>&1; then
            log "SUCCESS" "Missing packages installed successfully"
            return 0
        else
            log "ERROR" "Failed to install missing packages"
            return 1
        fi
    else
        log "SUCCESS" "All common packages are already installed"
        return 0
    fi
}

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    log "ERROR" "Root privileges required"
    echo "Usage: sudo $0"
    exit 1
fi

# Check if this is first run (no backup exists)
FIRST_RUN=false
if [[ ! -f /etc/apt/sources.list.backup ]]; then
    FIRST_RUN=true
fi

# Only run initialization on first run
if $FIRST_RUN; then
    log "INFO" "First run detected, initializing system..."
    update_debian_sources
    install_common_packages
    echo ""
fi

# Show menu
show_menu() {
    clear
    echo "==============================="
    echo "       DebianKit v1.0.1        "
    echo "==============================="
    echo "01. Init User"
    echo "02. Install BBR"
    echo "03. Install Docker"
    echo "04. Install Telegraf"
    echo "05. Install Komari Agent (Non-Root)"
    echo "99. Install All"
    echo "00. Exit"
    echo "==============================="
}

init_user() {
    log "INFO" "Initialize user setup..."
    
    # Get username
    read -p "Enter username: " username
    if [[ -z "$username" ]]; then
        log "ERROR" "Username cannot be empty"
        return 1
    fi
    
    # Create user if not exists
    if ! id "$username" &>/dev/null; then
    # 用户不存在 - 创建并设置密码
        useradd --create-home --shell /bin/bash "$username"
        passwd "$username"
    else
        # 用户已存在
        log "INFO" "User '$username' already exists"
    fi
    
    # Add to groups
    usermod -aG sudo "$username"
    log "SUCCESS" "User '$username' added to sudo groups"
    
    # Show user info
    id "$username"
    
    return 0
}

# Install BBR
install_bbr() {
    log "INFO" "Installing BBR..."
    
    # Check if already enabled
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        log "SUCCESS" "BBR is already enabled"
        return 0
    fi
    
    # Check kernel support
    kernel_version=$(uname -r | cut -d. -f1-2)
    kernel_major=$(echo $kernel_version | cut -d. -f1)
    kernel_minor=$(echo $kernel_version | cut -d. -f2)
    
    if [[ $kernel_major -lt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -lt 9 ]]; then
        log "ERROR" "Kernel $(uname -r) does not support BBR (requires 4.9+)"
        return 1
    fi
    
    # Load module
    modprobe tcp_bbr > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to load tcp_bbr module"
        return 1
    fi
    
    # Configure sysctl
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf << EOF

# BBR Configuration
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
      
      if [ $? -eq 0 ]; then
        log "SUCCESS" "BBR configuration written to sysctl.conf"
      else
          log "ERROR" "Failed to write BBR configuration"
          return 1
      fi
    fi
    
    sysctl -p > /dev/null 2>&1
    
    # Verify
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        log "SUCCESS" "BBR installed and enabled"
        return 0
    else
        log "ERROR" "BBR installation failed"
        return 1
    fi
}

# Install Docker
install_docker() {
    log "INFO" "Installing Docker..."
    
    # Check if already installed
    if command -v docker &> /dev/null; then
        log "SUCCESS" "Docker is already installed ($(docker --version | cut -d' ' -f3 | cut -d',' -f1))"
        return 0
    fi
    
    # Create keyrings directory
    install -m 0755 -d /etc/apt/keyrings
    
    # Add Docker GPG key
    log "INFO" "Adding Docker GPG key..."
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.asc
    
    # Add Docker repository
    log "INFO" "Adding Docker repository..."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package list
    apt-get update > /dev/null 2>&1
    
    # Install Docker packages
    log "INFO" "Installing Docker packages..."
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
    
    # Start and enable Docker service
    systemctl enable docker --now > /dev/null 2>&1
    
    # Add user to docker group
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER" 2>/dev/null
        log "INFO" "User $SUDO_USER added to docker group"
    fi
    
    # Verify installation
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        log "SUCCESS" "Docker installed ($(docker --version | cut -d' ' -f3 | cut -d',' -f1))"
        return 0
    else
        log "ERROR" "Docker installation failed"
        return 1
    fi

    # Ask about adding user to docker group
    read -p "Add user to docker group? Enter username (or press Enter to skip): " docker_user
    if [[ -n "$docker_user" ]]; then
        if id "$docker_user" &>/dev/null; then
            usermod -aG docker "$docker_user" 2>/dev/null
            log "SUCCESS" "User '$docker_user' added to docker group"
        else
            log "ERROR" "User '$docker_user' does not exist"
        fi
    fi

    return 0
}

# Install Telegraf
install_telegraf() {
    log "INFO" "Installing Telegraf..."
    
    # Check if already installed
    if command -v telegraf &> /dev/null; then
        log "SUCCESS" "Telegraf is already installed"
        return 0
    fi
    
    # Download and verify InfluxData GPG key
    log "INFO" "Adding InfluxData repository..."
    cd /tmp || exit 1
    
    if curl -sl -O https://repos.influxdata.com/influxdata-archive.key; then
        # Verify GPG key fingerprint
        if gpg --show-keys --with-fingerprint --with-colons ./influxdata-archive.key 2>&1 | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:$'; then
            # Add GPG key and repository
            cat influxdata-archive.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/influxdata-archive.gpg > /dev/null
            echo 'deb [signed-by=/etc/apt/trusted.gpg.d/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main' | tee /etc/apt/sources.list.d/influxdata.list > /dev/null
            
            # Update and install
            log "INFO" "Installing Telegraf from repository..."
            if apt-get update > /dev/null 2>&1 && apt-get install -y telegraf > /dev/null 2>&1; then
                # Create log file and set permissions
                log "INFO" "Creating telegraf.log and setting permissions..."
                touch /var/log/telegraf/telegraf.log
                chown telegraf:telegraf /var/log/telegraf/telegraf.log

                # Start service
                systemctl enable telegraf --now > /dev/null 2>&1
                log "SUCCESS" "Telegraf installed from official repository"
                
                # Cleanup
                rm -f /tmp/influxdata-archive.key
                return 0
            else
                log "ERROR" "Failed to install Telegraf"
                rm -f /tmp/influxdata-archive.key
                return 1
            fi
        else
            log "ERROR" "GPG key verification failed"
            rm -f /tmp/influxdata-archive.key
            return 1
        fi
    else
        log "ERROR" "Failed to download GPG key"
        return 1
    fi
}

# Install Komari Agent (Non-Root)
install_komari_agent() {
    log "INFO" "Installing Komari Agent (Non-Root Mode)..."
    echo ""
    
    local target_user="komari"
    
    # Check if komari user exists
    if id "$target_user" &>/dev/null; then
        log "INFO" "User 'komari' already exists"
    else
        log "INFO" "Creating dedicated 'komari' user (UID 5774)..."
        
        # Create komari user with specific UID
        if useradd --uid 5774 --create-home --shell /bin/bash --comment "Komari Agent Service User" "$target_user" 2>/dev/null; then
            log "SUCCESS" "User 'komari' created successfully"
        else
            # If UID 5774 is taken, create without specific UID
            if useradd --create-home --shell /bin/bash --comment "Komari Agent Service User" "$target_user" 2>/dev/null; then
                log "WARN" "User 'komari' created with auto-assigned UID (5774 was not available)"
            else
                log "ERROR" "Failed to create 'komari' user"
                return 1
            fi
        fi

        # Set a random password (user won't need to login directly)
        echo "komari:$(openssl rand -base64 32)" | chpasswd 2>/dev/null
        log "INFO" "Password set for 'komari' user"
    fi
    
    # Get user home directory
    target_home=$(eval echo "~$target_user")
    log "INFO" "Using user: $target_user ($(id -u $target_user):$(id -g $target_user))"
    log "INFO" "Home directory: $target_home"
    
    # Detect architecture
    log "INFO" "Detecting system architecture..."
    local arch=$(uname -m)
    local komari_arch=""
    
    case $arch in
        x86_64|amd64)
            komari_arch="amd64"
            ;;
        i386|i686)
            komari_arch="386"
            ;;
        aarch64|arm64)
            komari_arch="arm64"
            ;;
        armv7l)
            komari_arch="arm"
            ;;
        *)
            log "ERROR" "Unsupported architecture: $arch"
            return 1
            ;;
    esac
    
    log "INFO" "Detected architecture: $arch -> komari-agent-linux-$komari_arch"
    
    # Download Komari Agent
    log "INFO" "Downloading Komari Agent..."
    local download_url="https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-linux-${komari_arch}"
    local target_file="${target_home}/.komari-agent"
    
    if su - "$target_user" -c "curl -L -o '$target_file' '$download_url'" 2>/dev/null; then
        log "SUCCESS" "Download completed"
    else
        log "ERROR" "Download failed"
        return 1
    fi
    
    # Verify file
    if [[ ! -f "$target_file" ]] || [[ ! -s "$target_file" ]]; then
        log "ERROR" "Downloaded file is invalid"
        return 1
    fi
    
    # Set execute permission
    chmod +x "$target_file"
    chown "$target_user:$target_user" "$target_file"
    log "INFO" "File size: $(ls -lh $target_file | awk '{print $5}')"
    
    # Get server parameters
    echo ""
    log "INFO" "Please provide Komari Agent configuration:"
    read -p "Server URL (-e): " server_url
    read -p "Token (-t): " token
    
    if [[ -z "$server_url" ]] || [[ -z "$token" ]]; then
        log "ERROR" "Server URL and Token cannot be empty"
        return 1
    fi
    
    local run_params="-e $server_url -t $token"

    # Optional parameters
    echo ""
    log "INFO" "Optional parameters"
    read -p "Enter additional parameters (or press Enter to skip): " additional_params
    if [[ -n "$additional_params" ]]; then
        run_params="$run_params $additional_params"
        log "INFO" "Added parameters: $additional_params"
    fi

    echo ""
    log "INFO" "Final command: komari-agent $run_params"
    
    # Install screen if not available
    if ! command -v screen &> /dev/null; then
        log "INFO" "Installing screen..."
        apt-get update > /dev/null 2>&1
        apt-get install -y screen > /dev/null 2>&1
    fi
    
    log "INFO" "Setting up screen keepalive..."
    
    # Kill existing screen session if exists
    su - "$target_user" -c "screen -S komari -X quit 2>/dev/null" || true
    
    # Start in screen directly
    su - "$target_user" -c "cd $target_home && screen -dmS komari $target_file $run_params"
    sleep 2
    
    if su - "$target_user" -c "screen -ls" | grep -q "komari"; then
        log "SUCCESS" "Komari Agent started in screen session"
        log "INFO" "Reconnect: screen -r komari (or sudo -u komari screen -r komari)"
        log "INFO" "List sessions: screen -ls"
        log "INFO" "Detach session: Press Ctrl+A then D"
    else
        log "ERROR" "Failed to start screen session"
        return 1
    fi
    
    return 0
}

# Install all
install_all() {
    log "INFO" "Installing all components..."
    echo ""
    
    install_bbr
    echo ""
    install_docker
    echo ""
    install_telegraf
    echo ""
    install_komari_agent
    echo ""
    
    log "SUCCESS" "Installation completed!"
}

# Main loop
while true; do
    show_menu
    echo ""
    read -p "Select option: " choice
    
    case $choice in
        01)
            init_user
            ;;
        02)
            install_bbr
            ;;
        03)
            install_docker
            ;;
        04)
            install_telegraf
            ;;
        05)
            install_komari_agent
            ;;
        99)
            install_all
            echo ""
            read -p "Reboot system now? (y/N): " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Rebooting in 3 seconds..."
                sleep 3
                reboot
            fi
            ;;
        00)
            log "INFO" "Exiting"
            exit 0
            ;;
        *)
            log "ERROR" "Invalid option"
            ;;
    esac
    
    echo ""
    read -p "Press Enter to continue..." -r
done
