#!/bin/sh
# Executado dentro da distro pelo docker-wsl.ps1. Uso: sh wsl-docker.sh <comando> [argumentos]
# Comandos: status | info | user <nome> | systemd | install <usuario> | start | data | uninstall [--purge]

set -u

WSL_CONF=/etc/wsl.conf
BOOT_SCRIPT=/usr/local/sbin/wsl-docker-boot.sh

log()  { printf '    %s\n' "$*"; }
fail() { printf '    ERRO: %s\n' "$*" >&2; exit 1; }

load_os() {
    [ -r /etc/os-release ] || fail "não encontrei /etc/os-release; distro não suportada."
    . /etc/os-release
    OS_ID=${ID:-unknown}
    OS_LIKE=${ID_LIKE:-}
    OS_NAME=${PRETTY_NAME:-$OS_ID}
    FAMILY=unsupported
    REPO=
    CODENAME=
    case " $OS_ID $OS_LIKE " in
        *" alpine "*) FAMILY=alpine ;;
        *" ubuntu "*) FAMILY=debian; REPO=ubuntu; CODENAME=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}} ;;
        *" debian "*) FAMILY=debian; REPO=debian; CODENAME=${VERSION_CODENAME:-} ;;
    esac
}

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "este comando precisa ser executado como root."
}

systemd_running() {
    [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]
}

# Altera ou cria "chave=valor" dentro de [secao] de um arquivo INI, sem duplicar linhas.
ini_set() {
    file=$1; section=$2; key=$3; value=$4
    [ -f "$file" ] || : > "$file"
    awk -v s="$section" -v k="$key" -v v="$value" '
        function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
        function flush() { while (blanks > 0) { print ""; blanks-- } }
        BEGIN { insec = 0; done = 0; blanks = 0 }
        /^[[:space:]]*$/ { blanks++; next }
        /^[[:space:]]*\[[^]]*\][[:space:]]*$/ {
            if (insec && !done) { print k "=" v; done = 1 }
            flush()
            name = trim($0); gsub(/^\[|\]$/, "", name)
            insec = (trim(name) == s)
            print; next
        }
        insec && index($0, "=") > 0 && trim(substr($0, 1, index($0, "=") - 1)) == k {
            flush()
            if (!done) { print k "=" v; done = 1 }
            next
        }
        { flush(); print }
        END {
            if (done) { flush() }
            else if (insec) { print k "=" v; flush() }
            else { b = blanks; flush(); if (b == 0 && NR > 0) print ""; print "[" s "]"; print k "=" v }
        }' "$file" > "$file.tmp" && cat "$file.tmp" > "$file" && rm -f "$file.tmp"
}

ini_get() {
    file=$1; section=$2; key=$3
    [ -f "$file" ] || return 0
    awk -v s="$section" -v k="$key" '
        function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
        /^[[:space:]]*\[[^]]*\][[:space:]]*$/ { name = trim($0); gsub(/^\[|\]$/, "", name); insec = (trim(name) == s); next }
        insec && index($0, "=") > 0 && trim(substr($0, 1, index($0, "=") - 1)) == k {
            print trim(substr($0, index($0, "=") + 1)); exit
        }' "$file"
}

ini_del() {
    file=$1; section=$2; key=$3
    [ -f "$file" ] || return 0
    awk -v s="$section" -v k="$key" '
        function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
        /^[[:space:]]*\[[^]]*\][[:space:]]*$/ { name = trim($0); gsub(/^\[|\]$/, "", name); insec = (trim(name) == s); print; next }
        insec && index($0, "=") > 0 && trim(substr($0, 1, index($0, "=") - 1)) == k { next }
        { print }' "$file" > "$file.tmp" && cat "$file.tmp" > "$file" && rm -f "$file.tmp"
}

docker_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof dockerd >/dev/null 2>&1
    else
        pgrep -x dockerd >/dev/null 2>&1
    fi
}

cmd_info() {
    load_os
    echo "OS_ID=$OS_ID"
    echo "OS_NAME=$OS_NAME"
    echo "FAMILY=$FAMILY"
    echo "DEFAULT_USER=$(id -un)"
}

cmd_status() {
    load_os
    user=${1:-$(id -un)}
    echo "OS_ID=$OS_ID"
    echo "OS_NAME=$OS_NAME"
    echo "FAMILY=$FAMILY"
    echo "DEFAULT_USER=$user"
    if systemd_running; then echo "SYSTEMD=1"; else echo "SYSTEMD=0"; fi
    if command -v docker >/dev/null 2>&1 || command -v dockerd >/dev/null 2>&1; then
        echo "DOCKER_INSTALLED=1"
        echo "DOCKER_VERSION=$(docker --version 2>/dev/null | sed -n 's/^Docker version \([^,]*\).*/\1/p')"
        echo "COMPOSE_VERSION=$(docker compose version --short 2>/dev/null)"
        echo "BUILDX_VERSION=$(docker buildx version 2>/dev/null | awk '{print $2}')"
    else
        echo "DOCKER_INSTALLED=0"
    fi
    if docker_running; then echo "SERVICE_ACTIVE=1"; else echo "SERVICE_ACTIVE=0"; fi
    if [ "$user" = "root" ] || id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo "USER_IN_GROUP=1"
    else
        echo "USER_IN_GROUP=0"
    fi
}

cmd_user() {
    require_root
    load_os
    name=${1:-}
    [ -n "$name" ] || fail "informe o nome do usuário."
    if id "$name" >/dev/null 2>&1; then
        log "Usuário '$name' já existe."
    elif [ "$FAMILY" = "alpine" ]; then
        log "Criando o usuário '$name'..."
        apk add --no-cache sudo >/dev/null || fail "não consegui instalar o sudo."
        adduser -D -s /bin/ash "$name" || fail "não consegui criar o usuário."
        addgroup "$name" wheel
        mkdir -p /etc/sudoers.d
        echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/wheel
        chmod 0440 /etc/sudoers.d/wheel
    else
        log "Criando o usuário '$name'..."
        if ! command -v sudo >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q sudo || fail "não consegui instalar o sudo."
        fi
        useradd -m -s /bin/bash "$name" || fail "não consegui criar o usuário."
        usermod -aG sudo "$name"
    fi
    ini_set "$WSL_CONF" user default "$name"
    log "Usuário padrão da distro: $name"
}

cmd_systemd() {
    require_root
    load_os
    if [ "$FAMILY" = "alpine" ]; then
        echo "SYSTEMD_CHANGED=0"
        return 0
    fi
    if [ "$(ini_get "$WSL_CONF" boot systemd)" = "true" ]; then
        log "systemd já está habilitado no $WSL_CONF."
        echo "SYSTEMD_CHANGED=0"
    else
        ini_set "$WSL_CONF" boot systemd true
        log "systemd habilitado no $WSL_CONF."
        echo "SYSTEMD_CHANGED=1"
    fi
}

install_debian() {
    export DEBIAN_FRONTEND=noninteractive
    [ -n "$CODENAME" ] || fail "não identifiquei a versão (codename) da distro."
    old=""
    for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        dpkg -s "$p" >/dev/null 2>&1 && old="$old $p"
    done
    if [ -n "$old" ]; then
        log "Removendo pacotes antigos do Docker:$old"
        apt-get remove -y -q $old || fail "não consegui remover os pacotes antigos."
    fi
    log "Atualizando a lista de pacotes..."
    apt-get update -q || fail "falha no apt-get update. Verifique a conexão com a internet."
    apt-get install -y -q ca-certificates curl || fail "não consegui instalar ca-certificates e curl."
    log "Adicionando o repositório oficial do Docker ($REPO $CODENAME)..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$REPO/gpg" -o /etc/apt/keyrings/docker.asc || fail "não consegui baixar a chave do repositório do Docker."
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$REPO $CODENAME stable" > /etc/apt/sources.list.d/docker.list
    apt-get update -q || fail "falha ao ler o repositório do Docker."
    log "Instalando Docker Engine, Compose v2 e Buildx..."
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || fail "falha ao instalar os pacotes do Docker."
}

install_alpine() {
    log "Atualizando a lista de pacotes..."
    apk update || fail "falha no apk update. Verifique a conexão com a internet."
    log "Instalando Docker Engine, Compose v2 e Buildx..."
    apk add docker docker-cli-compose docker-cli-buildx openrc || fail "falha ao instalar os pacotes do Docker."
    rc-update add docker default >/dev/null 2>&1
    # O serviço docker do OpenRC depende do "networking", que falha sem /etc/network/interfaces.
    if ! grep -Eqs '^[[:space:]]*iface[[:space:]]+lo([[:space:]]|$)' /etc/network/interfaces; then
        mkdir -p /etc/network
        printf 'auto lo\niface lo inet loopback\n' >> /etc/network/interfaces
        log "Rede do OpenRC configurada (/etc/network/interfaces com loopback)."
    fi
    mkdir -p "$(dirname "$BOOT_SCRIPT")"
    cat > "$BOOT_SCRIPT" <<'EOF'
#!/bin/sh
mkdir -p /run/openrc
[ -f /run/openrc/softlevel ] || touch /run/openrc/softlevel
rc-service docker start
EOF
    chmod 0755 "$BOOT_SCRIPT"
    ini_set "$WSL_CONF" boot command "$BOOT_SCRIPT"
    log "Inicialização automática configurada em $WSL_CONF ([boot] command)."
}

cmd_install() {
    require_root
    load_os
    user=${1:-}
    case "$FAMILY" in
        debian) install_debian ;;
        alpine) install_alpine ;;
        *) fail "distro '$OS_NAME' não suportada. Use Ubuntu, Debian ou Alpine." ;;
    esac
    if [ "$FAMILY" = "alpine" ]; then
        addgroup docker >/dev/null 2>&1 || true
    else
        groupadd -f docker
    fi
    if [ -n "$user" ] && [ "$user" != "root" ]; then
        if [ "$FAMILY" = "alpine" ]; then addgroup "$user" docker >/dev/null 2>&1; else usermod -aG docker "$user"; fi
        log "Usuário '$user' adicionado ao grupo docker."
    fi
    if [ "$FAMILY" = "debian" ] && ! systemd_running; then
        log "O systemd ainda não está ativo; o serviço será iniciado após reiniciar a distro."
        echo "RESTART_REQUIRED=1"
        return 0
    fi
    cmd_start
}

use_iptables_legacy() {
    if [ -x /usr/sbin/iptables-legacy ] && command -v update-alternatives >/dev/null 2>&1; then
        log "Tentando novamente com iptables-legacy..."
        update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1
        return 0
    fi
    return 1
}

run_boot_alpine() {
    "$BOOT_SCRIPT" 2>&1 | grep -v 'needs non existent service' | sed 's/^/    /'
}

start_alpine() {
    [ -x "$BOOT_SCRIPT" ] || fail "não encontrei $BOOT_SCRIPT; rode a instalação de novo."
    log "Iniciando o Docker pelo OpenRC..."
    run_boot_alpine
    i=0
    while [ $i -lt 10 ] && ! docker_running; do sleep 1; i=$((i + 1)); done
    docker_running && return 0
    log "A primeira tentativa falhou; limpando o estado do OpenRC e tentando de novo..."
    rc-service docker stop >/dev/null 2>&1
    rm -rf /run/openrc
    run_boot_alpine
}

cmd_start() {
    require_root
    load_os
    if [ "$FAMILY" = "alpine" ]; then
        start_alpine
    elif systemd_running; then
        systemctl enable docker.service containerd.service >/dev/null 2>&1
        systemctl restart docker.service >/dev/null 2>&1
        if ! systemctl is-active --quiet docker.service && use_iptables_legacy; then
            systemctl restart docker.service >/dev/null 2>&1
        fi
    else
        service docker start >/dev/null 2>&1
    fi
    i=0
    while [ $i -lt 15 ] && ! docker_running; do sleep 1; i=$((i + 1)); done
    if docker_running; then
        log "Serviço do Docker em execução."
        echo "SERVICE_ACTIVE=1"
    else
        log "O serviço do Docker não iniciou."
        echo "SERVICE_ACTIVE=0"
        return 1
    fi
}

cmd_data() {
    require_root
    if docker_running && command -v docker >/dev/null 2>&1; then
        echo "CONTAINERS=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')"
        echo "IMAGES=$(docker images -q 2>/dev/null | sort -u | wc -l | tr -d ' ')"
        echo "VOLUMES=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')"
    fi
    if [ -d /var/lib/docker ]; then
        echo "DATA_SIZE=$(du -sh /var/lib/docker 2>/dev/null | awk '{print $1}')"
    else
        echo "DATA_SIZE=0"
    fi
}

cmd_uninstall() {
    require_root
    load_os
    purge=0
    [ "${1:-}" = "--purge" ] && purge=1
    case "$FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            if systemd_running; then
                systemctl stop docker.service docker.socket containerd.service >/dev/null 2>&1
                systemctl disable docker.service containerd.service >/dev/null 2>&1
            fi
            log "Removendo os pacotes do Docker..."
            pkgs=""
            for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker.io docker-compose-v2; do
                dpkg -s "$p" >/dev/null 2>&1 && pkgs="$pkgs $p"
            done
            [ -n "$pkgs" ] && { apt-get purge -y -q $pkgs || fail "falha ao remover os pacotes."; }
            apt-get autoremove -y -q >/dev/null 2>&1
            rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
            ;;
        alpine)
            rc-service docker stop >/dev/null 2>&1
            rc-update del docker default >/dev/null 2>&1
            log "Removendo os pacotes do Docker..."
            apk del docker docker-cli-compose docker-cli-buildx >/dev/null 2>&1 || fail "falha ao remover os pacotes."
            rm -f "$BOOT_SCRIPT"
            ini_del "$WSL_CONF" boot command
            ;;
        *) fail "distro '$OS_NAME' não suportada." ;;
    esac
    if [ $purge -eq 1 ]; then
        log "Apagando imagens, containers e volumes (/var/lib/docker e /var/lib/containerd)..."
        rm -rf /var/lib/docker /var/lib/containerd
    fi
    log "Docker removido."
}

command=${1:-}
[ $# -gt 0 ] && shift
case "$command" in
    info)      cmd_info ;;
    status)    cmd_status "$@" ;;
    user)      cmd_user "$@" ;;
    systemd)   cmd_systemd ;;
    install)   cmd_install "$@" ;;
    start)     cmd_start ;;
    data)      cmd_data ;;
    uninstall) cmd_uninstall "$@" ;;
    *) fail "comando desconhecido: '$command'. Use: info, status, user, systemd, install, start, data, uninstall." ;;
esac
