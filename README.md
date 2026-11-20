# script_labs — configuração das máquinas dos laboratórios

Script que deixa as máquinas dos laboratórios prontas para as aulas: instala os
programas, cria o usuário dos alunos e aplica as configurações de segurança.

- **Sistema:** Ubuntu 26.04 LTS Desktop, 64 bits (amd64)
- **Script:** [`setupifsul.sh`](setupifsul.sh). Os demais arquivos deste repositório são baixados por ele automaticamente.

---

## Visão geral do processo

```
 1. Máquina-template            2. Clonagem           3. Cada máquina do laboratório
 ┌──────────────────────┐      ┌────────────┐       ┌───────────────────────────────┐
 │ Instalar Ubuntu      │      │ TI clona a │       │ Ligar (reinicia sozinha 1 vez │
 │ Rodar o script       │ ───► │ template   │ ────► │ no primeiro boot)             │
 │ (~1 h, baixa tudo)   │      │ pela rede  │       │ Laboratorista define nome/IP  │
 └──────────────────────┘      └────────────┘       └───────────────────────────────┘
```

O script é rodado **uma única vez, na template**. As máquinas clonadas não
precisam rodar nada: no primeiro boot, cada uma gera sozinha a sua identidade
própria e reinicia uma vez.

---

## 1. Preparar a máquina-template

No terminal da template, logado como `ifsul`:

```bash
wget -qO setupifsul.sh https://raw.githubusercontent.com/alexorozco-ifsul/script_labs/main/setupifsul.sh
sudo bash setupifsul.sh
```

1. O script pede para definir a **senha do root** (duas vezes, para confirmar). É a única pergunta,
   e só acontece aqui: a senha vai junto para todas as máquinas clonadas.
   Para trocá-la depois: `sudo passwd root`.
2. Depois disso ele roda sozinho. Leva **cerca de 1 hora**, dependendo da rede.
3. No final aparece um resumo:
   - `Tudo certo. Reinicie a máquina para concluir.` → reinicie e siga para a clonagem;
   - `Etapas com FALHA` → veja [Quando algo falha](#quando-algo-falha).

> **Importante:** antes de clonar, confira que o resumo final não tem falhas e
> reinicie a template uma vez.

---

## 2. Clonar

Clone a template normalmente pela ferramenta de clonagem da TI. Não é preciso
preparar nada antes.

---

## 3. Em cada máquina do laboratório

1. **Ligue a máquina.** No primeiro boot depois da clonagem ela **reinicia
   sozinha uma vez** (leva alguns segundos a mais). Isso é esperado: é o serviço
   `identidade-clone` gerando a identidade própria da máquina (veja abaixo).
2. Execute o script da TI que define **hostname** e **IP**.

### O que é a "identidade própria"

Uma máquina clonada sai com dados internos iguais aos da template. O serviço
`identidade-clone` percebe que o hardware mudou (pelo UUID da placa-mãe ou da VM)
e gera novos:

- identificador da máquina (`/etc/machine-id`), usado pelo sistema e pelos logs;
- chaves de identificação do SSH.

Ele age só uma vez por máquina. Também age se a placa-mãe for trocada.

### Rodar o script de novo (opcional)

O script pode ser executado de novo em qualquer máquina, a qualquer momento, para
corrigir algo que falhou ou aplicar mudanças novas deste repositório. Ele pula o
que já está feito e não pergunta nada (a senha do root já existe):

```bash
wget -qO setupifsul.sh https://raw.githubusercontent.com/alexorozco-ifsul/script_labs/main/setupifsul.sh
sudo bash setupifsul.sh
```

---

## Quando algo falha

O script **não para** quando uma etapa falha: ele segue com as outras e, no fim,
lista as que falharam.

1. Veja o motivo no log: `/var/log/setupifsul.log`
   (os programas snap têm um log próprio: `/var/log/setupifsul-snaps.log`).
2. A causa mais comum é **queda de rede** ou um site fora do ar por alguns minutos.
3. Resolvido o problema, **rode o script de novo**. Ele refaz só o que faltou;
   o que já foi feito é pulado.

Rodar o script várias vezes na mesma máquina é seguro.

---

## Acesso remoto (SSH)

Depois do script, o SSH das máquinas aceita **somente o usuário `root` com a
chave `ifsul_labs`**. Senha não funciona, e o usuário `ifsul` não entra por SSH.

```bash
ssh -i ~/.ssh/ifsul_labs root@<ip-da-maquina>
```

- A chave privada `ifsul_labs` é entregue à TI separadamente e **dá acesso de
  root a todas as máquinas**: guarde em local seguro e não compartilhe por e-mail
  ou chat.
- Cada máquina tem suas próprias chaves de identificação do SSH. Se uma máquina
  for clonada de novo, o SSH vai avisar `REMOTE HOST IDENTIFICATION HAS CHANGED`.
  Isso é esperado; para aceitar a nova identificação:

  ```bash
  ssh-keygen -R <ip-da-maquina>
  ```

---

## O que o script faz

### Programas

| Área | Programas |
|---|---|
| Redes | Cisco Packet Tracer 9.0.1, nmap, traceroute, net-tools |
| Programação | VS Code, Eclipse, IntelliJ IDEA Community, Android Studio, Spring Tools, OpenJDK, Node.js, Git, Postman |
| Banco de dados | MySQL, MySQL Workbench, MongoDB (com `mongosh`), brModelo |
| Web | Apache, PHP |
| IA / ciência de dados | Python 3.13 com scikit-learn, pandas, matplotlib, seaborn, TensorFlow e PyTorch (comando `python-ia`) |
| Contêineres | Docker e Docker Compose (cada aluno usa o seu, sem acesso de administrador) |
| Outros | LibreOffice, VLC, VirtualBox, Arduino IDE, Blender, Blockbench |

Os programas são instalados sempre na **versão mais nova** disponível no momento em
que o script roda. As exceções são o Packet Tracer (versão fixa) e o Python 3.13 do
ambiente de IA (o TensorFlow ainda não funciona com versões mais novas do Python).

### Usuário dos alunos

- Usuário **`alunoinfo`**, senha **`alunoinfo`**.
- **A pasta pessoal é apagada a cada sessão:** ao sair da sessão (e ao ligar a
  máquina), tudo o que o aluno criou ou alterou some e a pasta volta ao padrão.
  Os alunos devem salvar trabalhos em pendrive ou na nuvem.
- Wallpaper do IFSul, teclado brasileiro e tema padrão aplicados a cada login.

### Rede

- O IP continua vindo do **DHCP com filtro por MAC**: o script faz a máquina se
  identificar pelo MAC da placa de rede.
- Se o IP for definido manualmente, ele deixa de voltar para "automático" depois
  de reiniciar ou atualizar o sistema (problema do instalador do Ubuntu que o
  script corrige).

### Outras configurações

- Usuário administrador `ifsul` escondido da tela de login.
- MySQL: usuário `root`, senha `root` (apenas acesso local, para as aulas).
- MongoDB: sem senha, apenas acesso local (`mongosh` na própria máquina).
- Pasta do Apache (`/var/www/html`) gravável pelo aluno e pelo PHP.
- Swap adicional de 20 GB.
- Atualizações de segurança automáticas mantidas; avisos de atualização para o
  usuário desativados.

### Não incluído

- **Veyon:** fica fora deste script por enquanto. No Ubuntu 26.04 (só Wayland)
  ele não permite controle remoto. Será instalado à parte quando isso for resolvido.
- Máquinas dos professores (Veyon Master): configuradas manualmente, fora deste script.

---

## Arquivos do repositório

| Arquivo | Uso |
|---|---|
| `setupifsul.sh` | O script |
| `ifsul_labs.pub` | Chave pública do SSH (vai para o root das máquinas) |
| `defaultsifsul.sh` | Padrões aplicados a cada login do aluno |
| `ifsul.png` | Wallpaper |
| `brmodelo.desktop`, `firefox_firefox.desktop` | Atalhos de menu |
| `veyon-ppa.asc`, `aluno-veyon-config.json`, `professor_public_key.pem` | Reservados para a instalação futura do Veyon |
| `linux-configure_aluno.yml`, `alunoinfo_clean.bat`, `ifsul_pascoa.png` | Não usados pelo script (referência) |

> **Atenção:** este repositório é público e o script roda como root em todas as
> máquinas. Nunca adicione senhas, tokens ou chaves **privadas** aqui.
