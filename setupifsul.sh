#Arquivos de apoio (desktop, wallpaper, chave SSH, defaults) - repositório privado
REPO="https://api.github.com/repos/alexorozco-ifsul/script_labs/contents"
BRANCH="main"

#Token do GitHub (somente leitura): use a variável GITHUB_TOKEN ou digite quando pedido
if [ -z "$GITHUB_TOKEN" ]; then
    read -r -s -p "Token do GitHub: " GITHUB_TOKEN
    echo
fi

#Baixa um arquivo do repositório: baixar <arquivo> <destino>
baixar() {
    wget -q --header="Authorization: Bearer $GITHUB_TOKEN" \
        --header="Accept: application/vnd.github.raw" \
        "$REPO/$1?ref=$BRANCH" -O "$2" || echo "ERRO ao baixar $1"
}

#Testa o token antes de começar
if ! wget -q --spider --header="Authorization: Bearer $GITHUB_TOKEN" "$REPO/setupifsul.sh?ref=$BRANCH"; then
    echo "Token inválido ou sem acesso ao repositório. Abortando."
    exit 1
fi

#Passwd root
passwd root

#Update
apt update

#Packet Tracer 9.0.1 (AppImage empacotado em .deb; depende de libfuse2, já resolvido pelo apt)
wget 'https://www.dropbox.com/scl/fi/4yn88h3o8ihbiodj3twme/CiscoPacketTracer_901_Ubuntu_64bit.deb?rlkey=p80dod2n2jg2mgq74sgstg0vt&st=tuehpkz6&dl=1' -O CiscoPacketTracer_901_Ubuntu_64bit.deb
apt install -y ./CiscoPacketTracer_901_Ubuntu_64bit.deb
rm CiscoPacketTracer_901_Ubuntu_64bit.deb

#Spring Tools for Eclipse 5.4.0
wget "https://cdn.spring.io/spring-tools/release/dist/5.4.0.RELEASE/e4.41/spring-tools-for-eclipse-5.4.0.RELEASE-e4.41.0-linux.gtk.x86_64.tar.gz"
tar -xvf spring-tools-for-eclipse-5.4.0.RELEASE-e4.41.0-linux.gtk.x86_64.tar.gz -C /opt/
rm spring-tools-for-eclipse-5.4.0.RELEASE-e4.41.0-linux.gtk.x86_64.tar.gz
cat <<EOT | tee /usr/share/applications/sts-5.4.0.RELEASE.desktop
[Desktop Entry]
Name=Spring Tools for Eclipse
Exec=/opt/sts-5.4.0.RELEASE/SpringToolsForEclipse %u
Icon=/opt/sts-5.4.0.RELEASE/icon.xpm
Type=Application
Categories=Development;IDE;
MimeType=x-scheme-handler/eclipse+command;x-scheme-handler/eclipse+mpc;
EOT

#JDK padrão do Ubuntu (default-jdk -> OpenJDK 25 no 26.04)
apt install -y default-jdk

#Remove Packages
apt auto-remove -y \
    gnome-initial-setup \
    gnome-startup-applications \
    totem \
    unattended-upgrades \
    update-manager \
    apport \
    apport-gtk

#Install packages
apt install -y \
    uidmap \
    libreoffice \
    virtualbox \
    vlc \
    git \
    curl \
    net-tools \
    openssh-server \
    nmap \
    mysql-server \
    apache2 \
    php \
    libapache2-mod-php \
    php-mysql \
    python3-pip \
    traceroute

#Veyon (PPA oficial)
add-apt-repository -y ppa:veyon/stable
apt install -y veyon

#Veyon - configuração de aluno (antigo linux-configure_aluno.yml)
VEYON_TMP=$(mktemp -d)
baixar aluno-veyon-config.json "$VEYON_TMP"/aluno-veyon-config.json
baixar professor_public_key.pem "$VEYON_TMP"/professor_public_key.pem
veyon-cli config import "$VEYON_TMP"/aluno-veyon-config.json
veyon-cli authkeys import professor/public "$VEYON_TMP"/professor_public_key.pem
rm -rf "$VEYON_TMP"
systemctl enable veyon.service
#Esconde o Veyon Master e o Configurator dos usuários comuns (dpkg-statoverride mantém após atualizações do pacote)
for f in veyon-master veyon-configurator; do
    dpkg-statoverride --update --add root root 0640 /usr/share/applications/$f.desktop
done
#Obs.: o custom.conf do playbook (WaylandEnable=false) NÃO é usado: o Ubuntu 26.04 não tem sessão Xorg,
#e o Veyon 4.11 já tem suporte (experimental) a Wayland

#Remove Snap Store
snap remove snap-store

#brModelo
mkdir /opt/brmodelo
wget https://github.com/chcandido/brModelo/releases/download/3.31/brModelo.jar -O /opt/brmodelo/brmodelo.jar
wget https://github.com/chcandido/brModelo/raw/master/src/imagens/icone.png -O /opt/brmodelo/icon.png
baixar brmodelo.desktop /usr/share/applications/brmodelo.desktop

#Eclipse
snap install eclipse --classic

#NodeJS 26 (LTS) - o canal "latest" do snap node está vazio, é preciso fixar o canal
snap install node --classic --channel=26/stable

#Android Studio
snap install android-studio --classic

#Visual Studio Code
snap install code --classic

#MySQL Workbench
snap install mysql-workbench-community

#Arduino IDE 2 (o canal "latest" ainda é a IDE 1.8.19 antiga)
snap install arduino --channel=2/stable

#Postman
snap install postman

#Blender
snap install blender --classic

#Blockbench
snap install blockbench-snapcraft

#IntelliJ IDEA Community Edition
snap install intellij-idea-community --classic

#SSH config
systemctl enable ssh --now
echo PasswordAuthentication no | tee -a /etc/ssh/sshd_config
echo PermitRootLogin without-password | tee -a /etc/ssh/sshd_config
echo AllowUsers root | sudo tee -a /etc/ssh/sshd_config

#MySQL config
systemctl enable mysql --now
# MySQL 8.4 (Ubuntu 26.04) não carrega mais o mysql_native_password por padrão
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'root';"
snap connect mysql-workbench-community:password-manager-service :password-manager-service

#Create alunoinfo User
useradd -s /bin/bash -d /home/alunoinfo -m alunoinfo
echo "alunoinfo:alunoinfo" | chpasswd

#Reset alunoinfo crontab job
echo '@reboot echo "alunoinfo:alunoinfo" | chpasswd && usermod -c "alunoinfo" alunoinfo && rm -f /var/lib/AccountsService/icons/alunoinfo' | crontab -

#Firefox Desktop
sudo -u alunoinfo mkdir -p /home/alunoinfo/.local/share
mkdir /home/alunoinfo/.local/share/applications
baixar firefox_firefox.desktop /home/alunoinfo/.local/share/applications/firefox_firefox.desktop

#SSH Key
mkdir -p /root/.ssh
baixar ifsul_labs.pub /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

#Apache permissions
chmod 777 -R /var/www/html

#Defaults
baixar defaultsifsul.sh /etc/profile.d/defaultsifsul.sh

#Wallpaper
baixar ifsul.png /usr/share/backgrounds/ifsul.png

#Upgrade
apt upgrade -y

#Hide User ifsul
echo -e "[User]\nSystemAccount=true" | tee -a /var/lib/AccountsService/users/ifsul

#Install Docker
curl -fsSL get.docker.com | bash

#Fix alunoinfo Docker permissions
cat <<EOT | tee "/etc/apparmor.d/home.alunoinfo.bin.rootlesskit"
# ref: https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces
abi <abi/4.0>,
include <tunables/global>

/home/alunoinfo/bin/rootlesskit flags=(unconfined) {
  userns,

  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/home.alunoinfo.bin.rootlesskit>
}
EOT
systemctl restart apparmor.service

#Install rootless docker for alunoinfo
sudo -H -u alunoinfo bash -c 'curl -fsSL https://get.docker.com/rootless | bash'

#Change owner of /home/alunoinfo/bin directory to root
chown root:root -R /home/alunoinfo/bin

#Usermod alunoinfo dialout
usermod -a -G dialout alunoinfo

#Usermod ifsul dialout
usermod -a -G dialout ifsul

#Create swap file
fallocate -l 20G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile swap swap defaults 0 0" | tee -a /etc/fstab
