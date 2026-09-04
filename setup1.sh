#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup1.sh — public bootstrap / fallback maintenance contract
# =============================================================================
#
# PURPOSE
# -------
# Prepare a supported machine for the private Fish stage `setup2.fish`:
#   1. detect OS family, distribution and CPU;
#   2. establish and verify the package-manager policy;
#   3. install/verify Git, GitHub CLI (`gh`) and Fish;
#   4. make Homebrew first in PATH where Homebrew is the selected manager;
#   5. authenticate GitHub as `panlelapin` and configure Git;
#   6. clone/reuse the private `panlelapin/setup2` checkout;
#   7. invoke `setup2.fish` with a versioned, validated SETUP_* context.
#
# If AGENTS.md is absent, an LLM modifying this file MUST preserve this contract
# unless the user explicitly changes it.
#
# SUPPORTED CPU / OS
# ------------------
# CPU:
#   arm64|aarch64 -> arm64
#   x86_64|amd64 -> x86_64
#   anything else -> error
#
# Families:
#   macOS
#   classic Fedora / Fedora-like
#   Fedora Atomic / Universal Blue
#   Debian/Ubuntu and derivatives
#   Termux on ARM64 only
#
# PACKAGE POLICY
# --------------
# macOS:
#   Homebrew owns Git/gh/Fish. Install Brew if missing.
#   Apple Silicon prefix: /opt/homebrew; Intel prefix: /usr/local.
#   Under Rosetta, always use native ARM64 Homebrew.
#
# classic Fedora:
#   DNF is bootstrap-only for Homebrew prerequisites.
#   Git/gh/Fish and future CLI tools are Homebrew-managed afterwards.
#   Brew prefix: /home/linuxbrew/.linuxbrew.
#
# Fedora Atomic / Universal Blue:
#   Homebrew must already exist at /home/linuxbrew/.linuxbrew.
#   Do not layer packages or bootstrap Brew with rpm-ostree here.
#
# Debian/Ubuntu family:
#   Use apt-get in scripts, not the interactive apt frontend.
#   Git/Fish come from APT. gh comes from GitHub CLI's official APT repo.
#
# Termux:
#   ARM64 only. Use pkg; validate its apt or pacman backend.
#
# HOMEBREW PATH POLICY
# --------------------
# HOMEBREW_PREFIX/bin and HOMEBREW_PREFIX/sbin must be PATH entries 1 and 2.
# Persist `brew shellenv <shell>` only for installed shells and never duplicate
# lines. Configure Bash, Zsh and Fish using their normal user startup files.
#
# GITHUB / GIT POLICY
# -------------------
# Expected account: panlelapin. Protocol: HTTPS.
# `gh auth setup-git` configures credentials.
# Git name = GitHub `.name`, falling back to `.login`.
# Git email = <id>+<login>@users.noreply.github.com.
# Do not use /user/emails.
#
# SETUP2 HANDOFF CONTRACT — version 1
# -----------------------------------
# Private repo: panlelapin/setup2
# Checkout: ~/p/setup2
# Entrypoint: ~/p/setup2/setup2.fish
# Fish is launched with `--no-config` so user/system Fish configuration does not
# affect the bootstrap. This requires Fish >= 3.4; capability is tested rather
# than assumed.
#
# setup1 passes these non-secret environment variables to setup2.fish:
#   SETUP_CONTEXT_VERSION
#   SETUP_DISTRO
#   SETUP_FAMILY
#   SETUP_CPU
#   SETUP_PROCESS_CPU
#   SETUP_KERNEL
#   SETUP_PACKAGE_MANAGER
#   SETUP_PACKAGE_MANAGER_VERSION
#   SETUP_PACKAGE_MANAGER_BIN
#   SETUP_HOMEBREW_PREFIX
#   SETUP_HOMEBREW_BIN
#   SETUP_TERMUX_BACKEND
#   SETUP_GIT_BIN
#   SETUP_GH_BIN
#   SETUP_FISH_BIN
#   SETUP_GITHUB_LOGIN
#   SETUP_PROJECTS_DIR
#   SETUP_REPO_DIR
#
# setup2.fish must itself be idempotent and validate this context before use.
#
# IDEMPOTENCE / VALIDATION CONTRACT
# ---------------------------------
# Every state-changing step MUST follow:
#   detect desired state -> already correct? -> mutate only if needed -> verify.
# Repeated runs must converge and must not duplicate lines/packages/settings,
# reclone over a valid checkout, overwrite unrelated state, switch accounts, or
# silently use a wrong package manager/binary.
#
# Existing ~/p/setup2 is reused only if it is the expected Git repository.
# Do not automatically pull/reset/clean it; private local work may exist.
#
# setup1 itself must not run as root. Privileged operations are localized to
# sudo. Do not rely on `set -e` as a substitute for explicit postconditions.
# Keep compatibility with old macOS Bash where practical: avoid Bash-4-only
# associative arrays/mapfile/etc.
#
# OUTPUT CONTRACT
# ---------------
# One final status line per setup step:
#   ==> <action>... fait          green
#   ==> <action>... déjà fait    green
#   ==> <action>... ERREUR: ...  red, then exit
# Successful command output/progress stays hidden. Interactive gh login output
# and a genuinely required sudo password prompt are the only normal exceptions.
# =============================================================================

readonly COLOR_GREEN=$'\033[32m'
readonly COLOR_RED=$'\033[31m'
readonly COLOR_RESET=$'\033[0m'
readonly EXPECTED_GITHUB_LOGIN='panlelapin'
readonly PRIVATE_REPO='panlelapin/setup2'
readonly PRIVATE_REPO_HTTPS='https://github.com/panlelapin/setup2.git'
readonly HOMEBREW_INSTALL_URL='https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh'
readonly GH_APT_KEY_URL='https://cli.github.com/packages/githubcli-archive-keyring.gpg'
readonly GH_APT_KEY_SHA256='6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b'
readonly GH_APT_KEYRING='/etc/apt/keyrings/githubcli-archive-keyring.gpg'
readonly GH_APT_SOURCE='/etc/apt/sources.list.d/github-cli.list'

current_action=''
distro='unknown'
family='unknown'
cpu='unknown'
process_cpu='unknown'
kernel='unknown'
pkgmgr='unknown'
pkgver='unknown'
brew_prefix=''
brew_bin=''
git_bin=''
gh_bin=''
fish_bin=''
termux_backend=''
tmp_file=''
gh_apt_repo_changed='false'
PDIR=''
SETUP_DIR=''
SETUP_SCRIPT=''

die() {
    local message="$*"
    if [[ -n "${current_action:-}" ]]; then
        printf '==> %s... %sERREUR%s: %s\n' "$current_action" "$COLOR_RED" "$COLOR_RESET" "$message" >&2
        current_action=''
    else
        printf '%sERREUR%s: %s\n' "$COLOR_RED" "$COLOR_RESET" "$message" >&2
    fi
    exit 1
}

info() { current_action="$*"; }
interactive_info() { current_action="$*"; }

ok() {
    local action="$current_action"
    [[ -n "$action" ]] || die "résultat 'fait' sans action active"
    printf '==> %s... %sfait%s\n' "$action" "$COLOR_GREEN" "$COLOR_RESET"
    current_action=''
}

already() {
    local action="$*"
    current_action=''
    printf '==> %s... %sdéjà fait%s\n' "$action" "$COLOR_GREEN" "$COLOR_RESET"
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "commande requise introuvable: $1"; }
require_exec() { [[ -f "$1" && -x "$1" ]] || die "exécutable requis introuvable: $1"; }
assert_eq() { [[ "$1" == "$2" ]] || die "$3: attendu '$2', obtenu '$1'"; }
assert_nonempty() { [[ -n "$1" ]] || die "$2 est vide"; }

first_line() {
    local value="$1"
    printf '%s\n' "${value%%$'\n'*}"
}

first_nonempty_line() {
    local value="$1" line
    while IFS= read -r line; do
        [[ -n "$line" ]] && { printf '%s\n' "$line"; return 0; }
    done <<< "$value"
    return 1
}

run_quiet() {
    local log_file status
    log_file="$(mktemp)" || die 'mktemp a échoué pour capturer une commande'
    if "$@" >"$log_file" 2>&1; then
        rm -f "$log_file" || die 'suppression du journal temporaire impossible'
        return 0
    else
        status=$?
    fi
    rm -f "$log_file" || true
    return "$status"
}

ensure_sudo_ready() {
    require_cmd sudo
    sudo -n true >/dev/null 2>&1 && return 0
    sudo -v || die "sudo n'a pas pu être validé"
    sudo -n true >/dev/null 2>&1 || die 'sudo reste indisponible après authentification'
}

run_root_quiet() {
    ensure_sudo_ready
    run_quiet sudo -n "$@"
}

cleanup() {
    if [[ -n "$tmp_file" && -e "$tmp_file" ]]; then
        rm -f "$tmp_file" || true
    fi
}
trap cleanup EXIT

preflight() {
    [[ -n "${BASH_VERSION:-}" ]] || die 'ce script doit être exécuté avec Bash'
    [[ -n "${BASH:-}" && -x "$BASH" ]] || die "Bash courant invalide: ${BASH:-<vide>}"
    (( EUID != 0 )) || die 'ne pas exécuter setup1.sh en root/sudo'
    [[ -n "${HOME:-}" && -d "$HOME" && -w "$HOME" ]] || die 'HOME absent/invalide/non inscriptible'
    [[ -n "${PATH:-}" ]] || die "PATH n'est pas défini"
    require_cmd uname
    require_cmd mkdir
    require_cmd grep
    require_cmd mktemp
    require_cmd rm
    require_cmd touch
    require_cmd env
    PDIR="${HOME}/p"
    SETUP_DIR="${PDIR}/setup2"
    SETUP_SCRIPT="${SETUP_DIR}/setup2.fish"
}

detect_cpu() {
    process_cpu="$(uname -m)"
    case "$process_cpu" in
        arm64|aarch64) cpu='arm64' ;;
        x86_64|amd64) cpu='x86_64' ;;
        *) die "CPU non supporté: $process_cpu" ;;
    esac
}

detect_environment() {
    local os_id os_like variant_id apple_arm64
    detect_cpu
    kernel="$(uname -s)"
    if [[ "$kernel" == 'Darwin' ]]; then
        distro='macos'
        family='macos'
        require_cmd sysctl
        apple_arm64="$(sysctl -in hw.optional.arm64 2>/dev/null || true)"
        [[ "$apple_arm64" == '1' ]] && cpu='arm64'
        return
    fi
    if [[ -n "${TERMUX_VERSION:-}" || "${PREFIX:-}" == */com.termux/files/usr ]]; then
        distro='termux'
        family='termux'
        [[ "$cpu" == 'arm64' ]] || die 'Termux non ARM64 non supporté par ce setup'
        return
    fi
    [[ "$kernel" == 'Linux' ]] || die "système non supporté: $kernel"
    [[ -r /etc/os-release ]] || die '/etc/os-release est requis sur Linux'
    . /etc/os-release
    os_id="${ID:-unknown}"
    os_like=" ${ID_LIKE:-} "
    variant_id="${VARIANT_ID:-}"
    distro="$os_id"
    [[ "$os_id" == 'fedora' && -n "$variant_id" ]] && distro="fedora-${variant_id}"
    case "$os_id" in
        aurora|bluefin|bazzite) family='fedora-atomic' ;;
        fedora)
            if [[ -e /run/ostree-booted ]]; then
                family='fedora-atomic'
            else
                case "$variant_id" in
                    silverblue|kinoite|sway-atomic|budgie-atomic|cosmic-atomic|sericea|onyx) family='fedora-atomic' ;;
                    *) family='fedora' ;;
                esac
            fi
            ;;
        fedora-asahi-remix) family='fedora' ;;
        debian|ubuntu) family='debian' ;;
        *)
            if [[ "$os_like" == *' fedora '* ]]; then
                [[ -e /run/ostree-booted ]] && family='fedora-atomic' || family='fedora'
            elif [[ "$os_like" == *' debian '* || "$os_like" == *' ubuntu '* ]]; then
                family='debian'
            else
                die "distribution non supportée: $os_id"
            fi
            ;;
    esac
    if [[ "$family" == 'fedora' && "$cpu" == 'arm64' && "$(uname -r)" == *asahi* ]]; then
        distro='fedora-asahi-remix'
    fi
}

set_expected_brew() {
    case "$family" in
        macos) [[ "$cpu" == 'arm64' ]] && brew_prefix='/opt/homebrew' || brew_prefix='/usr/local' ;;
        fedora|fedora-atomic) brew_prefix='/home/linuxbrew/.linuxbrew' ;;
        *) die "Homebrew demandé pour une famille non Homebrew: $family" ;;
    esac
    brew_bin="${brew_prefix}/bin/brew"
}

run_native_if_needed() {
    if [[ "$family" == 'macos' && "$cpu" == 'arm64' && "$process_cpu" == 'x86_64' ]]; then
        require_exec /usr/bin/arch
        /usr/bin/arch -arm64 "$@"
    else
        "$@"
    fi
}

brew_run() { run_native_if_needed "$brew_bin" "$@"; }

verify_brew() {
    local actual version
    require_exec "$brew_bin"
    actual="$(brew_run --prefix)" || die "brew --prefix a échoué: $brew_bin"
    assert_eq "$actual" "$brew_prefix" 'préfixe Homebrew'
    version="$(brew_run --version)" || die 'brew --version a échoué'
    assert_nonempty "$version" 'version Homebrew'
    pkgmgr='brew'
    pkgver="$(first_line "$version")"
}

activate_brew() {
    local shellenv first remainder second active
    verify_brew
    shellenv="$(brew_run shellenv bash)" || die 'brew shellenv bash a échoué'
    [[ -n "$shellenv" ]] && eval "$shellenv"
    hash -r
    active="$(command -v brew 2>/dev/null || true)"
    assert_eq "$active" "$brew_bin" 'brew actif'
    first="${PATH%%:*}"
    remainder="${PATH#*:}"
    [[ "$remainder" == "$PATH" ]] && second='' || second="${remainder%%:*}"
    assert_eq "$first" "${brew_prefix}/bin" 'PATH[0] Homebrew'
    assert_eq "$second" "${brew_prefix}/sbin" 'PATH[1] Homebrew'
}

verify_dnf() {
    local version
    require_cmd dnf
    version="$(dnf --version)" || die 'DNF inutilisable'
    assert_nonempty "$version" 'version DNF'
}

fedora_bootstrap_ready() {
    command -v git >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v file >/dev/null 2>&1 && command -v ps >/dev/null 2>&1 && command -v cc >/dev/null 2>&1 && command -v make >/dev/null 2>&1
}

ensure_fedora_prereqs() {
    if fedora_bootstrap_ready; then
        already 'Prérequis Homebrew Fedora'
        return
    fi
    info 'Installation des prérequis Homebrew Fedora'
    run_root_quiet dnf group install -y development-tools || die 'installation development-tools échouée'
    run_root_quiet dnf install -y procps-ng curl file git || die 'installation des utilitaires Homebrew échouée'
    fedora_bootstrap_ready || die 'prérequis Homebrew Fedora incomplets après DNF'
    ok
}

install_homebrew() {
    require_cmd curl
    require_exec /bin/bash
    tmp_file="$(mktemp)" || die 'mktemp a échoué'
    if [[ "$family" == 'macos' ]]; then
        require_exec /usr/bin/sudo
        if ! /usr/bin/sudo -n true >/dev/null 2>&1; then
            interactive_info 'Validation sudo'
            /usr/bin/sudo -v || die "sudo n'a pas pu être validé"
            /usr/bin/sudo -n true >/dev/null 2>&1 || die 'Homebrew nécessite sudo administrateur'
            ok
        fi
    fi
    info "Installation de Homebrew dans $brew_prefix"
    curl -fsSL "$HOMEBREW_INSTALL_URL" -o "$tmp_file" || die "téléchargement de l'installateur Homebrew impossible"
    [[ -s "$tmp_file" ]] || die 'installateur Homebrew téléchargé vide'
    if [[ "$family" == 'macos' && "$cpu" == 'arm64' && "$process_cpu" == 'x86_64' ]]; then
        require_exec /usr/bin/arch
        run_quiet env NONINTERACTIVE=1 /usr/bin/arch -arm64 /bin/bash "$tmp_file" || die 'installation Homebrew ARM64 sous Rosetta échouée'
    else
        run_quiet env NONINTERACTIVE=1 /bin/bash "$tmp_file" || die 'installation Homebrew échouée'
    fi
    rm -f "$tmp_file" || die 'suppression du temporaire Homebrew impossible'
    tmp_file=''
    verify_brew
    ok
}

ensure_homebrew() {
    set_expected_brew
    [[ "$family" == 'fedora' ]] && verify_dnf
    if [[ -x "$brew_bin" ]]; then
        verify_brew
        already "Homebrew $pkgver dans $brew_prefix"
    else
        case "$family" in
            macos) install_homebrew ;;
            fedora) ensure_fedora_prereqs; install_homebrew ;;
            fedora-atomic) die "Homebrew requis mais absent: $brew_bin" ;;
        esac
    fi
    activate_brew
}

brew_formula_installed() { brew_run list --formula --versions "$1" >/dev/null 2>&1; }

ensure_brew_formula_binary() {
    local formula="$1" binary="$2"
    [[ -x "$binary" ]] && return 0
    info "Lien Homebrew $formula"
    run_quiet brew_run link "$formula" || die "brew link $formula a échoué"
    [[ -x "$binary" ]] || die "$binary absent après brew link $formula"
    ok
}

install_brew_tools() {
    local formula
    local -a missing
    missing=()
    for formula in git gh fish; do brew_formula_installed "$formula" || missing+=("$formula"); done
    if (( ${#missing[@]} == 0 )); then
        already 'git, gh et fish via Homebrew'
    else
        info "Installation Homebrew: ${missing[*]}"
        ( export HOMEBREW_NO_ASK=1; run_quiet brew_run install "${missing[@]}" ) || die 'brew install git/gh/fish a échoué'
        for formula in git gh fish; do brew_formula_installed "$formula" || die "formule Homebrew absente après installation: $formula"; done
        ok
    fi
    activate_brew
    git_bin="${brew_prefix}/bin/git"
    gh_bin="${brew_prefix}/bin/gh"
    fish_bin="${brew_prefix}/bin/fish"
    ensure_brew_formula_binary git "$git_bin"
    ensure_brew_formula_binary gh "$gh_bin"
    ensure_brew_formula_binary fish "$fish_bin"
    require_exec "$git_bin"; require_exec "$gh_bin"; require_exec "$fish_bin"
    assert_eq "$(command -v git)" "$git_bin" 'Git actif'
    assert_eq "$(command -v gh)" "$gh_bin" 'gh actif'
    assert_eq "$(command -v fish)" "$fish_bin" 'Fish actif'
}

deb_package_installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == 'install ok installed' ]]; }
apt_candidate_exists() { apt-cache show "$1" >/dev/null 2>&1; }

file_sha256() {
    local output
    output="$(sha256sum "$1")" || return 1
    printf '%s\n' "${output%% *}"
}

gh_apt_keyring_valid() {
    [[ -s "$GH_APT_KEYRING" && -r "$GH_APT_KEYRING" ]] || return 1
    [[ "$(file_sha256 "$GH_APT_KEYRING" 2>/dev/null || true)" == "$GH_APT_KEY_SHA256" ]]
}

gh_apt_repo_configured() {
    local expected="$1"
    gh_apt_keyring_valid || return 1
    [[ -r "$GH_APT_SOURCE" ]] || return 1
    [[ "$(<"$GH_APT_SOURCE")" == "$expected" ]]
}

official_gh_deb_installed() {
    deb_package_installed gh || return 1
    [[ "$(dpkg-query -W -f='${Maintainer}' gh 2>/dev/null || true)" == GitHub* ]]
}

ensure_debian_download_prereqs() {
    local p
    local -a missing
    missing=()
    for p in curl ca-certificates; do deb_package_installed "$p" || missing+=("$p"); done
    if (( ${#missing[@]} == 0 )); then require_cmd curl; already 'Prérequis de téléchargement APT'; return; fi
    info "Installation APT: ${missing[*]}"
    run_root_quiet apt-get update || die 'apt-get update a échoué'
    for p in "${missing[@]}"; do apt_candidate_exists "$p" || die "aucun candidat APT: $p"; done
    run_root_quiet apt-get install -y "${missing[@]}" || die 'installation des prérequis APT échouée'
    for p in "${missing[@]}"; do deb_package_installed "$p" || die "paquet absent après installation: $p"; done
    require_cmd curl
    ok
}

expected_debian_arch() { case "$cpu" in arm64) printf 'arm64\n' ;; x86_64) printf 'amd64\n' ;; *) return 1 ;; esac; }

configure_github_cli_apt_repo() {
    local arch expected_arch source
    arch="$(dpkg --print-architecture)" || die 'dpkg --print-architecture a échoué'
    expected_arch="$(expected_debian_arch)" || die "architecture Debian non supportée: $cpu"
    assert_eq "$arch" "$expected_arch" 'architecture APT/dpkg'
    source="deb [arch=${arch} signed-by=${GH_APT_KEYRING}] https://cli.github.com/packages stable main"
    if gh_apt_repo_configured "$source"; then gh_apt_repo_changed='false'; already 'dépôt APT officiel GitHub CLI'; return; fi
    require_cmd curl; require_cmd install
    info 'Configuration du dépôt APT officiel GitHub CLI'
    run_root_quiet install -d -m 0755 /etc/apt/keyrings || die 'création /etc/apt/keyrings impossible'
    tmp_file="$(mktemp)" || die 'mktemp a échoué'
    curl -fsSL "$GH_APT_KEY_URL" -o "$tmp_file" || die 'téléchargement keyring GitHub CLI impossible'
    [[ -s "$tmp_file" ]] || die 'keyring GitHub CLI téléchargé vide'
    assert_eq "$(file_sha256 "$tmp_file")" "$GH_APT_KEY_SHA256" 'SHA-256 du keyring GitHub CLI'
    run_root_quiet install -m 0644 "$tmp_file" "$GH_APT_KEYRING" || die 'installation keyring GitHub CLI impossible'
    gh_apt_keyring_valid || die 'keyring GitHub CLI invalide après installation'
    printf '%s\n' "$source" >"$tmp_file" || die 'création source APT temporaire impossible'
    run_root_quiet install -d -m 0755 /etc/apt/sources.list.d || die 'création sources.list.d impossible'
    run_root_quiet install -m 0644 "$tmp_file" "$GH_APT_SOURCE" || die 'installation source GitHub CLI impossible'
    gh_apt_repo_configured "$source" || die 'dépôt GitHub CLI invalide après configuration'
    rm -f "$tmp_file" || die 'suppression temporaire APT impossible'
    tmp_file=''; gh_apt_repo_changed='true'; ok
}

verify_debian_binary_owner() {
    local package="$1" binary="$2" path="/usr/bin/$2" owner
    require_exec "$path"
    owner="$(dpkg-query -S "$path" 2>/dev/null || true)"
    [[ "$owner" == "$package:"* ]] || die "$path n'est pas fourni par $package: $owner"
}

install_debian_tools() {
    local version p
    local -a missing
    require_cmd apt-get; require_cmd apt-cache; require_cmd dpkg; require_cmd dpkg-query; require_cmd sha256sum
    version="$(apt-get --version)" || die 'apt-get inutilisable'
    assert_nonempty "$version" 'version apt-get'
    pkgmgr='apt-get'; pkgver="$(first_line "$version")"
    ensure_debian_download_prereqs
    configure_github_cli_apt_repo
    missing=()
    for p in git fish; do deb_package_installed "$p" || missing+=("$p"); done
    if ! official_gh_deb_installed || [[ "$gh_apt_repo_changed" == 'true' ]]; then missing+=(gh); fi
    if (( ${#missing[@]} == 0 )); then
        already 'git, gh et fish via APT'
    else
        info "Installation APT: ${missing[*]}"
        run_root_quiet apt-get update || die 'apt-get update a échoué'
        for p in git gh fish; do apt_candidate_exists "$p" || die "aucun candidat APT: $p"; done
        run_root_quiet apt-get install -y "${missing[@]}" || die 'installation APT git/gh/fish échouée'
        ok
    fi
    for p in git gh fish; do deb_package_installed "$p" || die "paquet APT absent: $p"; done
    official_gh_deb_installed || die "le paquet gh installé n'est pas l'officiel GitHub"
    verify_debian_binary_owner git git; verify_debian_binary_owner gh gh; verify_debian_binary_owner fish fish
    git_bin='/usr/bin/git'; gh_bin='/usr/bin/gh'; fish_bin='/usr/bin/fish'
}

termux_package_installed() {
    local status
    case "$termux_backend" in
        apt) status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"; [[ "$status" == 'install ok installed' ]] ;;
        pacman) pacman -Q "$1" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

termux_tools_present() {
    [[ -x "${PREFIX}/bin/git" && -x "${PREFIX}/bin/gh" && -x "${PREFIX}/bin/fish" ]] && termux_package_installed git && termux_package_installed gh && termux_package_installed fish
}

install_termux_tools() {
    local version pacman_version p
    require_cmd pkg
    [[ -n "${PREFIX:-}" && -d "$PREFIX" ]] || die 'PREFIX Termux invalide'
    if command -v apt >/dev/null 2>&1; then
        termux_backend='apt'; require_cmd dpkg-query; version="$(apt --version)" || die 'backend APT de pkg inutilisable'
    elif command -v pacman >/dev/null 2>&1; then
        termux_backend='pacman'; version="$(pacman --version)" || die 'backend pacman de pkg inutilisable'; pacman_version="$(first_nonempty_line "$version")" || die 'version pacman illisible'; version="$pacman_version"
    else
        die 'pkg présent mais backend APT/pacman introuvable'
    fi
    pkgmgr='pkg'; pkgver="pkg / $(first_line "$version")"
    if termux_tools_present; then
        already 'git, gh et fish via Termux'
    else
        info 'Installation Termux: git gh fish'
        run_quiet pkg update -y || die 'pkg update a échoué'
        case "$termux_backend" in
            apt) require_cmd apt-cache; for p in git gh fish; do apt-cache show "$p" >/dev/null 2>&1 || die "paquet Termux indisponible: $p"; done ;;
            pacman) for p in git gh fish; do pacman -Si "$p" >/dev/null 2>&1 || die "paquet Termux indisponible: $p"; done ;;
        esac
        run_quiet pkg install -y git gh fish || die 'pkg install git/gh/fish a échoué'
        termux_tools_present || die 'git/gh/fish manquent après pkg install'
        ok
    fi
    git_bin="${PREFIX}/bin/git"; gh_bin="${PREFIX}/bin/gh"; fish_bin="${PREFIX}/bin/fish"
    require_exec "$git_bin"; require_exec "$gh_bin"; require_exec "$fish_bin"
}

install_core_tools() {
    case "$family" in
        macos|fedora|fedora-atomic) install_brew_tools ;;
        debian) install_debian_tools ;;
        termux) install_termux_tools ;;
        *) die "famille non supportée: $family" ;;
    esac
}

verify_core_tools() {
    require_exec "$git_bin"; require_exec "$gh_bin"; require_exec "$fish_bin"
    "$git_bin" --version >/dev/null 2>&1 || die 'Git installé mais inutilisable'
    "$gh_bin" --version >/dev/null 2>&1 || die 'gh installé mais inutilisable'
    "$fish_bin" --version >/dev/null 2>&1 || die 'Fish installé mais inutilisable'
}

brew_shellenv_invocation() {
    if [[ "$family" == 'macos' && "$cpu" == 'arm64' ]]; then printf '/usr/bin/arch -arm64 %s shellenv %s\n' "$brew_bin" "$1"; else printf '%s shellenv %s\n' "$brew_bin" "$1"; fi
}

exact_line_present() {
    local file="$1" line="$2" s
    [[ -f "$file" ]] || return 1
    grep -Fqx "$line" "$file" 2>/dev/null && return 0
    s=$?
    [[ $s -eq 1 ]] || die "impossible de lire $file"
    return 1
}

ensure_exact_line() {
    local file="$1" line="$2" label="$3"
    [[ ! -e "$file" || -f "$file" ]] || die "$file existe mais n'est pas un fichier régulier"
    exact_line_present "$file" "$line" && return 0
    [[ -f "$file" ]] || { touch "$file" || die "impossible de créer $file"; }
    [[ -w "$file" ]] || die "$file n'est pas inscriptible"
    printf '\n%s\n' "$line" >>"$file" || die "impossible d'ajouter $label à $file"
    exact_line_present "$file" "$line" || die "$label absent après écriture dans $file"
}

configure_bash_brew_path() {
    local bash_path login_rc invocation line
    bash_path="$(command -v bash 2>/dev/null || true)"; [[ -n "$bash_path" ]] || return
    if [[ -f "$HOME/.bash_profile" ]]; then login_rc="$HOME/.bash_profile"; elif [[ -f "$HOME/.bash_login" ]]; then login_rc="$HOME/.bash_login"; else login_rc="$HOME/.profile"; fi
    run_quiet brew_run shellenv bash || die 'brew shellenv bash non supporté'
    invocation="$(brew_shellenv_invocation bash)"; line="eval \"\$(${invocation})\""
    if exact_line_present "$login_rc" "$line" && exact_line_present "$HOME/.bashrc" "$line"; then
        already 'PATH Homebrew Bash'
    else
        info 'Configuration PATH Homebrew Bash'; ensure_exact_line "$login_rc" "$line" 'brew shellenv bash login'; ensure_exact_line "$HOME/.bashrc" "$line" 'brew shellenv bash interactif'; ok
    fi
}

configure_zsh_brew_path() {
    local zsh_path invocation line
    zsh_path="$(command -v zsh 2>/dev/null || true)"; [[ -n "$zsh_path" ]] || return
    run_quiet brew_run shellenv zsh || die 'brew shellenv zsh non supporté'
    invocation="$(brew_shellenv_invocation zsh)"; line="eval \"\$(${invocation})\""
    if exact_line_present "$HOME/.zprofile" "$line" && exact_line_present "$HOME/.zshrc" "$line"; then
        already 'PATH Homebrew Zsh'
    else
        info 'Configuration PATH Homebrew Zsh'; ensure_exact_line "$HOME/.zprofile" "$line" 'brew shellenv zsh login'; ensure_exact_line "$HOME/.zshrc" "$line" 'brew shellenv zsh interactif'; ok
    fi
}

configure_fish_brew_path() {
    local config_home fish_dir file invocation line
    run_quiet brew_run shellenv fish || die 'brew shellenv fish non supporté'
    [[ -n "${XDG_CONFIG_HOME:-}" ]] && config_home="$XDG_CONFIG_HOME" || config_home="$HOME/.config"
    [[ "$config_home" == /* ]] || die "XDG_CONFIG_HOME Fish doit être absolu: $config_home"
    fish_dir="$config_home/fish"; file="$fish_dir/config.fish"
    [[ ! -e "$fish_dir" || -d "$fish_dir" ]] || die "$fish_dir existe mais n'est pas un dossier"
    [[ -d "$fish_dir" ]] || { mkdir -p "$fish_dir" || die "création de $fish_dir impossible"; [[ -d "$fish_dir" ]] || die "$fish_dir absent après création"; }
    invocation="$(brew_shellenv_invocation fish)"; line="eval (${invocation})"
    if exact_line_present "$file" "$line"; then
        already 'PATH Homebrew Fish'
    else
        info 'Configuration PATH Homebrew Fish'; ensure_exact_line "$file" "$line" 'brew shellenv fish'; ok
    fi
}

persist_brew_path() {
    case "$family" in macos|fedora|fedora-atomic) configure_bash_brew_path; configure_zsh_brew_path; configure_fish_brew_path; activate_brew ;; esac
}

gh_run() {
    local git_dir="${git_bin%/*}"
    PATH="${git_dir}:$PATH" "$gh_bin" "$@"
}

ensure_github_auth() {
    local login protocol helper helper_needle
    if ! gh_run auth status --hostname github.com >/dev/null 2>&1; then
        interactive_info 'Authentification GitHub via navigateur'
        gh_run auth login --hostname github.com --web --git-protocol https || die 'gh auth login a échoué'
        gh_run auth status --hostname github.com >/dev/null 2>&1 || die "GitHub n'est pas authentifié après login"
        ok
    fi
    login="$(gh_run api user --jq '.login')" || die 'impossible de lire le compte GitHub actif'
    assert_eq "$login" "$EXPECTED_GITHUB_LOGIN" 'compte GitHub actif'
    protocol="$(gh_run config get git_protocol --host github.com 2>/dev/null || true)"
    helper_needle="!${gh_bin} auth git-credential"
    helper="$("$git_bin" config --global --get-all credential.https://github.com.helper 2>/dev/null || true)"
    if [[ "$protocol" == 'https' && "$helper" == $'\n'"$helper_needle" ]]; then already 'Configuration GitHub CLI'; return; fi
    info 'Configuration GitHub CLI'
    [[ "$protocol" == 'https' ]] || run_quiet gh_run config set git_protocol https --host github.com || die 'configuration git_protocol=https impossible'
    helper="$("$git_bin" config --global --get-all credential.https://github.com.helper 2>/dev/null || true)"
    [[ "$helper" == $'\n'"$helper_needle" ]] || run_quiet gh_run auth setup-git --hostname github.com --force || die 'gh auth setup-git a échoué'
    assert_eq "$(gh_run config get git_protocol --host github.com 2>/dev/null || true)" 'https' 'protocole GitHub CLI'
    helper="$("$git_bin" config --global --get-all credential.https://github.com.helper 2>/dev/null || true)"
    [[ "$helper" == $'\n'"$helper_needle" ]] || die 'credential helper GitHub CLI incorrect'
    ok
}

ensure_git_identity() {
    local name login id email current_name current_email
    name="$(gh_run api user --jq 'if (.name // "") == "" then .login else .name end')" || die 'lecture nom GitHub impossible'
    login="$(gh_run api user --jq '.login')" || die 'lecture login GitHub impossible'
    id="$(gh_run api user --jq '.id')" || die 'lecture id GitHub impossible'
    assert_eq "$login" "$EXPECTED_GITHUB_LOGIN" 'login GitHub identité Git'
    [[ "$id" =~ ^[0-9]+$ ]] || die "id GitHub non numérique: $id"
    email="${id}+${login}@users.noreply.github.com"
    current_name="$("$git_bin" config --global --get user.name 2>/dev/null || true)"
    current_email="$("$git_bin" config --global --get user.email 2>/dev/null || true)"
    if [[ "$current_name" == "$name" && "$current_email" == "$email" ]]; then already 'Identité Git'; return; fi
    info "Configuration de l'identité Git"
    [[ "$current_name" == "$name" ]] || run_quiet "$git_bin" config --global user.name "$name" || die 'configuration user.name impossible'
    [[ "$current_email" == "$email" ]] || run_quiet "$git_bin" config --global user.email "$email" || die 'configuration user.email impossible'
    assert_eq "$("$git_bin" config --global --get user.name 2>/dev/null || true)" "$name" 'git user.name'
    assert_eq "$("$git_bin" config --global --get user.email 2>/dev/null || true)" "$email" 'git user.email'
    ok
}

verify_private_repo_remote() {
    local data name private
    data="$(gh_run repo view "$PRIVATE_REPO" --json nameWithOwner,isPrivate --jq '[.nameWithOwner,.isPrivate]|@tsv')" || die "dépôt $PRIVATE_REPO absent/inaccessible"
    IFS=$'\t' read -r name private <<<"$data"
    assert_eq "$name" "$PRIVATE_REPO" 'nom du dépôt privé'
    assert_eq "$private" 'true' "visibilité privée de $PRIVATE_REPO"
}

ensure_project_parent() {
    [[ ! -e "$PDIR" || -d "$PDIR" ]] || die "$PDIR existe mais n'est pas un dossier"
    if [[ ! -d "$PDIR" ]]; then info "Création de $PDIR"; mkdir -p "$PDIR" || die "création de $PDIR impossible"; [[ -d "$PDIR" ]] || die "$PDIR absent après création"; ok; fi
    [[ -w "$PDIR" ]] || die "$PDIR n'est pas inscriptible"
}

origin_is_setup2() {
    case "$1" in
        https://github.com/panlelapin/setup2|https://github.com/panlelapin/setup2.git|git@github.com:panlelapin/setup2.git|ssh://git@github.com/panlelapin/setup2.git|git://github.com/panlelapin/setup2.git) return 0 ;;
        *) return 1 ;;
    esac
}

fish_no_config_supported() { "$fish_bin" --no-config -c 'exit 0' >/dev/null 2>&1; }

ensure_setup2_checkout() {
    local inside origin
    ensure_project_parent
    if [[ ! -e "$SETUP_DIR" ]]; then
        info "Clone de $PRIVATE_REPO vers $SETUP_DIR"
        run_quiet gh_run repo clone "$PRIVATE_REPO_HTTPS" "$SETUP_DIR" || die "clone de $PRIVATE_REPO échoué"
        [[ -d "$SETUP_DIR" ]] || die "$SETUP_DIR absent après clone"
        ok
    else
        [[ -d "$SETUP_DIR" ]] || die "$SETUP_DIR existe mais n'est pas un dossier"
        inside="$("$git_bin" -C "$SETUP_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)"
        assert_eq "$inside" 'true' "$SETUP_DIR doit être un dépôt Git"
        already 'Checkout setup2'
    fi
    origin="$("$git_bin" -C "$SETUP_DIR" remote get-url origin 2>/dev/null || true)"
    assert_nonempty "$origin" 'remote origin setup2'
    origin_is_setup2 "$origin" || die "$SETUP_DIR pointe vers un autre dépôt: $origin"
    if [[ "$origin" != "$PRIVATE_REPO_HTTPS" ]]; then
        info 'Normalisation de origin setup2 vers HTTPS'
        run_quiet "$git_bin" -C "$SETUP_DIR" remote set-url origin "$PRIVATE_REPO_HTTPS" || die 'normalisation origin setup2 impossible'
        assert_eq "$("$git_bin" -C "$SETUP_DIR" remote get-url origin)" "$PRIVATE_REPO_HTTPS" 'origin setup2'
        ok
    fi
    [[ -f "$SETUP_SCRIPT" && -r "$SETUP_SCRIPT" ]] || die "script privé absent/illisible: $SETUP_SCRIPT"
    "$git_bin" -C "$SETUP_DIR" ls-files --error-unmatch setup2.fish >/dev/null 2>&1 || die 'setup2.fish existe mais n’est pas suivi par Git'
    fish_no_config_supported || die 'Fish installé ne supporte pas --no-config (Fish >= 3.4 requis)'
    "$fish_bin" --no-config --no-execute "$SETUP_SCRIPT" >/dev/null 2>&1 || die 'syntaxe Fish invalide dans setup2.fish'
}

setup2_package_manager_bin() {
    case "$pkgmgr" in
        brew) printf '%s\n' "$brew_bin" ;;
        apt-get) command -v apt-get ;;
        pkg) command -v pkg ;;
        *) return 1 ;;
    esac
}

run_setup2() {
    local package_manager_bin status
    package_manager_bin="$(setup2_package_manager_bin)" || die "binaire du gestionnaire introuvable pour $pkgmgr"
    require_exec "$package_manager_bin"
    if env \
        SETUP_CONTEXT_VERSION='1' \
        SETUP_DISTRO="$distro" \
        SETUP_FAMILY="$family" \
        SETUP_CPU="$cpu" \
        SETUP_PROCESS_CPU="$process_cpu" \
        SETUP_KERNEL="$kernel" \
        SETUP_PACKAGE_MANAGER="$pkgmgr" \
        SETUP_PACKAGE_MANAGER_VERSION="$pkgver" \
        SETUP_PACKAGE_MANAGER_BIN="$package_manager_bin" \
        SETUP_HOMEBREW_PREFIX="$brew_prefix" \
        SETUP_HOMEBREW_BIN="$brew_bin" \
        SETUP_TERMUX_BACKEND="$termux_backend" \
        SETUP_GIT_BIN="$git_bin" \
        SETUP_GH_BIN="$gh_bin" \
        SETUP_FISH_BIN="$fish_bin" \
        SETUP_GITHUB_LOGIN="$EXPECTED_GITHUB_LOGIN" \
        SETUP_PROJECTS_DIR="$PDIR" \
        SETUP_REPO_DIR="$SETUP_DIR" \
        "$fish_bin" --no-config "$SETUP_SCRIPT"; then
        info 'Passage au setup privé Fish'
        ok
        return 0
    fi
    status=$?
    return "$status"
}

main() {
    preflight
    detect_environment
    case "$family" in
        macos|fedora|fedora-atomic) ensure_homebrew ;;
        debian|termux) ;;
        *) die "famille non supportée: $family" ;;
    esac
    install_core_tools
    persist_brew_path
    verify_core_tools
    ensure_github_auth
    ensure_git_identity
    verify_private_repo_remote
    ensure_setup2_checkout
    run_setup2
}

main "$@"
