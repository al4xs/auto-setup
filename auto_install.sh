#!/bin/bash

# Script de configuração automática do ambiente de desenvolvimento
# Compatível com Ubuntu, Linux Mint e outras distribuições baseadas em Debian
# Versão: 2.0

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir mensagens coloridas
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_process() {
    echo -e "${YELLOW}🔄 $1${NC}"
}

# Função para verificar se é sistema baseado em Debian/Ubuntu
check_system() {
    if [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]; then
        log_success "Sistema baseado em Debian/Ubuntu detectado"
        return 0
    else
        log_error "Este script é otimizado para sistemas baseados em Debian/Ubuntu"
        log_warning "Tentando continuar mesmo assim..."
        return 1
    fi
}

# Função para verificar conexão com internet
check_internet() {
    log_process "Verificando conexão com internet..."
    if ping -c 1 google.com &> /dev/null; then
        log_success "Conexão com internet OK"
        return 0
    else
        log_error "Sem conexão com internet. Verifique sua rede."
        return 1
    fi
}

# Função para instalar dependências básicas
install_basic_deps() {
    log_process "Instalando dependências básicas..."
    
    # Atualizar repositórios
    sudo apt update -qq
    
    # Instalar ferramentas básicas necessárias
    sudo apt install -y \
        curl \
        wget \
        git \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        build-essential \
        fontconfig \
        unzip
        
    log_success "Dependências básicas instaladas"
}

# Função para verificar se comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Função para instalar Node.js e npm
install_nodejs() {
    log_process "Verificando instalação do Node.js..."
    
    # Verificar se Node.js já está instalado com versão adequada
    if command_exists node; then
        NODE_VERSION=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$NODE_VERSION" -ge 18 ]; then
            log_success "Node.js já está instalado (versão $(node --version))"
            return 0
        else
            log_warning "Node.js versão antiga detectada. Atualizando..."
        fi
    fi
    
    log_process "Instalando Node.js LTS mais recente..."
    
    # Remover versões antigas do Node.js se existirem
    sudo apt remove --purge nodejs npm -y || true
    sudo apt autoremove -y || true
    
    # Instalar Node.js via NodeSource (método oficial recomendado)
    log_process "Baixando script de instalação do NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    
    log_process "Instalando Node.js e npm..."
    sudo apt-get install -y nodejs
    
    # Verificar se a instalação foi bem-sucedida
    if command_exists node && command_exists npm; then
        log_success "Node.js $(node --version) e npm $(npm --version) instalados com sucesso"
    else
        log_error "Falha na instalação do Node.js/npm"
        return 1
    fi
    
    # Configurar npm para instalações globais no diretório do usuário
    log_process "Configurando npm para instalações globais..."
    
    # Criar diretório para pacotes globais npm
    mkdir -p "$HOME/.npm-global"
    
    # Configurar npm para usar o diretório local
    npm config set prefix "$HOME/.npm-global"
    
    # Adicionar ao PATH nos arquivos de configuração do shell
    configure_nodejs_path
    
    # Atualizar npm para a versão mais recente
    log_process "Atualizando npm para a versão mais recente..."
    npm install -g npm@latest
    
    log_success "Node.js e npm configurados e prontos para uso!"
}

# Função para configurar PATH do Node.js
configure_nodejs_path() {
    log_process "Configurando PATH para Node.js e npm..."
    
    # Definir linha do PATH
    NPM_PATH_LINE='export PATH="$HOME/.npm-global/bin:$PATH"'
    
    # Configurar para bash
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -q ".npm-global/bin" "$HOME/.bashrc"; then
            echo "" >> "$HOME/.bashrc"
            echo "# Node.js npm global path" >> "$HOME/.bashrc"
            echo "$NPM_PATH_LINE" >> "$HOME/.bashrc"
            log_success "PATH configurado no .bashrc"
        fi
    fi
    
    # Configurar para zsh
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -q ".npm-global/bin" "$HOME/.zshrc"; then
            echo "" >> "$HOME/.zshrc"
            echo "# Node.js npm global path" >> "$HOME/.zshrc"
            echo "$NPM_PATH_LINE" >> "$HOME/.zshrc"
            log_success "PATH configurado no .zshrc"
        fi
    fi
    
    # Configurar para o ambiente atual
    export PATH="$HOME/.npm-global/bin:$PATH"
    
    log_success "PATH do Node.js configurado para funcionar de qualquer lugar"
}

# Função principal de instalação
main_installation() {
    log_process "Iniciando configuração do ambiente de desenvolvimento..."

    # Verificar sistema
    check_system

    # Verificar internet
    if ! check_internet; then
        exit 1
    fi

    # Instalar dependências básicas
    install_basic_deps

    # Atualizar sistema
    log_process "Atualizando sistema..."
    sudo apt upgrade -y -qq
    log_success "Sistema atualizado"

    # Instalar Git (se não estiver instalado)
    if ! command_exists git; then
        log_process "Instalando Git..."
        sudo apt install git -y
        log_success "Git instalado"
    else
        log_success "Git já está instalado"
    fi

    # Instalar Neovim via PPA
    if ! command_exists nvim; then
        log_process "Instalando Neovim..."
        
        # Remover versão antiga se existir
        sudo apt remove --purge neovim -y || true
        
        # Adicionar PPA do Neovim
        sudo add-apt-repository ppa:neovim-ppa/unstable -y
        sudo apt update -qq
        
        # Instalar Neovim
        sudo apt install neovim -y
        log_success "Neovim instalado"
    else
        log_success "Neovim já está instalado"
    fi

    # Configurar Neovim
    configure_neovim

    # Instalar e configurar Zsh
    install_configure_zsh

    # Instalar fontes Nerd Font
    install_nerd_fonts

    log_success "🚀 Instalação concluída!"
    log_info "Reinicie o terminal ou execute 'source ~/.zshrc' para aplicar as mudanças"
    
    # Exibir resumo
    display_summary
}

# Função para configurar Neovim
configure_neovim() {
    log_process "Configurando Neovim..."
    
    # Criar diretório de configuração se não existir
    mkdir -p "$HOME/.config"
    
    # Clonar configuração do Neovim
    if [ ! -d "$HOME/.config/nvim" ]; then
        log_process "Clonando configuração do Neovim..."
        git clone https://github.com/al4xs/neovim-config ~/.config/nvim
        log_success "Configuração do Neovim clonada"
    else
        log_warning "Configuração do Neovim já existe"
        read -p "Deseja sobrescrever? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$HOME/.config/nvim"
            git clone https://github.com/al4xs/neovim-config ~/.config/nvim
            log_success "Configuração do Neovim atualizada"
        fi
    fi

    # Instalar dependências do Neovim (Node.js para alguns plugins)
    install_nodejs

    # Instalar Python provider para Neovim
    if command_exists python3; then
        log_process "Instalando Python provider para Neovim..."
        python3 -m pip install --user --upgrade pynvim
        log_success "Python provider instalado"
    fi
}

# Função para instalar e configurar Zsh
install_configure_zsh() {
    # Instalar Zsh
    if ! command_exists zsh; then
        log_process "Instalando Zsh..."
        sudo apt install zsh -y
        log_success "Zsh instalado"
    else
        log_success "Zsh já está instalado"
    fi

    # Instalar Oh My Zsh
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        log_process "Instalando Oh My Zsh..."
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        log_success "Oh My Zsh instalado"
    else
        log_success "Oh My Zsh já está instalado"
    fi

    # Instalar plugins do Zsh
    install_zsh_plugins

    # Configurar Zsh como shell padrão
    if [ "$SHELL" != "$(which zsh)" ]; then
        log_process "Configurando Zsh como shell padrão..."
        sudo chsh -s $(which zsh) $USER
        log_success "Shell padrão alterado para Zsh"
        log_warning "Faça logout e login novamente para aplicar a mudança"
    else
        log_success "Zsh já é o shell padrão"
    fi
}

# Função para instalar plugins do Zsh
install_zsh_plugins() {
    ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
    
    # Plugin zsh-autosuggestions
    if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
        log_process "Instalando zsh-autosuggestions..."
        git clone https://github.com/zsh-users/zsh-autosuggestions $ZSH_CUSTOM/plugins/zsh-autosuggestions
        log_success "Plugin zsh-autosuggestions instalado"
    else
        log_success "Plugin zsh-autosuggestions já instalado"
    fi

    # Plugin zsh-syntax-highlighting
    if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
        log_process "Instalando zsh-syntax-highlighting..."
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git $ZSH_CUSTOM/plugins/zsh-syntax-highlighting
        log_success "Plugin zsh-syntax-highlighting instalado"
    else
        log_success "Plugin zsh-syntax-highlighting já instalado"
    fi

    # Configurar plugins no .zshrc
    if [ -f "$HOME/.zshrc" ]; then
        log_process "Configurando plugins no .zshrc..."
        
        # Backup do .zshrc original
        cp "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Ativar plugins
        if ! grep -q "zsh-autosuggestions" ~/.zshrc; then
            sed -i 's/plugins=(\(.*\))/plugins=(\1 zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc
            log_success "Plugins ativados no .zshrc"
        else
            log_success "Plugins já estão ativados no .zshrc"
        fi
    else
        log_warning ".zshrc não encontrado, plugins não foram configurados automaticamente"
    fi
}

# Função para instalar Nerd Fonts
install_nerd_fonts() {
    log_process "Instalando Nerd Fonts..."
    
    # Criar diretório de fontes
    mkdir -p "$HOME/.local/share/fonts"
    
    # Criar diretório temporário
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # Baixar e instalar Fira Code Nerd Font
    log_process "Baixando Fira Code Nerd Font..."
    wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/FiraCode.zip"
    
    if [ -f "FiraCode.zip" ]; then
        unzip -q FiraCode.zip
        cp *.ttf "$HOME/.local/share/fonts/" 2>/dev/null || true
        log_success "Fira Code Nerd Font instalada"
    else
        log_error "Falha ao baixar Fira Code Nerd Font"
    fi
    
    # Baixar e instalar JetBrains Mono Nerd Font (alternativa)
    log_process "Baixando JetBrains Mono Nerd Font..."
    wget -q "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.0.2/JetBrainsMono.zip"
    
    if [ -f "JetBrainsMono.zip" ]; then
        unzip -q JetBrainsMono.zip
        cp *.ttf "$HOME/.local/share/fonts/" 2>/dev/null || true
        log_success "JetBrains Mono Nerd Font instalada"
    else
        log_warning "Falha ao baixar JetBrains Mono Nerd Font"
    fi
    
    # Limpar diretório temporário
    cd "$HOME"
    rm -rf "$TEMP_DIR"
    
    # Atualizar cache de fontes
    if command_exists fc-cache; then
        log_process "Atualizando cache de fontes..."
        fc-cache -fv
        log_success "Cache de fontes atualizado"
    fi
}

# Função para exibir resumo da instalação
display_summary() {
    echo ""
    log_info "📋 Resumo da Instalação:"
    echo ""
    
    # Verificar Git
    if command_exists git; then
        echo -e "   ${GREEN}✅ Git: $(git --version)${NC}"
    else
        echo -e "   ${RED}❌ Git: Não instalado${NC}"
    fi
    
    # Verificar Neovim
    if command_exists nvim; then
        echo -e "   ${GREEN}✅ Neovim: $(nvim --version | head -n1)${NC}"
    else
        echo -e "   ${RED}❌ Neovim: Não instalado${NC}"
    fi
    
    # Verificar configuração do Neovim
    if [ -d "$HOME/.config/nvim" ]; then
        echo -e "   ${GREEN}✅ Configuração Neovim: Instalada${NC}"
    else
        echo -e "   ${RED}❌ Configuração Neovim: Não encontrada${NC}"
    fi
    
    # Verificar Zsh
    if command_exists zsh; then
        echo -e "   ${GREEN}✅ Zsh: $(zsh --version)${NC}"
    else
        echo -e "   ${RED}❌ Zsh: Não instalado${NC}"
    fi
    
    # Verificar Oh My Zsh
    if [ -d "$HOME/.oh-my-zsh" ]; then
        echo -e "   ${GREEN}✅ Oh My Zsh: Instalado${NC}"
    else
        echo -e "   ${RED}❌ Oh My Zsh: Não instalado${NC}"
    fi
    
    # Verificar plugins do Zsh
    if [ -d "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ]; then
        echo -e "   ${GREEN}✅ Plugin zsh-autosuggestions: Instalado${NC}"
    else
        echo -e "   ${RED}❌ Plugin zsh-autosuggestions: Não instalado${NC}"
    fi
    
    if [ -d "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" ]; then
        echo -e "   ${GREEN}✅ Plugin zsh-syntax-highlighting: Instalado${NC}"
    else
        echo -e "   ${RED}❌ Plugin zsh-syntax-highlighting: Não instalado${NC}"
    fi
    
    # Verificar fontes
    if [ -d "$HOME/.local/share/fonts" ] && [ "$(ls -A $HOME/.local/share/fonts)" ]; then
        echo -e "   ${GREEN}✅ Nerd Fonts: Instaladas${NC}"
    else
        echo -e "   ${RED}❌ Nerd Fonts: Não instaladas${NC}"
    fi
    
    # Verificar Node.js
    if command_exists node; then
        echo -e "   ${GREEN}✅ Node.js: $(node --version)${NC}"
    else
        echo -e "   ${YELLOW}⚠️  Node.js: Não instalado${NC}"
    fi
    
    # Verificar npm
    if command_exists npm; then
        echo -e "   ${GREEN}✅ npm: $(npm --version)${NC}"
    else
        echo -e "   ${YELLOW}⚠️  npm: Não instalado${NC}"
    fi
    
    echo ""
    log_info "🎯 Próximos passos:"
    echo "   1. Reinicie o terminal ou execute 'source ~/.zshrc'"
    echo "   2. Configure seu terminal para usar uma Nerd Font (Fira Code ou JetBrains Mono)"
    echo "   3. Abra o Neovim e execute ':PackerInstall' se necessário"
    echo "   4. Execute 'nvim' para verificar se tudo está funcionando"
}

# Verificar se o script está sendo executado com bash
if [ -z "$BASH_VERSION" ]; then
    echo "❌ Este script deve ser executado com bash!"
    echo "Use: bash $0"
    exit 1
fi

# Verificar se está sendo executado como root
if [ "$EUID" -eq 0 ]; then
    echo "❌ Não execute este script como root!"
    echo "Use: bash $0"
    exit 1
fi

# Executar instalação principal
main_installation
