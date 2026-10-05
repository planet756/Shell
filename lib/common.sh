#!/usr/bin/env bash
# Shared DebianKit colors, logging and privilege checks.

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging function with colors
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

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
        error_exit "Root privileges required. Usage: sudo bash debiankit.sh"
    fi
}

