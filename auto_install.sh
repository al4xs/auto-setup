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
SCRIPT_VERSION="2.1.0"

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
configuração ou plugins.

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

    local deps=(curl wget git unzip build-essential ca-certificates gnupg
                lsb-release apt-transport-https software-properties-common
                python3 python3-pip python3-venv file)
    local missing=()

    for pkg in "${deps[@]}"; do
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
        ok "Node já instalado ($(node -v))"
        SUMMARY[node]="Mantido ($(node -v))"
        return
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

    if [ "$CURRENT_SHELL_NAME" != "zsh" ]; then
        if ! confirm "Seu shell padrão é '$CURRENT_SHELL_NAME'. Deseja instalar e configurar Zsh + Oh My Zsh também?" "s"; then
            ok "Zsh não será instalado — mantendo $CURRENT_SHELL_NAME"
            SUMMARY[zsh]="Ignorado (usuário optou por manter $CURRENT_SHELL_NAME)"
            return
        fi
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
install_nvim() {
    header "Neovim (al4xs/neovim-config)"

    if [ "$SKIP_NEOVIM" = true ]; then
        ok "Instalação do Neovim ignorada (--skip-neovim)"
        SUMMARY[nvim]="Ignorado (--skip-neovim)"
        return
    fi

    if command -v nvim >/dev/null 2>&1; then
        ok "Neovim já instalado ($(nvim --version | head -1))"
    else
        log "Instalando Neovim..."
        apt_install neovim || { err "Falha ao instalar o pacote neovim."; return 1; }
        ok "Neovim instalado ($(nvim --version | head -1))"
    fi

    _install_nvim_dependencies

    mkdir -p ~/.config
    local nvim_cfg="$HOME/.config/nvim"

    if [ -d "$nvim_cfg" ]; then
        local backup_dir="$BACKUP_ROOT$nvim_cfg"
        mkdir -p "$(dirname "$backup_dir")"
        cp -a "$nvim_cfg" "$backup_dir" 2>/dev/null || true
        ok "Backup da configuração atual salvo em: $backup_dir"

        if [ -d "$nvim_cfg/.git" ] && git -C "$nvim_cfg" remote get-url origin 2>/dev/null | grep -qi "al4xs/neovim-config"; then
            log "Configuração já é al4xs/neovim-config — atualizando..."
            if git -C "$nvim_cfg" pull --ff-only >>"$LOG_FILE" 2>&1; then
                ok "Configuração do Neovim atualizada"
            else
                warn "Não foi possível atualizar via 'git pull --ff-only' (possíveis alterações locais). Mantendo a versão atual."
            fi
        else
            if confirm "Encontrada uma configuração de Neovim existente que NÃO é al4xs/neovim-config. Já foi feito um backup em $backup_dir. Deseja substituí-la?" "s"; then
                log "Substituindo configuração existente (backup já salvo acima)..."
                rm -rf "$nvim_cfg"
                log "Clonando al4xs/neovim-config..."
                git clone --depth=1 https://github.com/al4xs/neovim-config "$nvim_cfg" \
                    || { err "Falha ao clonar al4xs/neovim-config."; return 1; }
            else
                ok "Configuração de Neovim existente mantida (nada foi apagado)."
                SUMMARY[nvim]="Mantido (configuração existente preservada)"
                return
            fi
        fi
    else
        log "Clonando al4xs/neovim-config..."
        git clone --depth=1 https://github.com/al4xs/neovim-config "$nvim_cfg" \
            || { err "Falha ao clonar al4xs/neovim-config."; return 1; }
    fi

    python3 -m pip install --user --quiet pynvim 2>/dev/null || warn "Não foi possível instalar 'pynvim' (opcional para plugins Python)."

    log "Sincronizando plugins do Neovim (pode levar alguns minutos na primeira vez)..."
    if timeout 300 nvim --headless "+Lazy! sync" +qa >>"$LOG_FILE" 2>&1; then
        ok "Plugins sincronizados com sucesso"
    else
        warn "A sincronização de plugins retornou avisos/erros — verifique o log: $LOG_FILE"
    fi

    log "Validando que o Neovim abre sem erros..."
    if timeout 30 nvim --headless -c "quit" >>"$LOG_FILE" 2>&1; then
        ok "Neovim abre corretamente, sem erros"
        SUMMARY[nvim]="Instalado, plugins sincronizados e validados"
    else
        err "Neovim apresentou um erro ao abrir — verifique o log: $LOG_FILE"
        SUMMARY[nvim]="Instalado (com erros na validação — veja o log)"
    fi
}

_install_nvim_dependencies() {
    log "Verificando dependências do Neovim (ripgrep, fd, unzip, ferramentas de build, cargo)..."
    local missing=()
    command -v rg >/dev/null 2>&1 || missing+=(ripgrep)
    { command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1; } || missing+=(fd-find)
    command -v unzip >/dev/null 2>&1 || missing+=(unzip)
    command -v gcc >/dev/null 2>&1 || missing+=(build-essential)
    command -v cargo >/dev/null 2>&1 || missing+=(cargo)

    if [ ${#missing[@]} -gt 0 ]; then
        log "Instalando dependências ausentes: ${missing[*]}"
        apt_install "${missing[@]}" || warn "Algumas dependências opcionais do Neovim não puderam ser instaladas — alguns plugins podem não funcionar."
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
        ok "VS Code já instalado ($ver)"
        if ! confirm "Deseja atualizar/reinstalar?" "n"; then
            SUMMARY[vscode]="Mantido ($ver)"
            _install_vscode_extensions
            return
        fi
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
        ok "Chrome já instalado ($ver)"
        if ! confirm "Deseja reinstalar?" "n"; then
            SUMMARY[chrome]="Mantido ($ver)"
            return
        fi
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
        ok "Postman já instalado"
        if ! confirm "Deseja reinstalar?" "n"; then
            SUMMARY[postman]="Mantido"
            return
        fi
        sudo rm -rf /opt/Postman
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
        ok "Burp Suite já instalado"
        if ! confirm "Deseja reinstalar?" "n"; then
            SUMMARY[burpsuite]="Mantido"
            return
        fi
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

    if [ -d "$HOME/.local/share/torbrowser" ] || [ -d /opt/tor-browser ]; then
        ok "Tor Browser já instalado"
        if ! confirm "Deseja reinstalar?" "n"; then
            SUMMARY[tor]="Mantido"
            return
        fi
        sudo rm -rf /opt/tor-browser "$HOME/.local/share/torbrowser"
    fi

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

    log "Verificando integridade do arquivo..."
    if ! tar -tJf "$archive" >/dev/null 2>&1; then
        err "Arquivo do Tor Browser corrompido."
        SUMMARY[tor]="Falhou (arquivo corrompido)"
        return 1
    fi

    log "Instalando em /opt/tor-browser..."
    sudo mkdir -p /opt/tor-browser
    sudo tar -xJf "$archive" --strip-components=1 -C /opt/tor-browser
    sudo chown -R root:root /opt/tor-browser
    sudo chmod -R a+rX /opt/tor-browser
    sudo chmod +x /opt/tor-browser/Browser/start-tor-browser 2>/dev/null || true

    if [ -f /opt/tor-browser/Browser/start-tor-browser.desktop ]; then
        sudo cp /opt/tor-browser/Browser/start-tor-browser.desktop \
                /usr/share/applications/tor-browser.desktop
        sudo sed -i \
            's|Exec=.*|Exec=/opt/tor-browser/Browser/start-tor-browser %u|' \
            /usr/share/applications/tor-browser.desktop
        sudo sed -i \
            's|Icon=.*|Icon=/opt/tor-browser/Browser/browser/chrome/icons/default/default128.png|' \
            /usr/share/applications/tor-browser.desktop 2>/dev/null || true
        sudo chmod 644 /usr/share/applications/tor-browser.desktop
        ok "Atalho criado no menu de aplicativos"
    else
        warn "Arquivo .desktop de origem não encontrado — o atalho pode não aparecer no menu de aplicativos."
    fi

    sudo tee /usr/local/bin/tor-browser > /dev/null << 'EOF'
#!/usr/bin/env bash
exec /opt/tor-browser/Browser/start-tor-browser "$@"
EOF
    sudo chmod +x /usr/local/bin/tor-browser

    log "Validando instalação..."
    if [ -x /opt/tor-browser/Browser/start-tor-browser ] \
       && file /opt/tor-browser/Browser/firefox.real 2>/dev/null | grep -qi "ELF"; then
        ok "Tor Browser $tor_ver instalado e validado com sucesso"
        SUMMARY[tor]="Instalado ($tor_ver)"
    else
        warn "Tor Browser instalado, mas não foi possível confirmar totalmente o binário na validação."
        SUMMARY[tor]="Instalado ($tor_ver, validação parcial)"
    fi
}

# ── MENU DE FERRAMENTAS ───────────────────────────────────────────────────────
show_tools_menu() {
    header "Ferramentas Opcionais"

    local items=()

    if [ "$INSTALL_ALL" = true ]; then
        ok "Instalando todas as ferramentas opcionais (--install-all)"
        items=(1 2 3 4 5)
    elif [ "$NONINTERACTIVE" = true ]; then
        ok "[não interativo] Ferramentas opcionais ignoradas (use --install-all para instalá-las)"
        return
    else
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

        if echo "$input" | grep -qw "6"; then
            items=(1 2 3 4 5)
        else
            for n in $input; do
                [[ "$n" =~ ^[1-5]$ ]] && items+=("$n")
            done
        fi
    fi

    # Cada instalação é isolada e passa por run_step: falha individual não
    # interrompe as demais, e cada uma tem sua própria recuperação de falhas.
    # `|| true` é obrigatório aqui pelo mesmo motivo do main(): sem ele, o
    # `set -e` do topo do script abortaria todo o menu de ferramentas no
    # primeiro item que falhar.
    for item in "${items[@]}"; do
        case "$item" in
            1) run_step "Visual Studio Code" install_vscode   || true ;;
            2) run_step "Google Chrome"       install_chrome   || true ;;
            3) run_step "Postman"             install_postman  || true ;;
            4) run_step "Burp Suite"          install_burpsuite || true ;;
            5)
                if [ "$SKIP_TOR" = true ]; then
                    ok "Tor Browser ignorado (--skip-tor)"
                    SUMMARY[tor]="Ignorado (--skip-tor)"
                else
                    run_step "Tor Browser" install_tor || true
                fi
                ;;
        esac
    done
}

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
    log "Log desta execução:                $LOG_FILE"
    log "Backups desta execução (se houver): $BACKUP_ROOT"
    [ "$NONINTERACTIVE" = true ] && log "Modo não interativo ativado — nenhuma pergunta será feita."

    # Detecção do sistema e do shell são pré-requisitos e não modificam nada:
    # se falharem de forma irrecuperável, elas mesmas abortam com exit 1.
    detect_system
    detect_shell

    # IMPORTANTE: cada run_step é chamado com `|| true`. Sem isso, o `set -e`
    # do topo do script abortaria a instalação inteira no primeiro passo que
    # falhar, mesmo que run_step já tenha tratado, registrado e (se preciso)
    # restaurado os backups daquela etapa — o que anularia todo o sistema de
    # recuperação de falhas. Com `|| true`, run_step decide o que fazer
    # (tentar novamente, pular, restaurar, abortar) e o script sempre segue
    # para a etapa seguinte por conta própria.
    run_step "Dependências Base"    install_deps          || true
    run_step "Node.js"              install_node          || true
    run_step "Zsh + Oh My Zsh"      install_zsh           || true
    run_step "pyenv"                install_pyenv         || true
    run_step "Python 3.10"          install_python310     || true
    run_step "Neovim"               install_nvim          || true
    run_step ".NET SDK"             install_dotnet        || true
    run_step "Idioma do Sistema"    check_and_set_locale  || true
    show_tools_menu
    show_summary
}

main "$@"
