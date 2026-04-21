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

    . /etc/os-release
    DISTRO=$ID
    VERSION=$VERSION_ID
    ok "Sistema: $DISTRO $VERSION"
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

    install_zsh_plugins
    configure_zsh_plugins

    if [ "$WSL" = false ]; then
        chsh -s "$(which zsh)" || warn "Não foi possível alterar shell automaticamente"
    fi

    if ! grep -q "exec zsh" ~/.bashrc; then
        echo 'command -v zsh >/dev/null && exec zsh' >> ~/.bashrc
    fi

    ok "Zsh configurado"
}

# ===== PLUGINS ZSH =====
install_zsh_plugins() {
    ZSH_CUSTOM="$HOME/.oh-my-zsh/custom/plugins"

    if [ ! -d "$ZSH_CUSTOM/zsh-autosuggestions" ]; then
        log "Instalando zsh-autosuggestions..."
        git clone https://github.com/zsh-users/zsh-autosuggestions $ZSH_CUSTOM/zsh-autosuggestions
    fi

    if [ ! -d "$ZSH_CUSTOM/zsh-syntax-highlighting" ]; then
        log "Instalando zsh-syntax-highlighting..."
        git clone https://github.com/zsh-users/zsh-syntax-highlighting $ZSH_CUSTOM/zsh-syntax-highlighting
    fi
}

configure_zsh_plugins() {
    log "Configurando plugins no .zshrc..."

    if [ ! -f ~/.zshrc ]; then
        touch ~/.zshrc
    fi

    sed -i '/^plugins=/d' ~/.zshrc
    echo 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting)' >> ~/.zshrc

    if ! grep -q "ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE" ~/.zshrc; then
        echo "ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'" >> ~/.zshrc
    fi

    ok "Plugins configurados corretamente"
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
    log "Verificando Python 3.10..."

    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"

    if ! command -v pyenv >/dev/null; then
        err "pyenv não encontrado!"
        return
    fi

    eval "$(pyenv init -)"

    sudo apt install -y \
        make build-essential libssl-dev zlib1g-dev \
        libbz2-dev libreadline-dev libsqlite3-dev \
        curl libncurses-dev xz-utils tk-dev \
        libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev

    if pyenv versions --bare | grep -q "^3.10"; then
        ok "Python 3.10 já instalado"
    else
        log "Instalando Python 3.10..."
        pyenv install 3.10.13
        ok "Python 3.10 instalado"
    fi

    pyenv global 3.10.13
    pyenv rehash

    ok "Python 3.10 configurado como padrão"

    if ! grep -q "alias python3=" ~/.zshrc; then
        echo 'alias python3="python"' >> ~/.zshrc
        echo 'alias pip3="pip"' >> ~/.zshrc
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

    python3 -m pip install --user pynvim || true

    ok "Neovim configurado"
}

# ===== MAIN =====
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
