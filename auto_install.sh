#!/usr/bin/env bash
# =============================================================================
# Instalador de ambiente de desenvolvimento — Ubuntu/Debian
# Usa somente fontes e métodos oficiais.
# =============================================================================

set -e

# ── CORES & UI ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
ok()     { echo -e "${GREEN}✅ $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()    { echo -e "${RED}❌ $1${NC}"; }
header() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
}
ask() { echo -en "${BOLD}  ➜ $1${NC} "; }

# Resumo final: chave → status
declare -A SUMMARY

# Diretório temporário limpo ao sair
SETUP_TMP=$(mktemp -d)
trap 'rm -rf "$SETUP_TMP"' EXIT

# ── DETECÇÃO DO SISTEMA ───────────────────────────────────────────────────────
detect_system() {
    WSL=false
    grep -qi microsoft /proc/version 2>/dev/null && WSL=true && ok "WSL detectado"

    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO=$ID
    VERSION=$VERSION_ID
    ok "Sistema: $DISTRO $VERSION"
}

# ── DEPENDÊNCIAS BASE ─────────────────────────────────────────────────────────
install_deps() {
    log "Verificando dependências básicas..."
    local deps=(curl wget git unzip build-essential ca-certificates gnupg
                lsb-release apt-transport-https software-properties-common
                python3 python3-pip python3-venv)
    local missing=()

    for pkg in "${deps[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
            | grep -q "ok installed" || missing+=("$pkg")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        ok "Todas as dependências base já instaladas"
        return
    fi

    log "Instalando: ${missing[*]}"
    sudo apt update -y
    sudo apt install -y "${missing[@]}"
    ok "Dependências instaladas"
}

# ── NODE.JS ───────────────────────────────────────────────────────────────────
install_node() {
    if command -v node >/dev/null 2>&1; then
        ok "Node já instalado ($(node -v))"
        return
    fi
    log "Instalando Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs
    ok "Node instalado ($(node -v))"
}

# ════════════════════════════════════════════════════════════════════════════════
#  ZSH + OH MY ZSH
#
#  PROBLEMA IDENTIFICADO (análise do .zshrc real do usuário):
#
#  O template moderno do Oh My Zsh NÃO gera uma linha `plugins=()` —
#  apenas comentários. A abordagem anterior com `sed` falhava silenciosamente
#  e caia no `else`, executando `echo >> ~/.zshrc`, que adiciona plugins=()
#  NO FIM DO ARQUIVO — depois do `source $ZSH/oh-my-zsh.sh`.
#
#  O Oh My Zsh lê $plugins ANTES de fazer o source. Com plugins= após o
#  source, os plugins nunca são registrados → zsh-autosuggestions não funciona.
#
#  SOLUÇÃO: Python manipula o .zshrc com precisão, independente do template,
#  versão do Oh My Zsh, ou escaping problemático do sed.
# ════════════════════════════════════════════════════════════════════════════════

install_zsh() {
    header "Zsh + Oh My Zsh"

    # Instala Zsh se necessário
    if command -v zsh >/dev/null 2>&1; then
        ok "Zsh já instalado ($(zsh --version | head -1))"
    else
        log "Instalando Zsh..."
        sudo apt install -y zsh
        ok "Zsh instalado"
    fi

    # Instala Oh My Zsh se necessário
    # CHSH=no → não troca shell padrão automaticamente
    # RUNZSH=no → não abre nova sessão zsh ao terminar
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        log "Instalando Oh My Zsh..."
        RUNZSH=no CHSH=no sh -c \
            "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
        ok "Oh My Zsh instalado"
    else
        ok "Oh My Zsh já instalado"
    fi

    _install_zsh_plugins
    _configure_zshrc      # Configura via Python (confiável)
    _validate_zsh_config  # Valida resultado

    # Troca o shell padrão para zsh
    if [ "$WSL" = false ]; then
        # || true: evita que set -e mate o script se chsh falhar (ex: container)
        chsh -s "$(which zsh)" 2>/dev/null || true
    fi

    # Fallback: no bash, entra em zsh automaticamente se disponível
    if ! grep -q "exec zsh" ~/.bashrc 2>/dev/null; then
        echo 'command -v zsh >/dev/null && exec zsh' >> ~/.bashrc
    fi

    ok "Zsh configurado com sucesso"
}

# ── INSTALAÇÃO DOS PLUGINS ────────────────────────────────────────────────────
_install_zsh_plugins() {
    # ZSH_CUSTOM pode ser sobrescrito pelo usuário; usa o padrão se não estiver definido
    local plugins_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
    mkdir -p "$plugins_dir"

    if [ ! -d "$plugins_dir/zsh-autosuggestions" ]; then
        log "Instalando zsh-autosuggestions..."
        git clone --depth=1 \
            https://github.com/zsh-users/zsh-autosuggestions \
            "$plugins_dir/zsh-autosuggestions"
    else
        ok "zsh-autosuggestions já instalado"
    fi

    if [ ! -d "$plugins_dir/zsh-syntax-highlighting" ]; then
        log "Instalando zsh-syntax-highlighting..."
        git clone --depth=1 \
            https://github.com/zsh-users/zsh-syntax-highlighting \
            "$plugins_dir/zsh-syntax-highlighting"
    else
        ok "zsh-syntax-highlighting já instalado"
    fi
}

# ── CONFIGURAÇÃO DO .zshrc ────────────────────────────────────────────────────
#
# Usa Python para garantir que plugins=() fique ANTES de `source $ZSH/oh-my-zsh.sh`.
# Isso evita todos os problemas de escaping do sed com $ZSH no padrão de endereço.
#
# Regras aplicadas:
#   1. Faz backup do .zshrc antes de qualquer modificação.
#   2. Remove TODAS as linhas plugins=() existentes (qualquer posição).
#   3. Remove config duplicada de autosuggestions.
#   4. Insere plugins=() IMEDIATAMENTE ANTES de `source $ZSH/oh-my-zsh.sh`.
#   5. Adiciona config de autosuggestions APÓS o source (final do arquivo).
#   6. Nunca sobrescreve ZSH_THEME — preserva tema existente do usuário.
# ─────────────────────────────────────────────────────────────────────────────
_configure_zshrc() {
    log "Configurando .zshrc..."

    # Garante que .zshrc existe
    if [ ! -f ~/.zshrc ]; then
        if [ -f "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" ]; then
            cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" ~/.zshrc
            ok ".zshrc criado a partir do template do Oh My Zsh"
        else
            touch ~/.zshrc
            warn ".zshrc criado vazio (template não encontrado)"
        fi
    fi

    # Escreve o script Python em arquivo temporário
    cat > "$SETUP_TMP/configure_zshrc.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Configura corretamente plugins e autosuggestions no .zshrc.

Garante que plugins=() aparece ANTES de `source $ZSH/oh-my-zsh.sh`.
O Oh My Zsh lê $plugins antes de executar o source — se plugins= vier
depois, os plugins externos nunca são registrados.
"""
import sys, re, shutil, os

ZSHRC_PATH = os.path.expanduser(sys.argv[1]) if len(sys.argv) > 1 else os.path.expanduser("~/.zshrc")
BACKUP_PATH = ZSHRC_PATH + ".bak"

PLUGINS_LINE = "plugins=(git zsh-autosuggestions zsh-syntax-highlighting)\n"
AUTOSUGGEST_CONFIG = (
    "\n# zsh-autosuggestions — configurado pelo setup.sh\n"
    "ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'\n"   # fg=244 = cinza médio visível
    "ZSH_AUTOSUGGEST_STRATEGY=(history completion)\n"
)

# Padrões para identificar linhas já existentes
RE_SOURCE   = re.compile(r'^\s*source\s+\$ZSH/oh-my-zsh\.sh\s*$')
RE_PLUGINS  = re.compile(r'^\s*plugins=\(')
RE_AS_STYLE = re.compile(r'^\s*ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE\s*=')
RE_AS_STRAT = re.compile(r'^\s*ZSH_AUTOSUGGEST_STRATEGY\s*=')
RE_AS_BLOCK = re.compile(r'^\s*#\s*zsh-autosuggestions')

def is_autosuggest_line(line):
    return RE_AS_STYLE.match(line) or RE_AS_STRAT.match(line) or RE_AS_BLOCK.match(line)

# ── Lê o arquivo ──────────────────────────────────────────────────────────────
with open(ZSHRC_PATH) as f:
    lines = f.readlines()

# ── Backup ────────────────────────────────────────────────────────────────────
shutil.copy2(ZSHRC_PATH, BACKUP_PATH)
print(f"  Backup: {BACKUP_PATH}")

# ── Localiza a linha do source ─────────────────────────────────────────────────
source_idx = next((i for i, l in enumerate(lines) if RE_SOURCE.match(l)), None)

if source_idx is None:
    # .zshrc sem source line (arquivo vazio ou personalizado).
    # Adiciona no final como fallback seguro.
    print("  AVISO: 'source $ZSH/oh-my-zsh.sh' não encontrado — adicionando ao final.")
    cleaned = [l for l in lines if not RE_PLUGINS.match(l) and not is_autosuggest_line(l)]
    cleaned.append("\n" + PLUGINS_LINE)
    cleaned.append(AUTOSUGGEST_CONFIG)
    with open(ZSHRC_PATH, "w") as f:
        f.writelines(cleaned)
    print("  OK (fallback: plugins e config no final)")
    sys.exit(0)

# ── Reconstrói o arquivo ───────────────────────────────────────────────────────
# Passo 1: remove todas as linhas plugins=() e config de autosuggestions
#          (podem estar em qualquer posição — inclusive após o source)
cleaned = [l for l in lines if not RE_PLUGINS.match(l) and not is_autosuggest_line(l)]

# Passo 2: encontra a linha do source no array limpo
source_new_idx = next((i for i, l in enumerate(cleaned) if RE_SOURCE.match(l)), None)

if source_new_idx is not None:
    # Insere plugins=() IMEDIATAMENTE ANTES do source
    cleaned.insert(source_new_idx, PLUGINS_LINE)
else:
    # Fallback improvável: sem source após limpeza
    cleaned.append("\n" + PLUGINS_LINE)

# Passo 3: adiciona config de autosuggestions no final
#          (deve ficar APÓS o source para sobrescrever defaults do plugin)
cleaned.append(AUTOSUGGEST_CONFIG)

# ── Grava o arquivo ────────────────────────────────────────────────────────────
with open(ZSHRC_PATH, "w") as f:
    f.writelines(cleaned)

# ── Confirma posição ───────────────────────────────────────────────────────────
with open(ZSHRC_PATH) as f:
    final = f.readlines()

plugin_pos = next((i+1 for i, l in enumerate(final) if RE_PLUGINS.match(l)), None)
source_pos = next((i+1 for i, l in enumerate(final) if RE_SOURCE.match(l)), None)

if plugin_pos and source_pos and plugin_pos < source_pos:
    print(f"  OK: plugins= linha {plugin_pos}  |  source linha {source_pos}  (ordem correta)")
elif plugin_pos and source_pos:
    print(f"  ERRO: plugins= linha {plugin_pos} está DEPOIS do source linha {source_pos}!")
    sys.exit(2)
else:
    print("  AVISO: não foi possível confirmar posição das linhas")
PYEOF

    # Executa o script Python e captura saída
    local py_out
    if py_out=$(python3 "$SETUP_TMP/configure_zshrc.py" "$HOME/.zshrc" 2>&1); then
        echo "$py_out" | while IFS= read -r line; do log "$line"; done
        ok "Plugins configurados na posição correta"
    else
        echo "$py_out" | while IFS= read -r line; do err "$line"; done
        err "Falha ao configurar .zshrc — verifique ~/.zshrc.bak"
        return 1
    fi
}

# ── VALIDAÇÃO DA CONFIGURAÇÃO ZSH ─────────────────────────────────────────────
#
# Verifica que:
#   1. .zshrc não tem erros de sintaxe
#   2. plugins=() está ANTES de source $ZSH/oh-my-zsh.sh
#   3. Diretórios dos plugins existem com as permissões corretas
#   4. Os plugins carregam em uma sessão real do Zsh
# ─────────────────────────────────────────────────────────────────────────────
_validate_zsh_config() {
    header "Validando configuração do Zsh"
    local errors=0

    # 1. Sintaxe do .zshrc
    log "Verificando sintaxe do .zshrc..."
    if zsh -n ~/.zshrc 2>/tmp/zsh_syntax_err; then
        ok ".zshrc sem erros de sintaxe"
    else
        err "Erros de sintaxe no .zshrc:"
        cat /tmp/zsh_syntax_err | while IFS= read -r l; do err "  $l"; done
        errors=$((errors + 1))
    fi

    # 2. Posição de plugins= vs source no arquivo
    log "Verificando posição de plugins= no .zshrc..."
    local plugins_ln source_ln
    plugins_ln=$(grep -n "^plugins=(" ~/.zshrc 2>/dev/null | head -1 | cut -d: -f1)
    source_ln=$(grep -n "source \$ZSH/oh-my-zsh.sh" ~/.zshrc 2>/dev/null | head -1 | cut -d: -f1)

    if [ -n "$plugins_ln" ] && [ -n "$source_ln" ]; then
        if [ "$plugins_ln" -lt "$source_ln" ]; then
            ok "plugins= linha $plugins_ln ← antes do source linha $source_ln ✓"
        else
            err "plugins= linha $plugins_ln está DEPOIS do source linha $source_ln!"
            err "Os plugins não serão carregados. Corrija o .zshrc manualmente."
            errors=$((errors + 1))
        fi
    else
        [ -z "$plugins_ln" ] && warn "Linha plugins=() não encontrada no .zshrc"
        [ -z "$source_ln" ] && warn "Linha 'source \$ZSH/oh-my-zsh.sh' não encontrada"
        errors=$((errors + 1))
    fi

    # 3. Existência e permissão dos diretórios dos plugins
    local plugins_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"

    if [ -d "$plugins_dir/zsh-autosuggestions" ]; then
        ok "Diretório zsh-autosuggestions: $plugins_dir/zsh-autosuggestions"
    else
        err "Diretório zsh-autosuggestions não encontrado!"
        errors=$((errors + 1))
    fi

    if [ -d "$plugins_dir/zsh-syntax-highlighting" ]; then
        ok "Diretório zsh-syntax-highlighting: $plugins_dir/zsh-syntax-highlighting"
    else
        err "Diretório zsh-syntax-highlighting não encontrado!"
        errors=$((errors + 1))
    fi

    # 4. Teste de carregamento real em sessão Zsh
    #    Usa uma tag única para isolar o echo do output do tema/prompt
    log "Testando carregamento dos plugins em sessão Zsh (pode demorar alguns segundos)..."

    local autosuggest_ver
    # zsh -i: sessão interativa → carrega .zshrc e plugins
    # 2>/dev/null: descarta mensagens do tema e do compinit
    # grep na tag: ignora output do prompt/tema
    autosuggest_ver=$(
        zsh -i -c 'echo "SETUP_CHECK:${ZSH_AUTOSUGGEST_VERSION:-NOT_LOADED}"' \
        2>/dev/null | grep "^SETUP_CHECK:" | cut -d: -f2 || echo "NOT_LOADED"
    )

    if [ "$autosuggest_ver" != "NOT_LOADED" ] && [ -n "$autosuggest_ver" ]; then
        ok "zsh-autosuggestions carregado (versão $autosuggest_ver)"
    else
        err "zsh-autosuggestions NÃO foi carregado na sessão Zsh"
        warn "Verifique: exec zsh && echo \$ZSH_AUTOSUGGEST_VERSION"
        errors=$((errors + 1))
    fi

    local highlight_ver
    highlight_ver=$(
        zsh -i -c 'echo "SETUP_CHECK:${ZSH_HIGHLIGHT_VERSION:-NOT_LOADED}"' \
        2>/dev/null | grep "^SETUP_CHECK:" | cut -d: -f2 || echo "NOT_LOADED"
    )

    if [ "$highlight_ver" != "NOT_LOADED" ] && [ -n "$highlight_ver" ]; then
        ok "zsh-syntax-highlighting carregado (versão $highlight_ver)"
    else
        err "zsh-syntax-highlighting NÃO foi carregado na sessão Zsh"
        warn "Verifique: exec zsh && echo \$ZSH_HIGHLIGHT_VERSION"
        errors=$((errors + 1))
    fi

    # Resultado final da validação
    echo ""
    if [ "$errors" -eq 0 ]; then
        ok "Todas as verificações do Zsh passaram com sucesso!"
    else
        warn "$errors verificação(ões) falharam."
        warn "Para aplicar as configurações: exec zsh  (ou reabra o terminal)"
        warn "Backup do .zshrc original: ~/.zshrc.bak"
    fi

    return 0  # Não bloqueia o resto do script por problemas de validação
}

# ── PYENV ─────────────────────────────────────────────────────────────────────
install_pyenv() {
    if [ -d "$HOME/.pyenv" ]; then
        ok "pyenv já instalado"
    else
        log "Instalando pyenv..."
        git clone --depth=1 https://github.com/pyenv/pyenv.git ~/.pyenv
    fi

    # Usa aspas simples no heredoc para evitar expansão de variáveis
    if ! grep -q "pyenv" ~/.zshrc 2>/dev/null; then
        cat >> ~/.zshrc <<'EOF'

# PYENV
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF
    fi

    ok "pyenv configurado"
}

# ── PYTHON 3.10 ───────────────────────────────────────────────────────────────
install_python310() {
    log "Verificando Python 3.10..."
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"

    if ! command -v pyenv >/dev/null 2>&1; then
        err "pyenv não encontrado!"
        return
    fi

    eval "$(pyenv init -)"

    # Verifica e instala apenas as dependências de build ausentes
    local build_deps=(make build-essential libssl-dev zlib1g-dev libbz2-dev
                      libreadline-dev libsqlite3-dev curl libncurses-dev xz-utils
                      tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev)
    local missing=()
    for pkg in "${build_deps[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
            | grep -q "ok installed" || missing+=("$pkg")
    done
    [ ${#missing[@]} -gt 0 ] && { log "Instalando dependências de build..."; sudo apt install -y "${missing[@]}"; }

    if pyenv versions --bare 2>/dev/null | grep -q "^3\.10"; then
        ok "Python 3.10 já instalado"
    else
        log "Instalando Python 3.10.13..."
        pyenv install 3.10.13
        ok "Python 3.10.13 instalado"
    fi

    pyenv global 3.10.13
    pyenv rehash
    ok "Python 3.10.13 definido como padrão"

    if ! grep -q "alias python3=" ~/.zshrc 2>/dev/null; then
        echo 'alias python3="python"' >> ~/.zshrc
        echo 'alias pip3="pip"' >> ~/.zshrc
    fi
}

# ── NEOVIM ────────────────────────────────────────────────────────────────────
install_nvim() {
    if command -v nvim >/dev/null 2>&1; then
        ok "Neovim já instalado ($(nvim --version | head -1))"
    else
        log "Instalando Neovim..."
        sudo apt install -y neovim
    fi

    mkdir -p ~/.config

    if [ ! -d ~/.config/nvim ]; then
        log "Clonando configuração do Neovim..."
        git clone https://github.com/al4xs/neovim-config ~/.config/nvim
    else
        ok "Configuração do Neovim já presente"
    fi

    python3 -m pip install --user pynvim 2>/dev/null || true
    ok "Neovim configurado"
}

# ════════════════════════════════════════════════════════════════════════════════
#  .NET SDK
#  Detecta versões disponíveis dinamicamente via API oficial da Microsoft.
#  Nunca usa números de versão fixos no código.
# ════════════════════════════════════════════════════════════════════════════════

# Preenche: DOTNET_STABLE_CHANNEL, DOTNET_STABLE_SDK, DOTNET_LTS_CHANNEL, DOTNET_LTS_SDK
_fetch_dotnet_versions() {
    local json_file="$SETUP_TMP/dotnet-releases.json"
    log "Buscando versões disponíveis do .NET na Microsoft..."

    if ! curl -fsSL \
        "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json" \
        -o "$json_file"; then
        err "Não foi possível buscar versões do .NET. Verifique sua conexão."
        return 1
    fi

    cat > "$SETUP_TMP/parse_dotnet.py" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

releases = data.get("releases-index", [])

# Apenas versões ativas ou em manutenção (exclui eol, preview, rc)
valid = [
    r for r in releases
    if r.get("support-phase") in ("active", "maintenance")
    and "preview" not in r.get("channel-version", "").lower()
    and "rc"      not in r.get("channel-version", "").lower()
]

# Ordena por versão decrescente
valid.sort(
    key=lambda r: [int(x) for x in r["channel-version"].split(".")],
    reverse=True
)

if not valid:
    print("none N/A none N/A")
    sys.exit(0)

# Versão estável = mais recente (STS ou LTS)
stable = valid[0]

# Versão LTS mais recente
lts_list = [r for r in valid if r.get("release-type") == "lts"]
lts = lts_list[0] if lts_list else None

# Se a estável já é LTS, oferece o LTS anterior como alternativa
if lts and lts["channel-version"] == stable["channel-version"]:
    lts = next((r for r in lts_list[1:]), None)

print(
    stable["channel-version"],
    stable.get("latest-sdk", "N/A"),
    (lts["channel-version"]        if lts else "none"),
    (lts.get("latest-sdk", "N/A") if lts else "N/A"),
)
PYEOF

    local result
    result=$(python3 "$SETUP_TMP/parse_dotnet.py" "$json_file") || {
        err "Falha ao interpretar versões do .NET."
        return 1
    }

    read -r DOTNET_STABLE_CHANNEL DOTNET_STABLE_SDK \
             DOTNET_LTS_CHANNEL   DOTNET_LTS_SDK <<< "$result"
}

_dotnet_already_installed_menu() {
    local current="$1"
    echo ""
    warn ".NET SDK já detectado: $current"
    echo "  [1] Manter versão atual"
    echo "  [2] Instalar outra versão lado a lado"
    echo "  [3] Atualizar (reinstalar canal atual)"
    echo "  [4] Reinstalar do zero (~/.dotnet)"
    ask "Escolha [1-4, padrão=1]:"
    local choice
    read -r choice || choice="1"
    case "${choice:-1}" in
        2) echo "side-by-side" ;;
        3) echo "update"       ;;
        4) echo "reinstall"    ;;
        *) echo "keep"         ;;
    esac
}

_dotnet_run_install() {
    local channel="$1"
    local install_dir="$HOME/.dotnet"
    local script="$SETUP_TMP/dotnet-install.sh"

    log "Baixando instalador oficial do .NET ($channel)..."
    curl -fsSL "https://dot.net/v1/dotnet-install.sh" -o "$script"
    chmod +x "$script"

    log "Instalando .NET SDK canal $channel em $install_dir ..."
    "$script" --channel "$channel" --install-dir "$install_dir"

    # Adiciona ao PATH nos arquivos rc apenas uma vez
    for rc in ~/.zshrc ~/.bashrc; do
        [ -f "$rc" ] || continue
        grep -q "DOTNET_ROOT" "$rc" && continue
        cat >> "$rc" << 'EOF'

# .NET SDK
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"
EOF
    done

    export DOTNET_ROOT="$HOME/.dotnet"
    export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"
}

_dotnet_validate() {
    log "Validando instalação do .NET..."
    local dotnet_cmd="${DOTNET_ROOT:-$HOME/.dotnet}/dotnet"

    if [ ! -x "$dotnet_cmd" ] && ! command -v dotnet >/dev/null 2>&1; then
        err ".NET não encontrado após instalação."
        warn "Execute: source ~/.zshrc && dotnet --version"
        return 1
    fi

    command -v dotnet >/dev/null 2>&1 && dotnet_cmd="dotnet"

    ok ".NET versão: $($dotnet_cmd --version 2>/dev/null)"
    log "SDKs instalados:"
    "$dotnet_cmd" --list-sdks 2>/dev/null | while IFS= read -r line; do
        echo "   • $line"
    done
}

install_dotnet() {
    header ".NET SDK"

    _fetch_dotnet_versions || { SUMMARY[dotnet]="Falhou (sem conexão)"; return; }

    # Verifica se .NET já está disponível
    local current_dotnet="" dotnet_cmd=""
    if command -v dotnet >/dev/null 2>&1; then
        dotnet_cmd="dotnet"
    elif [ -x "$HOME/.dotnet/dotnet" ]; then
        dotnet_cmd="$HOME/.dotnet/dotnet"
        export DOTNET_ROOT="$HOME/.dotnet"
        export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"
    fi

    if [ -n "$dotnet_cmd" ]; then
        current_dotnet=$($dotnet_cmd --version 2>/dev/null || echo "desconhecida")
        local action
        action=$(_dotnet_already_installed_menu "$current_dotnet")
        case "$action" in
            keep)
                ok ".NET mantido ($current_dotnet)"
                SUMMARY[dotnet]="Mantido ($current_dotnet)"
                return
                ;;
            reinstall)
                log "Removendo ~/.dotnet para reinstalação limpa..."
                rm -rf "$HOME/.dotnet"
                ;;
        esac
    fi

    # Menu de escolha de versão
    echo ""
    header "Escolha a versão do .NET SDK"
    echo "  [1] .NET $DOTNET_STABLE_CHANNEL — Estável atual (SDK $DOTNET_STABLE_SDK)"
    [ "$DOTNET_LTS_CHANNEL" != "none" ] && \
        echo "  [2] .NET $DOTNET_LTS_CHANNEL  — LTS anterior   (SDK $DOTNET_LTS_SDK)"
    echo "  [0] Pular"
    ask "Escolha [1/2/0, padrão=1]:"
    local vchoice
    read -r vchoice || vchoice="1"

    local channel
    case "${vchoice:-1}" in
        1) channel="$DOTNET_STABLE_CHANNEL" ;;
        2) [ "$DOTNET_LTS_CHANNEL" != "none" ] \
               && channel="$DOTNET_LTS_CHANNEL" \
               || channel="$DOTNET_STABLE_CHANNEL" ;;
        0) ok ".NET ignorado"; SUMMARY[dotnet]="Ignorado"; return ;;
        *) channel="$DOTNET_STABLE_CHANNEL" ;;
    esac

    _dotnet_run_install "$channel" || { SUMMARY[dotnet]="Falhou"; return; }
    _dotnet_validate               || { SUMMARY[dotnet]="Instalado (validação falhou)"; return; }

    local ver
    ver=$("${DOTNET_ROOT:-$HOME/.dotnet}/dotnet" --version 2>/dev/null || echo "?")
    ok ".NET $ver instalado com sucesso"
    SUMMARY[dotnet]="Instalado ($ver)"
}

# ════════════════════════════════════════════════════════════════════════════════
#  FERRAMENTAS OPCIONAIS
# ════════════════════════════════════════════════════════════════════════════════

# ── VS CODE ───────────────────────────────────────────────────────────────────
install_vscode() {
    header "Visual Studio Code"

    if command -v code >/dev/null 2>&1; then
        local ver; ver=$(code --version 2>/dev/null | head -1)
        ok "VS Code já instalado ($ver)"
        ask "Deseja atualizar/reinstalar? [s/N]:"
        local resp; read -r resp || resp="n"
        [[ "${resp,,}" =~ ^s ]] || { SUMMARY[vscode]="Mantido ($ver)"; return; }
    fi

    log "Instalando VS Code (repositório oficial Microsoft)..."
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor \
        | sudo tee /etc/apt/trusted.gpg.d/microsoft-vscode.gpg > /dev/null

    echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/repos/code stable main" \
        | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

    sudo apt update -y
    sudo apt install -y code

    if command -v code >/dev/null 2>&1; then
        local ver; ver=$(code --version 2>/dev/null | head -1)
        ok "VS Code instalado ($ver)"
        SUMMARY[vscode]="Instalado ($ver)"
    else
        warn "VS Code instalado mas 'code' não está no PATH. Reinicie a sessão."
        SUMMARY[vscode]="Instalado (reinicie a sessão para usar 'code')"
    fi

    _install_vscode_extensions
}

_install_vscode_extensions() {
    command -v code >/dev/null 2>&1 || {
        warn "VS Code não disponível no PATH. Extensões serão ignoradas."
        return
    }

    echo ""
    ask "Instalar extensões C# recomendadas para o VS Code? [s/N]:"
    local resp; read -r resp || resp="n"
    [[ "${resp,,}" =~ ^s ]] || { ok "Extensões ignoradas"; return; }

    header "Extensões do VS Code"

    declare -A EXTS=(
        [1]="ms-dotnettools.csdevkit|C# Dev Kit (Microsoft)"
        [2]="ms-dotnettools.csharp|C#"
        [3]="ms-dotnettools.vscode-dotnet-runtime|.NET Install Tool"
        [4]="VisualStudioExptTeam.vscodeintellicode|IntelliCode"
        [5]="eamodio.gitlens|GitLens"
        [6]="PKief.material-icon-theme|Material Icon Theme"
    )

    echo "  [1] C# Dev Kit (Microsoft)"
    echo "  [2] C#"
    echo "  [3] .NET Install Tool"
    echo "  [4] IntelliCode"
    echo "  [5] GitLens"
    echo "  [6] Material Icon Theme"
    echo "  [7] Instalar Todas"
    echo "  [0] Pular"
    ask "Escolha (ex: 1 3 5  ou  7 para todas):"
    local input; read -r input || input="0"

    local to_install=()
    if echo "$input" | grep -qw "0"; then
        ok "Extensões ignoradas"; return
    elif echo "$input" | grep -qw "7"; then
        to_install=(1 2 3 4 5 6)
    else
        for n in $input; do
            [[ "$n" =~ ^[1-6]$ ]] && to_install+=("$n")
        done
    fi

    local ext_summary=""
    for n in "${to_install[@]}"; do
        local entry="${EXTS[$n]}"
        local ext_id="${entry%%|*}"
        local ext_name="${entry##*|}"

        if code --list-extensions 2>/dev/null | grep -qi "^${ext_id}$"; then
            ok "$ext_name já instalada"
            ext_summary+="  ✅ $ext_name (já instalada)\n"
            continue
        fi

        log "Instalando: $ext_name ..."
        if code --install-extension "$ext_id" 2>/dev/null; then
            ok "$ext_name instalada"
            ext_summary+="  ✅ $ext_name\n"
        else
            warn "Falha ao instalar $ext_name"
            ext_summary+="  ⚠️  $ext_name (falhou)\n"
        fi
    done

    SUMMARY[vscode_extensions]="$ext_summary"
}

# ── GOOGLE CHROME ─────────────────────────────────────────────────────────────
install_chrome() {
    header "Google Chrome"

    if command -v google-chrome >/dev/null 2>&1 \
    || command -v google-chrome-stable >/dev/null 2>&1; then
        local ver
        ver=$(google-chrome --version 2>/dev/null \
              || google-chrome-stable --version 2>/dev/null \
              || echo "?")
        ok "Chrome já instalado ($ver)"
        ask "Deseja reinstalar? [s/N]:"
        local resp; read -r resp || resp="n"
        [[ "${resp,,}" =~ ^s ]] || { SUMMARY[chrome]="Mantido ($ver)"; return; }
    fi

    log "Baixando Google Chrome (dl.google.com — oficial)..."
    local deb="$SETUP_TMP/google-chrome.deb"
    if ! curl -fsSL \
        "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
        -o "$deb"; then
        err "Falha no download do Chrome."
        SUMMARY[chrome]="Falhou"
        return
    fi

    sudo apt install -y "$deb" 2>/dev/null \
        || { sudo dpkg -i "$deb" 2>/dev/null; sudo apt-get install -f -y; }

    local ver
    ver=$(google-chrome-stable --version 2>/dev/null || echo "?")
    ok "Chrome instalado ($ver)"
    SUMMARY[chrome]="Instalado ($ver)"
}

# ── POSTMAN ───────────────────────────────────────────────────────────────────
install_postman() {
    header "Postman"

    if command -v postman >/dev/null 2>&1 || [ -d /opt/Postman ]; then
        ok "Postman já instalado"
        ask "Deseja reinstalar? [s/N]:"
        local resp; read -r resp || resp="n"
        [[ "${resp,,}" =~ ^s ]] || { SUMMARY[postman]="Mantido"; return; }
        sudo rm -rf /opt/Postman
    fi

    log "Baixando Postman (dl.pstmn.io — oficial)..."
    local archive="$SETUP_TMP/postman.tar.gz"
    if ! curl -fsSL "https://dl.pstmn.io/download/latest/linux64" -o "$archive"; then
        err "Falha no download do Postman."
        SUMMARY[postman]="Falhou"
        return
    fi

    log "Instalando em /opt/Postman..."
    sudo tar -xzf "$archive" -C /opt/
    sudo ln -sf /opt/Postman/Postman /usr/local/bin/postman

    # Atalho no menu de aplicativos
    cat > "$SETUP_TMP/postman.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Postman
Icon=/opt/Postman/app/resources/app/assets/icon.png
Exec=/opt/Postman/Postman
Categories=Development;
EOF
    sudo mv "$SETUP_TMP/postman.desktop" /usr/share/applications/postman.desktop

    ok "Postman instalado"
    SUMMARY[postman]="Instalado"
}

# ── BURP SUITE COMMUNITY ──────────────────────────────────────────────────────
install_burpsuite() {
    header "Burp Suite Community Edition"

    if command -v burpsuite >/dev/null 2>&1 \
    || [ -f /usr/local/bin/burpsuite ]; then
        ok "Burp Suite já instalado"
        ask "Deseja reinstalar? [s/N]:"
        local resp; read -r resp || resp="n"
        [[ "${resp,,}" =~ ^s ]] || { SUMMARY[burpsuite]="Mantido"; return; }
    fi

    log "Baixando Burp Suite Community (portswigger.net — oficial)..."
    local installer="$SETUP_TMP/burpsuite_installer.sh"
    if ! curl -fsSL -L \
        "https://portswigger.net/burp/releases/download?product=community&type=Linux" \
        -o "$installer"; then
        err "Falha no download do Burp Suite."
        SUMMARY[burpsuite]="Falhou"
        return
    fi
    chmod +x "$installer"

    log "Executando instalador (modo silencioso, destino: /opt/BurpSuiteCommunity)..."
    sudo "$installer" -q -dir /opt/BurpSuiteCommunity 2>/dev/null || {
        warn "Modo silencioso falhou — abrindo instalador interativo..."
        sudo "$installer"
    }

    if [ -f /opt/BurpSuiteCommunity/BurpSuiteCommunity ]; then
        sudo ln -sf /opt/BurpSuiteCommunity/BurpSuiteCommunity \
                    /usr/local/bin/burpsuite
        ok "Burp Suite instalado (/opt/BurpSuiteCommunity)"
        SUMMARY[burpsuite]="Instalado"
    else
        warn "Instalação concluída. Verifique o diretório /opt/BurpSuiteCommunity"
        SUMMARY[burpsuite]="Instalado (verifique o diretório)"
    fi
}

# ── TOR BROWSER ───────────────────────────────────────────────────────────────
_get_tor_latest_version() {
    # API oficial do Tor Project — retorna versão e URL do binário Linux64
    cat > "$SETUP_TMP/get_tor_ver.py" << 'PYEOF'
import urllib.request, json, sys

try:
    url = "https://aus1.torproject.org/torbrowser/update_3/release/downloads.json"
    with urllib.request.urlopen(url, timeout=15) as r:
        data = json.load(r)
    ver = data.get("version", "")
    dl  = (data.get("downloads", {})
               .get("linux64", {})
               .get("en-US", {})
               .get("binary", ""))
    print(ver, dl)
except Exception:
    sys.exit(1)
PYEOF
    python3 "$SETUP_TMP/get_tor_ver.py" 2>/dev/null || echo ""
}

install_tor() {
    header "Tor Browser"

    if [ -d "$HOME/.local/share/torbrowser" ] || [ -d /opt/tor-browser ]; then
        ok "Tor Browser já instalado"
        ask "Deseja reinstalar? [s/N]:"
        local resp; read -r resp || resp="n"
        [[ "${resp,,}" =~ ^s ]] || { SUMMARY[tor]="Mantido"; return; }
        rm -rf /opt/tor-browser "$HOME/.local/share/torbrowser"
    fi

    log "Detectando versão mais recente do Tor Browser (torproject.org)..."
    local tor_info
    tor_info=$(_get_tor_latest_version)
    local tor_ver; tor_ver=$(echo "$tor_info" | awk '{print $1}')
    local tor_url; tor_url=$(echo "$tor_info" | awk '{print $2}')

    if [ -z "$tor_ver" ] || [ -z "$tor_url" ]; then
        err "Não foi possível detectar versão do Tor Browser."
        warn "Acesse: https://www.torproject.org/download/"
        SUMMARY[tor]="Falhou (API indisponível)"
        return
    fi

    ok "Versão detectada: $tor_ver"
    log "Baixando de: $tor_url"

    local archive="$SETUP_TMP/tor-browser.tar.xz"
    if ! curl -fsSL "$tor_url" -o "$archive"; then
        err "Falha no download do Tor Browser."
        SUMMARY[tor]="Falhou"
        return
    fi

    log "Instalando em /opt/tor-browser..."
    sudo mkdir -p /opt/tor-browser
    sudo tar -xJf "$archive" --strip-components=1 -C /opt/tor-browser

    # Arquivo .desktop para o menu de aplicativos
    if [ -f /opt/tor-browser/Browser/start-tor-browser.desktop ]; then
        sudo cp /opt/tor-browser/Browser/start-tor-browser.desktop \
                /usr/share/applications/tor-browser.desktop
        sudo sed -i \
            's|Exec=.*|Exec=/opt/tor-browser/Browser/start-tor-browser %u|' \
            /usr/share/applications/tor-browser.desktop
    fi

    # Lançador no PATH
    sudo tee /usr/local/bin/tor-browser > /dev/null << 'EOF'
#!/usr/bin/env bash
exec /opt/tor-browser/Browser/start-tor-browser "$@"
EOF
    sudo chmod +x /usr/local/bin/tor-browser

    ok "Tor Browser $tor_ver instalado"
    SUMMARY[tor]="Instalado ($tor_ver)"
}

# ── MENU DE FERRAMENTAS ───────────────────────────────────────────────────────
show_tools_menu() {
    header "Ferramentas Opcionais"
    echo ""
    echo "  [1] Visual Studio Code  (+ extensões C#)"
    echo "  [2] Google Chrome"
    echo "  [3] Postman"
    echo "  [4] Burp Suite Community Edition"
    echo "  [5] Tor Browser"
    echo ""
    echo "  [6] Instalar Todas"
    echo "  [0] Pular"
    echo ""
    ask "Escolha (ex: 1 3  ou  6 para todas):"
    local input; read -r input || input="0"

    if [[ "${input:-0}" == "0" ]]; then
        ok "Ferramentas opcionais ignoradas"
        return
    fi

    local items=()
    if echo "$input" | grep -qw "6"; then
        items=(1 2 3 4 5)
    else
        for n in $input; do
            [[ "$n" =~ ^[1-5]$ ]] && items+=("$n")
        done
    fi

    # Cada instalação é isolada — falha individual não para as demais
    for item in "${items[@]}"; do
        case "$item" in
            1) install_vscode    || warn "Falha na instalação do VS Code" ;;
            2) install_chrome    || warn "Falha na instalação do Chrome" ;;
            3) install_postman   || warn "Falha na instalação do Postman" ;;
            4) install_burpsuite || warn "Falha na instalação do Burp Suite" ;;
            5) install_tor       || warn "Falha na instalação do Tor Browser" ;;
        esac
    done
}

# ── RESUMO FINAL ──────────────────────────────────────────────────────────────
show_summary() {
    header "Resumo da Instalação"
    echo ""
    echo -e "  Sistema: ${BOLD}$DISTRO $VERSION${NC}"
    echo ""

    _summary_line() {
        local label="$1" key="$2"
        [ -n "${SUMMARY[$key]+x}" ] || return
        echo -e "  ${BOLD}$label${NC}"
        echo -e "    ${SUMMARY[$key]}"
        echo ""
    }

    _summary_line ".NET SDK"           dotnet
    _summary_line "Visual Studio Code" vscode
    _summary_line "Extensões VS Code"  vscode_extensions
    _summary_line "Google Chrome"      chrome
    _summary_line "Postman"            postman
    _summary_line "Burp Suite"         burpsuite
    _summary_line "Tor Browser"        tor

    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo ""
    ok "Ambiente configurado com sucesso!"
    echo ""
    echo "  ► Reabra o terminal ou execute: exec zsh"
    echo "  ► .NET: source ~/.zshrc && dotnet --info"
    echo "  ► Backup do .zshrc original: ~/.zshrc.bak"
    echo ""
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    header "Setup do Ambiente de Desenvolvimento"

    detect_system
    install_deps
    install_node
    install_zsh        # Inclui _configure_zshrc (Python) + _validate_zsh_config
    install_pyenv
    install_python310
    install_nvim

    install_dotnet
    show_tools_menu
    show_summary
}

main
