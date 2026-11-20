#!/bin/bash
# =============================================================================
# setupifsul.sh - Configuração das máquinas dos laboratórios do IFSul
# Alvo: Ubuntu 26.04 LTS (resolute), amd64
#
# Fluxo previsto:
#   1. Rodar este script UMA vez na máquina-template (faz os downloads pesados).
#   2. A TI clona a template para as máquinas do laboratório.
#   3. Em cada máquina, o laboratorista só liga e define nome e IP (conforme a
#      posição do PC). No primeiro boot, o serviço identidade-clone gera a
#      identidade própria da máquina e reinicia uma vez, sozinho.
#
# Rodar o script de novo numa máquina é opcional: serve para corrigir uma etapa
# que falhou ou aplicar mudanças novas deste repositório.
#
# Uso:   wget -qO setupifsul.sh https://raw.githubusercontent.com/alexorozco-ifsul/script_labs/main/setupifsul.sh
#        sudo bash setupifsul.sh
#
# O script pode ser executado novamente na mesma máquina: cada etapa verifica o
# que já foi feito. Uma etapa que falha não interrompe as outras; no final é
# mostrado um resumo com as falhas. Log completo em /var/log/setupifsul.log
# =============================================================================

set -uo pipefail

# ----------------------------------------------------------------------------
# Configurações
# ----------------------------------------------------------------------------
REPO="https://raw.githubusercontent.com/alexorozco-ifsul/script_labs/main"
ALUNO="alunoinfo"                 # usuário dos alunos (home limpa a cada sessão)
ADMIN="ifsul"                     # usuário administrador (escondido da tela de login)
SWAP_GB=20                        # tamanho do /swapfile adicional

PT_URL="https://www.dropbox.com/scl/fi/4yn88h3o8ihbiodj3twme/CiscoPacketTracer_901_Ubuntu_64bit.deb?rlkey=p80dod2n2jg2mgq74sgstg0vt&st=tuehpkz6&dl=1"
PT_SHA256="3683dd87e779885372ae9a35c1a6e594d12f493e649e7c697408729c1459479b"

# Versões: só o Packet Tracer (arquivo fixo) e o Python do /opt/ia (3.13, o TensorFlow
# ainda não tem pacotes para o 3.14) são fixos. O resto é sempre a versão mais nova.

# Spring Tools: o link da versão atual é lido da página oficial
STS_PAGINA="https://spring.io/tools"

BRMODELO_URL="https://github.com/chcandido/brModelo/releases/latest/download/brModelo.jar"
BRMODELO_ICON="https://github.com/chcandido/brModelo/raw/master/src/imagens/icone.png"

# update-notifier (avisos de atualização) e não update-manager: o update-manager é
# dependência do ubuntu-desktop-minimal, e removê-lo derruba o metapacote do desktop
APT_REMOVER=(gnome-initial-setup totem showtime update-notifier apport apport-gtk)

APT_INSTALAR=(
    default-jdk uidmap libreoffice virtualbox vlc git curl wget rsync
    net-tools traceroute nmap openssh-server
    mysql-server apache2 php libapache2-mod-php php-mysql
    python3-pip python3-venv
)

# "nome|opções[|trilha]" - instalados em segundo plano, em paralelo com o resto.
# "trilha": usa a trilha numérica mais nova com versão estável (ex.: node 26/stable),
# para snaps cujo canal latest está vazio ou parado numa versão antiga.
SNAPS=(
    "eclipse|--classic"
    "node|--classic|trilha"                     # canal latest do snap node está vazio
    "android-studio|--classic"
    "code|--classic"
    "mysql-workbench-community|"
    "arduino||trilha"                           # latest ainda é a IDE 1.8.19
    "postman|"
    "blender|--classic"
    "blockbench-snapcraft|"
    "intellij-idea-community|--classic"
)

IA_PACOTES=(scikit-learn matplotlib pandas seaborn tensorflow ipykernel)

# ----------------------------------------------------------------------------
# Infraestrutura
# ----------------------------------------------------------------------------
LOG=/var/log/setupifsul.log
SNAP_LOG=/var/log/setupifsul-snaps.log
FALHAS=()
TMP=""

msg()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
aviso(){ printf '\033[1;33m[AVISO]\033[0m %s\n' "$*"; }

# passo "descrição" comando [args...]  -> executa, registra e segue em frente
passo() {
    local desc=$1; shift
    msg "$desc"
    if "$@"; then
        echo "[OK] $desc"
    else
        echo "[FALHA] $desc"
        FALHAS+=("$desc")
    fi
}

# baixa <url> <destino>  (com novas tentativas)
baixa() {
    wget -q --tries=5 --waitretry=5 --timeout=60 "$1" -O "$2.part" && mv "$2.part" "$2"
}

# baixa um arquivo deste repositório
baixa_repo() { baixa "$REPO/$1" "$2"; }

apt_get() {
    DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        -o DPkg::Lock::Timeout=600 "$@"
}

# apt-get update esperando a trava das listas (o DPkg::Lock::Timeout só cobre a do
# dpkg; a atualização automática do Ubuntu pode estar com as listas ocupadas)
apt_update() {
    local i
    for i in $(seq 60); do
        apt_get update && return 0
        sleep 10
    done
    return 1
}

como_aluno() { runuser -u "$ALUNO" -- "$@"; }

# saida_contem <padrão> comando [args...]  -> o comando escreve o texto procurado?
# Não usar "comando | grep -q": com pipefail, o grep -q fecha o pipe ao achar o
# texto, o comando recebe SIGPIPE e o teste "falha" mesmo tendo encontrado.
saida_contem() {
    local padrao=$1 saida; shift
    saida=$("$@" 2>/dev/null)
    grep -q -- "$padrao" <<< "$saida"
}

# ----------------------------------------------------------------------------
# Verificações iniciais
# ----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Execute como root: sudo bash $0"
    exit 1
fi

. /etc/os-release
if [ "${VERSION_ID:-}" != "26.04" ]; then
    aviso "Este script foi feito para o Ubuntu 26.04 (detectado: ${PRETTY_NAME:-desconhecido})."
    read -r -p "Continuar mesmo assim? [s/N] " r
    [[ "$r" =~ ^[sS]$ ]] || exit 1
fi

if ! wget -q --spider --timeout=15 "$REPO/setupifsul.sh"; then
    echo "Sem acesso a $REPO - verifique a rede."
    exit 1
fi

# Senha do root: definida uma única vez, na template (num Ubuntu recém-instalado o
# root vem bloqueado, sem senha). Nos clones ela já existe e o script não pergunta.
# Para trocar depois: sudo passwd root
root_tem_senha() { [[ "$(getent shadow root | cut -d: -f2)" == \$* ]]; }
if [ -z "${ROOT_PASS:-}" ] && ! root_tem_senha; then
    echo "O root ainda não tem senha (primeira execução, na template)."
    while true; do
        read -r -s -p "Nova senha do root: " ROOT_PASS; echo
        read -r -s -p "Repita a senha: " r; echo
        [ -n "$ROOT_PASS" ] && [ "$ROOT_PASS" = "$r" ] && break
        echo "As senhas não conferem ou estão vazias. Tente de novo."
    done
fi

exec > >(tee -a "$LOG") 2>&1
echo "===== setupifsul.sh - início: $(date) ====="

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------------------
# Etapas
# ----------------------------------------------------------------------------
senha_root() {
    if [ -z "${ROOT_PASS:-}" ]; then
        echo "Senha do root já definida (veio da template): mantida."
        return 0
    fi
    echo "root:$ROOT_PASS" | chpasswd
}

# Máquinas clonadas saem com a identidade da template (machine-id, chaves de host do
# SSH, chave do NetworkManager que gera os endereços IPv6, etc.). Em vez de exigir que
# o script rode em cada clone, instala um serviço que, no boot, compara o UUID do
# hardware (placa/VM) com o registrado: se mudou, é um clone -> gera identidade nova e
# reinicia uma vez. Nome e IP não são alterados: o laboratorista define conforme a
# posição do PC no laboratório.
identidade() {
    mkdir -p /var/lib/setupifsul
    cat > /usr/local/sbin/identidade-clone <<'EOT'
#!/bin/bash
# Gera identidade nova quando a máquina é um clone (UUID do hardware mudou).
# Uso: identidade-clone [--sem-reiniciar]
ESTADO=/var/lib/setupifsul/uuid
UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo desconhecido)
[ "$(cat "$ESTADO" 2>/dev/null)" = "$UUID" ] && exit 0

echo "Hardware diferente do registrado ($UUID): gerando identidade nova."
# machine-id (aleatório; não usar systemd-machine-id-setup, que pode derivar do UUID)
systemd-id128 new > /etc/machine-id.novo && mv /etc/machine-id.novo /etc/machine-id
chmod 444 /etc/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
# Chaves de host do SSH
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A
# NetworkManager: chave secreta (endereços IPv6 estáveis) e concessões DHCP da template
rm -f /var/lib/NetworkManager/secret_key /var/lib/NetworkManager/*.lease
# Segredo e semente aleatória do systemd (recriados automaticamente)
rm -f /var/lib/systemd/credential.secret /var/lib/systemd/random-seed

# Só reinicia se o registro foi gravado (senão reiniciaria em todo boot)
if ! { echo "$UUID" > "$ESTADO" && [ "$(cat "$ESTADO")" = "$UUID" ]; }; then
    logger -t identidade-clone "ERRO: não gravou $ESTADO; sem reiniciar"
    exit 1
fi
logger -t identidade-clone "Identidade nova gerada para o hardware $UUID"
# Reinicia uma vez para todos os serviços usarem a identidade nova
[ "${1:-}" = "--sem-reiniciar" ] || systemctl --no-block reboot
exit 0
EOT
    chmod 755 /usr/local/sbin/identidade-clone

    cat > /etc/systemd/system/identidade-clone.service <<'EOT'
[Unit]
Description=Gera identidade nova em máquinas clonadas (machine-id, SSH, rede)
After=local-fs.target
Before=NetworkManager.service ssh.service display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/identidade-clone

[Install]
WantedBy=multi-user.target
EOT
    systemctl daemon-reload && systemctl enable identidade-clone.service || return 1

    # Primeira execução (template): registra o hardware atual, sem trocar nada.
    # Se o script rodar num clone cujo serviço ainda não agiu, gera a identidade
    # agora (sem reiniciar; reinicie ao final).
    if [ ! -f /var/lib/setupifsul/uuid ]; then
        cat /sys/class/dmi/id/product_uuid > /var/lib/setupifsul/uuid 2>/dev/null ||
            echo desconhecido > /var/lib/setupifsul/uuid
        echo "Hardware desta máquina registrado como referência (template)."
    else
        /usr/local/sbin/identidade-clone --sem-reiniciar
    fi
}

# O instalador do Ubuntu grava /etc/netplan/00-installer-config.yaml com dhcp4: true.
# Quando o IP é definido à mão (GNOME/nmcli), o NetworkManager grava 90-NM-*.yaml, e o
# netplan JUNTA os dois: a conexão vira "automática + endereço fixo". Sem servidor DHCP,
# a placa cai no reboot ou quando o netplan é regenerado (ex.: atualização do netplan).
# Retira os arquivos do instalador/cloud-init (com backup); o NetworkManager passa a ser
# a única fonte: IP manual fica manual, e sem IP manual ele usa DHCP normalmente.
# Em clones, o arquivo do instalador ainda aponta para o MAC da máquina-template.
rede() {
    grep -qs 'renderer: NetworkManager' /etc/netplan/*.yaml || {
        echo "Netplan não usa o NetworkManager: configuração de rede não alterada."; return 0; }
    local bkp=/var/lib/setupifsul/netplan-backup f mudou=0
    mkdir -p "$bkp"
    for f in /etc/netplan/00-installer-config.yaml /etc/netplan/50-cloud-init.yaml; do
        [ -f "$f" ] || continue
        echo "Movendo $f para $bkp/"
        mv "$f" "$bkp/" && mudou=1
    done
    if [ -d /etc/cloud ]; then
        echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi
    # Nos laboratórios o IP vem do DHCP com filtro/reserva por MAC: garante que o
    # cliente DHCP se identifique pelo MAC (já é o padrão do NM; fica explícito para
    # não depender do machine-id, que muda nos clones)
    cat > /etc/NetworkManager/conf.d/90-ifsul-dhcp.conf <<'EOT'
[connection]
ipv4.dhcp-client-id=mac
ipv6.dhcp-duid=ll
EOT
    # Só regera os arquivos; a mudança vale no próximo boot (não derruba a rede agora)
    [ $mudou -eq 0 ] || netplan generate
}

# Snaps em segundo plano: baixam enquanto o apt trabalha
# maior trilha numérica do snap com versão estável publicada (ex.: 26)
snap_trilha_mais_nova() {
    snap info "$1" 2>/dev/null | awk '
        /^channels:/ { c = 1; next }
        c && $1 ~ /^[0-9]+\/stable:$/ && $2 != "--" { split($1, a, "/"); print a[1] }
    ' | sort -n | tail -n 1
}

snaps_inicia() {
    (
        snap wait system seed.loaded
        for item in "${SNAPS[@]}"; do
            nome=${item%%|*}; resto=${item#*|}; opts=${resto%%|*}; canal=""
            if [ "$resto" != "$opts" ] && [ "${resto#*|}" = trilha ]; then
                t=$(snap_trilha_mais_nova "$nome")
                if [ -n "$t" ]; then canal="$t/stable"; opts="$opts --channel=$canal"
                else echo "snap $nome: trilha mais nova não encontrada, usando latest"; fi
            fi
            if snap list "$nome" >/dev/null 2>&1; then
                # Já instalado: atualiza para a trilha mais nova, se surgiu uma
                atual=$(snap list "$nome" 2>/dev/null | awk 'NR == 2 { print $4 }')
                if [ -n "$canal" ] && [ "$atual" != "$canal" ]; then
                    snap refresh "$nome" --channel="$canal" &&
                        echo "[OK] snap $nome ($atual -> $canal)" ||
                        echo "[FALHA] snap $nome ($atual -> $canal)"
                else
                    echo "[OK] snap $nome (já instalado)"
                fi
                continue
            fi
            # Até 3 tentativas: o apt pode atualizar o snapd ao mesmo tempo e
            # reiniciá-lo no meio de uma instalação
            for t in 1 2 3; do
                snap install "$nome" $opts && break
                echo "snap $nome falhou (tentativa $t/3)"; sleep 30
            done
            if snap list "$nome" >/dev/null 2>&1; then
                echo "[OK] snap $nome"
            else
                echo "[FALHA] snap $nome"
            fi
        done
        snap remove snap-store 2>/dev/null
        echo "[FIM]"
    ) > "$SNAP_LOG" 2>&1 &
    SNAP_PID=$!
}

apt_base() {
    apt_update && apt_get full-upgrade
}

apt_remover() {
    local instalados=()
    for p in "${APT_REMOVER[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 && instalados+=("$p")
    done
    [ ${#instalados[@]} -eq 0 ] || apt_get purge "${instalados[@]}"
}

apt_instalar() {
    apt_get install "${APT_INSTALAR[@]}"
}

packet_tracer() {
    if dpkg -s packettracer >/dev/null 2>&1 &&
       [ "$(dpkg-query -W -f='${Version}' packettracer)" = "9.0.1" ]; then
        echo "Packet Tracer 9.0.1 já instalado."; return 0
    fi
    baixa "$PT_URL" "$TMP/pt.deb" || return 1
    if ! echo "$PT_SHA256  $TMP/pt.deb" | sha256sum -c -; then
        echo "SHA-256 do Packet Tracer não confere - arquivo alterado ou corrompido."
        return 1
    fi
    apt_get install "$TMP/pt.deb"
}

spring_tools() {
    local url ver dir
    url=$(wget -qO- "$STS_PAGINA" | grep -m 1 -oE 'https://cdn\.spring\.io/spring-tools/release/dist/[^"]*-linux\.gtk\.x86_64\.tar\.gz')
    [ -n "$url" ] || { aviso "Link do Spring Tools não encontrado em $STS_PAGINA"; return 1; }
    ver=$(sed -E 's#.*/dist/([^/]+)/.*#\1#' <<< "$url")
    echo "Spring Tools mais novo: $ver"
    dir=/opt/sts-$ver
    if [ ! -x "$dir/SpringToolsForEclipse" ]; then
        baixa "$url" "$TMP/sts.tar.gz" &&
        tar -xzf "$TMP/sts.tar.gz" -C /opt/ || return 1
    fi
    # Remove atalhos e versões antigas (o script antigo usava sts-<versão>.desktop)
    rm -f /usr/share/applications/sts-*.desktop
    for d in /opt/sts-*; do [ "$d" != "$dir" ] && [ -d "$d" ] && rm -rf "$d"; done
    cat > /usr/share/applications/spring-tools.desktop <<EOT
[Desktop Entry]
Name=Spring Tools for Eclipse
Exec=$dir/SpringToolsForEclipse %u
Icon=$dir/icon.xpm
Type=Application
Categories=Development;IDE;
MimeType=x-scheme-handler/eclipse+command;x-scheme-handler/eclipse+mpc;
EOT
}

brmodelo() {
    mkdir -p /opt/brmodelo &&
    baixa "$BRMODELO_URL" /opt/brmodelo/brmodelo.jar &&
    baixa "$BRMODELO_ICON" /opt/brmodelo/icon.png &&
    baixa_repo brmodelo.desktop /usr/share/applications/brmodelo.desktop
}

# Python 3.13 compartilhado: o TensorFlow ainda não suporta o Python 3.14 do sistema
# Python mais novo (estável) para uso geral, como comando python3.X em /usr/local/bin.
# Não substitui o python3 do sistema (as ferramentas do Ubuntu dependem dele).
python_novo() {
    export UV_PYTHON_INSTALL_DIR=/opt/ia-python UV_PYTHON_BIN_DIR=/usr/local/bin
    local ver menor
    ver=$(uv python list --only-downloads 2>/dev/null |
          grep -oE '^cpython-3\.[0-9]+\.[0-9]+-linux-x86_64-gnu ' | cut -d- -f2 | sort -V | tail -n 1)
    [ -n "$ver" ] || { aviso "Não foi possível descobrir o Python mais novo"; return 1; }
    menor=${ver%.*}
    echo "Python mais novo: $ver"
    uv python install --upgrade "$menor" || return 1
    chmod -R a+rX /opt/ia-python
    "/usr/local/bin/python$menor" --version
}

python_ia() {
    export UV_PYTHON_INSTALL_DIR=/opt/ia-python
    if command -v uv >/dev/null; then
        uv self update >/dev/null 2>&1 || true
    else
        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh || return 1
    fi
    [ -x /opt/ia/bin/python ] || uv venv --python 3.13 /opt/ia || return 1
    uv python install --upgrade --no-bin 3.13 >/dev/null 2>&1 || true   # correções do 3.13
    # --upgrade: a cada execução as bibliotecas vão para a versão mais nova
    uv pip install --upgrade --python /opt/ia/bin/python "${IA_PACOTES[@]}" &&
    # PyTorch só CPU: a versão padrão traz vários GB de bibliotecas CUDA
    uv pip install --upgrade --python /opt/ia/bin/python torch --index-url https://download.pytorch.org/whl/cpu || return 1
    # python-ia: script (não link simbólico). O Python acha o ambiente virtual pelo
    # caminho por onde é chamado; via link em /usr/local/bin ele ignorava o /opt/ia
    # e as bibliotecas não eram encontradas (testado na VM).
    rm -f /usr/local/bin/python-ia
    printf '#!/bin/sh\nexec /opt/ia/bin/python "$@"\n' > /usr/local/bin/python-ia
    chmod 755 /usr/local/bin/python-ia
    /usr/local/bin/python-ia -c 'import sklearn, matplotlib, pandas, seaborn, torch, tensorflow' 2>/dev/null
}

docker_instalar() {
    if ! command -v docker >/dev/null; then
        curl -fsSL https://get.docker.com -o "$TMP/get-docker.sh" && sh "$TMP/get-docker.sh" || return 1
    fi
    # Docker Compose (comando "docker compose"): o get.docker.com já instala; garante
    # caso o Docker tenha vindo de outra forma
    if ! docker compose version >/dev/null 2>&1; then
        apt_get install docker-compose-plugin || return 1
    fi
    # AppArmor: o Ubuntu 26.04 já traz /etc/apparmor.d/rootlesskit, que libera user
    # namespaces para /usr/bin/rootlesskit (dono root). NÃO criar outro perfil para o
    # mesmo executável: dois perfis no mesmo caminho fazem o kernel negar a execução
    # ("fork/exec /proc/self/exe: permission denied" - testado na VM).
    # Remove perfis extras (do script antigo ou da documentação do Docker).
    for p in /etc/apparmor.d/usr.bin.rootlesskit /etc/apparmor.d/home.alunoinfo.bin.rootlesskit; do
        [ -f "$p" ] || continue
        apparmor_parser -R "$p" 2>/dev/null
        rm -f "$p"
    done
    if [ -f /etc/apparmor.d/rootlesskit ]; then
        apparmor_parser -r /etc/apparmor.d/rootlesskit
    else
        # Ubuntu sem o perfil oficial: cria um equivalente, com o mesmo nome
        cat > /etc/apparmor.d/rootlesskit <<'EOT'
abi <abi/4.0>,
include <tunables/global>

profile rootlesskit /usr/bin/rootlesskit flags=(unconfined) {
  userns,
  include if exists <local/rootlesskit>
}
EOT
        apparmor_parser -r /etc/apparmor.d/rootlesskit
    fi
}

usuario_aluno() {
    id "$ALUNO" >/dev/null 2>&1 || useradd -m -s /bin/bash -c "$ALUNO" "$ALUNO" || return 1
    echo "$ALUNO:$ALUNO" | chpasswd
    usermod -aG dialout "$ALUNO"
    id "$ADMIN" >/dev/null 2>&1 && usermod -aG dialout "$ADMIN"
    # Atalho do Firefox (janela privativa) - vai para o modelo da home
    runuser -u "$ALUNO" -- mkdir -p "/home/$ALUNO/.local/share/applications"
    baixa_repo firefox_firefox.desktop "/home/$ALUNO/.local/share/applications/firefox_firefox.desktop" &&
    chown "$ALUNO:$ALUNO" "/home/$ALUNO/.local/share/applications/firefox_firefox.desktop" || return 1
    # Packet Tracer 9: a "ativação" (menu, ícones, arquivos .pkt) é por usuário, em ~/.local.
    # O postinst só ativa para quem rodou o sudo; aqui ativa para o aluno (vai para o modelo da home).
    # DEBIAN_FRONTEND=noninteractive aceita a EULA sem abrir o leitor de texto.
    # SUDO_USER precisa ser removido: o pt-manage.sh usa essa variável para decidir
    # a home, e sem isso ativaria na home de quem rodou o sudo (testado na VM).
    if [ -x /usr/local/bin/packettracer ]; then
        (cd / && como_aluno env -u SUDO_USER -u SUDO_UID -u SUDO_GID DEBIAN_FRONTEND=noninteractive \
            /usr/local/bin/packettracer --pt-activate </dev/null)
        [ -f "/home/$ALUNO/.local/share/applications/CiscoPacketTracer-9.0.1.desktop" ] || return 1
    fi
}

docker_rootless_aluno() {
    local uid; uid=$(id -u "$ALUNO")
    [ -f "/home/$ALUNO/.config/systemd/user/docker.service" ] && return 0
    loginctl enable-linger "$ALUNO"
    for _ in $(seq 1 30); do [ -S "/run/user/$uid/bus" ] && break; sleep 1; done
    runuser -u "$ALUNO" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        dockerd-rootless-setuptool.sh install
    local r=$?
    como_aluno docker context use rootless
    loginctl disable-linger "$ALUNO"
    return $r
}

ssh_config() {
    mkdir -p /root/.ssh && chmod 700 /root/.ssh &&
    baixa_repo ifsul_labs.pub /root/.ssh/authorized_keys &&
    chmod 600 /root/.ssh/authorized_keys || return 1
    # Arquivo próprio em sshd_config.d (vale antes do sshd_config principal)
    cat > /etc/ssh/sshd_config.d/10-ifsul.conf <<'EOT'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
AllowUsers root
EOT
    sshd -t || return 1
    systemctl enable ssh && systemctl try-reload-or-restart ssh
}

mysql_config() {
    systemctl enable --now mysql || return 1
    # Só na primeira vez (root ainda autentica pelo socket). MySQL 8.4 não tem mais mysql_native_password
    if mysql -uroot -e 'SELECT 1' >/dev/null 2>&1; then
        mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'root';"
    else
        mysql -uroot -proot -e 'SELECT 1' >/dev/null 2>&1
    fi
}

mongodb() {
    local codinome base serie="" s k ok=""
    local chave=/usr/share/keyrings/mongodb-server.asc
    codinome=$(. /etc/os-release && echo "$VERSION_CODENAME")
    base="https://repo.mongodb.org/apt/ubuntu/dists/$codinome/mongodb-org"
    # Série mais nova que já tem o pacote mongodb-org para esta versão do Ubuntu
    # (o repositório cria a pasta da série antes de publicar os pacotes)
    for s in $(wget -qO- "https://s3.amazonaws.com/repo.mongodb.org?prefix=apt/ubuntu/dists/$codinome/mongodb-org/&delimiter=/" |
               grep -oE 'mongodb-org/[0-9]+\.[0-9]+/' | cut -d/ -f2 | sort -rV); do
        if saida_contem '^Package: mongodb-org$' sh -c "wget -qO- '$base/$s/multiverse/binary-amd64/Packages.gz' | gunzip"; then
            serie=$s; break
        fi
    done
    [ -n "$serie" ] || { aviso "Nenhuma série do MongoDB para o Ubuntu $codinome"; return 1; }
    echo "MongoDB mais novo para $codinome: série $serie"
    # Chave da série (server-8.0.asc) ou da versão maior (server-9.asc), aceita só
    # se for ela que assina o repositório
    baixa "$base/$serie/Release" "$TMP/Release" &&
    baixa "$base/$serie/Release.gpg" "$TMP/Release.gpg" || return 1
    for k in "$serie" "${serie%%.*}"; do
        baixa "https://pgp.mongodb.com/server-$k.asc" "$TMP/mongo.asc" 2>/dev/null || continue
        gpg --dearmor < "$TMP/mongo.asc" > "$TMP/mongo.gpg" 2>/dev/null &&
        gpgv --keyring "$TMP/mongo.gpg" "$TMP/Release.gpg" "$TMP/Release" >/dev/null 2>&1 &&
        { ok=1; break; }
    done
    [ -n "$ok" ] || { aviso "Chave do MongoDB $serie não encontrada ou não confere"; return 1; }
    install -m 644 "$TMP/mongo.asc" "$chave" || return 1
    rm -f /usr/share/keyrings/mongodb-server-*.asc
    cat > /etc/apt/sources.list.d/mongodb-org.sources <<EOT
Types: deb
URIs: https://repo.mongodb.org/apt/ubuntu
Suites: $codinome/mongodb-org/$serie
Components: multiverse
Architectures: amd64
Signed-By: $chave
EOT
    apt_update && apt_get install mongodb-org || return 1
    systemctl enable mongod && systemctl restart mongod || return 1
    # Escuta só em 127.0.0.1 (padrão do pacote), sem autenticação: uso local nas aulas
    local i
    for i in $(seq 30); do
        saida_contem '^1$' mongosh --quiet --eval 'db.runCommand({ping: 1}).ok' && return 0
        sleep 1
    done
    aviso "mongod não respondeu (o MongoDB exige CPU com AVX)"; return 1
}

apache_config() {
    # Aluno e PHP (www-data) podem escrever; os demais usuários não (antes era 777)
    chown -R "$ALUNO:www-data" /var/www/html &&
    find /var/www/html -type d -exec chmod 2775 {} + &&
    find /var/www/html -type f -exec chmod 664 {} +
}

visual() {
    baixa_repo ifsul.png /usr/share/backgrounds/ifsul.png &&
    baixa_repo defaultsifsul.sh /etc/profile.d/defaultsifsul.sh || return 1
    # Esconde o administrador da tela de login
    if id "$ADMIN" >/dev/null 2>&1; then
        local f=/var/lib/AccountsService/users/$ADMIN
        mkdir -p /var/lib/AccountsService/users
        # O AccountsService grava SystemAccount=false sozinho; e com a chave repetida
        # vale a última. Então remove todas e grava uma só, logo após [User].
        touch "$f"
        sed -i '/^SystemAccount=/d' "$f"
        if ! grep -q '^\[User\]' "$f"; then
            if [ -s "$f" ]; then sed -i '1i [User]' "$f"; else echo "[User]" > "$f"; fi
        fi
        sed -i '/^\[User\]/a SystemAccount=true' "$f"
        [ "$(grep -c '^SystemAccount=' "$f")" -eq 1 ] || return 1
    fi
}

swap() {
    [ -f /swapfile ] && return 0
    fallocate -l "${SWAP_GB}G" /swapfile && chmod 600 /swapfile &&
    mkswap /swapfile && swapon /swapfile || return 1
    grep -q '^/swapfile ' /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
}

# Home do aluno restaurada de um modelo ao sair da sessão e no boot
home_limpa() {
    local uid; uid=$(id -u "$ALUNO")
    systemctl stop "user@$uid.service"
    mkdir -p /var/lib/alunoinfo-modelo && chmod 700 /var/lib/alunoinfo-modelo
    rsync -a --delete --exclude=.local/share/docker "/home/$ALUNO/" /var/lib/alunoinfo-modelo/home/ || return 1

    cat > /usr/local/sbin/limpar-alunoinfo <<EOT
#!/bin/bash
# Restaura /home/$ALUNO a partir do modelo (roda como root, fora da sessão)
ALUNO=$ALUNO
EOT
    cat >> /usr/local/sbin/limpar-alunoinfo <<'EOT'
# Espera a sessão que está saindo terminar; se outra sessão já começou, não mexe
for i in $(seq 1 30); do
    STATE=$(loginctl show-user "$ALUNO" -p State --value 2>/dev/null)
    case "$STATE" in active|online) sleep 1 ;; *) break ;; esac
done
case "$STATE" in active|online) exit 0 ;; esac
systemctl stop "user@$(id -u "$ALUNO").service"
pkill -KILL -u "$ALUNO"
rsync -a --delete /var/lib/alunoinfo-modelo/home/ "/home/$ALUNO/"
crontab -r -u "$ALUNO" 2>/dev/null
find /tmp /var/tmp /dev/shm -xdev -user "$ALUNO" -delete 2>/dev/null
# Senha, nome e foto padrão (caso o aluno tenha alterado)
echo "$ALUNO:$ALUNO" | chpasswd
usermod -c "$ALUNO" "$ALUNO"
rm -f "/var/lib/AccountsService/icons/$ALUNO"
exit 0
EOT
    chmod 755 /usr/local/sbin/limpar-alunoinfo

    cat > /etc/systemd/system/limpar-alunoinfo.service <<'EOT'
[Unit]
Description=Restaura a home do aluno a partir do modelo
After=local-fs.target
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/limpar-alunoinfo

[Install]
WantedBy=multi-user.target
EOT
    systemctl daemon-reload && systemctl enable limpar-alunoinfo.service || return 1

    # Gatilho ao sair da sessão gráfica (o GDM 50 não tem mais PostSession; usa PAM)
    cat > /usr/local/sbin/limpar-alunoinfo-pam <<EOT
#!/bin/sh
[ "\$PAM_USER" = "$ALUNO" ] && systemctl start --no-block limpar-alunoinfo.service
exit 0
EOT
    chmod 755 /usr/local/sbin/limpar-alunoinfo-pam
    grep -q limpar-alunoinfo-pam /etc/pam.d/gdm-password ||
        echo "session optional pam_exec.so quiet type=close_session /usr/local/sbin/limpar-alunoinfo-pam" >> /etc/pam.d/gdm-password
    # Substitui o antigo @reboot do crontab do root (agora feito pelo serviço).
    # Só mexe se a linha existir (com crontab vazio o grep -v "falha" e derrubava a etapa)
    if saida_contem "$ALUNO:$ALUNO" crontab -l; then
        crontab -l | grep -v "$ALUNO:$ALUNO" | crontab -
    fi
    return 0
}

snaps_aguarda() {
    msg "Aguardando os snaps terminarem (log: $SNAP_LOG)"
    wait "$SNAP_PID"
    cat "$SNAP_LOG" | grep -E '^\[(OK|FALHA)\]'
    snap connect mysql-workbench-community:password-manager-service :password-manager-service 2>/dev/null
    snap connect arduino:raw-usb 2>/dev/null
    ! grep -q '^\[FALHA\]' "$SNAP_LOG"
}

limpeza_final() {
    apt_get autoremove --purge && apt_get clean
}

# ----------------------------------------------------------------------------
# Execução
# ----------------------------------------------------------------------------
passo "Identidade de clones (1º boot)"     identidade
passo "Senha do root"                       senha_root
passo "Rede (netplan e DHCP por MAC)"       rede
snaps_inicia
passo "Atualização do sistema"              apt_base
passo "Remoção de pacotes desnecessários"   apt_remover
passo "Pacotes do apt (inclui o JDK)"       apt_instalar
passo "Packet Tracer 9.0.1"                 packet_tracer
passo "Spring Tools"                        spring_tools
passo "brModelo"                            brmodelo
passo "Docker"                              docker_instalar
passo "Python para IA (/opt/ia)"            python_ia
passo "Python mais novo"                    python_novo
passo "Usuário $ALUNO"                      usuario_aluno
passo "Docker rootless do $ALUNO"           docker_rootless_aluno
passo "MySQL"                               mysql_config
passo "MongoDB"                             mongodb
passo "Apache (/var/www/html)"              apache_config
passo "Wallpaper, defaults e login"         visual
passo "Swap de ${SWAP_GB} GB"               swap
passo "Snaps"                               snaps_aguarda
passo "Home do $ALUNO limpa a cada sessão"  home_limpa
passo "SSH (somente root com chave)"        ssh_config
passo "Limpeza do apt"                      limpeza_final

# ----------------------------------------------------------------------------
# Resumo
# ----------------------------------------------------------------------------
echo
echo "===== setupifsul.sh - fim: $(date) ====="
if [ ${#FALHAS[@]} -eq 0 ]; then
    msg "Tudo certo. Reinicie a máquina para concluir."
    exit 0
else
    printf '\n\033[1;31mEtapas com FALHA (detalhes em %s):\033[0m\n' "$LOG"
    printf '  - %s\n' "${FALHAS[@]}"
    echo "Corrija o problema e execute o script de novo: as etapas já concluídas são puladas."
    exit 1
fi
