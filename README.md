# Docker no WSL2 sem Docker Desktop

Instale e gerencie o **Docker Engine** direto numa distro Linux do **WSL2**, sem o Docker Desktop. Este repositório tem:

- um **script PowerShell** (`docker-wsl.ps1`) que faz tudo por você, com menu e perguntas com valores padrão. Ele nunca reinicia o Windows sem perguntar;
- um **passo a passo manual**, para quem quer entender cada etapa ou fazer sem o script;
- um **guia de solução de problemas** com os erros mais comuns.

```text
  O que você quer fazer?

    1) Listar distros e status do Docker
    2) Instalar Docker em uma nova distro
    3) Instalar Docker em uma distro existente
    4) Mover uma distro para outro disco
    5) Desinstalar Docker de uma distro
    6) Sair
```

## Sumário

- [Por que usar Docker no WSL sem o Docker Desktop](#por-que-usar-docker-no-wsl-sem-o-docker-desktop)
- [Pré-requisitos](#pré-requisitos)
- [Instalação rápida](#instalação-rápida)
- [Instalação manual](#instalação-manual)
- [Instalar ou mover uma distro para outro disco](#instalar-ou-mover-uma-distro-para-outro-disco)
- [Usando o Docker depois de instalado](#usando-o-docker-depois-de-instalado)
- [Solução de problemas](#solução-de-problemas)
- [Desinstalar](#desinstalar)
- [FAQ](#faq)
- [Estrutura do repositório](#estrutura-do-repositório)

## Por que usar Docker no WSL sem o Docker Desktop

| | Docker Desktop | Docker Engine no WSL2 |
|---|---|---|
| **Licença** | Gratuito só para uso pessoal, educação, open source e empresas pequenas. Empresas com mais de 250 funcionários **ou** mais de US$ 10 milhões de faturamento anual precisam de assinatura paga. | Docker Engine é open source (Apache 2.0). Sem custo, em qualquer empresa. |
| **Desempenho** | Roda numa distro própria (`docker-desktop`) e integra com as suas via proxy. | O daemon roda na mesma distro onde está o seu código. Sem camadas intermediárias. |
| **Consumo de recursos** | Mantém processos no Windows (interface, backend, atualizador) e uma VM dedicada. | Só o `dockerd` dentro da distro. Nada roda no Windows. |
| **Controle** | Configuração pela interface, versões amarradas ao Desktop. | Você escolhe a versão, edita o `/etc/docker/daemon.json` e atualiza com `apt upgrade`. |

O que você deixa de ter: a interface gráfica, as Docker Extensions e o Kubernetes integrado. Para o dia a dia de desenvolvimento (build, `docker run`, `docker compose`, Dev Containers no VS Code), o Engine resolve tudo.

## Pré-requisitos

- **Windows 10 versão 2004 (build 19041) ou mais novo, ou Windows 11**, 64 bits. Funciona nas edições Home, Pro e Enterprise.
  Para ver a sua versão: `Win + R` → `winver`.
- **Virtualização habilitada na BIOS/UEFI** (Intel VT-x ou AMD-V/SVM).
  Para conferir: Gerenciador de Tarefas → Desempenho → CPU → **Virtualização: Habilitado**.
- **Permissão de administrador** no Windows (para habilitar o WSL e atualizá-lo).
- Conexão com a internet e pelo menos **5 GB livres** no disco onde a distro vai ficar.

## Instalação rápida

Abra o **PowerShell 7** (`pwsh`) e rode:

```powershell
irm https://raw.githubusercontent.com/rcoliveira2016/docker-in-wsl/main/install.ps1 | iex
```

O `install.ps1` baixa a versão mais recente do script para `%LOCALAPPDATA%\docker-wsl` e a executa no PowerShell 7. Se o 7 não estiver instalado, ele usa o Windows PowerShell 5.1, que também funciona. Para instalar o 7: `winget install Microsoft.PowerShell`. O script abre o menu. Se o PowerShell não estiver como administrador, ele mesmo pede a elevação (confirme no aviso do Windows) e continua numa nova janela. Escolha a opção **2** e aperte Enter nas perguntas para aceitar os padrões.

Prefere baixar antes de executar? Clone o repositório:

```powershell
git clone https://github.com/rcoliveira2016/docker-in-wsl.git
cd docker-in-wsl
pwsh -ExecutionPolicy Bypass -File .\docker-wsl.ps1
```

Se você abrir o script no Windows PowerShell 5.1 e o PowerShell 7 estiver instalado, ele se reabre sozinho no 7.

### O que o script faz

1. Confere a versão do Windows e se a virtualização está ligada.
2. Habilita a **Plataforma de Máquina Virtual**, se ainda não estiver habilitada. O recurso antigo **Subsistema do Windows para Linux** só é habilitado quando o WSL da Microsoft Store não está instalado.
3. Só pede para reiniciar quando um desses recursos acabou de ser habilitado. Nesse caso, **ele pergunta antes** (o padrão é "Não"). Se você recusar, nada é reiniciado: reinicie quando quiser e rode o script de novo, que ele pergunta se quer continuar de onde parou. No modo `-Silent`, ele nunca reinicia e termina com o código `3010`.
4. Atualiza o WSL (`wsl --update`) e define o WSL2 como padrão. Toda distro criada, importada ou movida pelo script é WSL2.
5. Instala a distro escolhida (Ubuntu, Debian ou Alpine) no disco que você escolher, com o seu usuário Linux.
6. Habilita o systemd no `/etc/wsl.conf` (no Alpine, configura a inicialização automática pelo OpenRC).
7. Instala o **Docker Engine pelo repositório oficial**, o **Compose v2** e o **Buildx**.
8. Coloca o seu usuário no grupo `docker`, para não precisar de `sudo`.
9. Roda `docker run hello-world` e mostra um resumo com o local da distro e os próximos passos.

Ele pode ser executado várias vezes sem quebrar nada: o que já está feito é pulado. Cada execução gera um log em `%LOCALAPPDATA%\docker-wsl\logs`.

### Uso sem perguntas (automação)

```powershell
# Nova distro Ubuntu em D:\WSL\Ubuntu, sem perguntas
.\docker-wsl.ps1 -Acao Instalar -Distro Ubuntu -Local D:\WSL -Silent

# Docker numa distro que você já tem, movendo-a antes para o D:
.\docker-wsl.ps1 -Acao InstalarExistente -Distro Ubuntu-24.04 -Local D:\WSL -Silent

# Só a tabela de status
.\docker-wsl.ps1 -Acao Listar
```

Com o one-liner, passe os parâmetros assim:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/rcoliveira2016/docker-in-wsl/main/install.ps1))) -Acao Instalar -Distro Debian -Local D:\WSL -Silent
```

| Parâmetro | Descrição |
|---|---|
| `-Acao` | `Menu` (padrão), `Listar`, `Instalar`, `InstalarExistente`, `Mover` ou `Desinstalar`. |
| `-Distro` | Em `Instalar`: `Ubuntu`, `Debian` ou `Alpine`. Nas outras ações: o nome de uma distro instalada. |
| `-Nome` | Nome personalizado da nova distro (ex.: `Ubuntu-Docker`). |
| `-Local` | Pasta base para os dados da distro. A distro fica em `<Local>\<Nome>` (ex.: `D:\WSL` vira `D:\WSL\Ubuntu`). Sem este parâmetro, usa o local padrão do WSL no C:. |
| `-Usuario` | Usuário Linux a criar. Padrão: o seu usuário do Windows em minúsculas. |
| `-Mover` | Em `InstalarExistente`, move a distro para `-Local` antes de instalar. |
| `-ComandoWindows` | Cria o comando `docker` no PowerShell/CMD do Windows. |
| `-RemoverDados` | Em `Desinstalar`, apaga também imagens, containers e volumes. |
| `-RemoverDistro` | Em `Desinstalar`, remove a distro inteira. |
| `-Silent` | Não faz perguntas: usa os parâmetros informados ou os padrões. |

No modo `-Silent`, a senha do usuário Linux não é definida. Defina depois com `wsl -d <distro> -u root passwd <usuario>` para poder usar o `sudo`.

## Instalação manual

Os comandos abaixo fazem o mesmo que o script, um passo de cada vez.

### 1. Habilitar o WSL2

No PowerShell **como administrador**:

```powershell
wsl --install --no-distribution
```

Em versões mais antigas do Windows 10, se o comando acima não existir:

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

**Reinicie o Windows.** Depois:

```powershell
wsl --update
wsl --set-default-version 2
```

### 2. Instalar a distro

```powershell
wsl --list --online                 # distros disponíveis
wsl --install -d Ubuntu              # instala e pede usuário e senha do Linux
```

Para escolher o nome e o disco já na instalação, veja [Instalar ou mover uma distro para outro disco](#instalar-ou-mover-uma-distro-para-outro-disco).

### 3. Habilitar o systemd

Dentro da distro (`wsl -d Ubuntu`):

```bash
sudo tee -a /etc/wsl.conf > /dev/null <<'EOF'
[boot]
systemd=true
EOF
```

Se o arquivo já tiver uma seção `[boot]`, edite-a com `sudo nano /etc/wsl.conf` em vez de acrescentar outra. Depois, no PowerShell:

```powershell
wsl --terminate Ubuntu
```

Abra a distro de novo e confira: `ps -p 1 -o comm=` deve mostrar `systemd`.

### 4. Instalar o Docker Engine pelo repositório oficial

**Ubuntu** (para **Debian**, troque `ubuntu` por `debian` nas duas URLs e use `$VERSION_CODENAME` em vez de `$UBUNTU_CODENAME`):

```bash
# Remove pacotes antigos ou não oficiais, se existirem
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg 2>/dev/null
done

# Chave e repositório oficial
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Engine, CLI, containerd, Buildx e Compose v2
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**Alpine** (a Docker não publica pacotes para Alpine; o oficial é o repositório community da própria distro):

```sh
apk add docker docker-cli-compose docker-cli-buildx openrc
rc-update add docker default
printf 'auto lo\niface lo inet loopback\n' >> /etc/network/interfaces
```

A última linha é necessária porque o serviço `docker` do OpenRC depende do `networking`, que não sobe sem o `/etc/network/interfaces` (o minirootfs não traz esse arquivo).

No Alpine não há systemd. Para o Docker subir junto com a distro, crie `/usr/local/sbin/wsl-docker-boot.sh`:

```sh
#!/bin/sh
mkdir -p /run/openrc
[ -f /run/openrc/softlevel ] || touch /run/openrc/softlevel
rc-service docker start
```

Dê permissão de execução (`chmod +x`) e acrescente ao `/etc/wsl.conf`:

```ini
[boot]
command=/usr/local/sbin/wsl-docker-boot.sh
```

### 5. Usar o Docker sem sudo

```bash
sudo usermod -aG docker $USER          # no Alpine: addgroup $USER docker
sudo systemctl enable --now docker     # no Alpine: /usr/local/sbin/wsl-docker-boot.sh
```

Feche o terminal, rode `wsl --terminate Ubuntu` no PowerShell e abra a distro de novo para o grupo valer.

### 6. Testar

```bash
docker run hello-world
docker compose version
docker buildx version
```

## Instalar ou mover uma distro para outro disco

Por padrão o WSL guarda cada distro num disco virtual (`ext4.vhdx`) dentro de `%LOCALAPPDATA%` no C:. Esse arquivo cresce com as imagens e os volumes do Docker e passa fácil de dezenas de GB. Se o C: é pequeno, coloque a distro em outro disco.

O script faz isso nas opções 2, 3 e 4. Manualmente:

**Nova distro já em outro disco** (WSL atualizado):

```powershell
wsl --install -d Ubuntu --name Ubuntu-Docker --location D:\WSL\Ubuntu-Docker
```

**Mover uma distro existente**:

```powershell
wsl --shutdown
wsl --manage Ubuntu --move D:\WSL\Ubuntu
```

O `--move` só funciona com o WSL inteiro desligado (`wsl --shutdown`); só desligar a distro com `--terminate` dá `ERROR_SHARING_VIOLATION`. O script cuida disso: se outras distros suas estiverem rodando, ele pergunta antes de desligá-las ou move por exportar/importar, sem mexer nelas.

**Versões antigas do WSL, sem `--move`** (exportar e importar):

```powershell
wsl --shutdown
wsl --export Ubuntu D:\WSL\ubuntu-backup.tar
wsl --unregister Ubuntu
wsl --import Ubuntu D:\WSL\Ubuntu D:\WSL\ubuntu-backup.tar --version 2
Remove-Item D:\WSL\ubuntu-backup.tar
```

Depois do `--import`, a distro passa a entrar como `root`. Para voltar ao seu usuário, dentro dela:

```bash
printf '\n[user]\ndefault=seu_usuario\n' >> /etc/wsl.conf
```

E rode `wsl --terminate Ubuntu`.

**Onde está cada distro?** A opção 1 do script mostra. Manualmente:

```powershell
Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss |
  ForEach-Object { Get-ItemProperty $_.PSPath } |
  Select-Object DistributionName, BasePath
```

## Usando o Docker depois de instalado

### Pelo terminal

Abra a distro pelo **Windows Terminal** (ela aparece no menu de perfis) ou com:

```powershell
wsl -d Ubuntu
```

Lá dentro, o Docker funciona como em qualquer Linux:

```bash
docker run -d -p 8080:80 --name web nginx    # abra http://localhost:8080 no navegador do Windows
docker compose up -d
docker ps
```

As portas publicadas pelos containers ficam acessíveis em `localhost` no Windows.

> **Desempenho:** guarde os projetos **dentro do Linux** (`~/projetos`), não em `/mnt/c/...`. Acessar o disco do Windows a partir do WSL é muitas vezes mais lento, principalmente em `npm install`, builds e volumes montados. Para ver os arquivos pelo Explorer, abra `\\wsl.localhost\Ubuntu\home\seu_usuario`.

### Pelo VS Code

1. Instale a extensão **WSL** (`ms-vscode-remote.remote-wsl`) no VS Code do Windows.
2. Na distro, vá até a pasta do projeto e rode `code .`. O VS Code abre conectado ao Linux, e o terminal integrado já tem o `docker`.
3. Para containers, instale a extensão **Container Tools** (ou **Docker**) *dentro* da conexão WSL. Ela usa o daemon da distro.
4. Para **Dev Containers**, abra o projeto pela conexão WSL e use "Dev Containers: Reopen in Container". Se abrir o projeto pelo Windows, ative a configuração `dev.containers.executeInWSL`.

### Pelo PowerShell ou CMD do Windows

Escolha "sim" na pergunta do script sobre o comando `docker` no Windows (ou use `-ComandoWindows`). O script cria `%LOCALAPPDATA%\docker-wsl\bin\docker.cmd`, que repassa os comandos para a distro, e coloca essa pasta no `PATH`. Abra um novo terminal e use:

```powershell
docker ps
docker compose -f /home/seu_usuario/projeto/compose.yaml up -d
```

Para fazer o mesmo à mão, acrescente ao seu perfil do PowerShell (`notepad $PROFILE`):

```powershell
function docker { wsl.exe -d Ubuntu --exec docker @args }
```

Atenção: os comandos rodam dentro do Linux. Caminhos de volume e de arquivos têm que ser caminhos Linux (`/home/...` ou `/mnt/c/...`), não `C:\...`.

## Solução de problemas

Os erros mais comuns e como resolver estão em **[docs/troubleshooting.md](docs/troubleshooting.md)**. Os principais:

| Sintoma | Resolução rápida |
|---|---|
| `0x80370102` ou "Habilite a Plataforma de Máquina Virtual" | Ative a virtualização na BIOS e a Plataforma de Máquina Virtual. |
| `permission denied while trying to connect to the Docker daemon socket` | Usuário fora do grupo `docker`: `sudo usermod -aG docker $USER` e `wsl --terminate <distro>`. |
| `Cannot connect to the Docker daemon` | Serviço parado: `sudo systemctl start docker`. Confira se o systemd está ativo. |
| `docker` funciona, mas tudo é lento | Projeto em `/mnt/c`. Mova-o para `~/`. |
| C: lotado | Mova a distro para outro disco (opção 4) e compacte o `ext4.vhdx`. |

Ao abrir uma issue, anexe o log mais recente de `%LOCALAPPDATA%\docker-wsl\logs`.

## Desinstalar

**Pelo script:** opção **5**. Ele remove os pacotes do Docker e, se você confirmar, apaga também imagens, containers e volumes, e pode remover a distro inteira.

**Manualmente**, dentro da distro (Ubuntu/Debian):

```bash
sudo systemctl stop docker docker.socket containerd
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
sudo rm -rf /var/lib/docker /var/lib/containerd        # apaga imagens, containers e volumes
sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
```

Para remover a distro inteira (apaga **todos** os arquivos dela):

```powershell
wsl --unregister Ubuntu
```

Para remover os arquivos do script no Windows: apague `%LOCALAPPDATA%\docker-wsl` e tire `%LOCALAPPDATA%\docker-wsl\bin` do `PATH` do usuário (Configurações → Sistema → Sobre → Configurações avançadas do sistema → Variáveis de ambiente).

## FAQ

**Posso manter o Docker Desktop instalado?**
Pode, mas os dois disputam o comando `docker`. Se mantiver, desative em Docker Desktop → Settings → Resources → WSL Integration a integração com a distro onde você instalou o Engine. O script avisa quando encontra o Docker Desktop.

**Preciso pagar alguma licença?**
Não. Docker Engine, Compose e Buildx são open source. A cobrança da Docker vale para o Docker Desktop e para alguns planos do Docker Hub.

**Funciona no Windows 10 Home?**
Funciona. O WSL2 não depende do Hyper-V da edição Pro.

**O Docker inicia sozinho?**
Sim: com o systemd, o serviço sobe sempre que a distro liga (ao abrir um terminal, o VS Code ou rodar `wsl`). Se a distro for desligada (por `wsl --shutdown`, reinício do Windows ou inatividade), os containers param. Use `--restart unless-stopped` (ou `restart: unless-stopped` no Compose) para eles voltarem quando a distro ligar de novo.

**Como limito a memória e a CPU do WSL?**
Crie `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=6GB
processors=4
swap=2GB
```

E rode `wsl --shutdown` para aplicar.

**O arquivo `ext4.vhdx` não diminui depois de apagar imagens. Como recupero o espaço?**
Rode `docker system prune -a` na distro, depois `wsl --shutdown` e, no PowerShell como administrador, `wsl --manage <distro> --set-sparse true` para o disco liberar o espaço automaticamente. Em versões antigas do WSL, use `Optimize-VHD` (Hyper-V) ou o `diskpart` (`compact vdisk`).

**Como atualizo o Docker?**
Como qualquer pacote: `sudo apt-get update && sudo apt-get upgrade` (no Alpine, `apk upgrade`).

**Posso ter Docker em mais de uma distro?**
Pode. Cada distro tem o seu próprio daemon, imagens e volumes. Cuidado com portas: duas distros publicando a mesma porta em `localhost` entram em conflito.

**Onde ficam os logs do script?**
Em `%LOCALAPPDATA%\docker-wsl\logs`, um arquivo por execução.

**Uso uma conta comum e digito a senha de outro usuário administrador. Funciona?**
As distros do WSL pertencem a cada usuário do Windows. Se a elevação usar outra conta, a distro é criada para ela, não para você. Nesse caso, peça para a sua conta ser administradora ou faça a [instalação manual](#instalação-manual), usando o administrador só para habilitar o WSL.

**Funciona em Windows ARM64?**
Funciona com Ubuntu, Debian e Alpine. O script detecta a arquitetura.

## Estrutura do repositório

```text
.
├── install.ps1             # instalador do one-liner: baixa e executa o docker-wsl.ps1
├── docker-wsl.ps1          # script principal (menu, preparação do Windows, instalação, mover, desinstalar)
├── scripts/
│   └── wsl-docker.sh       # executado dentro da distro: status, usuário, systemd, instalação e remoção do Docker
├── docs/
│   ├── troubleshooting.md  # solução de problemas detalhada
│   └── roteiro-de-teste.md # casos de teste de ponta a ponta
├── tests/
│   └── verificar.ps1       # confere automaticamente se uma distro ficou instalada corretamente
├── LICENSE                 # MIT
└── README.md
```

## Testes

O [roteiro de teste](docs/roteiro-de-teste.md) cobre todas as opções do menu, o modo silencioso, o pedido de reinício e os casos de erro. Depois de cada instalação, confira a distro com:

```powershell
.\tests\verificar.ps1 -Distro Ubuntu -LocalEsperado D:\WSL\Ubuntu
```

## Licença

[MIT](LICENSE)
