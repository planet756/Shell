#!/bin/bash

# DebianKit - Debian Environment Setup Tool
# Version: 1.1.0
# Author: Planet
# sudo bash <(curl -sL https://raw.githubusercontent.com/planet756/Shell/main/debiankit.sh)

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

# Install Docker
install_docker() {
    log "INFO" "Installing Docker..."
    
    # Check if already installed
    if command -v docker &> /dev/null; then
        local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1)
        log "SUCCESS" "Docker is already installed (version: $docker_version)"
        return 0
    fi
    
    # Create keyrings directory
    install -m 0755 -d /etc/apt/keyrings
    
    # Add Docker GPG key
    log "INFO" "Adding Docker GPG key..."
    if curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
        chmod a+r /etc/apt/keyrings/docker.asc
        log "SUCCESS" "Docker GPG key added"
    else
        log "ERROR" "Failed to download Docker GPG key"
        return 1
    fi
    
    # Add Docker repository using DEB822 format
    log "INFO" "Adding Docker repository..."
    local debian_version=$(. /etc/os-release && echo "$VERSION_CODENAME")
    tee /etc/apt/sources.list.d/docker.sources > /dev/null << EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $debian_version
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    
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
    
    # Start and enable Docker service
    log "INFO" "Starting Docker service..."
    systemctl enable docker --now > /dev/null 2>&1 || {
        log "ERROR" "Failed to start Docker service"
        return 1
    }

    # Wait for Docker to be ready
    sleep 2

    # Verify installation
    if command -v docker &> /dev/null && systemctl is-active --quiet docker; then
        local docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1)
        log "SUCCESS" "Docker installed successfully (version: $docker_version)"
        docker --version
    else
        log "ERROR" "Docker installation verification failed"
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

# Install Telegraf
install_telegraf() {
    log "INFO" "Installing Telegraf..."
    
    # Check if already installed
    if command -v telegraf &> /dev/null; then
        local telegraf_version=$(telegraf version 2>/dev/null | head -n1 || echo "unknown")
        log "SUCCESS" "Telegraf is already installed ($telegraf_version)"
        return 0
    fi
    
    # Download and verify InfluxData GPG key
    log "INFO" "Adding InfluxData repository..."
    cd /tmp || error_exit "Failed to change to /tmp directory"

    # Download GPG key
    if ! curl -sL -o influxdata-archive.key https://repos.influxdata.com/influxdata-archive.key; then
        log "ERROR" "Failed to download InfluxData GPG key"
        return 1
    fi

    # Verify GPG key fingerprint
    log "INFO" "Verifying GPG key fingerprint..."
    local key_fingerprint=$(gpg --show-keys --with-fingerprint --with-colons ./influxdata-archive.key 2>&1 | grep '^fpr:' | cut -d: -f10)

    if [[ "$key_fingerprint" == "9D539D90D3328DC7D6C8D3B9D8FF8E1F7DF8B07E" ]]; then
        log "SUCCESS" "GPG key verified"
    else
        log "WARN" "GPG key fingerprint mismatch, but continuing (fingerprint: $key_fingerprint)"
    fi

    # Add GPG key and repository using DEB822 format
    if cat influxdata-archive.key | gpg --dearmor | tee /etc/apt/trusted.gpg.d/influxdata-archive.gpg > /dev/null 2>&1; then
        log "SUCCESS" "GPG key added"
    else
        log "ERROR" "Failed to add GPG key"
        rm -f /tmp/influxdata-archive.key
        return 1
    fi

    tee /etc/apt/sources.list.d/influxdata.sources > /dev/null << EOF
Types: deb
URIs: https://repos.influxdata.com/debian
Suites: stable
Components: main
Signed-By: /etc/apt/trusted.gpg.d/influxdata-archive.gpg
EOF

    # Update and install
    log "INFO" "Installing Telegraf from repository..."
    if apt-get update > /dev/null 2>&1 && apt-get install -y telegraf > /dev/null 2>&1; then
        # Create log directory if not exists
        mkdir -p /var/log/telegraf
        
        # Create log file and set permissions
        log "INFO" "Configuring Telegraf logging..."
        touch /var/log/telegraf/telegraf.log
        chown telegraf:telegraf /var/log/telegraf/telegraf.log
        chown telegraf:telegraf /var/log/telegraf
        
        # Start service
        systemctl enable telegraf --now > /dev/null 2>&1
        
        # Verify service status
        if systemctl is-active --quiet telegraf; then
            log "SUCCESS" "Telegraf installed and service is running"
            telegraf version 2>/dev/null | head -n1 || true
        else
            log "WARN" "Telegraf installed but service is not running"
        fi
        
        # Cleanup
        rm -f /tmp/influxdata-archive.key
        return 0
    else
        log "ERROR" "Failed to install Telegraf"
        rm -f /tmp/influxdata-archive.key
        return 1
    fi
}

# Install Komari Agent (Non-Root)
install_komari_agent() {
    log "INFO" "Installing Komari Agent (Non-Root Mode)..."
    echo ""
    
    local target_user="komari"
    local target_uid=5774

    # Check if komari user exists
    if id "$target_user" &>/dev/null; then
        log "INFO" "User 'komari' already exists (UID: $(id -u $target_user))"
    else
        log "INFO" "Creating dedicated 'komari' user..."
        
        # Try to create with specific UID
        if useradd --uid $target_uid --create-home --shell /bin/bash --comment "Komari Agent Service User" "$target_user" 2>/dev/null; then
            log "SUCCESS" "User 'komari' created with UID $target_uid"
        else
            # If UID is taken, create without specific UID
            if useradd --create-home --shell /bin/bash --comment "Komari Agent Service User" "$target_user" 2>/dev/null; then
                log "WARN" "User 'komari' created with auto-assigned UID (${target_uid} was not available)"
            else
                log "ERROR" "Failed to create 'komari' user"
                return 1
            fi
        fi

        # Set a secure random password
        local random_password=$(openssl rand -base64 32 2>/dev/null || tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
        echo "${target_user}:${random_password}" | chpasswd 2>/dev/null
        log "INFO" "Secure password set for 'komari' user"
    fi
    
    # Get user home directory
    local target_home=$(eval echo "~$target_user")
    log "INFO" "User: $target_user ($(id -u $target_user):$(id -g $target_user))"
    log "INFO" "Home directory: $target_home"
    
    # Detect architecture
    log "INFO" "Detecting system architecture..."
    local sys_arch=$(uname -m)
    local komari_arch=""
    
    # Map system architecture to Komari naming convention
    case $sys_arch in
        x86_64)  komari_arch="amd64" ;;
        i386|i686) komari_arch="386" ;;
        aarch64) komari_arch="arm64" ;;
        riscv64) komari_arch="riscv64" ;;
        *)
            log "ERROR" "Unsupported architecture: $sys_arch"
            log "INFO" "Supported: x86_64, i386, aarch64, riscv64"
            return 1
            ;;
    esac
    
    log "SUCCESS" "System: $sys_arch -> Komari: komari-linux-$komari_arch"
    
    # Download Komari Agent
    log "INFO" "Downloading Komari Agent..."
    local download_url="https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-linux-${komari_arch}"
    local target_dir="${target_home}/.komari"
    local target_file="${target_dir}/.komari-agent"

    # Create .komari directory if not exists
    if ! su - "$target_user" -c "mkdir -p '$target_dir'" 2>/dev/null; then
        log "ERROR" "Failed to create directory: $target_dir"
        return 1
    fi
    log "INFO" "Target directory: $target_dir"
    
    # Remove old binary if exists
    if [[ -f "$target_file" ]]; then
        log "INFO" "Removing old Komari Agent binary..."
        rm -f "$target_file"
    fi
    
    # Download as komari user
    if su - "$target_user" -c "curl -L -f -o '$target_file' '$download_url'" 2>/dev/null; then
        log "SUCCESS" "Download completed"
    else
        log "ERROR" "Download failed. Please check network connection and try again"
        return 1
    fi
    
    # Verify downloaded file
    if [[ ! -f "$target_file" ]]; then
        log "ERROR" "Downloaded file not found"
        return 1
    fi

    if [[ ! -s "$target_file" ]]; then
        log "ERROR" "Downloaded file is empty"
        rm -f "$target_file"
        return 1
    fi
    
    # Set execute permission
    chmod +x "$target_file"
    chown "$target_user:$target_user" "$target_file"
    
    local file_size=$(ls -lh "$target_file" 2>/dev/null | awk '{print $5}')
    log "INFO" "Binary size: $file_size"
    
    # Get server configuration
    echo ""
    log "INFO" "Please provide Komari Agent configuration:"
    read -p "Server URL (-e): " server_url
    read -p "Token (-t): " token

    # Validate inputs
    if [[ -z "$server_url" ]]; then
        log "ERROR" "Server URL cannot be empty"
        return 1
    fi
    
    if [[ -z "$token" ]]; then
        log "ERROR" "Token cannot be empty"
        return 1
    fi
    
    local run_params="-e ${server_url} -t ${token}"

    # Optional parameters
    echo ""
    log "INFO" "Optional parameters (press Enter to skip):"
    read -p "Additional parameters: " additional_params
    if [[ -n "$additional_params" ]]; then
        run_params="${run_params} ${additional_params}"
        log "INFO" "Added parameters: $additional_params"
    fi

    echo ""
    log "INFO" "Final command: .komari-agent $run_params"
    
    # Install screen if not available
    if ! command -v screen &> /dev/null; then
        log "INFO" "Installing screen for session management..."
        apt-get update > /dev/null 2>&1
        if apt-get install -y screen > /dev/null 2>&1; then
            log "SUCCESS" "Screen installed"
        else
            log "ERROR" "Failed to install screen"
            return 1
        fi
    fi

    # Stop existing screen session if exists
    log "INFO" "Checking for existing Komari Agent sessions..."
    if su - "$target_user" -c "screen -ls" 2>/dev/null | grep -q "komari"; then
        log "INFO" "Stopping existing session..."
        su - "$target_user" -c "screen -S komari -X quit" >/dev/null 2>&1 || true
        sleep 1
    fi
    
    # Start Komari Agent in screen session
    log "INFO" "Starting Komari Agent in screen session..."
    if su - "$target_user" -c "cd '$target_dir' && screen -dmS komari ./.komari-agent $run_params"; then
        sleep 2
        
        # Verify session started
        if su - "$target_user" -c "screen -ls" 2>/dev/null | grep -q "komari"; then
            log "SUCCESS" "Komari Agent started successfully in screen session"
            echo ""
            log "INFO" "Session Management Commands:"
            log "INFO" "  - Attach session: sudo -u komari screen -r komari"
            log "INFO" "  - Detach session: Press Ctrl+A then D"
            log "INFO" "  - List sessions: sudo -u komari screen -ls"
            log "INFO" "  - Stop agent: sudo -u komari screen -S komari -X quit"
        else
            log "ERROR" "Screen session not found after start"
            return 1
        fi
    else
        log "ERROR" "Failed to start Komari Agent"
        return 1
    fi
    
    return 0
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
    echo -e "${GREEN}        DebianKit v1.1.0${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo "01. Update Debian Sources"
    echo "02. Initialize User"
    echo "03. Install BBR"
    echo "04. Install Docker"
    echo "05. Install Telegraf"
    echo "06. Install Komari Agent (Non-Root)"
    echo ""
    echo "99. Install All (BBR + Docker + Telegraf + Komari)"
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
        read -p "Select option [00-99]: " choice
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
