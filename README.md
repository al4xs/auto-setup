# Auto Setup - Configuração Automática do Ambiente de Desenvolvimento

Script automatizado para configurar um ambiente de desenvolvimento completo no Linux, otimizado para Ubuntu e Linux Mint XFCE.

## 📋 O que este script faz

Este script automatiza a instalação e configuração de:

- **Git** - Sistema de controle de versão
- **Neovim** - Editor de texto moderno com configuração personalizada
- **Zsh** - Shell avançado com Oh My Zsh
- **Plugins do Zsh** - Auto-sugestões e syntax highlighting
- **Nerd Fonts** - Fontes com ícones para terminais (Fira Code e JetBrains Mono)
- **Node.js** - Runtime JavaScript para plugins do Neovim
- **Python provider** - Suporte Python para Neovim
- **Dependências básicas** - Build tools e utilitários essenciais

## 🔧 Requisitos do Sistema

### Sistemas Suportados
- Ubuntu 18.04 ou superior
- Linux Mint 19 ou superior
- Outras distribuições baseadas em Debian/Ubuntu

### Pré-requisitos
- Conexão com internet ativa
- Usuário com privilégios sudo
- Pelo menos 500MB de espaço livre em disco

## 🚀 Como usar

### Opção 1: Download direto
```bash
# Baixar o script
wget https://raw.githubusercontent.com/al4xs/auto-setup/main/auto_install_fixed.sh

# Tornar executável
chmod +x auto_install_fixed.sh

# Executar
./auto_install_fixed.sh
```

### Opção 2: Clonar repositório
```bash
# Clonar o repositório
git clone https://github.com/al4xs/auto-setup.git

# Entrar no diretório
cd auto-setup

# Executar o script
./auto_install_fixed.sh
```

### Opção 3: Execução direta (uma linha)
```bash
bash <(wget -qO- https://raw.githubusercontent.com/al4xs/auto-setup/main/auto_install_fixed.sh)
```

## 📖 Processo de Instalação

O script executa as seguintes etapas automaticamente:

1. **Verificação do sistema** - Confirma compatibilidade
2. **Teste de conectividade** - Verifica conexão com internet
3. **Instalação de dependências** - Instala ferramentas básicas necessárias
4. **Atualização do sistema** - Atualiza pacotes existentes
5. **Instalação do Git** - Se não estiver presente
6. **Instalação do Neovim** - Via PPA oficial para versão mais recente
7. **Configuração do Neovim** - Clona configuração personalizada
8. **Instalação do Zsh e Oh My Zsh** - Shell moderno com framework
9. **Configuração de plugins** - Auto-sugestões e syntax highlighting
10. **Instalação de Nerd Fonts** - Fontes com ícones para melhor experiência visual
11. **Configuração final** - Definir Zsh como shell padrão

## ⚙️ Configurações Aplicadas

### Neovim
- Configuração personalizada do repositório `al4xs/neovim-config`
- Suporte a Python provider
- Suporte a Node.js para plugins avançados
- Localizado em `~/.config/nvim/`

### Zsh
- Oh My Zsh como framework
- Plugin `zsh-autosuggestions` para sugestões automáticas
- Plugin `zsh-syntax-highlighting` para destacar sintaxe
- Backup automático do `.zshrc` existente

### Fontes
- Fira Code Nerd Font
- JetBrains Mono Nerd Font
- Instaladas em `~/.local/share/fonts/`
- Cache de fontes atualizado automaticamente

## 🎯 Pós-Instalação

### 1. Reiniciar Terminal
Após a instalação, reinicie seu terminal ou execute:
```bash
source ~/.zshrc
```

### 2. Configurar Fonte do Terminal
Configure seu terminal para usar uma das Nerd Fonts instaladas:
- **Fira Code Nerd Font**
- **JetBrains Mono Nerd Font**

### 3. Verificar Neovim
Abra o Neovim e verifique se tudo está funcionando:
```bash
nvim
```

Se necessário, execute dentro do Neovim:
```vim
:PackerInstall
```

### 4. Configurar Shell (se necessário)
Se o Zsh não for definido automaticamente como padrão:
```bash
chsh -s $(which zsh)
```

## 🔍 Verificação da Instalação

O script exibe um resumo completo ao final mostrando o status de cada componente:

- ✅ Componente instalado com sucesso
- ❌ Componente com falha na instalação
- ⚠️ Componente opcional não instalado

## 🛠️ Solução de Problemas

### Erro de Permissões
```bash
# Se encontrar erro de permissões sudo, verifique:
sudo -l
```

### Erro de Conexão
```bash
# Teste sua conexão:
ping google.com
```

### Erro de PPA do Neovim
```bash
# Remover PPA e tentar novamente:
sudo add-apt-repository --remove ppa:neovim-ppa/unstable
sudo apt update
```

### Zsh não aparece como opção
```bash
# Verificar se Zsh está instalado:
which zsh

# Listar shells disponíveis:
cat /etc/shells
```

### Fontes não aparecem no terminal
1. Feche e abra o terminal
2. Verifique se as fontes estão instaladas:
```bash
fc-list | grep -i "fira\|jetbrains"
```

## 📁 Estrutura de Arquivos Criados

```
$HOME/
├── .config/
│   └── nvim/                    # Configuração do Neovim
├── .oh-my-zsh/                  # Framework Oh My Zsh
│   └── custom/
│       └── plugins/
│           ├── zsh-autosuggestions/
│           └── zsh-syntax-highlighting/
├── .local/
│   └── share/
│       └── fonts/               # Nerd Fonts instaladas
├── .zshrc                       # Configuração do Zsh
└── .zshrc.backup.YYYYMMDD_HHMMSS # Backup do .zshrc original
```

## 🔄 Atualizações

Para atualizar os componentes:

### Neovim
```bash
sudo apt update && sudo apt upgrade neovim
```

### Oh My Zsh
```bash
omz update
```

### Plugins do Zsh
```bash
cd ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions && git pull
cd ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting && git pull
```

### Configuração do Neovim
```bash
cd ~/.config/nvim && git pull
```

## 📞 Suporte

Se encontrar problemas:

1. Verifique os logs de erro exibidos pelo script
2. Consulte a seção de solução de problemas
3. Verifique se todos os pré-requisitos foram atendidos
4. Execute o script novamente (é seguro executar múltiplas vezes)

## 📝 Licença

Este projeto está sob a licença MIT. Veja o arquivo LICENSE para detalhes.

## 🤝 Contribuição

Contribuições são bem-vindas! Sinta-se à vontade para:

- Reportar bugs
- Sugerir melhorias
- Enviar pull requests
- Compartilhar feedback

---

**Nota**: Este script foi testado em Ubuntu 20.04/22.04 e Linux Mint 20/21. Pode funcionar em outras distribuições baseadas em Debian, mas não é garantido.
