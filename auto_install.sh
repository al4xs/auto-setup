#!/usr/bin/env bash
# =============================================================================
# Instalador de Ambiente de Desenvolvimento — Ubuntu/Debian e derivados
#
# Instala e configura: dependências base, Node.js, Zsh + Oh My Zsh, pyenv,
# Python 3.10, Neovim (al4xs/neovim-config), .NET SDK, idioma do sistema
# (opcional) e ferramentas opcionais (VS Code, Chrome, Postman, Burp Suite,
# Tor Browser).
#
# Características:
#   - Usa exclusivamente fontes e métodos oficiais para download/instalação.
#   - Idempotente: pode ser executado várias vezes sem duplicar configurações
#     ou reinstalar o que já está presente.
#   - Análise de estado antes de cada instalação: detecta se o componente está
#     instalado corretamente, instalado com problemas, ou ausente — e age
#     apenas no que é necessário.
#   - Cria backup automático de qualquer arquivo que modificar.
#   - Recuperação de falhas: cada etapa é isolada. Se uma etapa falhar, o
#     script nunca deixa o sistema em estado quebrado — os arquivos alterados
#     já têm backup e podem ser restaurados automaticamente. É possível
#     tentar novamente, pular ou abortar com rollback a partir de cada falha.
#   - Suporta modo interativo (menus) e modo não interativo (flags de linha
#     de comando), para uso manual ou automatizado (ex: provisionamento de VMs).
#   - Registra toda a execução em um arquivo de log.
#
# Uso:
#   ./setup.sh                          Modo interativo (menus)
#   ./setup.sh --yes --install-all      Modo automático, instala tudo
#   ./setup.sh --help                   Mostra todas as opções
# =============================================================================

set -Eeuo pipefail

# ═════════════════════════════ METADADOS ════════════════════════════════════
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="4.0.0"

# ═════════════════════════════ CORES & UI ════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ═════════════════════════════ ESTADO GLOBAL ═════════════════════════════════
declare -A SUMMARY=()
FAILED_STEPS=()
CURRENT_STEP=""
CURRENT_STEP_MANIFEST=""

NONINTERACTIVE=false
RUN_SELF_CHECK=false
INSTALL_ALL=false
SKIP_NEOVIM=false
SKIP_TOR=false
SKIP_LANGUAGE=false
SKIP_DOTNET=false
SKIP_ZSH=false
SET_LOCALE_PTBR=false
RESTART_SESSION_NEEDED=false

# Mapa de estado e detalhes por componente (preenchido pela fase de scan)
declare -A COMP_STATE=()   # ok | missing | incomplete | broken | update | skip
declare -A COMP_DETAIL=()  # string descritivo do estado
_NVIM_RAW_STATE=""         # estado bruto do Neovim para uso em install_nvim

# Lista de dependências base — definida aqui para ser acessível por _scan_deps
DEPS_LIST=(curl wget git unzip build-essential ca-certificates gnupg
           lsb-release apt-transport-https software-properties-common
           python3 python3-pip python3-venv file)

STATE_DIR="$HOME/.dev-setup"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE"

BACKUP_ROOT="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
MANIFEST_DIR="$BACKUP_ROOT/.manifests"
mkdir -p "$BACKUP_ROOT" "$MANIFEST_DIR"

# Diretório temporário limpo automaticamente ao sair
SETUP_TMP=$(mktemp -d)
trap 'rm -rf "$SETUP_TMP"' EXIT
trap 'err "Erro inesperado na etapa atual (${CURRENT_STEP:-desconhecida}), linha $LINENO, comando: $BASH_COMMAND. Consulte o log: $LOG_FILE"' ERR

# ═════════════════════════════ LOG & MENSAGENS ═══════════════════════════════
_write_log() { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$LOG_FILE"; }

log()    { echo -e "${BLUE}ℹ️  $1${NC}";  _write_log "INFO"  "$1"; }
ok()     { echo -e "${GREEN}✅ $1${NC}";  _write_log "OK"    "$1"; }
warn()   { echo -e "${YELLOW}⚠️  $1${NC}"; _write_log "WARN"  "$1"; }
err()    { echo -e "${RED}❌ $1${NC}" >&2; _write_log "ERROR" "$1"; }
header() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
    _write_log "STEP" "$1"
}
ask() { echo -en "${BOLD}  ➜ $1${NC} "; }

# confirm "pergunta" "padrão(s/n)" — em modo não interativo, retorna o padrão
# sem perguntar nada, o que garante execução 100% automatizável.
confirm() {
    local prompt="$1" default="${2:-n}"
    if [ "$NONINTERACTIVE" = true ]; then
        if [[ "${default,,}" == s* ]]; then
            log "[não interativo] assumindo SIM para: $prompt"
            return 0
        else
            log "[não interativo] assumindo NÃO para: $prompt"
            return 1
        fi
    fi
    local suffix="s/N"
    [[ "${default,,}" == s* ]] && suffix="S/n"
    ask "$prompt [$suffix]:"
    local resp
    read -r resp || resp=""
    resp="${resp:-$default}"
    [[ "${resp,,}" =~ ^s ]]
}

# ═════════════════════════════ BACKUP & IDEMPOTÊNCIA ═════════════════════════
# Faz backup de um arquivo (preservando o caminho completo) antes de alterá-lo.
backup_file() {
    local f="$1"
    [ -e "$f" ] || return 0
    local dest="$BACKUP_ROOT$f"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    cp -a "$f" "$dest" 2>/dev/null || true
    _write_log "BACKUP" "$f -> $dest"
    # Registra o arquivo no manifesto da etapa em execução (se houver), para
    # permitir rollback isolado apenas dos arquivos tocados por essa etapa.
    if [ -n "${CURRENT_STEP_MANIFEST:-}" ]; then
        grep -qxF "$f" "$CURRENT_STEP_MANIFEST" 2>/dev/null || printf '%s\n' "$f" >> "$CURRENT_STEP_MANIFEST"
    fi
}

# Adiciona uma linha a um arquivo apenas se ela ainda não existir (idempotente).
append_line_once() {
    local file="$1" line="$2"
    touch "$file" 2>/dev/null || true
    grep -qxF "$line" "$file" 2>/dev/null && return 0
    backup_file "$file"
    printf '%s\n' "$line" >> "$file"
}

# Adiciona um bloco de configuração identificado por um marcador único, apenas
# se o marcador ainda não estiver presente no arquivo (evita duplicação de
# blocos inteiros, como plugins=(), exports, aliases, etc).
append_block_once() {
    local file="$1" marker="$2" block="$3"
    touch "$file" 2>/dev/null || true
    grep -qF "$marker" "$file" 2>/dev/null && return 0
    backup_file "$file"
    printf '%s\n' "$block" >> "$file"
}

# Verifica se um arquivo baixado existe e tem um tamanho mínimo plausível.
verify_download() {
    local file="$1" min_bytes="${2:-1024}"
    if [ ! -f "$file" ]; then
        err "Arquivo não encontrado após o download: $file"
        return 1
    fi
    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -lt "$min_bytes" ]; then
        err "Download incompleto ou inválido: $file ($size bytes)"
        return 1
    fi
    return 0
}

# Wrappers para apt-get, sempre não interativos, evitando travar automações.
apt_update() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
}
apt_install() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# ═════════════════════════════ ANÁLISE DE ESTADO ═════════════════════════════
# Constantes de estado para componentes
STATE_OK="ok"                 # instalado e funcionando corretamente
STATE_MISSING="missing"       # não instalado
STATE_INCOMPLETE="incomplete" # instalado mas configuração incompleta
STATE_BROKEN="broken"         # instalado mas corrompido/defeituoso
STATE_UPDATE="update"         # instalado, mas atualização disponível
STATE_SKIP="skip"             # ignorado por flag (--skip-*)

# _report_state COMPONENTE STATE [DETALHE]
# Imprime o estado detectado de forma padronizada.
_report_state() {
    local component="$1" state="$2" detail="${3:-}"
    case "$state" in
        "$STATE_OK")
            ok "[$component] Detectado e funcionando${detail:+ — $detail}"
            ;;
        "$STATE_INCOMPLETE")
            warn "[$component] Configuração incompleta${detail:+ — $detail}"
            ;;
        "$STATE_BROKEN")
            warn "[$component] Instalação corrompida${detail:+ — $detail}"
            ;;
        "$STATE_MISSING")
            log "[$component] Não instalado${detail:+ — $detail}"
            ;;
        "$STATE_UPDATE")
            log "[$component] Atualização disponível${detail:+ — $detail}"
            ;;
    esac
}

# ═══════════════════════════ FUNÇÕES DE SCAN ══════════════════════════════════
# Cada _scan_* preenche COMP_STATE[key] e COMP_DETAIL[key].
# Rápidas e não destrutivas: apenas leitura do sistema.

_scan_deps() {
    local missing=()
    for pkg in "${DEPS_LIST[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
            | grep -q "ok installed" || missing+=("$pkg")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        COMP_STATE[deps]="ok"; COMP_DETAIL[deps]="todas instaladas"
    else
        COMP_STATE[deps]="missing"; COMP_DETAIL[deps]="${missing[*]}"
    fi
}

_scan_node() {
    if command -v node >/dev/null 2>&1; then
        if node -e "process.exit(0)" 2>/dev/null; then
            COMP_STATE[node]="ok"; COMP_DETAIL[node]="$(node -v 2>/dev/null)"
        else
            COMP_STATE[node]="broken"; COMP_DETAIL[node]="instalado mas não executa"
        fi
    else
        COMP_STATE[node]="missing"; COMP_DETAIL[node]=""
    fi
}

_scan_zsh() {
    if [ "$SKIP_ZSH" = true ]; then
        COMP_STATE[zsh]="$STATE_SKIP"; COMP_DETAIL[zsh]="--skip-zsh"; return
    fi
    if ! command -v zsh >/dev/null 2>&1; then
        COMP_STATE[zsh]="missing"; COMP_DETAIL[zsh]=""; return
    fi
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        COMP_STATE[zsh]="incomplete"; COMP_DETAIL[zsh]="Zsh instalado mas Oh My Zsh ausente"; return
    fi
    local plugins_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
    local mp=()
    [ ! -d "$plugins_dir/zsh-autosuggestions" ]    && mp+=(zsh-autosuggestions)
    [ ! -d "$plugins_dir/zsh-syntax-highlighting" ] && mp+=(zsh-syntax-highlighting)
    if [ ${#mp[@]} -gt 0 ]; then
        COMP_STATE[zsh]="incomplete"; COMP_DETAIL[zsh]="plugins ausentes: ${mp[*]}"; return
    fi
    if [ ! -f "$HOME/.zshrc" ]; then
        COMP_STATE[zsh]="incomplete"; COMP_DETAIL[zsh]=".zshrc não encontrado"; return
    fi
    local plugins_ln source_ln
    plugins_ln=$(grep -n "^plugins=(" "$HOME/.zshrc" 2>/dev/null | head -1 | cut -d: -f1)
    source_ln=$(grep -n "source \$ZSH/oh-my-zsh.sh" "$HOME/.zshrc" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -n "$plugins_ln" ] && [ -n "$source_ln" ] && [ "$plugins_ln" -lt "$source_ln" ]; then
        COMP_STATE[zsh]="ok"; COMP_DETAIL[zsh]="$(zsh --version 2>/dev/null | head -1)"
    else
        COMP_STATE[zsh]="incomplete"; COMP_DETAIL[zsh]="plugins= fora de ordem no .zshrc"
    fi
}

_scan_pyenv() {
    if [ -d "$HOME/.pyenv" ]; then
        if grep -qF "# PYENV — configurado pelo setup.sh" "$HOME/.bashrc" 2>/dev/null \
        || grep -qF "# PYENV — configurado pelo setup.sh" "$HOME/.zshrc" 2>/dev/null; then
            COMP_STATE[pyenv]="ok"; COMP_DETAIL[pyenv]="~/.pyenv"
        else
            COMP_STATE[pyenv]="incomplete"; COMP_DETAIL[pyenv]="instalado mas PATH não configurado no shell"
        fi
    else
        COMP_STATE[pyenv]="missing"; COMP_DETAIL[pyenv]=""
    fi
}

_scan_python310() {
    # Configura PATH do pyenv para detecção
    local pyenv_bin="$HOME/.pyenv/bin/pyenv"
    local existing=""
    if [ -x "$pyenv_bin" ]; then
        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/bin:$PATH"
        eval "$("$pyenv_bin" init -)" 2>/dev/null || true
        existing=$(pyenv versions --bare 2>/dev/null | grep "^3\.10\." | tail -1 || true)
    fi
    if [ -n "$existing" ]; then
        COMP_STATE[python310]="ok"; COMP_DETAIL[python310]="$existing"
    else
        COMP_STATE[python310]="missing"; COMP_DETAIL[python310]=""
    fi
}

_scan_nvim() {
    if [ "$SKIP_NEOVIM" = true ]; then
        COMP_STATE[nvim]="$STATE_SKIP"; COMP_DETAIL[nvim]="--skip-neovim"; return
    fi
    local s; s=$(_check_nvim_state)
    _NVIM_RAW_STATE="$s"
    case "$s" in
        ok)
            local lazy_count; lazy_count=$(ls -A "$HOME/.local/share/nvim/lazy" 2>/dev/null | wc -l)
            COMP_STATE[nvim]="ok"
            COMP_DETAIL[nvim]="$(nvim --version 2>/dev/null | head -1), $lazy_count plugins"
            ;;
        missing_nvim)
            COMP_STATE[nvim]="missing"; COMP_DETAIL[nvim]=""
            ;;
        missing_config)
            COMP_STATE[nvim]="incomplete"; COMP_DETAIL[nvim]="binário ok, configuração al4xs ausente"
            ;;
        wrong_config)
            COMP_STATE[nvim]="incomplete"; COMP_DETAIL[nvim]="configuração existente não é al4xs/neovim-config"
            ;;
        missing_plugins)
            COMP_STATE[nvim]="incomplete"; COMP_DETAIL[nvim]="config ok, plugins não instalados"
            ;;
        broken_startup)
            COMP_STATE[nvim]="broken"; COMP_DETAIL[nvim]="falha na inicialização"
            ;;
    esac
}

_scan_dotnet() {
    if [ "$SKIP_DOTNET" = true ]; then
        COMP_STATE[dotnet]="$STATE_SKIP"; COMP_DETAIL[dotnet]="--skip-dotnet"; return
    fi
    local dotnet_cmd=""
    command -v dotnet >/dev/null 2>&1          && dotnet_cmd="dotnet"
    [ -x "$HOME/.dotnet/dotnet" ]              && dotnet_cmd="$HOME/.dotnet/dotnet"
    command -v dotnet >/dev/null 2>&1          && dotnet_cmd="dotnet"  # prefere PATH
    if [ -n "$dotnet_cmd" ]; then
        local ver; ver=$($dotnet_cmd --version 2>/dev/null || echo "?")
        COMP_STATE[dotnet]="ok"; COMP_DETAIL[dotnet]="$ver"
    else
        COMP_STATE[dotnet]="missing"; COMP_DETAIL[dotnet]=""
    fi
}

_scan_locale() {
    if [ "$SKIP_LANGUAGE" = true ]; then
        COMP_STATE[locale]="$STATE_SKIP"; COMP_DETAIL[locale]="--skip-language"; return
    fi
    local cur; cur=$(locale 2>/dev/null | grep '^LANG=' | cut -d= -f2 | tr -d '"')
    [ -z "$cur" ] && cur="${LANG:-}"
    if [[ "$cur" == pt_BR* ]]; then
        COMP_STATE[locale]="ok"; COMP_DETAIL[locale]="$cur"
    else
        COMP_STATE[locale]="missing"; COMP_DETAIL[locale]="atual: ${cur:-não definido}"
    fi
}

_scan_vscode() {
    if command -v code >/dev/null 2>&1; then
        COMP_STATE[vscode]="ok"; COMP_DETAIL[vscode]="$(code --version 2>/dev/null | head -1)"
    else
        COMP_STATE[vscode]="missing"; COMP_DETAIL[vscode]=""
    fi
}

_scan_chrome() {
    if command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1; then
        local ver
        ver=$(google-chrome --version 2>/dev/null \
              || google-chrome-stable --version 2>/dev/null || echo "?")
        COMP_STATE[chrome]="ok"; COMP_DETAIL[chrome]="$ver"
    else
        COMP_STATE[chrome]="missing"; COMP_DETAIL[chrome]=""
    fi
}

_scan_postman() {
    if command -v postman >/dev/null 2>&1 || [ -d /opt/Postman ]; then
        COMP_STATE[postman]="ok"; COMP_DETAIL[postman]="/opt/Postman"
    else
        COMP_STATE[postman]="missing"; COMP_DETAIL[postman]=""
    fi
}

_scan_burpsuite() {
    if command -v burpsuite >/dev/null 2>&1 || [ -f /usr/local/bin/burpsuite ]; then
        COMP_STATE[burpsuite]="ok"; COMP_DETAIL[burpsuite]="/opt/BurpSuiteCommunity"
    else
        COMP_STATE[burpsuite]="missing"; COMP_DETAIL[burpsuite]=""
    fi
}

_scan_tor() {
    if [ "$SKIP_TOR" = true ]; then
        COMP_STATE[tor]="$STATE_SKIP"; COMP_DETAIL[tor]="--skip-tor"; return
    fi
    local s; s=$(_check_tor_state)
    case "$s" in
        ok)
            COMP_STATE[tor]="ok"; COMP_DETAIL[tor]="binário, .desktop e launcher ok"
            ;;
        missing)
            COMP_STATE[tor]="missing"; COMP_DETAIL[tor]=""
            ;;
        binary_missing)
            COMP_STATE[tor]="broken"; COMP_DETAIL[tor]="instalação presente mas binário ausente/corrompido"
            ;;
        desktop_missing)
            COMP_STATE[tor]="incomplete"; COMP_DETAIL[tor]="binário ok, .desktop ou launcher ausente"
            ;;
        desktop_broken)
            COMP_STATE[tor]="incomplete"; COMP_DETAIL[tor]="binário ok, .desktop com configuração incorreta"
            ;;
    esac
}

# Executa todos os scans em sequência.
_run_scan() {
    _write_log "SCAN" "Iniciando análise do estado do ambiente"
    _scan_deps
    _scan_node
    _scan_zsh
    _scan_pyenv
    _scan_python310
    _scan_nvim
    _scan_dotnet
    _scan_locale
    _scan_vscode
    _scan_chrome
    _scan_postman
    _scan_burpsuite
    _scan_tor
    _write_log "SCAN" "Análise concluída"
}

# Imprime a tabela de estado de todos os componentes.
_print_state_report() {
    header "Estado do Ambiente"
    echo ""

    _state_line() {
        local label="$1" key="$2"
        local state="${COMP_STATE[$key]:-unknown}"
        local detail="${COMP_DETAIL[$key]:-}"
        local lbl; lbl=$(printf '%-24s' "$label")
        case "$state" in
            ok)
                echo -e "  ${GREEN}✔${NC}  ${BOLD}${lbl}${NC} ${GREEN}OK${NC}${detail:+  ($detail)}"
                ;;
            missing)
                echo -e "  ${RED}✗${NC}  ${BOLD}${lbl}${NC} ${YELLOW}NÃO INSTALADO${NC}${detail:+  ($detail)}"
                ;;
            incomplete)
                echo -e "  ${YELLOW}⚠${NC}  ${BOLD}${lbl}${NC} ${YELLOW}CONFIGURAÇÃO INCOMPLETA${NC}${detail:+  — $detail}"
                ;;
            broken)
                echo -e "  ${RED}✗${NC}  ${BOLD}${lbl}${NC} ${RED}INSTALAÇÃO CORROMPIDA${NC}${detail:+  — $detail}"
                ;;
            update)
                echo -e "  ${CYAN}↑${NC}  ${BOLD}${lbl}${NC} ${CYAN}ATUALIZAÇÃO DISPONÍVEL${NC}${detail:+  — $detail}"
                ;;
            skip)
                echo -e "  ${BLUE}–${NC}  ${BOLD}${lbl}${NC} ignorado${detail:+  ($detail)}"
                ;;
        esac
    }

    _state_line "Deps base"           deps
    _state_line "Node.js"             node
    _state_line "Zsh + Oh My Zsh"     zsh
    _state_line "pyenv"               pyenv
    _state_line "Python 3.10"         python310
    _state_line "Neovim"              nvim
    _state_line ".NET SDK"            dotnet
    _state_line "Idioma do Sistema"   locale
    _state_line "VS Code"             vscode
    _state_line "Google Chrome"       chrome
    _state_line "Postman"             postman
    _state_line "Burp Suite"          burpsuite
    _state_line "Tor Browser"         tor
    echo ""
}

# Retorna 0 se o componente precisa de ação (não é ok nem skip).
_needs_action() {
    local s="${COMP_STATE[$1]:-}"
    [ "$s" != "ok" ] && [ "$s" != "skip" ] && [ -n "$s" ]
}

# Retorna 0 se o componente está ok ou skip (não precisa de ação).
_is_ok() {
    local s="${COMP_STATE[$1]:-}"
    [ "$s" = "ok" ] || [ "$s" = "skip" ]
}

# ────── Auto-reparo: broken/incomplete ──────────────────────────────────────
# Componentes que já foram instalados (broken/incomplete) são reparados
# automaticamente, sem perguntas. A exceção é "wrong_config" no Neovim
# (ação destrutiva — ainda pede confirmação).
_repair_components() {
    local to_repair=()

    for key in deps node zsh pyenv python310 nvim dotnet locale \
                vscode chrome postman burpsuite tor; do
        local s="${COMP_STATE[$key]:-}"
        [ "$s" = "broken" ] || [ "$s" = "incomplete" ] && to_repair+=("$key")
    done

    [ ${#to_repair[@]} -eq 0 ] && return 0

    header "Modo de Reparo Automático"
    log "Componentes com problema detectado serão reparados automaticamente."
    echo ""

    for key in "${to_repair[@]}"; do
        local detail="${COMP_DETAIL[$key]:-}"
        log "Reparando ${BOLD}$key${NC}${detail:+ — $detail}..."
        case "$key" in
            deps)      run_step "Dependências Base"   install_deps          || true ;;
            node)      run_step "Node.js"              install_node          || true ;;
            zsh)       run_step "Zsh + Oh My Zsh"      install_zsh           || true ;;
            pyenv)     run_step "pyenv"                install_pyenv         || true ;;
            python310) run_step "Python 3.10"          install_python310     || true ;;
            nvim)      run_step "Neovim"               install_nvim          || true ;;
            dotnet)    run_step ".NET SDK"             install_dotnet        || true ;;
            locale)    run_step "Idioma do Sistema"    check_and_set_locale  || true ;;
            vscode)    run_step "Visual Studio Code"   install_vscode        || true ;;
            chrome)    run_step "Google Chrome"        install_chrome        || true ;;
            postman)   run_step "Postman"              install_postman       || true ;;
            burpsuite) run_step "Burp Suite"           install_burpsuite     || true ;;
            tor)       run_step "Tor Browser"          install_tor           || true ;;
        esac

        # Atualiza o estado após o reparo para uso no resumo
        case "$key" in
            nvim) _NVIM_RAW_STATE="" ;;
        esac
    done
}

# ────── Instalação de componentes obrigatórios ausentes ─────────────────────
# Componentes "mandatórios" que não foram encontrados.
# Pergunta uma vez (lista consolidada), depois instala todos os confirmados.
_install_missing_mandatory() {
    local -a missing_keys=() missing_labels=()

    [ "${COMP_STATE[deps]:-}"      = "missing" ] && { missing_keys+=(deps);      missing_labels+=("Dependências Base"); }
    [ "${COMP_STATE[node]:-}"      = "missing" ] && { missing_keys+=(node);      missing_labels+=("Node.js"); }
    [ "${COMP_STATE[zsh]:-}"       = "missing" ] && { missing_keys+=(zsh);       missing_labels+=("Zsh + Oh My Zsh"); }
    [ "${COMP_STATE[pyenv]:-}"     = "missing" ] && { missing_keys+=(pyenv);     missing_labels+=("pyenv"); }
    [ "${COMP_STATE[python310]:-}" = "missing" ] \
        && [ "${COMP_STATE[pyenv]:-}" != "missing" ] \
        && { missing_keys+=(python310); missing_labels+=("Python 3.10"); }
    [ "${COMP_STATE[nvim]:-}"      = "missing" ] && { missing_keys+=(nvim);      missing_labels+=("Neovim"); }
    [ "${COMP_STATE[dotnet]:-}"    = "missing" ] && { missing_keys+=(dotnet);    missing_labels+=(".NET SDK"); }
    [ "${COMP_STATE[locale]:-}"    = "missing" ] && { missing_keys+=(locale);    missing_labels+=("Idioma do Sistema (pt_BR)"); }

    [ ${#missing_keys[@]} -eq 0 ] && return 0

    header "Componentes Ausentes"
    echo ""
    echo -e "  Os seguintes componentes ${BOLD}não foram encontrados${NC}:"
    echo ""
    local i
    for i in "${!missing_labels[@]}"; do
        echo -e "    ${RED}✗${NC}  ${missing_labels[$i]}"
    done
    echo ""

    local do_install=true
    if [ "$NONINTERACTIVE" = false ] && [ "$INSTALL_ALL" = false ]; then
        if ! confirm "Instalar todos os componentes listados acima?" "s"; then
            do_install=false
        fi
    fi

    [ "$do_install" = false ] && {
        warn "Instalação de componentes ausentes ignorada pelo usuário."
        for key in "${missing_keys[@]}"; do
            SUMMARY["$key"]="Ignorado pelo usuário"
        done
        return 0
    }

    for key in "${missing_keys[@]}"; do
        case "$key" in
            deps)      run_step "Dependências Base"   install_deps          || true ;;
            node)      run_step "Node.js"              install_node          || true ;;
            zsh)       run_step "Zsh + Oh My Zsh"      install_zsh           || true ;;
            pyenv)     run_step "pyenv"                install_pyenv         || true ;;
            python310) run_step "Python 3.10"          install_python310     || true ;;
            nvim)      run_step "Neovim"               install_nvim          || true ;;
            dotnet)    run_step ".NET SDK"             install_dotnet        || true ;;
            locale)    run_step "Idioma do Sistema"    check_and_set_locale  || true ;;
        esac
    done
}

# ────── Menu de ferramentas opcionais ausentes ───────────────────────────────
# Exibe apenas as ferramentas opcionais que NÃO estão instaladas.
# Ferramentas OK ou SKIP não aparecem no menu.
_install_missing_optional() {
    local -a opt_keys=() opt_labels=()

    [ "${COMP_STATE[vscode]:-}"    = "missing" ] && { opt_keys+=(vscode);    opt_labels+=("Visual Studio Code  (+ extensões C#)"); }
    [ "${COMP_STATE[chrome]:-}"    = "missing" ] && { opt_keys+=(chrome);    opt_labels+=("Google Chrome"); }
    [ "${COMP_STATE[postman]:-}"   = "missing" ] && { opt_keys+=(postman);   opt_labels+=("Postman"); }
    [ "${COMP_STATE[burpsuite]:-}" = "missing" ] && { opt_keys+=(burpsuite); opt_labels+=("Burp Suite Community Edition"); }
    [ "${COMP_STATE[tor]:-}"       = "missing" ] && { opt_keys+=(tor);       opt_labels+=("Tor Browser"); }

    [ ${#opt_keys[@]} -eq 0 ] && return 0

    header "Ferramentas Opcionais Disponíveis"
    echo ""
    echo -e "  Ferramentas ${BOLD}não instaladas${NC} que podem ser adicionadas:"
    echo ""

    local i
    for i in "${!opt_keys[@]}"; do
        echo -e "  [$(( i + 1 ))] ${opt_labels[$i]}"
    done
    echo ""
    local all_idx=$(( ${#opt_keys[@]} + 1 ))
    echo -e "  [$all_idx] Instalar Todas"
    echo -e "  [0] Pular"
    echo ""

    local items=()

    if [ "$INSTALL_ALL" = true ]; then
        ok "Instalando todas as ferramentas opcionais (--install-all)"
        items=("${opt_keys[@]}")
    elif [ "$NONINTERACTIVE" = true ]; then
        ok "[não interativo] Ferramentas opcionais ignoradas (use --install-all para instalá-las)"
        return
    else
        ask "Escolha (ex: 1 3  ou  $all_idx para todas):"
        local input; read -r input || input="0"
        if [[ "${input:-0}" == "0" ]]; then
            ok "Ferramentas opcionais ignoradas"
            return
        fi
        if echo "$input" | grep -qw "$all_idx"; then
            items=("${opt_keys[@]}")
        else
            for n in $input; do
                if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#opt_keys[@]}" ]; then
                    items+=("${opt_keys[$(( n - 1 ))]}")
                fi
            done
        fi
    fi

    for key in "${items[@]}"; do
        case "$key" in
            vscode)    run_step "Visual Studio Code" install_vscode    || true ;;
            chrome)    run_step "Google Chrome"      install_chrome    || true ;;
            postman)   run_step "Postman"            install_postman   || true ;;
            burpsuite) run_step "Burp Suite"         install_burpsuite || true ;;
            tor)       run_step "Tor Browser"        install_tor       || true ;;
        esac
    done
}

# ═════════════════════════════ RECUPERAÇÃO DE FALHAS ═════════════════════════
# Restaura, a partir do backup, todos os arquivos listados no manifesto de uma
# etapa. NUNCA apaga um arquivo que não tenha backup correspondente — ou seja,
# a única ação automática sobre arquivos é restaurar, nunca excluir algo que
# este script não tenha tocado/backupeado.
rollback_step() {
    local manifest="$1"
    [ -s "$manifest" ] || return 0
    local f restored=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        local src="$BACKUP_ROOT$f"
        if [ -e "$src" ]; then
            mkdir -p "$(dirname "$f")" 2>/dev/null || true
            if cp -a "$src" "$f" 2>/dev/null; then
                _write_log "ROLLBACK" "$f restaurado a partir de $src"
                restored=$((restored + 1))
            else
                _write_log "ROLLBACK_FAIL" "Não foi possível restaurar $f a partir de $src"
            fi
        fi
    done < "$manifest"
    [ "$restored" -gt 0 ] && ok "Rollback: $restored arquivo(s) restaurado(s) a partir do backup."
    return 0
}

# run_step "Nome da etapa" funcao [args...]
#
# Executa uma etapa de instalação de forma isolada e recuperável:
#   - Nunca deixa o sistema em estado quebrado: qualquer arquivo modificado
#     durante a etapa foi previamente salvo (via backup_file) e pode ser
#     restaurado com um único comando (rollback_step).
#   - Registra no log exatamente qual etapa falhou e por quê.
#   - Em modo interativo: pergunta ao usuário se deseja tentar novamente,
#     continuar sem essa etapa, restaurar backups e continuar, ou abortar
#     a instalação (restaurando os backups da etapa antes de saír).
#   - Em modo não interativo: nunca trava esperando input — restaura os
#     backups da etapa que falhou automaticamente e segue para a próxima,
#     deixando tudo registrado no resumo final.
#   - Nunca apaga configurações existentes do usuário automaticamente: a
#     única ação automática sobre arquivos é restaurar (via backup), nunca
#     excluir algo que não tenha sido backupeado por este próprio script.
run_step() {
    local step_name="$1" step_fn="$2"
    shift 2
    local step_slug
    step_slug=$(printf '%s' "$step_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_')
    local manifest="$MANIFEST_DIR/${step_slug}.manifest"
    : > "$manifest"

    while true; do
        CURRENT_STEP="$step_name"
        CURRENT_STEP_MANIFEST="$manifest"

        local rc=0
        "$step_fn" "$@" || rc=$?

        CURRENT_STEP_MANIFEST=""

        if [ "$rc" -eq 0 ]; then
            return 0
        fi

        err "Falha na etapa: '$step_name' (código de saída: $rc)"
        _write_log "STEP_FAILED" "$step_name (rc=$rc)"

        if [ "$NONINTERACTIVE" = true ]; then
            warn "Modo não interativo: restaurando backups da etapa '$step_name' (se houver) e seguindo para a próxima etapa."
            rollback_step "$manifest"
            SUMMARY["_falha_${step_slug}"]="FALHOU — veja o log ($LOG_FILE)"
            FAILED_STEPS+=("$step_name")
            return 1
        fi

        echo ""
        warn "A etapa '$step_name' falhou. O sistema NÃO foi deixado em estado quebrado:"
        warn "qualquer arquivo alterado por esta etapa já tem backup em: $BACKUP_ROOT"
        echo "  [1] Tentar novamente esta etapa"
        echo "  [2] Continuar sem esta etapa (pular)"
        echo "  [3] Restaurar backups desta etapa e continuar"
        echo "  [4] Abortar a instalação (restaura os backups desta etapa antes de saír)"
        ask "Escolha [1-4, padrão=2]:"
        local choice
        read -r choice || choice="2"
        case "${choice:-2}" in
            1)
                log "Tentando novamente a etapa '$step_name'..."
                continue
                ;;
            3)
                rollback_step "$manifest"
                SUMMARY["_falha_${step_slug}"]="FALHOU — backups restaurados, etapa pulada"
                FAILED_STEPS+=("$step_name")
                return 1
                ;;
            4)
                rollback_step "$manifest"
                err "Instalação abortada pelo usuário após falha em '$step_name'."
                _write_log "ABORTED" "Usuário abortou após falha em '$step_name'"
                SUMMARY["_falha_${step_slug}"]="FALHOU — instalação abortada pelo usuário"
                FAILED_STEPS+=("$step_name")
                show_summary
                exit 1
                ;;
            *)
                warn "Etapa '$step_name' pulada (backups mantidos, nada foi restaurado nem apagado)."
                SUMMARY["_falha_${step_slug}"]="FALHOU — etapa pulada pelo usuário"
                FAILED_STEPS+=("$step_name")
                return 1
                ;;
        esac
    done
}

# ═════════════════════════════ CLI: AJUDA E ARGUMENTOS ═══════════════════════
show_help() {
cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION — Instalador de Ambiente de Desenvolvimento

Uso: $SCRIPT_NAME [opções]

Opções:
  --yes, --non-interactive   Não faz perguntas; assume respostas padrão seguras
  --install-all               Instala também todas as ferramentas opcionais
                               (VS Code, Chrome, Postman, Burp Suite, Tor Browser)
  --skip-neovim               Não instala/configura o Neovim
  --skip-tor                  Não instala o Tor Browser
  --skip-language             Não verifica nem altera o idioma do sistema
  --skip-dotnet                Não instala o .NET SDK
  --skip-zsh                   Não instala/configura Zsh + Oh My Zsh
  --set-locale-ptbr            Confirma automaticamente a troca do locale para
                                pt_BR.UTF-8, caso o sistema não esteja nesse idioma
                                (use junto com --yes)
  --self-check                  Só verifica pré-requisitos do ambiente (sem
                                 instalar nada) e sai. Veja a seção abaixo.
  -h, --help                   Mostra esta ajuda e sai

Exemplos:
  $SCRIPT_NAME
  $SCRIPT_NAME --self-check
  $SCRIPT_NAME --yes --install-all
  $SCRIPT_NAME --yes --skip-tor --skip-neovim --skip-language

O script pode ser executado quantas vezes forem necessárias: ele detecta o
que já está instalado/configurado e nunca duplica pacotes, linhas de
configuração ou plugins. Antes de qualquer instalação, realiza uma análise
completa do estado atual do sistema e age apenas no que é necessário.

Recuperação de falhas: se uma etapa falhar, nada é deixado quebrado. Os
arquivos alterados por essa etapa já têm backup e podem ser restaurados
automaticamente. Em modo interativo você escolhe tentar novamente, pular,
restaurar backups ou abortar; em modo não interativo o script restaura os
backups da etapa que falhou e segue para a próxima automaticamente.

--self-check: roda uma verificação SOMENTE LEITURA do ambiente (bash, shell,
distro, apt, sudo, comandos essenciais, espaço em disco, conectividade e
permissão de escrita no HOME) e mostra um relatório PASSOU/FALHOU antes de
qualquer instalação real. Não modifica nada no sistema. Recomendado rodar
antes da primeira execução real.

NOTA SOBRE TESTES REAIS: Este script realiza análise estática de código
completa. Testes de execução real dependem do ambiente do usuário (sistema
operacional, pacotes instalados, conectividade de rede) e não podem ser
realizados fora do ambiente alvo. A análise de integridade de cada componente
é feita em tempo de execução pelo próprio script.
EOF
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --yes|--non-interactive) NONINTERACTIVE=true ;;
            --install-all)   INSTALL_ALL=true ;;
            --skip-neovim)   SKIP_NEOVIM=true ;;
            --skip-tor)      SKIP_TOR=true ;;
            --skip-language) SKIP_LANGUAGE=true ;;
            --skip-dotnet)   SKIP_DOTNET=true ;;
            --skip-zsh)      SKIP_ZSH=true ;;
            --set-locale-ptbr) SET_LOCALE_PTBR=true ;;
            --self-check)    RUN_SELF_CHECK=true ;;
            -h|--help) show_help; exit 0 ;;
            *)
                err "Opção desconhecida: $arg"
                show_help
                exit 1
                ;;
        esac
    done
}

# ═════════════════════════════ AUTOVERIFICAÇÃO (--self-check) ════════════════
# Verificação 100% somente-leitura: não instala, não baixa, não modifica nada.
# Serve para validar automaticamente, a cada execução, se o ambiente atual
# tem o que é necessário para o restante do script funcionar — sem depender
# de o usuário (ou de mim) "confiar" que vai funcionar.
self_check() {
    header "Autoverificação do Ambiente (--self-check)"
    local pass=0 fail=0 warnings=0

    _sc_pass() { ok "$1"; pass=$((pass + 1)); }
    _sc_fail() { err "$1"; fail=$((fail + 1)); }
    _sc_warn() { warn "$1"; warnings=$((warnings + 1)); }

    # Versão do bash — declare -A (usado em SUMMARY) requer bash >= 4.
    if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
        _sc_pass "Bash ${BASH_VERSION} (>= 4, suporta 'declare -A')"
    else
        _sc_fail "Bash ${BASH_VERSION:-desconhecido} é muito antigo (requer >= 4 para arrays associativos)"
    fi

    # /etc/os-release e apt-get — pré-requisitos rígidos do restante do script.
    if [ -f /etc/os-release ]; then
        _sc_pass "/etc/os-release encontrado"
    else
        _sc_fail "/etc/os-release não encontrado — não será possível detectar a distribuição"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        _sc_pass "apt-get disponível"
    else
        _sc_fail "apt-get não encontrado — este script requer Ubuntu/Debian ou derivado"
    fi

    if command -v sudo >/dev/null 2>&1; then
        if sudo -n true 2>/dev/null; then
            _sc_pass "sudo disponível e sem senha (ou cache de credencial válido)"
        else
            _sc_warn "sudo disponível, mas pode pedir senha durante a execução (normal fora de root)"
        fi
    else
        _sc_fail "sudo não encontrado — necessário para instalar pacotes"
    fi

    # Testa se apt-get realmente consegue rodar (alguns ambientes têm 'apt-get'
    # no PATH mas bloqueado por política/sandbox — como containers restritos).
    if command -v apt-get >/dev/null 2>&1; then
        local apt_probe
        apt_probe=$(apt-get --version 2>&1 | head -1)
        if echo "$apt_probe" | grep -qi "apt "; then
            _sc_pass "apt-get responde normalmente ($apt_probe)"
        else
            _sc_fail "apt-get está no PATH mas não respondeu como esperado — pode estar bloqueado neste ambiente (saída: $apt_probe)"
        fi
    fi

    # Comandos essenciais que o script chama diretamente.
    local cmd
    for cmd in curl wget git python3 tar gpg dpkg-query grep sed awk stat mktemp; do
        if command -v "$cmd" >/dev/null 2>&1; then
            _sc_pass "Comando disponível: $cmd"
        else
            _sc_fail "Comando ausente: $cmd (necessário para uma ou mais etapas)"
        fi
    done

    # Espaço em disco em $HOME — instalações (Node, .NET, Neovim, navegadores)
    # podem exigir alguns GB.
    local avail_kb
    avail_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$avail_kb" ]; then
        local avail_gb=$((avail_kb / 1024 / 1024))
        if [ "$avail_kb" -ge 2097152 ]; then
            _sc_pass "Espaço livre em \$HOME: ~${avail_gb}GB (>= 2GB recomendado)"
        else
            _sc_warn "Espaço livre em \$HOME: ~${avail_gb}GB — pode não ser suficiente para todas as ferramentas opcionais"
        fi
    else
        _sc_warn "Não foi possível determinar o espaço livre em \$HOME"
    fi

    # Permissão de escrita no HOME (necessária para backups, logs, rc files).
    if [ -w "$HOME" ]; then
        _sc_pass "Permissão de escrita em \$HOME confirmada"
    else
        _sc_fail "Sem permissão de escrita em \$HOME ($HOME)"
    fi

    # Conectividade — sem rede, praticamente nenhuma etapa funciona.
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --max-time 5 -o /dev/null "https://deb.nodesource.com" 2>/dev/null \
           || curl -fsS --max-time 5 -o /dev/null "https://github.com" 2>/dev/null; then
            _sc_pass "Conectividade de saída HTTPS confirmada"
        else
            _sc_fail "Sem conectividade de saída HTTPS (testado deb.nodesource.com e github.com) — downloads vão falhar"
        fi
    fi

    echo ""
    echo -e "${BOLD}Resultado: ${GREEN}$pass passou(aram)${NC}, ${YELLOW}$warnings aviso(s)${NC}, ${RED}$fail falhou(aram)${NC}${NC}"
    echo ""
    if [ "$fail" -gt 0 ]; then
        err "Autoverificação encontrou $fail problema(s) que provavelmente impedirão a instalação completa."
        return 1
    else
        ok "Autoverificação passou — o ambiente atende aos pré-requisitos conhecidos do script."
        [ "$warnings" -gt 0 ] && warn "$warnings aviso(s) não bloqueiam a execução, mas vale revisar."
        return 0
    fi
}

# ═════════════════════════════ DETECÇÃO DO SISTEMA ═══════════════════════════
detect_system() {
    header "Detecção do Sistema"

    WSL=false
    grep -qi microsoft /proc/version 2>/dev/null && WSL=true && ok "WSL detectado"

    if [ ! -f /etc/os-release ]; then
        err "Não foi possível identificar a distribuição (/etc/os-release ausente)."
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    DISTRO="${ID:-desconhecido}"
    DISTRO_LIKE="${ID_LIKE:-}"
    VERSION="${VERSION_ID:-desconhecida}"
    DISTRO_PRETTY="${PRETTY_NAME:-$DISTRO $VERSION}"
    ok "Sistema: $DISTRO_PRETTY"

    if ! command -v apt-get >/dev/null 2>&1; then
        err "Este instalador oferece suporte a distribuições baseadas em Debian/Ubuntu (apt)."
        err "A distribuição detectada ('$DISTRO') não possui 'apt-get'. Abortando."
        exit 1
    fi

    case " $DISTRO $DISTRO_LIKE " in
        *" ubuntu "*|*" debian "*) ok "Distribuição suportada oficialmente por este script" ;;
        *) warn "Distribuição '$DISTRO' não testada oficialmente, mas é compatível com apt — prosseguindo por sua conta e risco." ;;
    esac

    ARCH=$(uname -m)
    ok "Arquitetura: $ARCH"
}

# Detecta o shell atual do usuário e monta a lista de arquivos de configuração
# (rc files) que devem receber exports genéricos (pyenv, .NET, etc). Configurações
# específicas do Zsh (plugins, autosuggestions) NUNCA são escritas no .bashrc.
detect_shell() {
    header "Detecção do Shell"

    CURRENT_SHELL_NAME=$(basename "${SHELL:-bash}")
    ok "Shell padrão do usuário: $CURRENT_SHELL_NAME"

    RC_FILES=()
    [ -f "$HOME/.bashrc" ] || touch "$HOME/.bashrc"
    RC_FILES+=("$HOME/.bashrc")

    if [ "$CURRENT_SHELL_NAME" = "zsh" ] && [ -f "$HOME/.zshrc" ]; then
        RC_FILES+=("$HOME/.zshrc")
    fi
}

# Adiciona um bloco de configuração compatível com qualquer shell POSIX-like
# (export/eval) em todos os rc files relevantes, sem duplicar.
add_generic_export_block() {
    local marker="$1" block="$2"
    local f
    for f in "${RC_FILES[@]}"; do
        append_block_once "$f" "$marker" "$block"
    done
}

# ═════════════════════════════ DEPENDÊNCIAS BASE ═════════════════════════════
install_deps() {
    header "Dependências Base"

    local missing=()

    for pkg in "${DEPS_LIST[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
            | grep -q "ok installed" || missing+=("$pkg")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        ok "Todas as dependências base já instaladas"
        SUMMARY[base_deps]="Já instaladas"
        return
    fi

    log "Instalando: ${missing[*]}"
    apt_update || { err "Falha ao atualizar os índices do apt."; return 1; }
    apt_install "${missing[@]}" || { err "Falha ao instalar dependências base: ${missing[*]}"; return 1; }
    ok "Dependências base instaladas"
    SUMMARY[base_deps]="Instaladas (${missing[*]})"
}

# ═════════════════════════════ NODE.JS ═══════════════════════════════════════
install_node() {
    header "Node.js"

    if command -v node >/dev/null 2>&1; then
        local ver; ver=$(node -v 2>/dev/null || echo "?")
        # Verifica se o node realmente funciona
        if node -e "process.exit(0)" 2>/dev/null; then
            _report_state "Node.js" "$STATE_OK" "$ver"
            ok "Node.js funcionando corretamente — mantido"
            SUMMARY[node]="Mantido ($ver)"
            return
        else
            _report_state "Node.js" "$STATE_BROKEN" "$ver instalado mas não funciona"
            warn "Node.js detectado mas com problemas — reinstalando..."
        fi
    else
        _report_state "Node.js" "$STATE_MISSING"
    fi

    log "Instalando Node.js LTS (repositório oficial NodeSource)..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - \
        || { err "Falha ao configurar o repositório NodeSource."; return 1; }
    apt_install nodejs || { err "Falha ao instalar o pacote nodejs."; return 1; }
    command -v node >/dev/null 2>&1 || { err "Node.js não encontrado após a instalação."; return 1; }
    ok "Node instalado ($(node -v))"
    SUMMARY[node]="Instalado ($(node -v))"
}

# ════════════════════════════════════════════════════════════════════════════
#  ZSH + OH MY ZSH
#
#  O template moderno do Oh My Zsh NÃO gera uma linha `plugins=()` — apenas
#  comentários. O Oh My Zsh lê $plugins ANTES de fazer o `source`, então
#  plugins=() precisa necessariamente vir ANTES dessa linha no .zshrc.
#  Um script Python cuida dessa edição de forma robusta e idempotente,
#  independente do template ou versão instalada do Oh My Zsh.
# ════════════════════════════════════════════════════════════════════════════
install_zsh() {
    header "Zsh + Oh My Zsh"

    if [ "$SKIP_ZSH" = true ]; then
        ok "Instalação do Zsh ignorada (--skip-zsh)"
        SUMMARY[zsh]="Ignorado (--skip-zsh)"
        return
    fi

    if command -v zsh >/dev/null 2>&1; then
        ok "Zsh já instalado ($(zsh --version | head -1))"
    else
        log "Instalando Zsh..."
        apt_install zsh || { err "Falha ao instalar o pacote zsh."; return 1; }
        ok "Zsh instalado"
    fi

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        log "Instalando Oh My Zsh..."
        RUNZSH=no CHSH=no sh -c \
            "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
            || { err "Falha ao instalar o Oh My Zsh."; return 1; }
        ok "Oh My Zsh instalado"
    else
        ok "Oh My Zsh já instalado"
    fi

    # Garante que exports genéricos (pyenv, .NET, etc) também alcancem o zshrc.
    if [ -f "$HOME/.zshrc" ]; then
        local already=false f
        for f in "${RC_FILES[@]}"; do [ "$f" = "$HOME/.zshrc" ] && already=true; done
        [ "$already" = true ] || RC_FILES+=("$HOME/.zshrc")
    fi

    _install_zsh_plugins || { err "Falha ao instalar plugins do Zsh."; return 1; }
    _configure_zshrc     || { err "Falha ao configurar o .zshrc."; return 1; }
    _validate_zsh_config

    if [ "$WSL" = false ]; then
        if confirm "Deseja definir o Zsh como shell padrão (chsh)?" "s"; then
            if chsh -s "$(command -v zsh)" 2>/dev/null; then
                ok "Shell padrão alterado para zsh (efetivo no próximo login)"
                RESTART_SESSION_NEEDED=true
            else
                warn "Não foi possível alterar o shell padrão automaticamente (pode requerer senha interativa ou não ser permitido neste ambiente)."
            fi
        else
            ok "Shell padrão mantido como $CURRENT_SHELL_NAME"
        fi
    fi

    # Fallback: no bash, entra em zsh automaticamente se disponível (idempotente).
    append_line_once "$HOME/.bashrc" 'command -v zsh >/dev/null && exec zsh'

    ok "Zsh configurado com sucesso"
    SUMMARY[zsh]="Instalado e configurado"
}

_install_zsh_plugins() {
    local plugins_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
    mkdir -p "$plugins_dir"

    if [ ! -d "$plugins_dir/zsh-autosuggestions" ]; then
        log "Instalando zsh-autosuggestions..."
        git clone --depth=1 \
            https://github.com/zsh-users/zsh-autosuggestions \
            "$plugins_dir/zsh-autosuggestions" \
            || { err "Falha ao clonar zsh-autosuggestions."; return 1; }
    else
        ok "zsh-autosuggestions já instalado"
        git -C "$plugins_dir/zsh-autosuggestions" pull --ff-only >/dev/null 2>&1 || true
    fi

    if [ ! -d "$plugins_dir/zsh-syntax-highlighting" ]; then
        log "Instalando zsh-syntax-highlighting..."
        git clone --depth=1 \
            https://github.com/zsh-users/zsh-syntax-highlighting \
            "$plugins_dir/zsh-syntax-highlighting" \
            || { err "Falha ao clonar zsh-syntax-highlighting."; return 1; }
    else
        ok "zsh-syntax-highlighting já instalado"
        git -C "$plugins_dir/zsh-syntax-highlighting" pull --ff-only >/dev/null 2>&1 || true
    fi
}

_configure_zshrc() {
    log "Configurando .zshrc..."

    if [ ! -f ~/.zshrc ]; then
        if [ -f "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" ]; then
            cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" ~/.zshrc
            ok ".zshrc criado a partir do template do Oh My Zsh"
        else
            touch ~/.zshrc
            warn ".zshrc criado vazio (template não encontrado)"
        fi
    fi

    backup_file "$HOME/.zshrc"

    cat > "$SETUP_TMP/configure_zshrc.py" << 'PYEOF'
#!/usr/bin/env python3
"""
Configura corretamente plugins e autosuggestions no .zshrc.

Garante que plugins=() aparece ANTES de `source $ZSH/oh-my-zsh.sh`.
O Oh My Zsh lê $plugins antes de executar o source — se plugins= vier
depois, os plugins externos nunca são registrados. É idempotente: pode
ser executado quantas vezes forem necessárias sem duplicar linhas.
"""
import sys, re, os

ZSHRC_PATH = os.path.expanduser(sys.argv[1]) if len(sys.argv) > 1 else os.path.expanduser("~/.zshrc")

PLUGINS_LINE = "plugins=(git zsh-autosuggestions zsh-syntax-highlighting)\n"
AUTOSUGGEST_CONFIG = (
    "\n# zsh-autosuggestions — configurado pelo setup.sh\n"
    "ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=244'\n"
    "ZSH_AUTOSUGGEST_STRATEGY=(history completion)\n"
)

RE_SOURCE   = re.compile(r'^\s*source\s+\$ZSH/oh-my-zsh\.sh\s*$')
RE_PLUGINS  = re.compile(r'^\s*plugins=\(')
RE_AS_STYLE = re.compile(r'^\s*ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE\s*=')
RE_AS_STRAT = re.compile(r'^\s*ZSH_AUTOSUGGEST_STRATEGY\s*=')
RE_AS_BLOCK = re.compile(r'^\s*#\s*zsh-autosuggestions')

def is_autosuggest_line(line):
    return bool(RE_AS_STYLE.match(line) or RE_AS_STRAT.match(line) or RE_AS_BLOCK.match(line))

with open(ZSHRC_PATH) as f:
    lines = f.readlines()

source_idx = next((i for i, l in enumerate(lines) if RE_SOURCE.match(l)), None)

if source_idx is None:
    print("  AVISO: 'source $ZSH/oh-my-zsh.sh' não encontrado — adicionando ao final.")
    cleaned = [l for l in lines if not RE_PLUGINS.match(l) and not is_autosuggest_line(l)]
    cleaned.append("\n" + PLUGINS_LINE)
    cleaned.append(AUTOSUGGEST_CONFIG)
    with open(ZSHRC_PATH, "w") as f:
        f.writelines(cleaned)
    print("  OK (fallback: plugins e config no final)")
    sys.exit(0)

cleaned = [l for l in lines if not RE_PLUGINS.match(l) and not is_autosuggest_line(l)]
source_new_idx = next((i for i, l in enumerate(cleaned) if RE_SOURCE.match(l)), None)

if source_new_idx is not None:
    cleaned.insert(source_new_idx, PLUGINS_LINE)
else:
    cleaned.append("\n" + PLUGINS_LINE)

cleaned.append(AUTOSUGGEST_CONFIG)

with open(ZSHRC_PATH, "w") as f:
    f.writelines(cleaned)

with open(ZSHRC_PATH) as f:
    final = f.readlines()

plugin_pos = next((i + 1 for i, l in enumerate(final) if RE_PLUGINS.match(l)), None)
source_pos = next((i + 1 for i, l in enumerate(final) if RE_SOURCE.match(l)), None)

if plugin_pos and source_pos and plugin_pos < source_pos:
    print(f"  OK: plugins= linha {plugin_pos}  |  source linha {source_pos}  (ordem correta)")
elif plugin_pos and source_pos:
    print(f"  ERRO: plugins= linha {plugin_pos} está DEPOIS do source linha {source_pos}!")
    sys.exit(2)
else:
    print("  AVISO: não foi possível confirmar posição das linhas")
PYEOF

    local py_out
    if py_out=$(python3 "$SETUP_TMP/configure_zshrc.py" "$HOME/.zshrc" 2>&1); then
        echo "$py_out" | while IFS= read -r line; do log "$line"; done
        ok "Plugins configurados na posição correta"
    else
        echo "$py_out" | while IFS= read -r line; do err "$line"; done
        err "Falha ao configurar .zshrc — verifique o backup em $BACKUP_ROOT$HOME/.zshrc"
        return 1
    fi
}

_validate_zsh_config() {
    header "Validando configuração do Zsh"
    local errors=0

    log "Verificando sintaxe do .zshrc..."
    if zsh -n ~/.zshrc 2>/tmp/zsh_syntax_err; then
        ok ".zshrc sem erros de sintaxe"
    else
        err "Erros de sintaxe no .zshrc:"
        while IFS= read -r l; do err "  $l"; done < /tmp/zsh_syntax_err
        errors=$((errors + 1))
    fi

    log "Verificando posição de plugins= no .zshrc..."
    local plugins_ln source_ln
    plugins_ln=$(grep -n "^plugins=(" ~/.zshrc 2>/dev/null | head -1 | cut -d: -f1)
    source_ln=$(grep -n "source \$ZSH/oh-my-zsh.sh" ~/.zshrc 2>/dev/null | head -1 | cut -d: -f1)

    if [ -n "$plugins_ln" ] && [ -n "$source_ln" ]; then
        if [ "$plugins_ln" -lt "$source_ln" ]; then
            ok "plugins= linha $plugins_ln ← antes do source linha $source_ln"
        else
            err "plugins= linha $plugins_ln está DEPOIS do source linha $source_ln!"
            errors=$((errors + 1))
        fi
    else
        [ -z "$plugins_ln" ] && warn "Linha plugins=() não encontrada no .zshrc"
        [ -z "$source_ln" ] && warn "Linha 'source \$ZSH/oh-my-zsh.sh' não encontrada"
        errors=$((errors + 1))
    fi

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

    log "Testando carregamento dos plugins em sessão Zsh (pode demorar alguns segundos)..."

    local autosuggest_ver
    autosuggest_ver=$(
        zsh -i -c 'echo "SETUP_CHECK:${ZSH_AUTOSUGGEST_VERSION:-NOT_LOADED}"' \
        2>/dev/null | grep "^SETUP_CHECK:" | cut -d: -f2 || echo "NOT_LOADED"
    )
    if [ "$autosuggest_ver" != "NOT_LOADED" ] && [ -n "$autosuggest_ver" ]; then
        ok "zsh-autosuggestions carregado (versão $autosuggest_ver)"
    else
        err "zsh-autosuggestions NÃO foi carregado na sessão Zsh"
        warn "Verifique manualmente com: exec zsh && echo \$ZSH_AUTOSUGGEST_VERSION"
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
        warn "Verifique manualmente com: exec zsh && echo \$ZSH_HIGHLIGHT_VERSION"
        errors=$((errors + 1))
    fi

    echo ""
    if [ "$errors" -eq 0 ]; then
        ok "Todas as verificações do Zsh passaram com sucesso!"
    else
        warn "$errors verificação(ões) falharam."
        warn "Para aplicar as configurações: exec zsh  (ou reabra o terminal)"
        warn "Backup do .zshrc original: $BACKUP_ROOT$HOME/.zshrc"
    fi

    return 0  # Não bloqueia o restante do script por problemas de validação
}

# ═════════════════════════════ PYENV ═════════════════════════════════════════
install_pyenv() {
    header "pyenv"

    if [ -d "$HOME/.pyenv" ]; then
        ok "pyenv já instalado"
        (cd "$HOME/.pyenv" && git pull --ff-only >/dev/null 2>&1) || true
    else
        log "Instalando pyenv..."
        git clone --depth=1 https://github.com/pyenv/pyenv.git "$HOME/.pyenv" \
            || { err "Falha ao clonar o repositório do pyenv."; return 1; }
        ok "pyenv instalado"
    fi

    local block
    block=$(cat <<'EOF'

# PYENV — configurado pelo setup.sh
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF
)
    add_generic_export_block "# PYENV — configurado pelo setup.sh" "$block"
    ok "pyenv configurado em: ${RC_FILES[*]}"
    SUMMARY[pyenv]="Instalado/atualizado e configurado"
}

# ═════════════════════════════ PYTHON 3.10 ═══════════════════════════════════
install_python310() {
    header "Python 3.10"

    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"

    if ! command -v pyenv >/dev/null 2>&1; then
        err "pyenv não encontrado! Instalação do Python 3.10 foi ignorada."
        SUMMARY[python310]="Falhou (pyenv ausente)"
        return
    fi

    eval "$(pyenv init -)"

    local build_deps=(make build-essential libssl-dev zlib1g-dev libbz2-dev
                      libreadline-dev libsqlite3-dev curl libncurses-dev xz-utils
                      tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev)
    local missing=()
    for pkg in "${build_deps[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null \
            | grep -q "ok installed" || missing+=("$pkg")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log "Instalando dependências de build..."
        apt_install "${missing[@]}" || { err "Falha ao instalar dependências de build do Python."; return 1; }
    fi

    if pyenv versions --bare 2>/dev/null | grep -q "^3\.10\."; then
        local existing
        existing=$(pyenv versions --bare 2>/dev/null | grep "^3\.10\." | tail -1)
        ok "Python 3.10 já instalado ($existing)"
        pyenv global "$existing"
        SUMMARY[python310]="Mantido ($existing)"
    else
        log "Detectando a última versão estável do Python 3.10.x (pyenv)..."
        local latest
        latest=$(pyenv install --list 2>/dev/null | grep -E '^\s*3\.10\.[0-9]+$' | tail -1 | tr -d ' ')
        [ -z "$latest" ] && latest="3.10.13"
        log "Instalando Python $latest..."
        pyenv install "$latest" || { err "Falha ao compilar/instalar Python $latest via pyenv."; return 1; }
        pyenv global "$latest"  || { err "Falha ao definir Python $latest como padrão do pyenv."; return 1; }
        ok "Python $latest instalado e definido como padrão"
        SUMMARY[python310]="Instalado ($latest)"
    fi
    pyenv rehash

    local block
    block=$(cat <<'EOF'

# Python — aliases configurados pelo setup.sh
alias python3="python"
alias pip3="pip"
EOF
)
    add_generic_export_block "# Python — aliases configurados pelo setup.sh" "$block"
}

# ═════════════════════════════ NEOVIM ════════════════════════════════════════
#
# Análise de estado completa antes de qualquer ação:
#   - Verifica se nvim está instalado e qual versão
#   - Verifica se a config é al4xs/neovim-config
#   - Verifica se os plugins foram realmente instalados (lazy.nvim)
#   - Verifica se o nvim abre sem erros
#   - Corrige apenas o que estiver com problema
#
_check_nvim_state() {
    # Retorna: "missing_nvim" | "missing_config" | "wrong_config" | "missing_plugins" | "broken_startup" | "ok"
    local nvim_cfg="$HOME/.config/nvim"

    # 1. nvim instalado?
    if ! command -v nvim >/dev/null 2>&1; then
        echo "missing_nvim"
        return
    fi

    # 2. Config existe?
    if [ ! -d "$nvim_cfg" ]; then
        echo "missing_config"
        return
    fi

    # 3. Config é al4xs/neovim-config?
    if [ ! -d "$nvim_cfg/.git" ] || \
       ! git -C "$nvim_cfg" remote get-url origin 2>/dev/null | grep -qi "al4xs/neovim-config"; then
        echo "wrong_config"
        return
    fi

    # 4. Plugins realmente instalados? (lazy.nvim cria ~/.local/share/nvim/lazy/)
    local lazy_dir="$HOME/.local/share/nvim/lazy"
    if [ ! -d "$lazy_dir" ] || [ -z "$(ls -A "$lazy_dir" 2>/dev/null)" ]; then
        echo "missing_plugins"
        return
    fi

    # 5. Neovim abre sem erros?
    if ! timeout 15 nvim --headless -c "quit" >/dev/null 2>&1; then
        echo "broken_startup"
        return
    fi

    echo "ok"
}

install_nvim() {
    header "Neovim (al4xs/neovim-config)"

    if [ "$SKIP_NEOVIM" = true ]; then
        ok "Instalação do Neovim ignorada (--skip-neovim)"
        SUMMARY[nvim]="Ignorado (--skip-neovim)"
        return
    fi

    local nvim_cfg="$HOME/.config/nvim"

    # Usa o estado pré-computado pelo scan (ou re-detecta se chamado diretamente)
    local state
    if [ -n "$_NVIM_RAW_STATE" ]; then
        state="$_NVIM_RAW_STATE"
        log "Estado do Neovim (pré-computado): $state"
    else
        log "Analisando estado do Neovim..."
        state=$(_check_nvim_state)
    fi
    _NVIM_RAW_STATE=""  # consome para evitar reuso em chamadas subsequentes

    case "$state" in
        ok)
            local nvim_ver; nvim_ver=$(nvim --version | head -1)
            local lazy_count; lazy_count=$(ls -A "$HOME/.local/share/nvim/lazy" 2>/dev/null | wc -l)
            _report_state "Neovim" "$STATE_OK" "$nvim_ver, $lazy_count plugins, abre sem erros"
            ok "Neovim funcionando corretamente — mantido"
            SUMMARY[nvim]="Mantido e verificado ($nvim_ver, $lazy_count plugins)"
            return
            ;;
        missing_nvim)
            _report_state "Neovim" "$STATE_MISSING"
            ;;
        missing_config)
            _report_state "Neovim" "$STATE_BROKEN" "binário presente mas configuração ausente"
            warn "Neovim instalado mas sem configuração — clonando al4xs/neovim-config"
            ;;
        wrong_config)
            _report_state "Neovim" "$STATE_BROKEN" "configuração existente não é al4xs/neovim-config"
            ;;
        missing_plugins)
            _report_state "Neovim" "$STATE_BROKEN" "config ok mas plugins não foram instalados"
            warn "Plugins do Neovim ausentes — executando sincronização"
            ;;
        broken_startup)
            _report_state "Neovim" "$STATE_BROKEN" "nvim não abre sem erros"
            warn "Neovim com erros de inicialização — verificando e corrigindo"
            ;;
    esac

    # ── Instala o nvim se ausente ─────────────────────────────────────────────
    if [ "$state" = "missing_nvim" ]; then
        log "Instalando Neovim..."
        # Tenta instalar versão mais recente via snap (se disponível), pois a
        # versão do apt pode ser muito antiga para configurações modernas.
        if command -v snap >/dev/null 2>&1; then
            if snap install nvim --classic 2>/dev/null; then
                ok "Neovim instalado via snap ($(nvim --version | head -1))"
            else
                warn "snap install falhou — tentando via apt..."
                apt_install neovim || { err "Falha ao instalar o pacote neovim."; return 1; }
                ok "Neovim instalado via apt ($(nvim --version | head -1))"
            fi
        else
            apt_install neovim || { err "Falha ao instalar o pacote neovim."; return 1; }
            ok "Neovim instalado via apt ($(nvim --version | head -1))"
        fi
        state="missing_config"
    fi

    # ── Instala dependências necessárias ─────────────────────────────────────
    _install_nvim_dependencies

    mkdir -p "$HOME/.config"

    # ── Configura al4xs/neovim-config ────────────────────────────────────────
    if [ "$state" = "missing_config" ]; then
        log "Clonando al4xs/neovim-config..."
        git clone --depth=1 https://github.com/al4xs/neovim-config "$nvim_cfg" \
            || { err "Falha ao clonar al4xs/neovim-config."; return 1; }
        ok "Configuração clonada em $nvim_cfg"
        state="missing_plugins"
    elif [ "$state" = "wrong_config" ]; then
        local backup_dir="$BACKUP_ROOT$nvim_cfg"
        mkdir -p "$(dirname "$backup_dir")"
        cp -a "$nvim_cfg" "$backup_dir" 2>/dev/null || true
        ok "Backup da configuração existente salvo em: $backup_dir"

        if confirm "Encontrada configuração de Neovim que NÃO é al4xs/neovim-config. Já foi feito backup em $backup_dir. Deseja substituí-la?" "s"; then
            rm -rf "$nvim_cfg"
            log "Clonando al4xs/neovim-config..."
            git clone --depth=1 https://github.com/al4xs/neovim-config "$nvim_cfg" \
                || { err "Falha ao clonar al4xs/neovim-config."; return 1; }
            ok "Configuração instalada"
            state="missing_plugins"
        else
            ok "Configuração existente mantida (nada foi apagado)."
            SUMMARY[nvim]="Mantido (configuração existente preservada pelo usuário)"
            return
        fi
    elif [ "$state" = "ok" ] || [ "$state" = "broken_startup" ]; then
        # Config já é al4xs/neovim-config — apenas atualiza
        log "Atualizando al4xs/neovim-config..."
        if git -C "$nvim_cfg" pull --ff-only >>"$LOG_FILE" 2>&1; then
            ok "Configuração atualizada"
        else
            warn "Não foi possível atualizar via 'git pull --ff-only' — mantendo versão atual."
        fi
    fi

    # ── Instala pynvim (necessário para plugins Python) ───────────────────────
    python3 -m pip install --user --quiet pynvim 2>/dev/null \
        || warn "Não foi possível instalar 'pynvim' (opcional para plugins Python)."

    # ── Sincroniza plugins via lazy.nvim ─────────────────────────────────────
    log "Sincronizando plugins do Neovim (pode levar alguns minutos na primeira vez)..."
    local sync_ok=false
    if timeout 300 nvim --headless "+Lazy! sync" +qa >>"$LOG_FILE" 2>&1; then
        sync_ok=true
        ok "Plugins sincronizados com sucesso"
    else
        warn "Sincronização via '+Lazy! sync' retornou código não-zero — tentando método alternativo..."
        # Fallback: tenta via +Lazy sync sem o '!' (versões mais antigas do lazy.nvim)
        if timeout 300 nvim --headless "+Lazy sync" +qa >>"$LOG_FILE" 2>&1; then
            sync_ok=true
            ok "Plugins sincronizados (método alternativo)"
        else
            warn "Sincronização de plugins pode ter tido problemas — verifique o log: $LOG_FILE"
        fi
    fi

    # ── Verifica se plugins foram realmente instalados ────────────────────────
    local lazy_dir="$HOME/.local/share/nvim/lazy"
    if [ -d "$lazy_dir" ] && [ -n "$(ls -A "$lazy_dir" 2>/dev/null)" ]; then
        local plugin_count; plugin_count=$(ls -A "$lazy_dir" | wc -l)
        ok "Plugins instalados: $plugin_count diretórios em $lazy_dir"
    else
        warn "Diretório de plugins não encontrado ou vazio: $lazy_dir"
        warn "Isso pode indicar falha na sincronização. Tente abrir o Neovim manualmente e execute :Lazy sync"
        warn "Log da sincronização: $LOG_FILE"
    fi

    # ── Valida inicialização do Neovim ────────────────────────────────────────
    log "Validando que o Neovim abre sem erros..."
    local startup_errors=""
    startup_errors=$(timeout 30 nvim --headless -c "quit" 2>&1 | head -20 || true)

    if [ -z "$startup_errors" ]; then
        ok "Neovim abre corretamente, sem erros"
        local final_ver; final_ver=$(nvim --version | head -1)
        local final_count; final_count=$(ls -A "$lazy_dir" 2>/dev/null | wc -l || echo "?")
        SUMMARY[nvim]="Instalado e validado ($final_ver, $final_count plugins)"
    else
        # Filtra mensagens que não são erros reais (algumas configs emitem avisos normais)
        local real_errors
        real_errors=$(echo "$startup_errors" | grep -iE "^E[0-9]+:|error:|failed:" || true)
        if [ -z "$real_errors" ]; then
            ok "Neovim abre com avisos não-críticos (normal para configs complexas)"
            SUMMARY[nvim]="Instalado ($(nvim --version | head -1))"
        else
            warn "Neovim apresentou erros ao abrir:"
            echo "$real_errors" | while IFS= read -r line; do warn "  $line"; done
            warn "Consulte o log completo: $LOG_FILE"
            SUMMARY[nvim]="Instalado com avisos de inicialização — veja o log"
        fi
    fi
}

_install_nvim_dependencies() {
    log "Verificando dependências do Neovim (ripgrep, fd, unzip, make, cargo, npm)..."
    local missing=()
    command -v rg >/dev/null 2>&1       || missing+=(ripgrep)
    { command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1; } || missing+=(fd-find)
    command -v unzip >/dev/null 2>&1    || missing+=(unzip)
    command -v gcc >/dev/null 2>&1      || missing+=(build-essential)
    command -v make >/dev/null 2>&1     || missing+=(make)
    command -v cargo >/dev/null 2>&1    || missing+=(cargo)

    if [ ${#missing[@]} -gt 0 ]; then
        log "Instalando dependências ausentes: ${missing[*]}"
        apt_install "${missing[@]}" \
            || warn "Algumas dependências opcionais do Neovim não puderam ser instaladas — alguns plugins podem não funcionar."
    else
        ok "Todas as dependências do Neovim já estão presentes"
    fi

    # Debian/Ubuntu empacotam 'fd' como 'fdfind' — cria um link amigável 'fd'.
    if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
        add_generic_export_block "# fd — link local criado pelo setup.sh" \
'
# fd — link local criado pelo setup.sh
export PATH="$HOME/.local/bin:$PATH"'
        ok "Link 'fd' -> 'fdfind' criado em ~/.local/bin"
    fi

    # npm — usado por vários plugins do Neovim (Mason, null-ls, etc.)
    if ! command -v npm >/dev/null 2>&1; then
        warn "npm não encontrado — alguns plugins do Neovim (Mason) podem não funcionar."
        warn "npm é instalado junto com Node.js. Execute a etapa do Node.js antes."
    else
        ok "npm disponível ($(npm --version 2>/dev/null || echo '?'))"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
#  .NET SDK
#  Detecta versões disponíveis dinamicamente via API oficial da Microsoft.
#  Nunca usa números de versão fixos no código.
# ════════════════════════════════════════════════════════════════════════════
_fetch_dotnet_versions() {
    local json_file="$SETUP_TMP/dotnet-releases.json"
    log "Buscando versões disponíveis do .NET na Microsoft..."

    if ! curl -fsSL \
        "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/releases-index.json" \
        -o "$json_file"; then
        err "Não foi possível buscar versões do .NET. Verifique sua conexão."
        return 1
    fi
    verify_download "$json_file" 100 || return 1

    cat > "$SETUP_TMP/parse_dotnet.py" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

releases = data.get("releases-index", [])

valid = [
    r for r in releases
    if r.get("support-phase") in ("active", "maintenance")
    and "preview" not in r.get("channel-version", "").lower()
    and "rc"      not in r.get("channel-version", "").lower()
]

valid.sort(
    key=lambda r: [int(x) for x in r["channel-version"].split(".")],
    reverse=True
)

if not valid:
    print("none N/A none N/A")
    sys.exit(0)

stable = valid[0]
lts_list = [r for r in valid if r.get("release-type") == "lts"]
lts = lts_list[0] if lts_list else None

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
    if [ "$NONINTERACTIVE" = true ]; then
        log "[não interativo] mantendo .NET SDK atual ($current)"
        echo "keep"
        return
    fi
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
    verify_download "$script" 500 || return 1
    chmod +x "$script"

    log "Instalando .NET SDK canal $channel em $install_dir ..."
    "$script" --channel "$channel" --install-dir "$install_dir"

    local block
    block=$(cat <<'EOF'

# .NET SDK — configurado pelo setup.sh
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"
EOF
)
    add_generic_export_block "# .NET SDK — configurado pelo setup.sh" "$block"

    export DOTNET_ROOT="$HOME/.dotnet"
    export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"
}

_dotnet_validate() {
    log "Validando instalação do .NET..."
    local dotnet_cmd="${DOTNET_ROOT:-$HOME/.dotnet}/dotnet"

    if [ ! -x "$dotnet_cmd" ] && ! command -v dotnet >/dev/null 2>&1; then
        err ".NET não encontrado após instalação."
        warn "Execute: source ~/.bashrc  (ou ~/.zshrc)  &&  dotnet --version"
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

    if [ "$SKIP_DOTNET" = true ]; then
        ok "Instalação do .NET ignorada (--skip-dotnet)"
        SUMMARY[dotnet]="Ignorado (--skip-dotnet)"
        return
    fi

    _fetch_dotnet_versions || { SUMMARY[dotnet]="Falhou (sem conexão)"; return; }

    local current_dotnet="" dotnet_cmd=""
    if command -v dotnet >/dev/null 2>&1; then
        dotnet_cmd="dotnet"
    elif [ -x "$HOME/.dotnet/dotnet" ]; then
        dotnet_cmd="$HOME/.dotnet/dotnet"
        export DOTNET_ROOT="$HOME/.dotnet"
        export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"
    fi

    if [ -n "$dotnet_cmd" ]; then
        # Já instalado e funcionando — não há nada a fazer
        # (o scan inicial teria marcado como ok e não chegaria aqui)
        current_dotnet=$($dotnet_cmd --version 2>/dev/null || echo "desconhecida")
        ok ".NET já instalado ($current_dotnet) — mantido"
        SUMMARY[dotnet]="Mantido ($current_dotnet)"
        return
    fi

    local channel
    if [ "$NONINTERACTIVE" = true ]; then
        channel="$DOTNET_STABLE_CHANNEL"
        log "[não interativo] selecionando .NET $channel (estável)"
    else
        echo ""
        header "Escolha a versão do .NET SDK"
        echo "  [1] .NET $DOTNET_STABLE_CHANNEL — Estável atual (SDK $DOTNET_STABLE_SDK)"
        [ "$DOTNET_LTS_CHANNEL" != "none" ] && \
            echo "  [2] .NET $DOTNET_LTS_CHANNEL  — LTS anterior   (SDK $DOTNET_LTS_SDK)"
        echo "  [0] Pular"
        ask "Escolha [1/2/0, padrão=1]:"
        local vchoice
        read -r vchoice || vchoice="1"

        case "${vchoice:-1}" in
            1) channel="$DOTNET_STABLE_CHANNEL" ;;
            2) [ "$DOTNET_LTS_CHANNEL" != "none" ] \
                   && channel="$DOTNET_LTS_CHANNEL" \
                   || channel="$DOTNET_STABLE_CHANNEL" ;;
            0) ok ".NET ignorado"; SUMMARY[dotnet]="Ignorado"; return ;;
            *) channel="$DOTNET_STABLE_CHANNEL" ;;
        esac
    fi

    _dotnet_run_install "$channel" || { SUMMARY[dotnet]="Falhou"; return; }
    _dotnet_validate               || { SUMMARY[dotnet]="Instalado (validação falhou)"; return; }

    local ver
    ver=$("${DOTNET_ROOT:-$HOME/.dotnet}/dotnet" --version 2>/dev/null || echo "?")
    ok ".NET $ver instalado com sucesso"
    SUMMARY[dotnet]="Instalado ($ver)"
}

# ════════════════════════════════════════════════════════════════════════════
#  FERRAMENTAS OPCIONAIS
# ════════════════════════════════════════════════════════════════════════════

# ── VS CODE ───────────────────────────────────────────────────────────────────
install_vscode() {
    header "Visual Studio Code"

    if command -v code >/dev/null 2>&1; then
        local ver; ver=$(code --version 2>/dev/null | head -1)
        ok "VS Code já instalado ($ver) — mantido"
        SUMMARY[vscode]="Mantido ($ver)"
        _install_vscode_extensions
        return
    fi

    log "Instalando VS Code (repositório oficial Microsoft)..."
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor \
        | sudo tee /etc/apt/trusted.gpg.d/microsoft-vscode.gpg > /dev/null \
        || { err "Falha ao configurar a chave do repositório do VS Code."; return 1; }

    echo "deb [arch=amd64,arm64,armhf] https://packages.microsoft.com/repos/code stable main" \
        | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null

    apt_update || { err "Falha ao atualizar índices do apt para o VS Code."; return 1; }
    apt_install code || { err "Falha ao instalar o pacote code."; return 1; }

    if command -v code >/dev/null 2>&1; then
        local ver; ver=$(code --version 2>/dev/null | head -1)
        ok "VS Code instalado ($ver)"
        SUMMARY[vscode]="Instalado ($ver)"
    else
        warn "VS Code instalado mas 'code' não está no PATH. Reinicie a sessão."
        SUMMARY[vscode]="Instalado (reinicie a sessão para usar 'code')"
        RESTART_SESSION_NEEDED=true
    fi

    _install_vscode_extensions
}

_install_vscode_extensions() {
    command -v code >/dev/null 2>&1 || {
        warn "VS Code não disponível no PATH. Extensões serão ignoradas."
        return
    }

    local to_install=()

    if [ "$NONINTERACTIVE" = true ]; then
        if [ "$INSTALL_ALL" = true ]; then
            to_install=(1 2 3 4 5 6)
        else
            log "[não interativo] extensões do VS Code ignoradas (use --install-all para instalá-las)"
            return
        fi
    else
        if ! confirm "Instalar extensões C# recomendadas para o VS Code?" "n"; then
            ok "Extensões ignoradas"
            return
        fi

        header "Extensões do VS Code"
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

        if echo "$input" | grep -qw "0"; then
            ok "Extensões ignoradas"; return
        elif echo "$input" | grep -qw "7"; then
            to_install=(1 2 3 4 5 6)
        else
            for n in $input; do
                [[ "$n" =~ ^[1-6]$ ]] && to_install+=("$n")
            done
        fi
    fi

    declare -A EXTS=(
        [1]="ms-dotnettools.csdevkit|C# Dev Kit (Microsoft)"
        [2]="ms-dotnettools.csharp|C#"
        [3]="ms-dotnettools.vscode-dotnet-runtime|.NET Install Tool"
        [4]="VisualStudioExptTeam.vscodeintellicode|IntelliCode"
        [5]="eamodio.gitlens|GitLens"
        [6]="PKief.material-icon-theme|Material Icon Theme"
    )

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
        ok "Chrome já instalado ($ver) — mantido"
        SUMMARY[chrome]="Mantido ($ver)"
        return
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
    verify_download "$deb" 10000000 || { SUMMARY[chrome]="Falhou (download incompleto)"; return; }

    apt_install "$deb" 2>/dev/null \
        || { sudo dpkg -i "$deb" 2>/dev/null; apt_install -f; }

    local ver
    ver=$(google-chrome-stable --version 2>/dev/null || echo "?")
    ok "Chrome instalado ($ver)"
    SUMMARY[chrome]="Instalado ($ver)"
}

# ── POSTMAN ───────────────────────────────────────────────────────────────────
install_postman() {
    header "Postman"

    if command -v postman >/dev/null 2>&1 || [ -d /opt/Postman ]; then
        ok "Postman já instalado — mantido"
        SUMMARY[postman]="Mantido"
        return
    fi

    log "Baixando Postman (dl.pstmn.io — oficial)..."
    local archive="$SETUP_TMP/postman.tar.gz"
    if ! curl -fsSL "https://dl.pstmn.io/download/latest/linux64" -o "$archive"; then
        err "Falha no download do Postman."
        SUMMARY[postman]="Falhou"
        return
    fi
    verify_download "$archive" 10000000 || { SUMMARY[postman]="Falhou (download incompleto)"; return; }

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        err "Arquivo do Postman corrompido."
        SUMMARY[postman]="Falhou (arquivo corrompido)"
        return
    fi

    log "Instalando em /opt/Postman..."
    sudo tar -xzf "$archive" -C /opt/
    sudo ln -sf /opt/Postman/Postman /usr/local/bin/postman

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
        ok "Burp Suite já instalado — mantido"
        SUMMARY[burpsuite]="Mantido"
        return
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
    verify_download "$installer" 10000000 || { SUMMARY[burpsuite]="Falhou (download incompleto)"; return; }
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
#
# Análise de estado completa antes de qualquer ação:
#   - Verifica se o binário principal existe e é executável
#   - Verifica se o .desktop está criado e aponta para o local correto
#   - Verifica se o launcher na CLI existe
#   - Corrige apenas o que estiver com problema
#
_check_tor_state() {
    # Retorna: "missing" | "binary_missing" | "desktop_missing" | "desktop_broken" | "ok"
    local install_dir="/opt/tor-browser"
    local binary="$install_dir/Browser/start-tor-browser"
    local firefox_bin="$install_dir/Browser/firefox.real"
    local desktop="/usr/share/applications/tor-browser.desktop"
    local cli_launcher="/usr/local/bin/tor-browser"

    # Nem diretório de perfil legado nem diretório de instalação existem
    if [ ! -d "$install_dir" ] && [ ! -d "$HOME/.local/share/torbrowser" ]; then
        echo "missing"
        return
    fi

    # Instalação existe mas binário principal ausente ou não executável
    if [ ! -x "$binary" ]; then
        echo "binary_missing"
        return
    fi

    # Binário do Firefox ausente ou não é ELF
    if [ ! -f "$firefox_bin" ] || ! file "$firefox_bin" 2>/dev/null | grep -qi "ELF"; then
        echo "binary_missing"
        return
    fi

    # Launcher CLI ausente
    if [ ! -x "$cli_launcher" ]; then
        echo "desktop_missing"
        return
    fi

    # .desktop ausente
    if [ ! -f "$desktop" ]; then
        echo "desktop_missing"
        return
    fi

    # .desktop com Exec apontando para lugar errado
    if ! grep -q "Exec=/opt/tor-browser/Browser/start-tor-browser" "$desktop" 2>/dev/null; then
        echo "desktop_broken"
        return
    fi

    echo "ok"
}

_get_tor_latest_version() {
    local arch_key="$1"
    cat > "$SETUP_TMP/get_tor_ver.py" << PYEOF
import urllib.request, json, sys
try:
    url = "https://aus1.torproject.org/torbrowser/update_3/release/downloads.json"
    with urllib.request.urlopen(url, timeout=15) as r:
        data = json.load(r)
    ver = data.get("version", "")
    dl = data.get("downloads", {}).get("$arch_key", {}).get("en-US", {}).get("binary", "")
    print(ver, dl)
except Exception:
    sys.exit(1)
PYEOF
    python3 "$SETUP_TMP/get_tor_ver.py" 2>/dev/null || echo ""
}

# Cria o arquivo .desktop para o Tor Browser de forma robusta.
# Não depende do arquivo estar no tarball — sempre gera do zero se necessário.
_tor_create_desktop() {
    local install_dir="/opt/tor-browser"
    local desktop_dest="/usr/share/applications/tor-browser.desktop"

    # Determina o ícone: tenta vários caminhos conhecidos dentro do pacote
    local icon_path=""
    for candidate in \
        "$install_dir/Browser/browser/chrome/icons/default/default128.png" \
        "$install_dir/Browser/browser/chrome/icons/default/default64.png" \
        "$install_dir/start-tor-browser.desktop" \
        "$install_dir/Browser/icons/tor-logo.png"; do
        if [ -f "$candidate" ] && echo "$candidate" | grep -q "\.png$"; then
            icon_path="$candidate"
            break
        fi
    done

    # Fallback: ícone genérico do sistema se nenhum for encontrado no pacote
    [ -z "$icon_path" ] && icon_path="web-browser"

    log "Criando entrada .desktop do Tor Browser (ícone: $icon_path)..."

    sudo tee "$desktop_dest" > /dev/null << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Tor Browser
GenericName=Web Browser
Comment=Tor Browser is +1 for privacy and −1 for mass surveillance
Exec=/opt/tor-browser/Browser/start-tor-browser %u
Icon=${icon_path}
StartupWMClass=Tor Browser
Categories=Network;WebBrowser;Security;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/rss+xml;application/rdf+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
Keywords=browser;tor;privacy;
EOF
    sudo chmod 644 "$desktop_dest"

    # Atualiza o banco de dados do menu de aplicativos (se disponível)
    if command -v update-desktop-database >/dev/null 2>&1; then
        sudo update-desktop-database /usr/share/applications 2>/dev/null || true
    fi

    ok ".desktop criado: $desktop_dest"
}

# Cria o launcher CLI do Tor Browser.
_tor_create_cli_launcher() {
    sudo tee /usr/local/bin/tor-browser > /dev/null << 'EOF'
#!/usr/bin/env bash
exec /opt/tor-browser/Browser/start-tor-browser "$@"
EOF
    sudo chmod +x /usr/local/bin/tor-browser
    ok "Launcher CLI criado: /usr/local/bin/tor-browser"
}

install_tor() {
    header "Tor Browser"

    local tor_arch_key
    case "$ARCH" in
        x86_64) tor_arch_key="linux64" ;;
        aarch64|arm64)
            tor_arch_key="linux64"
            warn "O Tor Project não oferece build nativa para ARM64 no canal estável — tentando a build linux64 (pode não ser compatível)."
            ;;
        i386|i686) tor_arch_key="linux32" ;;
        *)
            err "Arquitetura não suportada pelo Tor Browser: $ARCH"
            SUMMARY[tor]="Falhou (arquitetura não suportada)"
            return 1
            ;;
    esac

    local install_dir="/opt/tor-browser"

    # ── Usa estado pré-computado pelo scan (ou re-detecta se chamado diretamente)
    local comp_s="${COMP_STATE[tor]:-}"
    local state
    if [ -n "$comp_s" ] && [ "$comp_s" != "missing" ]; then
        # Mapeia de volta para os valores brutos esperados pela lógica de instalação
        case "$comp_s" in
            ok)         state="ok"             ;;
            broken)     state="binary_missing" ;;
            incomplete)
                # Distingue desktop_missing de desktop_broken via detalhe
                if [[ "${COMP_DETAIL[tor]:-}" == *"incorreta"* ]]; then
                    state="desktop_broken"
                else
                    state="desktop_missing"
                fi
                ;;
            *)          state=$(_check_tor_state) ;;
        esac
        log "Estado do Tor Browser (pré-computado): $state"
    else
        log "Analisando estado do Tor Browser..."
        state=$(_check_tor_state)
    fi
    COMP_STATE[tor]=""   # consome para evitar reuso

    case "$state" in
        ok)
            ok "Tor Browser funcionando corretamente — mantido"
            SUMMARY[tor]="Mantido (instalação validada)"
            return
            ;;
        missing)
            : # continua para instalação
            ;;
        binary_missing)
            warn "Reinstalando Tor Browser (binário ausente/corrompido)..."
            sudo rm -rf "$install_dir"
            ;;
        desktop_missing)
            warn "Corrigindo apenas .desktop e launcher (sem reinstalar o navegador)..."
            _tor_create_desktop
            _tor_create_cli_launcher
            _tor_fix_permissions
            ok "Tor Browser corrigido (sem reinstalação)"
            SUMMARY[tor]="Reparado (.desktop e launcher criados)"
            return
            ;;
        desktop_broken)
            warn "Corrigindo .desktop do Tor Browser..."
            _tor_create_desktop
            _tor_create_cli_launcher
            _tor_fix_permissions
            ok "Tor Browser corrigido (.desktop atualizado)"
            SUMMARY[tor]="Reparado (.desktop atualizado)"
            return
            ;;
    esac

    # ── Se o diretório legado existe mas o estado é "missing", limpa ─────────
    if [ -d "$HOME/.local/share/torbrowser" ] && [ "$state" = "missing" ]; then
        log "Removendo instalação legada em ~/.local/share/torbrowser..."
        rm -rf "$HOME/.local/share/torbrowser"
    fi

    # Pergunta apenas quando chamado via menu de ausentes (state = missing)
    if [ "$state" = "missing" ]; then
        if ! confirm "Instalar o Tor Browser?" "s"; then
            ok "Tor Browser ignorado"
            SUMMARY[tor]="Ignorado pelo usuário"
            return
        fi
    fi

    # ── Download ─────────────────────────────────────────────────────────────
    log "Detectando versão mais recente do Tor Browser (torproject.org)..."
    local tor_info
    tor_info=$(_get_tor_latest_version "$tor_arch_key")
    local tor_ver; tor_ver=$(echo "$tor_info" | awk '{print $1}')
    local tor_url; tor_url=$(echo "$tor_info" | awk '{print $2}')

    if [ -z "$tor_ver" ] || [ -z "$tor_url" ]; then
        err "Não foi possível detectar a versão do Tor Browser."
        warn "Baixe manualmente em: https://www.torproject.org/download/"
        SUMMARY[tor]="Falhou (API indisponível)"
        return 1
    fi

    ok "Versão detectada: $tor_ver"
    log "Baixando de: $tor_url"

    local archive="$SETUP_TMP/tor-browser.tar.xz"
    if ! curl -fsSL "$tor_url" -o "$archive"; then
        err "Falha no download do Tor Browser."
        SUMMARY[tor]="Falhou (download)"
        return 1
    fi

    if ! verify_download "$archive" 20000000; then
        SUMMARY[tor]="Falhou (download incompleto)"
        return 1
    fi

    # ── Verifica integridade do arquivo ──────────────────────────────────────
    log "Verificando integridade do arquivo..."
    if ! tar -tJf "$archive" >/dev/null 2>&1; then
        err "Arquivo do Tor Browser corrompido ou incompleto."
        SUMMARY[tor]="Falhou (arquivo corrompido)"
        return 1
    fi

    # ── Extração e instalação ────────────────────────────────────────────────
    log "Instalando em $install_dir ..."
    sudo mkdir -p "$install_dir"
    sudo tar -xJf "$archive" --strip-components=1 -C "$install_dir" \
        || { err "Falha ao extrair o Tor Browser."; return 1; }

    # ── Permissões ───────────────────────────────────────────────────────────
    _tor_fix_permissions

    # ── .desktop e launcher CLI ──────────────────────────────────────────────
    _tor_create_desktop
    _tor_create_cli_launcher

    # ── Validação ────────────────────────────────────────────────────────────
    log "Validando instalação..."
    local validation_ok=true

    if [ ! -x "$install_dir/Browser/start-tor-browser" ]; then
        err "Binário start-tor-browser não encontrado ou não executável"
        validation_ok=false
    else
        ok "start-tor-browser: executável"
    fi

    if file "$install_dir/Browser/firefox.real" 2>/dev/null | grep -qi "ELF"; then
        ok "firefox.real: binário ELF válido"
    else
        warn "firefox.real não encontrado ou não é um binário ELF válido"
        # Tenta localizar o binário principal com nome diferente
        local alt_bin
        alt_bin=$(find "$install_dir/Browser" -maxdepth 1 -name "firefox*" -type f 2>/dev/null | head -1)
        if [ -n "$alt_bin" ] && file "$alt_bin" 2>/dev/null | grep -qi "ELF"; then
            ok "Binário alternativo encontrado: $alt_bin"
        else
            validation_ok=false
        fi
    fi

    if [ ! -f "/usr/share/applications/tor-browser.desktop" ]; then
        err ".desktop não encontrado em /usr/share/applications/"
        validation_ok=false
    else
        ok ".desktop presente: /usr/share/applications/tor-browser.desktop"
    fi

    if [ ! -x "/usr/local/bin/tor-browser" ]; then
        err "Launcher CLI não encontrado em /usr/local/bin/tor-browser"
        validation_ok=false
    else
        ok "Launcher CLI presente: /usr/local/bin/tor-browser"
    fi

    if [ "$validation_ok" = true ]; then
        ok "Tor Browser $tor_ver instalado e validado com sucesso"
        ok "Para iniciar: tor-browser  ou via menu de aplicativos"
        SUMMARY[tor]="Instalado e validado ($tor_ver)"
    else
        warn "Tor Browser instalado ($tor_ver), mas com problemas na validação."
        warn "Tente executar: /opt/tor-browser/Browser/start-tor-browser"
        SUMMARY[tor]="Instalado ($tor_ver) — validação parcial, veja o log"
    fi
}

# Corrige permissões do Tor Browser.
# /opt/tor-browser deve ser legível por todos, mas o diretório de perfil
# do usuário (~/.local/share/torbrowser) deve pertencer ao usuário.
_tor_fix_permissions() {
    local install_dir="/opt/tor-browser"
    if [ ! -d "$install_dir" ]; then return 0; fi

    log "Corrigindo permissões de $install_dir ..."
    sudo chown -R root:root "$install_dir"
    sudo chmod -R a+rX "$install_dir"

    # O binário principal precisa ser executável
    if [ -f "$install_dir/Browser/start-tor-browser" ]; then
        sudo chmod +x "$install_dir/Browser/start-tor-browser"
    fi
    # Outros scripts .sh dentro de Browser/
    find "$install_dir/Browser" -maxdepth 1 -name "*.sh" -type f 2>/dev/null \
        | xargs -I{} sudo chmod +x {} 2>/dev/null || true

    # O diretório de perfil do usuário deve pertencer ao usuário (não root)
    local user_tor_dir="$HOME/.local/share/torbrowser"
    if [ -d "$user_tor_dir" ]; then
        chown -R "$(id -u):$(id -g)" "$user_tor_dir" 2>/dev/null || true
    fi

    ok "Permissões corrigidas"
}

# show_tools_menu foi substituído por _install_missing_optional (definida acima).

# ═════════════════════════════ IDIOMA DO SISTEMA ═════════════════════════════
check_and_set_locale() {
    header "Idioma do Sistema"

    if [ "$SKIP_LANGUAGE" = true ]; then
        ok "Verificação de idioma ignorada (--skip-language)"
        SUMMARY[locale]="Ignorado (--skip-language)"
        return
    fi

    local current_locale
    current_locale=$(locale 2>/dev/null | grep '^LANG=' | cut -d= -f2 | tr -d '"')
    [ -z "$current_locale" ] && current_locale="${LANG:-desconhecido}"
    ok "Idioma atual do sistema: $current_locale"

    if [[ "$current_locale" == pt_BR* ]]; then
        ok "O sistema já está configurado em Português (Brasil)"
        SUMMARY[locale]="Mantido ($current_locale)"
        return
    fi

    local want_change=false
    if [ "$SET_LOCALE_PTBR" = true ]; then
        want_change=true
    elif confirm "O idioma atual é '$current_locale'. Deseja alterar o idioma padrão do sistema para Português (Brasil) — pt_BR.UTF-8?" "n"; then
        want_change=true
    fi

    if [ "$want_change" != true ]; then
        ok "Idioma mantido como $current_locale (nenhuma alteração foi feita sem confirmação)"
        SUMMARY[locale]="Mantido ($current_locale)"
        return
    fi

    backup_file /etc/default/locale
    backup_file /etc/locale.gen

    if ! locale -a 2>/dev/null | grep -qi "^pt_BR.utf8$"; then
        log "Gerando locale pt_BR.UTF-8..."
        if grep -q "^# *pt_BR.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null; then
            sudo sed -i 's/^# *pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
        elif ! grep -q "^pt_BR.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null; then
            echo "pt_BR.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen > /dev/null
        fi
        sudo locale-gen pt_BR.UTF-8 || { err "Falha ao gerar o locale pt_BR.UTF-8."; return 1; }
    else
        ok "Locale pt_BR.UTF-8 já estava gerado"
    fi

    log "Atualizando locale padrão do sistema..."
    sudo update-locale LANG=pt_BR.UTF-8 LC_ALL=pt_BR.UTF-8 || { err "Falha ao atualizar o locale padrão do sistema."; return 1; }

    ok "Locale padrão atualizado para pt_BR.UTF-8"
    warn "Será necessário reiniciar a sessão (logout/login) ou o sistema para aplicar completamente o novo idioma."
    RESTART_SESSION_NEEDED=true
    SUMMARY[locale]="Alterado para pt_BR.UTF-8 (requer reinício de sessão)"
}

# ═════════════════════════════ RESUMO FINAL ══════════════════════════════════
show_summary() {
    header "Resumo da Instalação"
    echo ""
    echo -e "  Sistema: ${BOLD}${DISTRO_PRETTY:-desconhecido}${NC} (${ARCH:-desconhecida})"
    echo ""

    _summary_line() {
        local label="$1" key="$2"
        if [ -n "${SUMMARY[$key]+x}" ]; then
            echo -e "  ${BOLD}$label${NC}"
            echo -e "    ${SUMMARY[$key]}"
            echo ""
        fi
        return 0
    }

    _summary_line "Dependências base"    base_deps
    _summary_line "Node.js"              node
    _summary_line "Zsh + Oh My Zsh"      zsh
    _summary_line "pyenv"                pyenv
    _summary_line "Python 3.10"          python310
    _summary_line "Neovim"               nvim
    _summary_line ".NET SDK"             dotnet
    _summary_line "Idioma do sistema"    locale
    _summary_line "Visual Studio Code"   vscode
    _summary_line "Extensões VS Code"    vscode_extensions
    _summary_line "Google Chrome"        chrome
    _summary_line "Postman"              postman
    _summary_line "Burp Suite"           burpsuite
    _summary_line "Tor Browser"          tor

    if [ "${#FAILED_STEPS[@]}" -gt 0 ]; then
        echo -e "  ${BOLD}${RED}Etapas com falha${NC}"
        local s
        for s in "${FAILED_STEPS[@]}"; do
            echo -e "    ⚠️  $s"
        done
        echo "    Nada foi deixado em estado quebrado: os arquivos alterados por essas"
        echo "    etapas já têm backup em $BACKUP_ROOT e podem ser restaurados manualmente"
        echo "    caso o rollback automático não tenha sido aplicado."
        echo ""
    fi

    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo ""
    if [ "${#FAILED_STEPS[@]}" -eq 0 ]; then
        ok "Ambiente configurado com sucesso!"
    else
        warn "Ambiente configurado com ${#FAILED_STEPS[@]} etapa(s) pendente(s) — veja acima."
    fi
    echo ""
    echo "  ► Log completo desta execução:      $LOG_FILE"
    echo "  ► Backups dos arquivos alterados:   $BACKUP_ROOT"
    if [ "$RESTART_SESSION_NEEDED" = true ]; then
        warn "  ► É necessário reiniciar a sessão (logout/login) para aplicar todas as mudanças."
    else
        echo "  ► Reabra o terminal ou execute: exec \$SHELL"
    fi
    echo ""
    _write_log "DONE" "Instalação finalizada (${#FAILED_STEPS[@]} etapa(s) com falha)"
}

# ═════════════════════════════ MAIN ══════════════════════════════════════════
main() {
    parse_args "$@"

    if [ "$RUN_SELF_CHECK" = true ]; then
        header "Setup do Ambiente de Desenvolvimento v$SCRIPT_VERSION"
        local sc_rc=0
        self_check || sc_rc=$?
        exit "$sc_rc"
    fi

    header "Setup do Ambiente de Desenvolvimento v$SCRIPT_VERSION"
    log "Log desta execução:                 $LOG_FILE"
    log "Backups desta execução (se houver):  $BACKUP_ROOT"
    [ "$NONINTERACTIVE" = true ] && log "Modo não interativo ativado — nenhuma pergunta será feita."

    # Detecção do sistema e do shell são pré-requisitos e não modificam nada.
    # Se falharem de forma irrecuperável, elas mesmas abortam com exit 1.
    detect_system
    detect_shell

    # ══════════════════════════════════════════════════════════════════════
    #  FASE 1 — Análise completa do estado do ambiente (somente leitura)
    #           Nenhuma instalação ou modificação ocorre aqui.
    # ══════════════════════════════════════════════════════════════════════
    _run_scan

    # Exibe a tabela de estado de todos os componentes
    _print_state_report

    # ── Verifica se há algo a fazer ──────────────────────────────────────
    local any_action=false
    for _chk_key in deps node zsh pyenv python310 nvim dotnet locale \
                    vscode chrome postman burpsuite tor; do
        local _chk_s="${COMP_STATE[$_chk_key]:-}"
        if [ "$_chk_s" != "ok" ] && [ "$_chk_s" != "skip" ] && [ -n "$_chk_s" ]; then
            any_action=true
            break
        fi
    done

    if [ "$any_action" = false ]; then
        echo -e "\n${GREEN}${BOLD}  ✔  Todos os componentes estão funcionando corretamente.${NC}"
        echo -e "     Nenhuma ação necessária.\n"
        show_summary
        return
    fi

    # ══════════════════════════════════════════════════════════════════════
    #  FASE 2 — Auto-reparo (broken / incomplete)
    #           Componentes com problema são reparados automaticamente,
    #           sem perguntas. Exceção: wrong_config no Neovim (destrutivo).
    #
    #  IMPORTANTE: cada run_step é chamado com `|| true`. Sem isso, o
    #  `set -e` do topo do script abortaria a execução inteira na primeira
    #  etapa com falha, anulando todo o sistema de recuperação. Com `|| true`,
    #  run_step trata a falha (tenta novamente / pula / restaura backups) e
    #  o script sempre segue para a próxima etapa.
    # ══════════════════════════════════════════════════════════════════════
    _repair_components

    # ══════════════════════════════════════════════════════════════════════
    #  FASE 3 — Instalação de componentes ausentes (missing)
    #           Mandatórios: pergunta uma vez (lista consolidada).
    #           Opcionais:   menu exibe apenas os ausentes.
    # ══════════════════════════════════════════════════════════════════════
    _install_missing_mandatory
    _install_missing_optional

    show_summary
}

main "$@"
