#!/usr/bin/env bash

set -e

# ===== CORES =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}ℹ️  $1${NC}"; }
ok() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err() { echo -e "${RED}❌ $1${NC}"; }

# ===== DETECÇÃO =====
detect_system() {
    if grep -qi microsoft /proc/version; then
        WSL=true
        ok "WSL detectado"
    else
        WSL=false
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        VERSION=$VERSION_ID
        ok "Sistema: $DISTRO $VERSION"
    else
        err "Sistema não identificado"
        exit 1
    fi
}

# ===== DEPENDÊNCIAS =====
install_deps() {
    log "Instalando dependências básicas..."

    sudo apt update -y

    sudo apt install -y \
        curl wget git unzip build-essential \
        ca-certificates gnupg lsb-release \
        python3 python3-pip python3-venv

    ok "Dependências instaladas"
}

# ===== NODE =====
install_node() {
    if command -v node >/dev/null; then
        ok "Node já instalado"
        return
    fi

    log "Instalando Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs
    ok "Node instalado"
}

# ===== ZSH =====
install_zsh() {
    if ! command -v zsh >/dev/null; then
        log "Instalando Zsh..."
        sudo apt install -y zsh
    fi

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        log "Instalando Oh My Zsh..."
        RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    fi

    # NÃO força chsh no WSL (evita bug)
    if [ "$WSL" = false ]; then
        chsh -s "$(which zsh)" || warn "Não foi possível alterar shell automaticamente"
    fi

    # fallback seguro
    if ! grep -q "exec zsh" ~/.bashrc; then
        echo "command -v zsh >/dev/null && exec zsh" >> ~/.bashrc
    fi

    ok "Zsh configurado"
}

# ===== PYENV =====
install_pyenv() {
    if [ ! -d "$HOME/.pyenv" ]; then
        log "Instalando pyenv..."
        git clone https://github.com/pyenv/pyenv.git ~/.pyenv
    fi

    if ! grep -q pyenv ~/.zshrc 2>/dev/null; then
        cat >> ~/.zshrc <<EOF

# PYENV
export PYENV_ROOT="\$HOME/.pyenv"
export PATH="\$PYENV_ROOT/bin:\$PATH"
eval "\$(pyenv init -)"
EOF
    fi

    ok "pyenv configurado"
}

# ===== PYTHON 3.10 =====
install_python310() {
    if command -v pyenv >/dev/null; then
        eval "$(pyenv init -)"

        if ! pyenv versions | grep -q "3.10"; then
            log "Instalando Python 3.10..."
            pyenv install 3.10.13
        fi

        pyenv global 3.10.13
        ok "Python 3.10 ativo"
    fi
}

# ===== NEOVIM =====
install_nvim() {
    if ! command -v nvim >/dev/null; then
        log "Instalando Neovim..."
        sudo apt install -y neovim
    fi

    mkdir -p ~/.config

    if [ ! -d ~/.config/nvim ]; then
        git clone https://github.com/al4xs/neovim-config ~/.config/nvim
    fi

    pip install --user pynvim || true

    ok "Neovim configurado"
}

# ===== FINAL =====
main() {
    detect_system
    install_deps
    install_node
    install_zsh
    install_pyenv
    install_python310
    install_nvim

    echo ""
    ok "🔥 Ambiente pronto!"
    echo "Reabra o terminal ou rode: exec zsh"
}

main
