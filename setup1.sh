#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup1.sh
# Public bootstrap:
#   1. Detect OS distribution, family and CPU architecture.
#   2. Validate the native/expected package manager.
#   3. Bootstrap Homebrew on macOS and classic Fedora when needed.
#   4. Require preinstalled Homebrew on Fedora Atomic / Universal Blue.
#   5. Ensure Homebrew's bin directory is first in PATH.
#   6. Install Git and GitHub CLI.
#   7. Authenticate GitHub and configure Git identity.
#   8. Clone the private setup repository and hand over to setup2.sh.
# =============================================================================

readonly PRIVATE_REPO="setup2"
readonly PDIR="${HOME}/p"
readonly SETUP_DIR="${PDIR}/setup2"
readonly SETUP_SCRIPT="${SETUP_DIR}/setup2.sh"

distro="unknown"
family="unknown"
cpu="unknown"
pkgmgr="unknown"
pkgver="unknown"
brew_prefix=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s\n' "$*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "commande introuvable: $1"
}

as_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        require_cmd sudo
        sudo "$@"
    fi
}

first_line() {
    local value="$1"
    printf '%s\n' "${value%%$'\n'*}"
}

find_brew() {
    local candidate

    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return 0
    fi

    for candidate in \
        /opt/homebrew/bin/brew \
        /home/linuxbrew/.linuxbrew/bin/brew \
        /usr/local/bin/brew
    do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

activate_brew() {
    local brew_bin
    local entry
    local clean_path=""
    local -a path_entries

    brew_bin="$(find_brew)" || return 1

    eval "$("$brew_bin" shellenv)"

    brew_prefix="$(brew --prefix)" ||
        die "impossible de déterminer HOMEBREW_PREFIX"

    IFS=':' read -r -a path_entries <<< "$PATH"

    for entry in "${path_entries[@]}"; do
        [[ "$entry" == "$brew_prefix/bin" ]] && continue
        [[ "$entry" == "$brew_prefix/sbin" ]] && continue

        if [[ -z "$clean_path" ]]; then
            clean_path="$entry"
        else
            clean_path="${clean_path}:$entry"
        fi
    done

    export PATH="${brew_prefix}/bin:${brew_prefix}/sbin${clean_path:+:${clean_path}}"
    hash -r

    [[ "${PATH%%:*}" == "${brew_prefix}/bin" ]] ||
        die "Homebrew bin n'est pas premier dans PATH"

    case "$PATH" in
        "${brew_prefix}/bin:${brew_prefix}/sbin"|\
        "${brew_prefix}/bin:${brew_prefix}/sbin:"*)
            ;;
        *)
            die "Homebrew sbin n'est pas deuxième dans PATH"
            ;;
    esac
}

install_homebrew() {
    require_cmd curl

    info "Installation de Homebrew"

    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    activate_brew ||
        die "Homebrew installé mais introuvable ou inutilisable"
}

check_brew_version() {
    local output

    activate_brew ||
        die "Homebrew introuvable"

    output="$(brew --version)" ||
        die "Homebrew inutilisable"

    pkgmgr="brew"
    pkgver="$(first_line "$output")"
}

# -----------------------------------------------------------------------------
# CPU detection
# -----------------------------------------------------------------------------

machine="$(uname -m)"

case "$machine" in
    arm64|aarch64)
        cpu="arm64"
        ;;
    x86_64|amd64)
        cpu="x86_64"
        ;;
    *)
        die "CPU non supporté: $machine"
        ;;
esac

kernel="$(uname -s)"

# -----------------------------------------------------------------------------
# Distribution detection
# -----------------------------------------------------------------------------

if [[ "$kernel" == "Darwin" ]]; then
    distro="macos"
    family="macos"

    if [[ "$(sysctl -in hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
        cpu="arm64"
    fi

elif [[ -n "${TERMUX_VERSION:-}" ]] ||
     [[ "${PREFIX:-}" == */com.termux/files/usr ]]; then
    distro="termux"
    family="termux"

    [[ "$cpu" == "arm64" ]] ||
        die "Termux non ARM64 non supporté"

elif [[ "$kernel" == "Linux" && -r /etc/os-release ]]; then
    . /etc/os-release

    os_id="${ID:-unknown}"
    os_like=" ${ID_LIKE:-} "
    variant_id="${VARIANT_ID:-}"

    distro="$os_id"

    if [[ "$os_id" == "fedora" && -n "$variant_id" ]]; then
        distro="fedora-${variant_id}"
    fi

    case "$os_id" in
        aurora|bluefin|bazzite)
            family="fedora-atomic"
            ;;

        fedora)
            case "$variant_id" in
                silverblue|kinoite|sway-atomic|budgie-atomic|cosmic-atomic|sericea|onyx)
                    family="fedora-atomic"
                    ;;
                *)
                    family="fedora"
                    ;;
            esac
            ;;

        fedora-asahi-remix)
            family="fedora"
            ;;

        debian|ubuntu)
            family="debian"
            ;;

        *)
            if [[ "$os_like" == *" fedora "* ]]; then
                if [[ -e /run/ostree-booted ]]; then
                    family="fedora-atomic"
                else
                    family="fedora"
                fi
            elif [[ "$os_like" == *" debian "* ]] ||
                 [[ "$os_like" == *" ubuntu "* ]]; then
                family="debian"
            else
                die "distribution non supportée: $os_id"
            fi
            ;;
    esac

    if [[ "$family" == "fedora" &&
          "$cpu" == "arm64" &&
          "$(uname -r)" == *asahi* ]]; then
        distro="fedora-asahi-remix"
    fi

else
    die "système non supporté: $kernel"
fi

# -----------------------------------------------------------------------------
# Package-manager validation / Homebrew bootstrap
# -----------------------------------------------------------------------------

case "$family" in
    macos)
        if activate_brew; then
            check_brew_version
        else
            install_homebrew
            check_brew_version
        fi
        ;;

    fedora)
        require_cmd dnf

        dnf_output="$(dnf --version)" ||
            die "DNF inutilisable"

        info "DNF détecté: $(first_line "$dnf_output")"

        if ! activate_brew; then
            info "Installation des prérequis Homebrew avec DNF"

            as_root dnf group install -y development-tools
            as_root dnf install -y procps-ng curl file

            install_homebrew
        fi

        check_brew_version
        ;;

    fedora-atomic)
        activate_brew ||
            die "Homebrew requis mais absent sur $distro"

        check_brew_version
        ;;

    debian)
        require_cmd apt

        apt_output="$(apt --version)" ||
            die "APT inutilisable"

        pkgmgr="apt"
        pkgver="$(first_line "$apt_output")"
        ;;

    termux)
        require_cmd pkg

        if command -v apt >/dev/null 2>&1; then
            termux_backend_output="$(apt --version)" ||
                die "backend APT de pkg inutilisable"

            pkgmgr="pkg"
            pkgver="pkg / $(first_line "$termux_backend_output")"
        elif command -v pacman >/dev/null 2>&1; then
            termux_backend_output="$(pacman --version)" ||
                die "backend pacman de pkg inutilisable"

            pacman_version="$(
                printf '%s\n' "$termux_backend_output" |
                awk '/Pacman v/ {print; exit}'
            )"

            [[ -n "$pacman_version" ]] ||
                die "version du backend pacman introuvable"

            pkgmgr="pkg"
            pkgver="pkg / $pacman_version"
        else
            die "pkg présent mais backend introuvable"
        fi
        ;;

    *)
        die "famille non supportée: $family"
        ;;
esac

# -----------------------------------------------------------------------------
# Detection report
# -----------------------------------------------------------------------------

printf '\nDetected environment\n'
printf '  distro : %s\n' "$distro"
printf '  family : %s\n' "$family"
printf '  cpu    : %s\n' "$cpu"
printf '  pkgmgr : %s\n' "$pkgmgr"
printf '  version: %s\n' "$pkgver"

if [[ "$pkgmgr" == "brew" ]]; then
    printf '  brew   : %s\n' "$brew_prefix"
    printf '  PATH[0]: %s\n' "${PATH%%:*}"

    [[ "${PATH%%:*}" == "${brew_prefix}/bin" ]] ||
        die "PATH invalide: ${brew_prefix}/bin doit être premier"
fi

printf '\n'

# -----------------------------------------------------------------------------
# Install Git + GitHub CLI
# -----------------------------------------------------------------------------

info "Installation de git et gh"

case "$family" in
    macos|fedora|fedora-atomic)
        HOMEBREW_NO_ASK=1 brew install -y git gh
        activate_brew
        ;;

    debian)
        as_root apt update
        as_root apt install -y git gh
        ;;

    termux)
        pkg update
        pkg install -y git gh
        ;;
esac

hash -r

require_cmd git
require_cmd gh

if [[ "$family" == "macos" ||
      "$family" == "fedora" ||
      "$family" == "fedora-atomic" ]]; then
    [[ "$(command -v git)" == "${brew_prefix}/bin/git" ]] ||
        die "Git utilisé n'est pas celui de Homebrew: $(command -v git)"

    [[ "$(command -v gh)" == "${brew_prefix}/bin/gh" ]] ||
        die "gh utilisé n'est pas celui de Homebrew: $(command -v gh)"
fi

printf '  %s\n' "$(git --version)"

gh_version="$(gh --version)"
printf '  %s\n\n' "$(first_line "$gh_version")"

# -----------------------------------------------------------------------------
# GitHub authentication
# -----------------------------------------------------------------------------

info "Authentification GitHub"

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    gh auth login \
        --hostname github.com \
        --web \
        --git-protocol https
fi

gh auth setup-git --hostname github.com

# -----------------------------------------------------------------------------
# Git identity from the authenticated GitHub profile
# -----------------------------------------------------------------------------

info "Configuration de l'identité Git"

git_name="$(
    gh api user --jq \
        'if (.name // "") == "" then .login else .name end'
)"

git_login="$(gh api user --jq '.login')"
git_id="$(gh api user --jq '.id')"
git_email="${git_id}+${git_login}@users.noreply.github.com"

git config --global user.name "$git_name"
git config --global user.email "$git_email"

printf '  user.name : %s\n' "$(git config --global user.name)"
printf '  user.email: %s\n\n' "$(git config --global user.email)"

# -----------------------------------------------------------------------------
# Hand over to private repository
# -----------------------------------------------------------------------------

info "Passage au setup privé"

mkdir -p "$PDIR"
cd "$PDIR"

gh repo clone "$PRIVATE_REPO" "$SETUP_DIR"

[[ -f "$SETUP_SCRIPT" ]] ||
    die "script privé introuvable: $SETUP_SCRIPT"

bash "$SETUP_SCRIPT"
