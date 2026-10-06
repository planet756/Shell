#!/usr/bin/env bash

# DebianKit - Single entrypoint for setup and OS reinstallation.
# Version: 1.4.0
# Author: Planet
# sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/planet756/Shell/main/debiankit.sh)"

DEBIANKIT_ROOT=''
DEBIANKIT_DOWNLOAD_DIR=''
DEBIANKIT_COMMON_LOADED=no
readonly DEBIANKIT_BASE_URL='https://raw.githubusercontent.com/planet756/Shell/main'

entry_error() {
    printf 'ERROR: %s\n' "$1" >&2
    return 1
}

cleanup_downloads() {
    if [[ -n "$DEBIANKIT_DOWNLOAD_DIR" ]]; then
        rm -rf -- "$DEBIANKIT_DOWNLOAD_DIR"
    fi
}

prepare_project() {
    local candidate='' source_path="${BASH_SOURCE[0]:-}" directory asset
    if [[ -n "$source_path" && -f "$source_path" ]]; then
        candidate=$(cd -- "$(dirname -- "$source_path")" && pwd) || return 1
        [[ -n "$candidate" ]] || return 1
        [[ -r "$candidate/lib/common.sh" ]] || {
            entry_error 'Project files are missing. Download the complete project or use the documented remote command.'
            return 1
        }
        DEBIANKIT_ROOT="$candidate"
        return 0
    fi

    # Inline bash -c execution has no source file: fetch our own project files.
    command -v curl >/dev/null 2>&1 || { entry_error 'curl is required for remote startup.'; return 1; }
    directory=$(mktemp -d "${TMPDIR:-/tmp}/debiankit.XXXXXX") || return 1
    DEBIANKIT_DOWNLOAD_DIR="$directory"
    trap cleanup_downloads EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p "$directory/lib" "$directory/modules" || return 1
    for asset in lib/common.sh modules/debian.sh modules/reinstall.sh; do
        if ! curl -fLsS --proto '=https' --proto-redir '=https' --connect-timeout 15 \
            --max-time 120 --retry 2 "$DEBIANKIT_BASE_URL/$asset" -o "$directory/$asset"; then
            entry_error 'Failed to download project files; no project module was executed.'
            return 1
        fi
        if ! bash -n "$directory/$asset"; then
            entry_error 'Downloaded project module has invalid shell syntax.'
            return 1
        fi
    done
    DEBIANKIT_ROOT="$directory"
}

load_common() {
    [[ "$DEBIANKIT_COMMON_LOADED" != yes ]] || return 0
    prepare_project || return 1
    # shellcheck source=lib/common.sh
    source "$DEBIANKIT_ROOT/lib/common.sh" || return 1
    DEBIANKIT_COMMON_LOADED=yes
}

show_menu() {
    if [[ -t 1 && -n "${TERM:-}" && "$TERM" != dumb ]]; then clear; fi
    printf '%b\n' "${BLUE}======================================${NC}"
    printf '%b\n' "${GREEN}        DebianKit v1.4.0${NC}"
    printf '%b\n' "${BLUE}======================================${NC}"
    printf '%s\n' \
        '01. Update Debian Sources' \
        '02. Initialize User' \
        '03. Install BBR' \
        '04. Install Docker' \
        '05. Install Telegraf' \
        '06. Install Komari Agent (Non-Root)' \
        '07. Install Node.js (Official Binary)' \
        '08. Install Go (Official Binary)' \
        '09. Reinstall OS' \
        '' \
        '99. Install All' \
        '00. Exit'
    printf '%b\n' "${BLUE}======================================${NC}"
    printf '%b\n' "${YELLOW}Tip: Type 'reset' to reset initialization${NC}"
}

show_help() {
    cat <<'EOF'
DebianKit - Debian setup and OS reinstallation

Usage:
  sudo bash debiankit.sh                         Main menu
  bash debiankit.sh --menu                       Display menu without changes
  bash debiankit.sh --help                       Show this help
  sudo bash debiankit.sh debian ACTION            Run a setup action
  sudo bash debiankit.sh reinstall PRESET         Prepare OS reinstallation
  bash debiankit.sh reinstall --dry-run PRESET    Preview reinstallation
  sudo bash debiankit.sh reinstall reset          Cancel BEFORE reboot

Debian actions: sources, user, bbr, docker, telegraf, komari, nodejs, go, all,
                reset-init
Reinstall presets: debian13, windows10-iot-ltsc
Run bash debiankit.sh reinstall --help for reinstallation options.
Menu option 09 opens Reinstall OS: choose a system, cancel pending installation,
or return to the main menu. Option 99 runs the original setup components.
EOF
}

run_module() {
    local name="$1" script
    shift
    case "$name" in
        debian|reinstall) script="$DEBIANKIT_ROOT/modules/$name.sh" ;;
        *) entry_error 'Unknown project module.'; return 2 ;;
    esac
    [[ -r "$script" ]] || { entry_error 'Project module is missing; restore the complete project.'; return 2; }
    # Separate processes keep module functions, shell options and traps isolated.
    bash "$script" "$@"
}

reinstall_menu() {
    local catalog id label choice index selected
    local -a presets=() labels=()
    if ! catalog=$(run_module reinstall --list); then
        log ERROR 'Cannot load reinstallation presets.'
        return 1
    fi
    while read -r id label; do
        [[ -n "$id" && -n "$label" ]] || continue
        presets+=("$id")
        labels+=("$label")
    done <<< "$catalog"
    (( ${#presets[@]} > 0 && ${#presets[@]} < 99 )) || {
        log ERROR 'No usable reinstallation presets were found.'
        return 1
    }
    while true; do
        if [[ -t 1 && -n "${TERM:-}" && "$TERM" != dumb ]]; then clear; fi
        printf '%b\n' "${BLUE}======================================${NC}"
        printf '%b\n' "${GREEN}             Reinstall OS${NC}"
        printf '%b\n' "${BLUE}======================================${NC}"
        for index in "${!presets[@]}"; do
            printf '%02d. %s\n' "$((index + 1))" "${labels[index]}"
        done
        printf '%s\n' '' '99. Cancel Pending Reinstallation' '00. Back to Main Menu'
        printf '%b\n' "${BLUE}======================================${NC}"
        if ! read -r -p 'Select option [00-99]: ' choice; then
            entry_error 'Interactive input is unavailable.'
            return 1
        fi
        case "$choice" in
            0|00) return 0 ;;
            99) selected=reset ;;
            *)
                if [[ ! "$choice" =~ ^[0-9]{1,2}$ ]] ||
                   (( 10#$choice < 1 || 10#$choice > ${#presets[@]} )); then
                    log ERROR 'Invalid option. Select a listed number.'
                    continue
                fi
                selected="${presets[10#$choice - 1]}"
                ;;
        esac
        if ! run_module reinstall "$selected"; then
            log WARN 'The selected action did not complete. Review its output before continuing.'
        fi
        pause || return 0
    done
}

offer_setup_reboot() {
    local status answer
    run_module reinstall --pending
    status=$?
    case "$status" in
        0)
            log WARN 'Reinstallation is pending. Rebooting will erase the target disk and start installation.'
            log INFO 'Review the reinstallation output, or open Reinstall OS and select 99 to cancel before rebooting.'
            return 0
            ;;
        1) ;;
        *) log ERROR 'Cannot check pending reinstallation; skipping the setup reboot prompt.'; return 1 ;;
    esac
    printf '\n'
    read -r -n 1 -p 'Reboot system now to apply all changes? (y/N): ' answer || return 0
    printf '\n'
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        log INFO 'Rebooting in 5 seconds... (Ctrl+C to cancel)'
        sleep 5
        reboot
    fi
}

dispatch_choice() {
    case "$1" in
        01) run_module debian sources ;;
        02) run_module debian user ;;
        03) run_module debian bbr ;;
        04) run_module debian docker ;;
        05) run_module debian telegraf ;;
        06) run_module debian komari ;;
        07) run_module debian nodejs ;;
        08) run_module debian go ;;
        09) reinstall_menu ;;
        reset) run_module debian reset-init ;;
        99)
            if ! run_module debian all; then return 1; fi
            offer_setup_reboot
            ;;
        *) log ERROR 'Invalid option. Select a listed number.'; return 1 ;;
    esac
}

pause() {
    printf '\n'
    read -r -p 'Press Enter to continue...' || return 1
}

main() {
    case "${1:-}" in
        -h|--help) show_help; return 0 ;;
        --menu) load_common || return 1; show_menu; return 0 ;;
        debian|reinstall)
            local module="$1"
            shift
            load_common || return 1
            if [[ "$module" == reinstall && $# -eq 0 ]]; then
                check_root
                reinstall_menu
                return $?
            fi
            run_module "$module" "$@"
            return $?
            ;;
        '') ;;
        *) entry_error 'Unknown command. Run bash debiankit.sh --help.'; return 1 ;;
    esac
    load_common || return 1
    check_root
    local choice
    while true; do
        show_menu
        printf '\n'
        if ! read -r -p 'Select option [00-99]: ' choice; then
            entry_error 'Interactive input is unavailable. Download the project or use the documented bash -c command.'
            return 1
        fi
        if [[ "$choice" == 00 ]]; then
            log INFO 'Exiting DebianKit. Goodbye!'
            return 0
        fi
        if ! dispatch_choice "$choice"; then
            log WARN 'The selected action did not complete. Review its output before continuing.'
        fi
        if [[ "$choice" != 09 ]]; then pause || return 0; fi
    done
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
