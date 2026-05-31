#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ui.sh — Shared UI library for Standard Notes Self-Hosted Server scripts
# ─────────────────────────────────────────────────────────────────────────────
# Source this file from other scripts:   source "$(dirname "$0")/ui.sh"
# No side effects on source. All output goes through functions.
# ─────────────────────────────────────────────────────────────────────────────

UI_VERSION="2.0.0"

# ═══════════════════════════════════════════════════════════════════════════════
# §1  COLOR PALETTE — with graceful degradation
# ═══════════════════════════════════════════════════════════════════════════════
# Detects terminal capability and sets color variables accordingly.
# Guards everything behind [[ -t 1 ]] so piped/redirected output stays clean.

_ui_init_colors() {
    # Default: no colors (safe for non-interactive / piped output)
    C_RESET=""
    C_BOLD="" ; C_DIM="" ; C_ITALIC="" ; C_UNDERLINE=""
    C_CYAN="" ; C_MAGENTA="" ; C_BLUE="" ; C_GREEN="" ; C_YELLOW="" ; C_RED=""
    C_WHITE="" ; C_GRAY=""
    C_BOLD_CYAN="" ; C_BOLD_MAGENTA="" ; C_BOLD_BLUE="" ; C_BOLD_GREEN=""
    C_BOLD_YELLOW="" ; C_BOLD_RED="" ; C_BOLD_WHITE=""
    C_DIM_CYAN="" ; C_DIM_WHITE="" ; C_DIM_GRAY=""
    C_BG_CYAN="" ; C_BG_MAGENTA="" ; C_BG_BLUE=""
    C_BG_GREEN="" ; C_BG_RED="" ; C_BG_YELLOW=""
    # Gradient steps for the banner (cyan → magenta)
    C_GRAD1="" ; C_GRAD2="" ; C_GRAD3="" ; C_GRAD4=""
    C_GRAD5="" ; C_GRAD6="" ; C_GRAD7=""

    # Only colorize when stdout is a terminal
    [[ -t 1 ]] || return 0

    local colors
    colors=$(tput colors 2>/dev/null || echo 0)

    if [[ ${COLORTERM:-} =~ ^(truecolor|24bit)$ ]] || (( colors >= 256 )); then
        # ── 256-color / truecolor mode ──────────────────────────────────
        C_RESET=$'\e[0m'
        C_BOLD=$'\e[1m'  ; C_DIM=$'\e[2m'
        C_ITALIC=$'\e[3m'; C_UNDERLINE=$'\e[4m'

        # Primary palette (256-color)
        C_CYAN=$'\e[38;5;87m'
        C_MAGENTA=$'\e[38;5;177m'
        C_BLUE=$'\e[38;5;75m'
        C_GREEN=$'\e[38;5;114m'
        C_YELLOW=$'\e[38;5;221m'
        C_RED=$'\e[38;5;203m'
        C_WHITE=$'\e[38;5;255m'
        C_GRAY=$'\e[38;5;245m'

        # Bold variants
        C_BOLD_CYAN=$'\e[1;38;5;87m'
        C_BOLD_MAGENTA=$'\e[1;38;5;177m'
        C_BOLD_BLUE=$'\e[1;38;5;75m'
        C_BOLD_GREEN=$'\e[1;38;5;114m'
        C_BOLD_YELLOW=$'\e[1;38;5;221m'
        C_BOLD_RED=$'\e[1;38;5;203m'
        C_BOLD_WHITE=$'\e[1;38;5;255m'

        # Dim variants
        C_DIM_CYAN=$'\e[2;38;5;87m'
        C_DIM_WHITE=$'\e[2;38;5;255m'
        C_DIM_GRAY=$'\e[2;38;5;240m'

        # Background highlights (for headers)
        C_BG_CYAN=$'\e[48;5;30m'
        C_BG_MAGENTA=$'\e[48;5;55m'
        C_BG_BLUE=$'\e[48;5;24m'
        C_BG_GREEN=$'\e[48;5;22m'
        C_BG_RED=$'\e[48;5;52m'
        C_BG_YELLOW=$'\e[48;5;58m'

        # Gradient: cyan (#00d7ff → #af87ff → #d787ff) — 7 steps
        C_GRAD1=$'\e[38;5;87m'   # bright cyan
        C_GRAD2=$'\e[38;5;81m'   # cyan-blue
        C_GRAD3=$'\e[38;5;111m'  # light blue
        C_GRAD4=$'\e[38;5;141m'  # blue-purple
        C_GRAD5=$'\e[38;5;140m'  # lavender
        C_GRAD6=$'\e[38;5;176m'  # light magenta
        C_GRAD7=$'\e[38;5;177m'  # magenta
    elif (( colors >= 8 )); then
        # ── Basic ANSI fallback ─────────────────────────────────────────
        C_RESET=$'\e[0m'
        C_BOLD=$'\e[1m'  ; C_DIM=$'\e[2m'
        C_ITALIC=$'\e[3m'; C_UNDERLINE=$'\e[4m'

        C_CYAN=$'\e[36m'    ; C_MAGENTA=$'\e[35m'  ; C_BLUE=$'\e[34m'
        C_GREEN=$'\e[32m'   ; C_YELLOW=$'\e[33m'   ; C_RED=$'\e[31m'
        C_WHITE=$'\e[37m'   ; C_GRAY=$'\e[90m'

        C_BOLD_CYAN=$'\e[1;36m'    ; C_BOLD_MAGENTA=$'\e[1;35m'
        C_BOLD_BLUE=$'\e[1;34m'    ; C_BOLD_GREEN=$'\e[1;32m'
        C_BOLD_YELLOW=$'\e[1;33m'  ; C_BOLD_RED=$'\e[1;31m'
        C_BOLD_WHITE=$'\e[1;37m'

        C_DIM_CYAN=$'\e[2;36m'   ; C_DIM_WHITE=$'\e[2;37m'
        C_DIM_GRAY=$'\e[2;90m'

        C_BG_CYAN=$'\e[46m'    ; C_BG_MAGENTA=$'\e[45m'
        C_BG_BLUE=$'\e[44m'    ; C_BG_GREEN=$'\e[42m'
        C_BG_RED=$'\e[41m'     ; C_BG_YELLOW=$'\e[43m'

        # Gradient fallback: alternate cyan / magenta
        C_GRAD1=$'\e[36m' ; C_GRAD2=$'\e[36m' ; C_GRAD3=$'\e[96m'
        C_GRAD4=$'\e[35m' ; C_GRAD5=$'\e[35m' ; C_GRAD6=$'\e[95m'
        C_GRAD7=$'\e[95m'
    fi
}

# Initialize colors immediately on source
_ui_init_colors


# ═══════════════════════════════════════════════════════════════════════════════
# §2  ASCII ART BANNER — gradient-colored Standard Notes logo
# ═══════════════════════════════════════════════════════════════════════════════
# Prints the stylized "STD.NO" banner with a cyan→magenta gradient on the
# block letters and a dimmed subtitle.

show_banner() {
    local border_color="${C_DIM_GRAY}"
    local subtitle_color="${C_GRAY}"
    local line_colors=( "$C_GRAD1" "$C_GRAD2" "$C_GRAD3" "$C_GRAD4" "$C_GRAD5" "$C_GRAD6" "$C_GRAD7" )

    cat <<EOF

${border_color}   ╔═══════════════════════════════════════════════════════╗${C_RESET}
${border_color}   ║${C_RESET}                                                       ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}   ${line_colors[0]}${C_BOLD}███████╗████████╗██████╗    ███╗   ██╗ ██████╗ ${C_RESET}     ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}   ${line_colors[1]}${C_BOLD}██╔════╝╚══██╔══╝██╔══██╗   ████╗  ██║██╔═══██╗${C_RESET}    ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}   ${line_colors[2]}${C_BOLD}███████╗   ██║   ██║  ██║   ██╔██╗ ██║██║   ██║${C_RESET}    ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}   ${line_colors[3]}${C_BOLD}╚════██║   ██║   ██║  ██║   ██║╚██╗██║██║   ██║${C_RESET}    ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}   ${line_colors[4]}${C_BOLD}███████║   ██║   ██████╔╝██╗██║ ╚████║╚██████╔╝${C_RESET}    ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}   ${line_colors[5]}${C_BOLD}╚══════╝   ╚═╝   ╚═════╝ ╚═╝╚═╝  ╚═══╝ ╚═════╝ ${C_RESET}   ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}                                                       ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}          ${subtitle_color}S E L F - H O S T E D   S E R V E R${C_RESET}          ${border_color}║${C_RESET}
${border_color}   ║${C_RESET}                                                       ${border_color}║${C_RESET}
${border_color}   ╚═══════════════════════════════════════════════════════╝${C_RESET}
EOF
}


# ═══════════════════════════════════════════════════════════════════════════════
# §3  OUTPUT FUNCTIONS — icon-prefixed, color-coded messages
# ═══════════════════════════════════════════════════════════════════════════════

# Print a success message with a green checkmark
ui_ok() {
    printf '%s\n' "${C_GREEN} ✓${C_RESET} ${C_GREEN}$*${C_RESET}"
}

# Print a warning message with a yellow caution symbol
ui_warn() {
    printf '%s\n' "${C_YELLOW} ⚠${C_RESET} ${C_YELLOW}$*${C_RESET}"
}

# Print an error message with a red cross (to stderr)
ui_error() {
    printf '%s\n' "${C_RED} ✗${C_RESET} ${C_RED}$*${C_RESET}" >&2
}

# Print an informational message with a blue info icon
ui_info() {
    printf '%s\n' "${C_BLUE} ℹ${C_RESET} ${C_BLUE}$*${C_RESET}"
}

# Print a visually prominent step/section header
# Usage: ui_step "Configuring database"
ui_step() {
    printf '\n%s\n' "${C_BOLD_CYAN}━━━ ▸ $* ◂ ━━━${C_RESET}"
}

# Print an indented substep with a tree-branch prefix
# Usage: ui_substep "Creating schema..."
ui_substep() {
    printf '%s\n' "${C_DIM_GRAY}  ├─${C_RESET} ${C_DIM_WHITE}$*${C_RESET}"
}

# Print a dim timestamped log message
# Usage: ui_log "Container started on port 3000"
ui_log() {
    local ts
    ts=$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')
    printf '%s\n' "${C_DIM_GRAY} [${ts}]${C_RESET} ${C_GRAY}$*${C_RESET}"
}

# Print an error message and exit with code 1
# Usage: ui_die "Fatal: could not connect to database"
ui_die() {
    ui_error "$@"
    exit 1
}

# Print a boxed section header with double-line border
# Usage: ui_header "Configuration Summary"
ui_header() {
    local text="$*"
    local len=${#text}
    local pad=$(( len + 4 ))
    local border
    border=$(printf '═%.0s' $(seq 1 "$pad"))

    printf '\n'
    printf '%s\n' "${C_BOLD_CYAN}  ╔${border}╗${C_RESET}"
    printf '%s\n' "${C_BOLD_CYAN}  ║${C_RESET}  ${C_BOLD_WHITE}${text}${C_RESET}  ${C_BOLD_CYAN}║${C_RESET}"
    printf '%s\n' "${C_BOLD_CYAN}  ╚${border}╝${C_RESET}"
}

# Print a thin horizontal divider line
ui_divider() {
    printf '%s\n' "${C_DIM_GRAY}  $(printf '─%.0s' $(seq 1 56))${C_RESET}"
}


# ═══════════════════════════════════════════════════════════════════════════════
# §4  SPINNER — braille animation for background commands
# ═══════════════════════════════════════════════════════════════════════════════
# Usage: with_spinner "Installing packages" apt-get install -y foo
# Runs <command...> in the background, shows a braille spinner with <message>,
# then prints ✓ or ✗ when done. Cleans up on SIGINT/SIGTERM/EXIT.

with_spinner() {
    local msg="$1"; shift

    # If stdout is not a terminal, just run the command silently
    if [[ ! -t 1 ]]; then
        "$@" >/dev/null 2>&1
        return $?
    fi

    local frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local frame_count=${#frames[@]}
    local i=0
    local pid

    # Hide cursor
    tput civis 2>/dev/null || true

    # Cleanup function: restore cursor and kill background job
    _spinner_cleanup() {
        tput cnorm 2>/dev/null || true
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
        # Clear the spinner line
        printf '\r\e[2K'
    }

    # Trap signals for robust cleanup
    trap '_spinner_cleanup' INT TERM

    # Run command in background, suppressing output
    "$@" >/dev/null 2>&1 &
    pid=$!

    # Animate spinner while the command runs
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r%s' " ${C_CYAN}${frames[i % frame_count]}${C_RESET} ${msg}"
        i=$(( i + 1 ))
        sleep 0.08
    done

    # Collect exit code
    wait "$pid" 2>/dev/null
    local exit_code=$?

    # Clear spinner line and print result
    printf '\r\e[2K'
    if (( exit_code == 0 )); then
        printf '%s\n' "${C_GREEN} ✓${C_RESET} ${msg}"
    else
        printf '%s\n' "${C_RED} ✗${C_RESET} ${msg} ${C_DIM_GRAY}(exit ${exit_code})${C_RESET}"
    fi

    # Restore cursor and reset trap
    tput cnorm 2>/dev/null || true
    trap - INT TERM

    return "$exit_code"
}


# ═══════════════════════════════════════════════════════════════════════════════
# §5  PROGRESS BAR — Unicode block rendering
# ═══════════════════════════════════════════════════════════════════════════════
# Usage: show_progress 57 100 "Installing packages"
# Renders:   ████████░░░░░░ 57% Installing packages

show_progress() {
    local current="${1:?current required}"
    local total="${2:?total required}"
    local label="${3:-}"
    local bar_width=20
    local pct=0

    if (( total > 0 )); then
        pct=$(( current * 100 / total ))
    fi

    local filled=$(( pct * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled bar_empty
    bar_filled=$(printf '█%.0s' $(seq 1 "$filled") 2>/dev/null)
    bar_empty=$(printf '░%.0s'  $(seq 1 "$empty")  2>/dev/null)

    # Use \r to overwrite in-place (caller can loop)
    printf '\r  %s%s%s %s%3d%%%s %s' \
        "${C_CYAN}" "${bar_filled}" "${C_DIM_GRAY}" \
        "${bar_empty}" "$pct" "${C_RESET}" \
        "${label}"

    # Print newline only when complete
    if (( pct >= 100 )); then
        printf '\n'
    fi
}


# ═══════════════════════════════════════════════════════════════════════════════
# §6  PROMPT FUNCTIONS — interactive input with styled formatting
# ═══════════════════════════════════════════════════════════════════════════════

# Prompt the user for a value and store it in a variable.
# Usage: ui_prompt_value MY_VAR "Enter your domain" "example.com"
ui_prompt_value() {
    local -n _ui_ref="$1"
    local question="$2"
    local default="${3:-}"
    local input

    if [[ -n "$default" ]]; then
        printf '%s %s %s: ' \
            "${C_CYAN} ❯${C_RESET}" \
            "${C_WHITE}${question}${C_RESET}" \
            "${C_DIM_GRAY}[${default}]${C_RESET}"
    else
        printf '%s %s: ' \
            "${C_CYAN} ❯${C_RESET}" \
            "${C_WHITE}${question}${C_RESET}"
    fi

    read -r input
    _ui_ref="${input:-$default}"
}

# Prompt the user for a secret value (input is masked).
# Usage: ui_prompt_secret MY_SECRET "Enter database password"
ui_prompt_secret() {
    local -n _ui_sref="$1"
    local question="$2"
    local input

    printf '%s %s: ' \
        "${C_CYAN} ❯${C_RESET}" \
        "${C_WHITE}${question}${C_RESET}"

    read -rs input
    printf '\n'
    _ui_sref="$input"
}

# Ask a yes/no confirmation question. Returns 0 for yes, 1 for no.
# Usage: ui_confirm "Proceed with installation?" Y
#        if ui_confirm "Delete data?" N; then ...
ui_confirm() {
    local question="$1"
    local default="${2:-Y}"
    local hint input

    if [[ "${default^^}" == "Y" ]]; then
        hint="${C_BOLD_WHITE}Y${C_RESET}${C_DIM_GRAY}/n${C_RESET}"
    else
        hint="${C_DIM_GRAY}y/${C_RESET}${C_BOLD_WHITE}N${C_RESET}"
    fi

    printf '%s %s [%s] ' \
        "${C_CYAN} ❯${C_RESET}" \
        "${C_WHITE}${question}${C_RESET}" \
        "${hint}"

    read -r input
    input="${input:-$default}"

    [[ "${input^^}" == "Y" || "${input^^}" == "YES" ]]
}


# ═══════════════════════════════════════════════════════════════════════════════
# §7  KEY-VALUE DISPLAY — aligned summary rows
# ═══════════════════════════════════════════════════════════════════════════════
# Prints a key-value pair with consistent column alignment.
# Usage: ui_kv "Install dir" "/opt/standardnotes"
#        ui_kv "Notes API"   "https://notes.example.com"

ui_kv() {
    local key="$1"
    local value="$2"
    printf '  %s%-22s%s %s%s%s\n' \
        "${C_GRAY}" "${key}" "${C_RESET}" \
        "${C_BOLD_WHITE}" "${value}" "${C_RESET}"
}


# ═══════════════════════════════════════════════════════════════════════════════
# §8  INTERNAL UTILITIES
# ═══════════════════════════════════════════════════════════════════════════════

# Re-export color init so scripts can refresh after redirections change
ui_reinit_colors() {
    _ui_init_colors
}
