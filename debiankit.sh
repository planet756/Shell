#!/bin/bash

# DebianKit - Debian Environment Setup Tool
# Version: 1.0.0
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

# Update Debian sources on startup
update_debian_sources

# Install common packages on startup
install_common_packages

# Show menu
show_menu() {
    clear
    echo "==============================="
    echo "       DebianKit v1.0.1        "
    echo "==============================="
    echo "i. Initialize User"
    echo "1. Install BBR"
    echo "2. Install Docker"
    echo "2. Install Telegraf"
    echo "9. Install All"
    echo "0. Exit"
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
        useradd --create-home --shell /bin/bash "$username"
        log "SUCCESS" "User '$username' created"
    else
        log "INFO" "User '$username' already exists"
    fi
    
    # Add to groups
    usermod -aG sudo "$username"
    log "SUCCESS" "User '$username' added to sudo groups"
    
    # Set password
    passwd "$username"
    
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
    
    log "SUCCESS" "Installation completed!"
}

# Main loop
while true; do
    show_menu
    echo ""
    read -p "Select option [i/1/2/3/9/0]: " choice
    
    case $choice in
        i|I)
            init_user
            ;;
        1)
            install_bbr
            ;;
        2)
            install_docker
            ;;
        3)
            install_telegraf
            ;;
        9)
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
        0)
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
