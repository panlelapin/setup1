#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup1.sh — public bootstrap / maintenance contract
# =============================================================================
#
# PURPOSE
# -------
# This script prepares a fresh supported machine for the private setup2 stage.
# It deliberately does only the minimum public bootstrap work needed to:
#   1. identify the OS family and CPU architecture;
#   2. establish the package manager policy for that platform;
#   3. install and verify Git, GitHub CLI (`gh`) and Fish;
#   4. make Homebrew take precedence in PATH where Homebrew is the chosen
#      package manager;
#   5. authenticate GitHub as the expected account and configure Git;
#   6. verify that the private setup2 repository exists and is private;
#   7. clone/reuse that repository and execute setup2.sh.
#
# THIS COMMENT IS ALSO THE FALLBACK AGENT/LLM SPECIFICATION
# --------------------------------------------------------
# If this repository has no AGENTS.md, an LLM modifying this file MUST preserve
# the rules below unless the user explicitly changes them.
#
# HOW TO RUN
# ----------
# Preferred when the file is already present:
#   bash setup1.sh
#
# The public raw source is:
#   https://raw.githubusercontent.com/panlelapin/setup1/master/setup1.sh
# When bootstrapping from the network, download successfully first, verify that
# the downloaded file is non-empty, then invoke it with Bash. Do not rely on a
# `curl | bash` pipeline as the implementation's only download-success check.
#
# HOW TO EXTEND THIS SCRIPT
# -------------------------
# When adding a new bootstrap responsibility or CLI tool, follow this order:
#   1. document the desired state and per-platform ownership in this contract;
#   2. validate every command/file/environment value before first use;
#   3. detect whether the desired state is already satisfied;
#   4. report the step as `déjà fait` and skip mutation when already satisfied;
#   5. otherwise perform the smallest necessary mutation;
#   6. immediately verify the mutation using an independent state query;
#   7. verify the executable actually selected by PATH, not just its package;
#   8. never repair/overwrite unrelated user state merely to make the run pass;
#   9. keep repeat runs convergent: no duplicate lines, clones, repos or config.
#
# Upstream behavior that matters to this bootstrap should be checked against
# current official documentation before changing commands or assumptions:
#   - https://docs.brew.sh/Installation
#   - https://docs.brew.sh/Homebrew-on-Linux
#   - https://docs.brew.sh/Manpage
#   - https://github.com/cli/cli/blob/trunk/docs/install_linux.md
#   - https://cli.github.com/manual/
#
# SUPPORTED PLATFORMS
# -------------------
# CPU architectures:
#   - arm64 / aarch64 -> normalized to `arm64`
#   - x86_64 / amd64 -> normalized to `x86_64`
#   - every other architecture is rejected.
#
# OS families:
#   - macOS
#   - classic Fedora and Fedora-like distributions
#   - Fedora Atomic / Universal Blue (Aurora, Bluefin, Bazzite, etc.)
#   - Debian/Ubuntu and Debian/Ubuntu-like distributions
#   - Termux on ARM64 only
#
# PACKAGE-MANAGER POLICY
# ----------------------
# macOS:
#   - Homebrew is the package manager for Git, gh, Fish and future CLI tools.
#   - Install Homebrew if missing.
#   - Apple Silicon MUST use /opt/homebrew; Intel MUST use /usr/local.
#   - If launched under Rosetta on Apple Silicon, bootstrap native ARM64 Brew.
#
# classic Fedora:
#   - DNF is bootstrap-only.
#   - DNF may install Homebrew prerequisites, but Git, gh, Fish and future CLI
#     tools MUST be installed and used from Homebrew afterwards.
#   - Supported Homebrew prefix is /home/linuxbrew/.linuxbrew.
#
# Fedora Atomic / Universal Blue:
#   - Homebrew MUST already exist at /home/linuxbrew/.linuxbrew.
#   - Do not bootstrap Homebrew with rpm-ostree or package layering here.
#   - Git, gh and Fish are managed by Homebrew.
#
# Debian/Ubuntu family:
#   - Use apt-get (not the interactive `apt` frontend) in this script.
#   - Git and Fish come from APT.
#   - gh comes from GitHub CLI's official APT repository, not from an assumed
#     distribution-provided community version.
#
# Termux:
#   - Only ARM64 is supported by policy.
#   - Use `pkg` and install Git, gh and Fish from Termux packages.
#
# HOMEBREW PATH POLICY
# --------------------
# In every Homebrew-managed environment:
#   - HOMEBREW_PREFIX/bin MUST be PATH entry 1.
#   - HOMEBREW_PREFIX/sbin MUST be PATH entry 2.
#   - use `brew shellenv <shell>` with the shell name explicitly supplied;
#   - persist shellenv only for shells that are actually installed;
#   - Bash: configure ~/.bashrc plus the existing login startup file selected by
#     Bash precedence (.bash_profile, .bash_login, otherwise .profile);
#   - Zsh: configure ~/.zprofile and ~/.zshrc;
#   - Fish: honor XDG_CONFIG_HOME when set, otherwise use ~/.config/fish;
#   - on Apple Silicon, persisted Homebrew calls force native ARM64 execution;
#   - never append duplicate configuration lines.
#
# GITHUB / GIT POLICY
# -------------------
#   - expected GitHub account: panlelapin
#   - Git protocol: HTTPS
#   - gh configures Git credential handling (`gh auth setup-git`).
#   - Git user.name comes from GitHub profile `.name`, falling back to `.login`.
#   - Git user.email is intentionally the modern GitHub noreply form:
#       <numeric-id>+<login>@users.noreply.github.com
#   - Do not query /user/emails for this bootstrap.
#   - private handoff repository: panlelapin/setup2
#   - local private checkout: ~/p/setup2
#   - private entry point: ~/p/setup2/setup2.sh
#   - setup2.sh is executed on every successful setup1 run; setup2.sh therefore
#     MUST itself be idempotent and use the same test/mutate/verify discipline.
#
# IDEMPOTENCE CONTRACT
# --------------------
# This script MUST be safe to run repeatedly.
# For every state-changing step:
#   - test whether the desired state already exists;
#   - if yes, report the step as `déjà fait` and skip the mutation;
#   - if no, perform the mutation;
#   - immediately verify the resulting state with an independent check;
#   - fail with a precise error if the postcondition is not true.
#
# Re-running MUST NOT:
#   - duplicate shell configuration lines;
#   - reclone setup2 over an existing valid checkout;
#   - overwrite unrelated existing directories;
#   - silently switch to another GitHub account;
#   - silently use a Homebrew installation from the wrong architecture/prefix;
#   - assume a binary/package/file exists without checking it first.
#
# EXISTING setup2 CHECKOUT POLICY
# ------------------------------
# If ~/p/setup2 already exists, reuse it only if it is a Git work tree for the
# expected repository. Do not automatically pull/reset/clean it: setup2 may
# contain local work. Normalize its `origin` URL to the expected HTTPS URL and
# verify setup2.sh before executing it.
#
# ROOT / PRIVILEGE POLICY
# -----------------------
# setup1.sh itself MUST NOT run as root. Privileged package/bootstrap operations
# are localized through sudo. This prevents Homebrew, dotfiles and global Git
# configuration from accidentally being created under /root.
#
# MAINTENANCE STYLE
# -----------------
# Keep this file compatible with the old Bash shipped on supported macOS where
# practical (avoid Bash-4-only associative arrays/mapfile/etc.). Prefer:
#   - [[ ... ]], case, indexed arrays, local variables, printf;
#   - explicit command checks and explicit postconditions;
#   - small single-purpose functions;
#   - full OWNER/REPO names and deterministic paths over implicit inference.
# Do not rely on `set -e` as a substitute for validation.
#
# OUTPUT POLICY
# -------------
# Normal successful output MUST stay minimal. For a step that is executed, print
# only one action prefix and its final result on the same line, for example:
#     ==> Installation de git, gh et fish... OK
# For an idempotent step that is already satisfied, print only:
#     ==> git, gh et fish... déjà fait
# Do not print environment reports, versions, verification chatter, package-
# manager progress, download progress or successful command output. External
# command stdout/stderr MUST be captured; reveal it only when that command fails,
# immediately before the fatal ERROR line. The sole intentional interactive
# exception is `gh auth login --web` when GitHub authentication is not already
# valid; its browser instructions/device code must remain visible. A sudo password
# prompt may also remain visible when privilege escalation is genuinely required.
# =============================================================================

# -----------------------------------------------------------------------------
# Logging / assertions
# -----------------------------------------------------------------------------

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '==> %s... ' "$*"
}

interactive_info() {
    printf '==> %s...\n' "$*"
}

ok() {
    printf 'OK\n'
}

already() {
    printf '==> %s... déjà fait\n' "$*"
}

run_quiet() {
    local log_file
    local status

    log_file="$(mktemp)" || die "mktemp a échoué pour capturer une commande"
    if "$@" >"$log_file" 2>&1; then
        rm -f "$log_file" || die "suppression du journal temporaire impossible"
        return 0
    else
        status=$?
    fi

    if [[ -s "$log_file" ]]; then
        cat "$log_file" >&2 || true
    fi
    rm -f "$log_file" || true
    return "$status"
}

ensure_sudo_ready() {
    require_cmd sudo

    if sudo -n true >/dev/null 2>&1; then
        return 0
    fi

    sudo -v || die "sudo n'a pas pu être validé"
    sudo -n true >/dev/null 2>&1 ||
        die "sudo reste indisponible après authentification"
}

run_root_quiet() {
    ensure_sudo_ready
    run_quiet sudo -n "$@"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "commande requise introuvable: $1"
}

require_exec() {
    [[ -x "$1" ]] || die "exécutable requis introuvable: $1"
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local description="$3"

    [[ "$actual" == "$expected" ]] ||
        die "$description: attendu '$expected', obtenu '$actual'"
}

assert_nonempty() {
    local value="$1"
    local description="$2"

    [[ -n "$value" ]] || die "$description est vide"
}

first_line() {
    local value="$1"
    printf '%s\n' "${value%%$'\n'*}"
}

first_nonempty_line() {
    local value="$1"
    local line

    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done <<< "$value"
    return 1
}

as_root() {
    ensure_sudo_ready
    sudo -n "$@"
}

# -----------------------------------------------------------------------------
# Fundamental preconditions — before using HOME-derived paths
# -----------------------------------------------------------------------------

[[ -n "${BASH_VERSION:-}" ]] || die "ce script doit être exécuté avec Bash"
[[ -n "${BASH:-}" && -x "$BASH" ]] || die "le chemin du Bash courant est invalide: ${BASH:-<vide>}"
(( EUID != 0 )) || die "ne pas exécuter setup1.sh en root/sudo"
[[ -n "${HOME:-}" ]] || die "HOME n'est pas défini"
[[ -d "$HOME" ]] || die "HOME n'est pas un dossier: $HOME"
[[ -w "$HOME" ]] || die "HOME n'est pas inscriptible: $HOME"
[[ -n "${PATH:-}" ]] || die "PATH n'est pas défini"

require_cmd uname
require_cmd mkdir
require_cmd grep
require_cmd mktemp
require_cmd rm
require_cmd touch
require_cmd cat
require_cmd env

readonly EXPECTED_GITHUB_LOGIN="panlelapin"
readonly PRIVATE_REPO="panlelapin/setup2"
readonly PRIVATE_REPO_HTTPS="https://github.com/panlelapin/setup2.git"
readonly PDIR="${HOME}/p"
readonly SETUP_DIR="${PDIR}/setup2"
readonly SETUP_SCRIPT="${SETUP_DIR}/setup2.sh"
readonly HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
readonly GH_APT_KEY_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
readonly GH_APT_KEY_SHA256="6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b"
readonly GH_APT_KEYRING="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
readonly GH_APT_SOURCE="/etc/apt/sources.list.d/github-cli.list"

distro="unknown"
family="unknown"
cpu="unknown"
process_cpu="unknown"
kernel="unknown"
pkgmgr="unknown"
pkgver="unknown"
brew_prefix=""
brew_bin=""
git_bin=""
gh_bin=""
fish_bin=""
tmp_file=""
termux_backend=""
gh_apt_repo_changed="false"

cleanup() {
    if [[ -n "$tmp_file" && -e "$tmp_file" ]]; then
        rm -f "$tmp_file" || true
    fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Environment detection
# -----------------------------------------------------------------------------

detect_cpu() {
    process_cpu="$(uname -m)"

    case "$process_cpu" in
        arm64|aarch64)
            cpu="arm64"
            ;;
        x86_64|amd64)
            cpu="x86_64"
            ;;
        *)
            die "CPU non supporté: $process_cpu"
            ;;
    esac
}

detect_environment() {
    local os_id
    local os_like
    local variant_id
    local apple_arm64

    detect_cpu
    kernel="$(uname -s)"

    if [[ "$kernel" == "Darwin" ]]; then
        distro="macos"
        family="macos"

        require_cmd sysctl
        apple_arm64="$(sysctl -in hw.optional.arm64 2>/dev/null || true)"
        if [[ "$apple_arm64" == "1" ]]; then
            cpu="arm64"
        fi
        return
    fi

    if [[ -n "${TERMUX_VERSION:-}" ]] ||
       [[ "${PREFIX:-}" == */com.termux/files/usr ]]; then
        distro="termux"
        family="termux"
        [[ "$cpu" == "arm64" ]] ||
            die "Termux non ARM64 non supporté par ce setup"
        return
    fi

    [[ "$kernel" == "Linux" ]] || die "système non supporté: $kernel"
    [[ -r /etc/os-release ]] || die "/etc/os-release est requis sur Linux"

    # /etc/os-release is the OS vendor-provided machine-readable identity file.
    # shellcheck disable=SC1091
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
            if [[ -e /run/ostree-booted ]]; then
                family="fedora-atomic"
            else
                case "$variant_id" in
                    silverblue|kinoite|sway-atomic|budgie-atomic|cosmic-atomic|sericea|onyx)
                        family="fedora-atomic"
                        ;;
                    *)
                        family="fedora"
                        ;;
                esac
            fi
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

    if [[ "$family" == "fedora" && "$cpu" == "arm64" &&
          "$(uname -r)" == *asahi* ]]; then
        distro="fedora-asahi-remix"
    fi
}

# -----------------------------------------------------------------------------
# Homebrew: deterministic prefix, bootstrap, activation and verification
# -----------------------------------------------------------------------------

set_expected_brew() {
    case "$family" in
        macos)
            if [[ "$cpu" == "arm64" ]]; then
                brew_prefix="/opt/homebrew"
            else
                brew_prefix="/usr/local"
            fi
            ;;
        fedora|fedora-atomic)
            brew_prefix="/home/linuxbrew/.linuxbrew"
            ;;
        *)
            die "set_expected_brew appelé pour une famille non Homebrew: $family"
            ;;
    esac

    brew_bin="${brew_prefix}/bin/brew"
}

brew_exists() {
    [[ -x "$brew_bin" ]]
}

run_native_if_needed() {
    if [[ "$family" == "macos" && "$cpu" == "arm64" &&
          "$process_cpu" == "x86_64" ]]; then
        require_exec /usr/bin/arch
        /usr/bin/arch -arm64 "$@"
    else
        "$@"
    fi
}

brew_run() {
    run_native_if_needed "$brew_bin" "$@"
}

verify_brew() {
    local actual_prefix
    local version_output

    require_exec "$brew_bin"

    actual_prefix="$(brew_run --prefix)" ||
        die "Homebrew existe mais 'brew --prefix' échoue: $brew_bin"
    assert_eq "$actual_prefix" "$brew_prefix" "préfixe Homebrew"

    version_output="$(brew_run --version)" ||
        die "Homebrew existe mais 'brew --version' échoue"
    assert_nonempty "$version_output" "version Homebrew"

    pkgmgr="brew"
    pkgver="$(first_line "$version_output")"
}

activate_brew() {
    local shellenv_output
    local first_path
    local remainder
    local second_path
    local active_brew

    verify_brew

    shellenv_output="$(brew_run shellenv bash)" ||
        die "'brew shellenv bash' a échoué"
    if [[ -n "$shellenv_output" ]]; then
        eval "$shellenv_output"
    fi
    hash -r

    active_brew="$(command -v brew 2>/dev/null || true)"
    assert_eq "$active_brew" "$brew_bin" "brew actif"

    first_path="${PATH%%:*}"
    if [[ "$PATH" == *:* ]]; then
        remainder="${PATH#*:}"
        second_path="${remainder%%:*}"
    else
        second_path=""
    fi

    assert_eq "$first_path" "${brew_prefix}/bin" "PATH[0] Homebrew"
    assert_eq "$second_path" "${brew_prefix}/sbin" "PATH[1] Homebrew"
}

ensure_macos_sudo_for_homebrew() {
    require_exec /usr/bin/sudo

    if /usr/bin/sudo -n true >/dev/null 2>&1; then
        return
    fi

    interactive_info "Validation sudo"
    /usr/bin/sudo -v || die "sudo n'a pas pu être validé"
    /usr/bin/sudo -n true >/dev/null 2>&1 ||
        die "Homebrew nécessite un accès sudo administrateur sur macOS"
    ok
}

verify_dnf() {
    local dnf_output

    require_cmd dnf
    dnf_output="$(dnf --version)" || die "DNF inutilisable"
    assert_nonempty "$dnf_output" "version DNF"
}

fedora_bootstrap_ready() {
    command -v git >/dev/null 2>&1 &&
    command -v curl >/dev/null 2>&1 &&
    command -v file >/dev/null 2>&1 &&
    command -v ps >/dev/null 2>&1 &&
    command -v cc >/dev/null 2>&1 &&
    command -v make >/dev/null 2>&1
}

ensure_fedora_homebrew_prereqs() {
    if fedora_bootstrap_ready; then
        already "Prérequis Homebrew Fedora"
        return
    fi

    info "Installation des prérequis Homebrew Fedora"
    run_root_quiet dnf group install -y development-tools ||
        die "échec de l'installation du groupe development-tools"
    run_root_quiet dnf install -y procps-ng curl file git ||
        die "échec de l'installation des utilitaires Homebrew"

    require_cmd cc
    require_cmd make
    require_cmd ps
    require_cmd curl
    require_cmd file
    require_cmd git
    fedora_bootstrap_ready ||
        die "les prérequis Homebrew Fedora restent incomplets après DNF"
    ok
}

install_homebrew() {
    local installer_arch

    require_cmd curl
    require_exec /bin/bash
    tmp_file="$(mktemp)" || die "mktemp a échoué"

    info "Installation de Homebrew dans $brew_prefix"
    curl -fsSL "$HOMEBREW_INSTALL_URL" -o "$tmp_file" ||
        die "téléchargement de l'installateur Homebrew impossible"
    [[ -s "$tmp_file" ]] || die "installateur Homebrew téléchargé vide"

    if [[ "$family" == "macos" ]]; then
        ensure_macos_sudo_for_homebrew
    fi

    if [[ "$family" == "macos" && "$cpu" == "arm64" &&
          "$process_cpu" == "x86_64" ]]; then
        require_exec /usr/bin/arch
        installer_arch="arm64"
        run_quiet env NONINTERACTIVE=1 /usr/bin/arch -arm64 /bin/bash "$tmp_file" ||
            die "installation Homebrew native ARM64 échouée sous Rosetta"
    else
        installer_arch="$process_cpu"
        run_quiet env NONINTERACTIVE=1 /bin/bash "$tmp_file" ||
            die "installation Homebrew échouée"
    fi

    rm -f "$tmp_file" || die "impossible de supprimer le fichier temporaire Homebrew"
    tmp_file=""

    brew_exists || die "Homebrew absent du préfixe attendu après installation: $brew_bin"
    verify_brew
    ok
}

ensure_homebrew() {
    set_expected_brew

    if [[ "$family" == "fedora" ]]; then
        verify_dnf
    fi

    if brew_exists; then
        verify_brew
        already "Homebrew $pkgver dans $brew_prefix"
        activate_brew
        return
    fi

    case "$family" in
        macos)
            install_homebrew
            ;;
        fedora)
            ensure_fedora_homebrew_prereqs
            install_homebrew
            ;;
        fedora-atomic)
            die "Homebrew requis mais absent à $brew_bin sur $distro"
            ;;
    esac

    activate_brew
}

# -----------------------------------------------------------------------------
# Package installation: git + gh + fish
# -----------------------------------------------------------------------------

brew_formula_installed() {
    brew_run list --formula --versions "$1" >/dev/null 2>&1
}

ensure_brew_formula_binary() {
    local formula="$1"
    local binary="$2"

    if [[ -x "$binary" ]]; then
        return
    fi

    info "Lien Homebrew $formula"
    run_quiet brew_run link "$formula" ||
        die "formule $formula installée mais impossible à lier dans $brew_prefix"
    [[ -x "$binary" ]] ||
        die "binaire $binary absent après brew link $formula"
    ok
}

install_brew_tools() {
    local formula
    local -a missing

    missing=()
    for formula in git gh fish; do
        brew_formula_installed "$formula" || missing+=("$formula")
    done

    if (( ${#missing[@]} == 0 )); then
        already "git, gh et fish via Homebrew"
    else
        info "Installation Homebrew: ${missing[*]}"
        (
            export HOMEBREW_NO_ASK=1
            run_quiet brew_run install -y "${missing[@]}"
        ) || die "brew install a échoué"

        for formula in git gh fish; do
            brew_formula_installed "$formula" ||
                die "formule Homebrew absente après installation: $formula"
        done
        ok
    fi

    activate_brew
    git_bin="${brew_prefix}/bin/git"
    gh_bin="${brew_prefix}/bin/gh"
    fish_bin="${brew_prefix}/bin/fish"

    ensure_brew_formula_binary git "$git_bin"
    ensure_brew_formula_binary gh "$gh_bin"
    ensure_brew_formula_binary fish "$fish_bin"

    require_exec "$git_bin"
    require_exec "$gh_bin"
    require_exec "$fish_bin"
    assert_eq "$(command -v git)" "$git_bin" "Git actif"
    assert_eq "$(command -v gh)" "$gh_bin" "gh actif"
    assert_eq "$(command -v fish)" "$fish_bin" "Fish actif"
}

deb_package_installed() {
    local status
    status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
    [[ "$status" == "install ok installed" ]]
}

verify_apt_candidate() {
    local package="$1"

    apt-cache show "$package" >/dev/null 2>&1 ||
        die "aucun candidat APT disponible pour $package"
}

ensure_debian_download_prereqs() {
    local -a missing
    local package

    missing=()
    for package in curl ca-certificates; do
        deb_package_installed "$package" || missing+=("$package")
    done

    if (( ${#missing[@]} == 0 )); then
        require_cmd curl
        already "Prérequis de téléchargement APT"
        return
    fi

    info "Installation APT: ${missing[*]}"
    run_root_quiet apt-get update || die "apt-get update a échoué"
    for package in "${missing[@]}"; do
        verify_apt_candidate "$package"
    done
    run_root_quiet apt-get install -y "${missing[@]}" ||
        die "installation des prérequis APT échouée"

    for package in "${missing[@]}"; do
        deb_package_installed "$package" ||
            die "paquet APT absent après installation: $package"
    done
    require_cmd curl
    ok
}

expected_debian_arch() {
    case "$cpu" in
        arm64) printf '%s\n' "arm64" ;;
        x86_64) printf '%s\n' "amd64" ;;
        *) die "architecture Debian non supportée: $cpu" ;;
    esac
}

file_sha256() {
    local file="$1"
    local output

    require_cmd sha256sum
    output="$(sha256sum "$file")" || return 1
    printf '%s\n' "${output%% *}"
}

gh_apt_keyring_valid() {
    local actual_hash

    [[ -s "$GH_APT_KEYRING" && -r "$GH_APT_KEYRING" ]] || return 1
    actual_hash="$(file_sha256 "$GH_APT_KEYRING" 2>/dev/null)" || return 1
    [[ "$actual_hash" == "$GH_APT_KEY_SHA256" ]]
}

gh_apt_repo_configured() {
    local expected_source="$1"
    local actual_source

    gh_apt_keyring_valid || return 1
    [[ -r "$GH_APT_SOURCE" ]] || return 1

    actual_source="$(<"$GH_APT_SOURCE")" || return 1
    [[ "$actual_source" == "$expected_source" ]]
}

official_gh_deb_installed() {
    local maintainer

    deb_package_installed gh || return 1
    maintainer="$(dpkg-query -W -f='${Maintainer}' gh 2>/dev/null || true)"
    [[ "$maintainer" == "GitHub" ]]
}

configure_github_cli_apt_repo() {
    local dpkg_arch
    local expected_arch
    local expected_source

    dpkg_arch="$(dpkg --print-architecture)" ||
        die "dpkg --print-architecture a échoué"
    expected_arch="$(expected_debian_arch)"
    assert_eq "$dpkg_arch" "$expected_arch" "architecture APT/dpkg"

    expected_source="deb [arch=${dpkg_arch} signed-by=${GH_APT_KEYRING}] https://cli.github.com/packages stable main"

    if gh_apt_repo_configured "$expected_source"; then
        gh_apt_repo_changed="false"
        already "dépôt APT officiel GitHub CLI"
        return 0
    fi

    require_cmd curl
    require_cmd install

    info "Configuration du dépôt APT officiel GitHub CLI"
    run_root_quiet install -d -m 0755 /etc/apt/keyrings ||
        die "création de /etc/apt/keyrings impossible"
    [[ -d /etc/apt/keyrings ]] || die "/etc/apt/keyrings absent après création"

    tmp_file="$(mktemp)" || die "mktemp a échoué"
    curl -fsSL "$GH_APT_KEY_URL" -o "$tmp_file" ||
        die "téléchargement du keyring GitHub CLI impossible"
    [[ -s "$tmp_file" ]] || die "keyring GitHub CLI téléchargé vide"
    assert_eq "$(file_sha256 "$tmp_file")" "$GH_APT_KEY_SHA256" \
        "SHA-256 du keyring GitHub CLI téléchargé"

    run_root_quiet install -m 0644 "$tmp_file" "$GH_APT_KEYRING" ||
        die "installation du keyring GitHub CLI impossible"
    gh_apt_keyring_valid ||
        die "keyring GitHub CLI invalide après installation"

    printf '%s\n' "$expected_source" > "$tmp_file" ||
        die "création du fichier source GitHub CLI temporaire impossible"
    grep -Fqx "$expected_source" "$tmp_file" ||
        die "source GitHub CLI temporaire invalide"

    run_root_quiet install -d -m 0755 /etc/apt/sources.list.d ||
        die "création de /etc/apt/sources.list.d impossible"
    [[ -d /etc/apt/sources.list.d ]] ||
        die "/etc/apt/sources.list.d absent après création"

    run_root_quiet install -m 0644 "$tmp_file" "$GH_APT_SOURCE" ||
        die "installation de la source APT GitHub CLI impossible"
    gh_apt_repo_configured "$expected_source" ||
        die "dépôt APT GitHub CLI invalide après configuration"

    rm -f "$tmp_file" || die "suppression du fichier temporaire APT impossible"
    tmp_file=""
    gh_apt_repo_changed="true"
    ok
    return 0
}

verify_debian_binary_owner() {
    local package="$1"
    local binary="$2"
    local binary_path="/usr/bin/${binary}"
    local owner

    require_exec "$binary_path"
    owner="$(dpkg-query -S "$binary_path" 2>/dev/null || true)"
    [[ "$owner" == "$package:"* ]] ||
        die "$binary_path n'est pas fourni par le paquet attendu '$package': $owner"
}

install_debian_tools() {
    local package
    local -a missing
    local apt_output

    require_cmd apt-get
    require_cmd apt-cache
    require_cmd dpkg
    require_cmd dpkg-query
    require_cmd sha256sum

    apt_output="$(apt-get --version)" || die "apt-get inutilisable"
    assert_nonempty "$apt_output" "version apt-get"
    pkgmgr="apt-get"
    pkgver="$(first_line "$apt_output")"

    ensure_debian_download_prereqs

    configure_github_cli_apt_repo

    missing=()
    for package in git fish; do
        deb_package_installed "$package" || missing+=("$package")
    done

    if ! official_gh_deb_installed || [[ "$gh_apt_repo_changed" == "true" ]]; then
        missing+=("gh")
    fi

    if (( ${#missing[@]} == 0 )); then
        already "git, gh et fish via APT"
    else
        info "Installation APT: ${missing[*]}"
        run_root_quiet apt-get update || die "apt-get update a échoué"
        for package in git gh fish; do
            verify_apt_candidate "$package"
        done
        run_root_quiet apt-get install -y "${missing[@]}" ||
            die "installation APT de git/gh/fish échouée"
        ok
    fi

    for package in git gh fish; do
        deb_package_installed "$package" ||
            die "paquet APT absent après installation: $package"
    done
    official_gh_deb_installed ||
        die "le paquet gh installé n'est pas le paquet officiel GitHub attendu"

    verify_debian_binary_owner git git
    verify_debian_binary_owner gh gh
    verify_debian_binary_owner fish fish

    git_bin="/usr/bin/git"
    gh_bin="/usr/bin/gh"
    fish_bin="/usr/bin/fish"
}

termux_package_installed() {
    local package="$1"
    local status

    case "$termux_backend" in
        apt)
            require_cmd dpkg-query
            status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
            [[ "$status" == "install ok installed" ]]
            ;;
        pacman)
            require_cmd pacman
            pacman -Q "$package" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

termux_tools_present() {
    [[ -x "${PREFIX}/bin/git" ]] &&
    [[ -x "${PREFIX}/bin/gh" ]] &&
    [[ -x "${PREFIX}/bin/fish" ]] &&
    termux_package_installed git &&
    termux_package_installed gh &&
    termux_package_installed fish
}

verify_termux_candidates() {
    local package

    case "$termux_backend" in
        apt)
            require_cmd apt-cache
            for package in git gh fish; do
                apt-cache show "$package" >/dev/null 2>&1 ||
                    die "paquet Termux indisponible après pkg update: $package"
            done
            ;;
        pacman)
            require_cmd pacman
            for package in git gh fish; do
                pacman -Si "$package" >/dev/null 2>&1 ||
                    die "paquet Termux indisponible après pkg update: $package"
            done
            ;;
        *)
            die "backend Termux inconnu: $termux_backend"
            ;;
    esac
}

install_termux_tools() {
    local backend_output
    local pacman_version

    require_cmd pkg
    [[ -n "${PREFIX:-}" ]] || die "PREFIX Termux n'est pas défini"
    [[ -d "$PREFIX" ]] || die "PREFIX Termux invalide: $PREFIX"

    if command -v apt >/dev/null 2>&1; then
        termux_backend="apt"
        backend_output="$(apt --version)" || die "backend APT de pkg inutilisable"
        pkgmgr="pkg"
        pkgver="pkg / $(first_line "$backend_output")"
    elif command -v pacman >/dev/null 2>&1; then
        termux_backend="pacman"
        backend_output="$(pacman --version)" || die "backend pacman de pkg inutilisable"
        assert_nonempty "$backend_output" "version pacman Termux"
        pacman_version="$(first_nonempty_line "$backend_output")" ||
            die "version pacman Termux illisible"
        pkgmgr="pkg"
        pkgver="pkg / $pacman_version"
    else
        die "pkg présent mais aucun backend APT/pacman détecté"
    fi

    if termux_tools_present; then
        already "git, gh et fish via Termux"
    else
        info "Installation Termux: git gh fish"
        run_quiet pkg update -y || die "pkg update a échoué"
        verify_termux_candidates
        run_quiet pkg install -y git gh fish || die "pkg install git gh fish a échoué"
        termux_tools_present ||
            die "git/gh/fish manquent après pkg install"
        ok
    fi

    git_bin="${PREFIX}/bin/git"
    gh_bin="${PREFIX}/bin/gh"
    fish_bin="${PREFIX}/bin/fish"
    require_exec "$git_bin"
    require_exec "$gh_bin"
    require_exec "$fish_bin"
}

install_core_tools() {
    case "$family" in
        macos|fedora|fedora-atomic)
            install_brew_tools
            ;;
        debian)
            install_debian_tools
            ;;
        termux)
            install_termux_tools
            ;;
        *)
            die "famille non supportée pour l'installation: $family"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Persistent Homebrew PATH for installed shells
# -----------------------------------------------------------------------------

brew_shellenv_invocation() {
    local shell_kind="$1"

    if [[ "$family" == "macos" && "$cpu" == "arm64" ]]; then
        printf '/usr/bin/arch -arm64 %s shellenv %s\n' "$brew_bin" "$shell_kind"
    else
        printf '%s shellenv %s\n' "$brew_bin" "$shell_kind"
    fi
}

exact_line_present() {
    local rc_file="$1"
    local line="$2"
    local grep_status

    [[ -f "$rc_file" ]] || return 1

    if grep -Fqx "$line" "$rc_file" 2>/dev/null; then
        return 0
    fi

    grep_status=$?
    [[ "$grep_status" -eq 1 ]] ||
        die "impossible de lire $rc_file"
    return 1
}

ensure_exact_line() {
    local rc_file="$1"
    local line="$2"
    local label="$3"

    if [[ -e "$rc_file" && ! -f "$rc_file" ]]; then
        die "$rc_file existe mais n'est pas un fichier régulier"
    fi

    if exact_line_present "$rc_file" "$line"; then
        return 0
    fi

    if [[ ! -f "$rc_file" ]]; then
        touch "$rc_file" || die "impossible de créer $rc_file"
        [[ -f "$rc_file" ]] || die "$rc_file n'a pas été créé"
    fi

    [[ -w "$rc_file" ]] || die "$rc_file n'est pas inscriptible"
    printf '\n%s\n' "$line" >> "$rc_file" ||
        die "impossible d'ajouter $label à $rc_file"
    exact_line_present "$rc_file" "$line" ||
        die "$label absent de $rc_file après écriture"
}

verify_shellenv_effect() {
    local shell_kind="$1"
    local shell_path="$2"
    local raw_output
    local result=""
    local line
    local test_home
    local test_command

    test_home="$(mktemp -d)" ||
        die "mktemp -d a échoué pour tester brew shellenv $shell_kind"

    case "$shell_kind" in
        bash)
            test_command="eval \"\$($(brew_shellenv_invocation bash))\"; printf '__SETUP_BREW__%s\\n' \"\$(command -v brew)\""
            if ! raw_output="$(
                HOME="$test_home" PATH="/usr/bin:/bin" \
                    run_native_if_needed "$shell_path" --noprofile --norc -c "$test_command"
            )"; then
                rm -rf "$test_home" || true
                die "la configuration brew shellenv bash ne fonctionne pas dans un Bash propre"
            fi
            ;;
        zsh)
            test_command="eval \"\$($(brew_shellenv_invocation zsh))\"; printf '__SETUP_BREW__%s\\n' \"\$(command -v brew)\""
            if ! raw_output="$(
                HOME="$test_home" ZDOTDIR="$test_home" PATH="/usr/bin:/bin" \
                    run_native_if_needed "$shell_path" -f -c "$test_command"
            )"; then
                rm -rf "$test_home" || true
                die "la configuration brew shellenv zsh ne fonctionne pas dans un Zsh propre"
            fi
            ;;
        fish)
            test_command="eval ($(brew_shellenv_invocation fish)); printf '__SETUP_BREW__%s\\n' (command -v brew)"
            if ! raw_output="$(
                HOME="$test_home" XDG_CONFIG_HOME="$test_home" PATH="/usr/bin:/bin" \
                    run_native_if_needed "$shell_path" -c "$test_command"
            )"; then
                rm -rf "$test_home" || true
                die "la configuration brew shellenv fish ne fonctionne pas dans un Fish propre"
            fi
            ;;
        *)
            rm -rf "$test_home" || true
            die "shell inconnu pour verify_shellenv_effect: $shell_kind"
            ;;
    esac

    rm -rf "$test_home" ||
        die "suppression du HOME temporaire de test impossible"

    while IFS= read -r line; do
        case "$line" in
            __SETUP_BREW__*) result="${line#__SETUP_BREW__}" ;;
        esac
    done <<< "$raw_output"

    assert_eq "$result" "$brew_bin" "brew shellenv $shell_kind dans un shell propre"
}

configure_bash_brew_path() {
    local bash_path
    local login_rc
    local line
    local invocation

    bash_path="$(command -v bash 2>/dev/null || true)"
    if [[ -z "$bash_path" ]]; then
        return
    fi

    if [[ -f "$HOME/.bash_profile" ]]; then
        login_rc="$HOME/.bash_profile"
    elif [[ -f "$HOME/.bash_login" ]]; then
        login_rc="$HOME/.bash_login"
    else
        login_rc="$HOME/.profile"
    fi

    run_quiet brew_run shellenv bash || die "brew shellenv bash non supporté"
    invocation="$(brew_shellenv_invocation bash)"
    line="eval \"\$(${invocation})\""

    if exact_line_present "$login_rc" "$line" &&
       exact_line_present "$HOME/.bashrc" "$line"; then
        already "PATH Homebrew Bash"
    else
        info "Configuration PATH Homebrew Bash"
        ensure_exact_line "$login_rc" "$line" "brew shellenv bash (login)"
        ensure_exact_line "$HOME/.bashrc" "$line" "brew shellenv bash (interactif)"
        ok
    fi
    verify_shellenv_effect bash "$bash_path"
}

configure_zsh_brew_path() {
    local zsh_path
    local line
    local invocation

    zsh_path="$(command -v zsh 2>/dev/null || true)"
    if [[ -z "$zsh_path" ]]; then
        return
    fi

    run_quiet brew_run shellenv zsh || die "brew shellenv zsh non supporté"
    invocation="$(brew_shellenv_invocation zsh)"
    line="eval \"\$(${invocation})\""

    if exact_line_present "$HOME/.zprofile" "$line" &&
       exact_line_present "$HOME/.zshrc" "$line"; then
        already "PATH Homebrew Zsh"
    else
        info "Configuration PATH Homebrew Zsh"
        ensure_exact_line "$HOME/.zprofile" "$line" "brew shellenv zsh (login)"
        ensure_exact_line "$HOME/.zshrc" "$line" "brew shellenv zsh (interactif)"
        ok
    fi
    verify_shellenv_effect zsh "$zsh_path"
}

configure_fish_brew_path() {
    local config_home
    local fish_dir
    local rc_file
    local invocation
    local line

    run_quiet brew_run shellenv fish || die "brew shellenv fish non supporté"
    [[ -x "$fish_bin" ]] || die "Fish Homebrew attendu mais absent: $fish_bin"

    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        [[ "$XDG_CONFIG_HOME" == /* ]] ||
            die "XDG_CONFIG_HOME doit être absolu pour Fish: $XDG_CONFIG_HOME"
        config_home="$XDG_CONFIG_HOME"
    else
        config_home="$HOME/.config"
    fi

    fish_dir="$config_home/fish"
    rc_file="$fish_dir/config.fish"
    invocation="$(brew_shellenv_invocation fish)"
    line="eval (${invocation})"

    if [[ -e "$fish_dir" && ! -d "$fish_dir" ]]; then
        die "$fish_dir existe mais n'est pas un dossier"
    fi

    if [[ ! -d "$fish_dir" ]]; then
        mkdir -p "$fish_dir" || die "création de $fish_dir impossible"
        [[ -d "$fish_dir" ]] || die "$fish_dir absent après mkdir"
    fi

    if exact_line_present "$rc_file" "$line"; then
        already "PATH Homebrew Fish"
    else
        info "Configuration PATH Homebrew Fish"
        ensure_exact_line "$rc_file" "$line" "brew shellenv fish"
        ok
    fi
    verify_shellenv_effect fish "$fish_bin"
}

persist_brew_path() {
    case "$family" in
        macos|fedora|fedora-atomic)
            configure_bash_brew_path
            configure_zsh_brew_path
            configure_fish_brew_path
            activate_brew
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Tool verification and report
# -----------------------------------------------------------------------------

verify_core_tools() {
    local git_version
    local gh_version
    local fish_version

    require_exec "$git_bin"
    require_exec "$gh_bin"
    require_exec "$fish_bin"

    git_version="$("$git_bin" --version)" || die "git --version a échoué"
    gh_version="$("$gh_bin" --version)" || die "gh --version a échoué"
    fish_version="$("$fish_bin" --version)" || die "fish --version a échoué"

    assert_nonempty "$git_version" "version Git"
    assert_nonempty "$gh_version" "version gh"
    assert_nonempty "$fish_version" "version Fish"

}

# -----------------------------------------------------------------------------
# GitHub authentication / Git configuration
# -----------------------------------------------------------------------------

gh_run() {
    local git_dir="${git_bin%/*}"

    # gh may invoke git internally. Put the verified Git directory first for
    # this command without permanently changing non-Homebrew PATH policy.
    PATH="${git_dir}:$PATH" "$gh_bin" "$@"
}

ensure_github_auth() {
    local actual_login
    local protocol
    local helper_output
    local helper_needle

    if ! gh_run auth status --hostname github.com >/dev/null 2>&1; then
        interactive_info "Authentification GitHub via navigateur"
        gh_run auth login --hostname github.com --web --git-protocol https ||
            die "gh auth login a échoué"
        gh_run auth status --hostname github.com >/dev/null 2>&1 ||
            die "GitHub n'est pas authentifié après gh auth login"
        ok
    fi

    actual_login="$(gh_run api user --jq '.login')" ||
        die "impossible de lire le compte GitHub actif"
    assert_nonempty "$actual_login" "login GitHub actif"

    if [[ "$actual_login" != "$EXPECTED_GITHUB_LOGIN" ]]; then
        if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
            die "compte GitHub actif '$actual_login' au lieu de '$EXPECTED_GITHUB_LOGIN';" \
                "GH_TOKEN/GITHUB_TOKEN a priorité: corriger ou désactiver ce token"
        fi
        die "compte GitHub actif '$actual_login' au lieu de '$EXPECTED_GITHUB_LOGIN'"
    fi

    protocol="$(gh_run config get git_protocol --host github.com 2>/dev/null || true)"
    helper_needle="!${gh_bin} auth git-credential"
    helper_output="$("$git_bin" config --global --get-all credential.https://github.com.helper 2>/dev/null || true)"

    if [[ "$protocol" == "https" && "$helper_output" == $'\n'"$helper_needle" ]]; then
        already "Configuration GitHub CLI"
    else
        info "Configuration GitHub CLI"

        if [[ "$protocol" != "https" ]]; then
            run_quiet gh_run config set git_protocol https --host github.com ||
                die "impossible de configurer git_protocol=https"
        fi

        helper_output="$("$git_bin" config --global --get-all credential.https://github.com.helper 2>/dev/null || true)"
        if [[ "$helper_output" != $'\n'"$helper_needle" ]]; then
            run_quiet gh_run auth setup-git --hostname github.com --force ||
                die "gh auth setup-git a échoué"
        fi

        protocol="$(gh_run config get git_protocol --host github.com 2>/dev/null || true)"
        assert_eq "$protocol" "https" "protocole GitHub CLI"
        helper_output="$("$git_bin" config --global --get-all credential.https://github.com.helper 2>/dev/null || true)"
        [[ "$helper_output" == $'\n'"$helper_needle" ]] ||
            die "credential helper GitHub CLI incorrect après configuration"
        ok
    fi

}

ensure_git_identity() {
    local git_name
    local git_login
    local git_id
    local git_email
    local current
    local current_email

    git_name="$(gh_run api user --jq 'if (.name // "") == "" then .login else .name end')" ||
        die "impossible de lire le nom du profil GitHub"
    git_login="$(gh_run api user --jq '.login')" ||
        die "impossible de lire le login GitHub"
    git_id="$(gh_run api user --jq '.id')" ||
        die "impossible de lire l'id GitHub"

    assert_nonempty "$git_name" "nom Git"
    assert_eq "$git_login" "$EXPECTED_GITHUB_LOGIN" "login GitHub pour l'identité Git"
    [[ "$git_id" =~ ^[0-9]+$ ]] || die "id GitHub non numérique: $git_id"

    git_email="${git_id}+${git_login}@users.noreply.github.com"

    current="$("$git_bin" config --global --get user.name 2>/dev/null || true)"
    current_email="$("$git_bin" config --global --get user.email 2>/dev/null || true)"

    if [[ "$current" == "$git_name" && "$current_email" == "$git_email" ]]; then
        already "Identité Git"
    else
        info "Configuration de l'identité Git"

        if [[ "$current" != "$git_name" ]]; then
            run_quiet "$git_bin" config --global user.name "$git_name" ||
                die "impossible de configurer git user.name"
        fi
        if [[ "$current_email" != "$git_email" ]]; then
            run_quiet "$git_bin" config --global user.email "$git_email" ||
                die "impossible de configurer git user.email"
        fi

        current="$("$git_bin" config --global --get user.name 2>/dev/null || true)"
        current_email="$("$git_bin" config --global --get user.email 2>/dev/null || true)"
        assert_eq "$current" "$git_name" "git user.name"
        assert_eq "$current_email" "$git_email" "git user.email"
        ok
    fi

}

# -----------------------------------------------------------------------------
# Private setup2 repository: validate, clone/reuse, hand off
# -----------------------------------------------------------------------------

verify_private_repo_remote() {
    local repo_info
    local repo_name
    local is_private

    repo_info="$(
        gh_run repo view "$PRIVATE_REPO" \
            --json nameWithOwner,isPrivate \
            --jq '[.nameWithOwner, .isPrivate] | @tsv'
    )" ||
        die "dépôt $PRIVATE_REPO absent, inaccessible ou non autorisé"

    IFS=$'\t' read -r repo_name is_private <<< "$repo_info"
    assert_eq "$repo_name" "$PRIVATE_REPO" "nom du dépôt privé"
    assert_eq "$is_private" "true" "visibilité privée de $PRIVATE_REPO"
}

ensure_project_parent() {
    if [[ -e "$PDIR" && ! -d "$PDIR" ]]; then
        die "$PDIR existe mais n'est pas un dossier"
    fi

    if [[ ! -d "$PDIR" ]]; then
        mkdir -p "$PDIR" || die "création de $PDIR impossible"
        [[ -d "$PDIR" ]] || die "$PDIR absent après mkdir"
    fi

    [[ -w "$PDIR" ]] || die "$PDIR n'est pas inscriptible"
}

origin_points_to_expected_repo() {
    local origin="$1"

    case "$origin" in
        "https://github.com/panlelapin/setup2"|\
        "https://github.com/panlelapin/setup2.git"|\
        "git@github.com:panlelapin/setup2.git"|\
        "ssh://git@github.com/panlelapin/setup2.git"|\
        "git://github.com/panlelapin/setup2.git")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_setup2_checkout() {
    local inside
    local origin

    ensure_project_parent

    if [[ ! -e "$SETUP_DIR" ]]; then
        info "Clone de $PRIVATE_REPO vers $SETUP_DIR"
        run_quiet gh_run repo clone "$PRIVATE_REPO_HTTPS" "$SETUP_DIR" ||
            die "clone de $PRIVATE_REPO échoué"
        [[ -d "$SETUP_DIR" ]] || die "$SETUP_DIR absent après clone"
        ok
    else
        [[ -d "$SETUP_DIR" ]] ||
            die "$SETUP_DIR existe mais n'est pas un dossier"
        inside="$("$git_bin" -C "$SETUP_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)"
        assert_eq "$inside" "true" "$SETUP_DIR doit être un dépôt Git"
        already "Checkout setup2"
    fi

    origin="$("$git_bin" -C "$SETUP_DIR" remote get-url origin 2>/dev/null || true)"
    assert_nonempty "$origin" "remote origin de $SETUP_DIR"

    origin_points_to_expected_repo "$origin" ||
        die "$SETUP_DIR existe déjà mais origin pointe vers un autre dépôt: $origin"

    if [[ "$origin" != "$PRIVATE_REPO_HTTPS" ]]; then
        info "Normalisation de l'origin setup2 existant vers HTTPS"
        run_quiet "$git_bin" -C "$SETUP_DIR" remote set-url origin "$PRIVATE_REPO_HTTPS" ||
            die "impossible de normaliser origin de setup2"
        origin="$("$git_bin" -C "$SETUP_DIR" remote get-url origin)" ||
            die "impossible de relire origin de setup2"
        assert_eq "$origin" "$PRIVATE_REPO_HTTPS" "origin setup2"
        ok
    fi

    [[ -f "$SETUP_SCRIPT" ]] || die "script privé introuvable: $SETUP_SCRIPT"
    [[ -r "$SETUP_SCRIPT" ]] || die "script privé illisible: $SETUP_SCRIPT"
    "$git_bin" -C "$SETUP_DIR" ls-files --error-unmatch setup2.sh >/dev/null 2>&1 ||
        die "setup2.sh existe mais n'est pas suivi par Git dans $PRIVATE_REPO"
    "$BASH" -n "$SETUP_SCRIPT" || die "syntaxe Bash invalide dans $SETUP_SCRIPT"
}

run_setup2() {
    info "Passage au setup privé"
    if "$BASH" "$SETUP_SCRIPT"; then
        ok
    else
        die "setup2.sh a échoué"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    detect_environment
    case "$family" in
        macos|fedora|fedora-atomic)
            ensure_homebrew
            ;;
        debian|termux)
            ;;
        *)
            die "famille non supportée: $family"
            ;;
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
