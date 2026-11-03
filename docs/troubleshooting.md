# Solução de problemas

Problemas comuns ao instalar e usar o Docker Engine no WSL2, com a causa e o que fazer. Se nada aqui resolver, abra uma issue com o log mais recente de `%LOCALAPPDATA%\docker-wsl\logs` e a saída de:

```powershell
wsl --version
wsl --list --verbose
wsl -d <distro> -- docker info
```

## Sumário

- [Windows e WSL](#windows-e-wsl)
- [Script](#script)
- [Docker dentro da distro](#docker-dentro-da-distro)
- [Rede](#rede)
- [Disco e desempenho](#disco-e-desempenho)
- [Mover e importar distros](#mover-e-importar-distros)
- [Integração com o Windows](#integração-com-o-windows)

---

## Windows e WSL

### Erro `0x80370102`: "A máquina virtual não pôde ser iniciada porque um recurso necessário não está instalado"

A virtualização está desligada na BIOS/UEFI ou a Plataforma de Máquina Virtual não está habilitada.

1. Gerenciador de Tarefas → Desempenho → CPU. Se aparecer **Virtualização: Desabilitado**, reinicie, entre na BIOS (F2, F10, F12 ou Del) e ative **Intel VT-x** / **Intel Virtualization Technology** ou **AMD-V** / **SVM Mode**.
2. No PowerShell como administrador:

   ```powershell
   dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
   ```

3. Reinicie o Windows.

Em máquinas virtuais (o Windows rodando dentro do VMware, Hyper-V etc.), habilite a **virtualização aninhada** no host.

### Erro `0x8007019e`: "O componente opcional Subsistema do Windows para Linux não está habilitado"

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
```

Reinicie o Windows e rode o script de novo.

### Erro `0x800701bc`: "O WSL 2 requer uma atualização para seu componente de kernel"

```powershell
wsl --update
```

Se a Microsoft Store estiver bloqueada (comum em empresas):

```powershell
wsl --update --web-download
```

### `wsl --install` ou `wsl --update` falham ao baixar

A Store pode estar bloqueada por proxy ou política da empresa. Use o download direto:

```powershell
wsl --update --web-download
wsl --install -d Ubuntu --web-download
```

Se mesmo assim falhar, baixe o instalador `.msi` mais recente em <https://github.com/microsoft/WSL/releases> e instale manualmente.

### `--location`, `--name` ou `--manage` não são reconhecidos

O WSL está desatualizado. Rode `wsl --update` (ou `wsl --update --web-download`) e confira com `wsl --version`. O script usa exportar/importar como alternativa quando essas opções não existem.

### A distro aparece como versão 1 no `wsl --list --verbose`

O Docker Engine só funciona no WSL2. Converta (a distro é desligada durante a conversão):

```powershell
wsl --set-version Ubuntu 2
```

A opção 3 do script oferece essa conversão automaticamente.

---

## Script

### "A execução de scripts foi desabilitada neste sistema"

A política de execução do PowerShell bloqueia scripts baixados. Rode assim:

```powershell
pwsh -ExecutionPolicy Bypass -File .\docker-wsl.ps1
```

Ou desbloqueie o arquivo: `Unblock-File .\docker-wsl.ps1`. O one-liner com `irm ... | iex` não é afetado pela política.

### O script diz que precisa reiniciar

Isso só acontece quando ele acabou de habilitar a Plataforma de Máquina Virtual (ou, sem o WSL da Store, o Subsistema do Windows para Linux). O script **nunca reinicia sozinho**:

- Se você respondeu **Não** (o padrão), nada foi reiniciado. Reinicie quando for melhor e rode o script de novo: ele pergunta se você quer continuar de onde parou. Enquanto o Windows não reiniciar, ele avisa e não tenta instalar.
- Se você respondeu **Sim**, o Windows reinicia em 60 segundos (para cancelar, rode `shutdown /a`). Depois do login, a tarefa agendada `docker-wsl-retomar` abre o script e continua a instalação.
- No modo `-Silent`, ele nunca reinicia e termina com o código `3010`.

### O script não continuou sozinho depois de reiniciar

A retomada automática só é agendada quando você aceita reiniciar pelo script. Em qualquer caso, rode o script de novo: ele detecta a instalação interrompida e pergunta se você quer retomar.

### A janela elevada fechou e não vi o erro

Todo o processo fica registrado em `%LOCALAPPDATA%\docker-wsl\logs`. Abra o arquivo mais recente:

```powershell
Get-ChildItem $env:LOCALAPPDATA\docker-wsl\logs | Sort-Object LastWriteTime | Select-Object -Last 1 | Invoke-Item
```

### "Não consegui acessar os arquivos do Windows de dentro da distro"

O script copia o `wsl-docker.sh` para o Windows e o executa na distro por `/mnt/c/...`. Se o `/etc/wsl.conf` da distro tem `[automount] enabled=false`, isso não funciona. Reative temporariamente (`enabled=true`), rode `wsl --terminate <distro>` e execute o script de novo.

### Acentos aparecem errados no console

Use o **Windows Terminal** ou uma fonte com suporte a Unicode (Cascadia Mono, Consolas). O script grava o log em UTF-8; abra-o no VS Code ou no Bloco de Notas.

---

## Docker dentro da distro

### `permission denied while trying to connect to the Docker daemon socket`

O usuário não está no grupo `docker`, ou entrou no grupo mas a sessão é antiga.

```bash
sudo usermod -aG docker $USER
```

Feche todos os terminais da distro e, no PowerShell, rode `wsl --terminate <distro>`. Confira com `id -nG`: a lista deve conter `docker`.

### `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`

O serviço não está rodando.

1. Confira se o systemd está ativo: `ps -p 1 -o comm=` deve mostrar `systemd`.
   Se não mostrar, verifique o `/etc/wsl.conf`:

   ```ini
   [boot]
   systemd=true
   ```

   Depois rode `wsl --terminate <distro>` no PowerShell.
2. Inicie e habilite o serviço:

   ```bash
   sudo systemctl enable --now docker
   systemctl status docker
   ```

### O serviço do Docker não inicia

Veja o motivo:

```bash
sudo journalctl -u docker --no-pager -n 50
```

- **Erros de `iptables`** (`failed to create NAT chain DOCKER`, `iptables: Protocol not supported`): troque para o iptables legado e reinicie o serviço.

  ```bash
  sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
  sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
  sudo systemctl restart docker
  ```

- **`daemon.json` inválido**: se você editou `/etc/docker/daemon.json`, valide o JSON (`python3 -m json.tool /etc/docker/daemon.json`).
- **Outra instalação do Docker na mesma distro** (por exemplo, o pacote `docker.io` ou o Snap): remova com `sudo apt-get remove docker.io` / `sudo snap remove docker` e rode o script de novo.

### Alpine: o Docker não sobe sozinho

O Alpine usa o OpenRC, que o script inicia pelo `[boot] command` do `/etc/wsl.conf`. Confira:

```sh
cat /etc/wsl.conf
sudo /usr/local/sbin/wsl-docker-boot.sh
rc-status
```

O `[boot] command` exige um WSL recente (`wsl --update`).

### `apt-get update` falha com "Release file ... is not valid yet"

O relógio da distro atrasou (acontece depois de suspender o notebook). Sincronize:

```bash
sudo hwclock -s
```

Se não resolver, rode `wsl --shutdown` no PowerShell e abra a distro de novo.

### `docker compose` não existe, só `docker-compose`

O Compose v2 é um plugin (`docker compose`, com espaço). Instale com `sudo apt-get install docker-compose-plugin`. O `docker-compose` antigo (v1) foi descontinuado.

---

## Rede

### Containers ou o `apt` não resolvem nomes (DNS) — comum com VPN

Crie ou edite `%UserProfile%\.wslconfig`:

```ini
[wsl2]
dnsTunneling=true
networkingMode=mirrored
```

Rode `wsl --shutdown` e teste de novo. Se a VPN da empresa continuar bloqueando, peça ao time de TI as regras para o WSL.

### Não consigo acessar `localhost:<porta>` a partir do Windows

- Confira se o container publicou a porta: `docker ps` deve mostrar `0.0.0.0:8080->80/tcp`.
- Use `-p 8080:80`, não só `--expose`.
- Confira se o `localhostForwarding` não foi desligado no `.wslconfig`.
- Com `networkingMode=mirrored`, o firewall do Windows (Hyper-V firewall) pode bloquear. Teste liberando a porta ou desligando temporariamente o firewall para isolar o problema.

### Outro computador da rede não acessa o container

Com a rede padrão (NAT), o WSL só é acessível pelo próprio Windows. Use `networkingMode=mirrored` no `.wslconfig` e libere a porta no firewall do Windows, ou crie um `netsh interface portproxy` para a porta.

---

## Disco e desempenho

### Tudo fica muito lento (build, `npm install`, volumes)

O projeto está no disco do Windows (`/mnt/c/...`). O acesso entre os sistemas de arquivos é lento. Mova o projeto para dentro do Linux:

```bash
mkdir -p ~/projetos
cp -r /mnt/c/Users/voce/projeto ~/projetos/
```

Abra com `code ~/projetos/projeto` (extensão WSL do VS Code).

### O disco C: está enchendo

O `ext4.vhdx` da distro cresce com imagens, containers, volumes e cache de build.

1. Limpe o que não usa:

   ```bash
   docker system df
   docker system prune -a          # remove imagens e containers parados
   docker builder prune            # cache de build
   ```

2. Deixe o disco virtual liberar o espaço automaticamente:

   ```powershell
   wsl --shutdown
   wsl --manage <distro> --set-sparse true
   ```

3. Mova a distro para outro disco com a opção 4 do script (ou `wsl --manage <distro> --move D:\WSL\<distro>`).

### O WSL consome memória demais

Limite no `%UserProfile%\.wslconfig`:

```ini
[wsl2]
memory=6GB
processors=4
```

Rode `wsl --shutdown` para aplicar.

---

## Mover e importar distros

### "Espaço insuficiente" ao mover

O `wsl --manage --move` precisa de espaço para uma cópia do disco virtual no destino. O método exportar/importar precisa de cerca do dobro (o `.tar` e o disco novo). Libere espaço ou escolha outro disco.

### "Essa pasta não está vazia"

O destino precisa ser uma pasta nova ou vazia, para não misturar com outra distro. Escolha outro caminho (ex.: `D:\WSL\Ubuntu-2`).

### A importação falhou no meio do processo

O script não apaga o backup quando algo dá errado. Restaure com o comando que ele mostrar, no formato:

```powershell
wsl --import <distro> D:\WSL\<distro> D:\WSL\<distro>\<distro>-backup.tar --version 2
```

### Depois de mover ou importar, a distro entra como `root`

O `wsl --import` não guarda o usuário padrão. Defina de uma das formas:

```powershell
wsl --manage <distro> --set-default-user seu_usuario
```

ou, dentro da distro, no `/etc/wsl.conf`:

```ini
[user]
default=seu_usuario
```

Depois rode `wsl --terminate <distro>`.

---

## Integração com o Windows

### O comando `docker` no PowerShell chama o Docker Desktop

O `docker.exe` do Docker Desktop vem antes no `PATH`. Desinstale o Docker Desktop ou coloque `%LOCALAPPDATA%\docker-wsl\bin` antes no `PATH` do usuário. Confira com `Get-Command docker`.

Se o `docker` dentro da distro tenta falar com o Docker Desktop, volte o contexto padrão:

```bash
docker context use default
```

### `docker run -v C:\projeto:/app` não funciona pelo PowerShell

O comando `docker` do Windows criado pelo script repassa tudo para a distro, então os caminhos precisam ser do Linux:

```powershell
docker run -v /mnt/c/projeto:/app alpine ls /app
```

Para desempenho, prefira projetos dentro do Linux (`/home/seu_usuario/...`).

### O comando `docker` não é encontrado depois de instalar

O `PATH` só é atualizado em terminais novos. Feche e abra o terminal (no VS Code, feche o VS Code inteiro). Confira se `%LOCALAPPDATA%\docker-wsl\bin\docker.cmd` existe.
