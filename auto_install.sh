#!/bin/bash

set -e

echo "🔄 Atualizando sistema..."
sudo apt update -qq > /dev/null && sudo apt upgrade -y -qq > /dev/null
echo "✅ Sistema atualizado."

# Instalar Git, se não tiver
if ! command -v git >/dev/null 2>&1; then
    echo "📦 Instalando Git..."
    sudo apt install git -y -qq
    echo "✅ Git instalado."
else
    echo "✅ Git já está instalado."
fi

# Instalar Neovim via PPA, se não tiver
if ! command -v nvim >/dev/null 2>&1; then
    echo "📦 Instalando Neovim..."
    sudo apt remove --purge neovim -y -qq || true
    sudo add-apt-repository ppa:neovim-ppa/unstable -y > /dev/null
    sudo apt update -qq > /dev/null
    sudo apt install neovim -y -qq
    echo "✅ Neovim instalado."
else
    echo "✅ Neovim já está instalado."
fi

# Clonar config do Neovim, se não existir
if [ ! -d "$HOME/.config/nvim" ]; then
    echo "🔧 Clonando config do Neovim..."
    git clone https://github.com/al4xs/neovim-config ~/.config/nvim
    echo "✅ Config do Neovim clonada."
else
    echo "✅ Config do Neovim já existe."
fi

# Instalar Zsh, se não tiver
if ! command -v zsh >/dev/null 2>&1; then
    echo "📦 Instalando Zsh..."
    sudo apt install zsh -y -qq
    echo "✅ Zsh instalado."
else
    echo "✅ Zsh já está instalado."
fi

# Tornar o Zsh o shell padrão
if [ "$SHELL" != "$(which zsh)" ]; then
    echo "🔧 Tornando o Zsh o shell padrão..."
    sudo chsh -s $(which zsh) $USER
    echo "✅ Shell padrão alterado para Zsh (reinicie o terminal)."
else
    echo "✅ Zsh já é o shell padrão."
fi

# Instalar Oh My Zsh, se não tiver
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "📦 Instalando Oh My Zsh..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    echo "✅ Oh My Zsh instalado."
else
    echo "✅ Oh My Zsh já está instalado."
fi

# Instalar plugin de sugestões automáticas
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
    echo "🔌 Instalando zsh-autosuggestions..."
    git clone https://github.com/zsh-users/zsh-autosuggestions $ZSH_CUSTOM/plugins/zsh-autosuggestions
    echo "✅ Plugin zsh-autosuggestions instalado."
else
    echo "✅ Plugin zsh-autosuggestions já instalado."
fi

# Ativar plugin no ~/.zshrc se ainda não estiver
if ! grep -q "zsh-autosuggestions" ~/.zshrc; then
    echo "🔧 Ativando zsh-autosuggestions no .zshrc..."
    sed -i 's/plugins=(\(.*\))/plugins=(\1 zsh-autosuggestions)/' ~/.zshrc
    echo "✅ Plugin ativado no .zshrc."
else
    echo "✅ Plugin já está ativado no .zshrc."
fi

echo "🚀 Instalação concluída. Reinicie o terminal para aplicar as mudanças."

# Instalar Fira Code Nerd Font
echo "🔤 Instalando Fira Code Nerd Font..."
git clone --depth=1 https://github.com/terroo/fonts
cd fonts
mv fonts ~/.local/share
fc-cache -fv
cd ..
rm -rf fonts
echo "✅ Fira Code Nerd Font instalada."

sudo apt install build-essential -y
