# Roteiro de teste

Roteiro para conferir, de ponta a ponta, se o `docker-wsl.ps1` faz o que promete. Cada caso tem os passos, o resultado esperado e um campo para marcar. Ao final de cada instalação, rode o verificador automático (`tests\verificar.ps1`). Ele confere o registro, o local, o usuário, o systemd, os pacotes, o serviço, o grupo `docker` e o `hello-world` da distro.

## Antes de começar

> **Use só distros de teste.** Todos os nomes abaixo começam com `Teste-`. Não rode os casos de mover e desinstalar nas suas distros de trabalho: mover desliga a distro e desinstalar pode apagar imagens e volumes.

**Ambientes:**

| Ambiente | Para quais casos | Como preparar |
|---|---|---|
| **Sua máquina** (WSL já habilitado) | B a H | Nada além do repositório clonado. |
| **VM limpa** com Windows 10 22H2 ou 11, sem WSL | A3 a A5 | Hyper-V: crie a VM e rode no host `Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $true` (virtualização aninhada). O Windows Sandbox não serve, porque não roda WSL2. |

**Preparação na sua máquina:**

```powershell
git clone https://github.com/rcoliveira2016/docker-in-wsl.git
cd docker-in-wsl
wsl --list --verbose > antes.txt          # foto das distros antes dos testes
```

Tenha um segundo disco ou partição (ex.: `D:`) com pelo menos 10 GB livres.

**Verificador automático:**

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\verificar.ps1 -Distro <nome> [-LocalEsperado <pasta>] [-Usuario <usuario>] [-ComandoWindows] [-SemDocker] [-SemReinicio]
```

Ele termina com código `0` quando tudo passa e lista o que falhou. Sem `-SemReinicio`, ele reinicia a distro para confirmar que o Docker sobe sozinho.

---

## A. Execução e preparação do Windows

### A1. Elevação automática

1. Abra o PowerShell **sem** "Executar como administrador".
2. Rode `powershell -ExecutionPolicy Bypass -File .\docker-wsl.ps1`.

**Esperado:** aparece o aviso de permissão do Windows (UAC). Depois de aceitar, abre uma nova janela com o banner e o menu. A janela original mostra "A execução continua na nova janela." e volta ao prompt.

**Variação:** recuse o UAC. A janela original mostra uma mensagem clara de que a elevação foi cancelada, sem erro vermelho do PowerShell.

- [ ] Passou

### A2. Instalação rápida (one-liner)

1. Num PowerShell comum, rode:

   ```powershell
   irm https://raw.githubusercontent.com/rcoliveira2016/docker-in-wsl/main/docker-wsl.ps1 | iex
   ```

**Esperado:** igual ao A1. O script se baixa para `%LOCALAPPDATA%\docker-wsl`, junto com `scripts\wsl-docker.sh`, e abre elevado. A janela original **não** fecha.

- [ ] Passou

### A3. Máquina sem WSL, com reinício e retomada *(VM limpa)*

1. Na VM, rode o one-liner e escolha a opção **2**.
2. Aceite a reinicialização.
3. Faça login com o mesmo usuário.

**Esperado:**
- As etapas `[1/4]` a `[3/4]` mostram que o Windows é compatível, que a virtualização está ativa e que os recursos foram habilitados "(requer reinicialização)".
- O script pergunta "Reiniciar agora? [S/n]".
- Depois do login, a janela do script abre sozinha, mostra "Retomando a instalação..." e continua para a escolha da distro.
- Ao terminar, a tarefa `docker-wsl-retomar` não existe mais: `Get-ScheduledTask docker-wsl-retomar` dá erro.

- [ ] Passou

### A4. Retomada manual

1. Na VM, repita até o pedido de reinício e responda **N**.
2. Reinicie pelo menu Iniciar, mas apague a tarefa antes do login seguinte: `Unregister-ScheduledTask docker-wsl-retomar -Confirm:$false`.
3. Rode o script de novo.

**Esperado:** o script pergunta "Há uma instalação interrompida por reinicialização. Retomar agora?" e, com Enter, segue para a instalação.

- [ ] Passou

### A5. Virtualização desligada *(VM sem virtualização aninhada)*

1. Desligue a VM e rode no host `Set-VMProcessor -VMName <vm> -ExposeVirtualizationExtensions $false`.
2. Ligue a VM e escolha a opção **2**.

**Esperado:** a etapa `[2/4]` falha com uma mensagem explicando como ativar VT-x/AMD-V na BIOS. Nenhuma alteração é feita no Windows.

- [ ] Passou

### A6. Ajuda do script

```powershell
Get-Help .\docker-wsl.ps1 -Full
```

**Esperado:** aparecem a descrição, todos os parâmetros e os exemplos, em português.

- [ ] Passou

---

## B. Opção 1: listar distros e status do Docker

### B1. Tabela de status

1. Rode o script e escolha a opção **1**.

**Esperado:**
- Aparece uma linha por distro, com nome, versão do WSL, estado (Rodando/Parada), Docker (versão ou "Não"), serviço (Ativo/Parado) e grupo (Sim/Não).
- Embaixo de cada linha aparece o caminho do `ext4.vhdx` e o tamanho dele.
- A distro padrão está marcada com `*`. Compare com `wsl --list --verbose`.
- Distros com Docker funcionando aparecem em verde, e com Docker incompleto, em amarelo.

- [ ] Passou

### B2. Destaque de WSL1

1. Crie uma distro em WSL1 a partir de outra:

   ```powershell
   wsl --export Ubuntu-24.04 $env:TEMP\base.tar      # use qualquer distro que você tenha
   wsl --import Teste-WSL1 D:\WSL\Teste-WSL1 $env:TEMP\base.tar --version 1
   ```

2. Rode a opção **1**.

**Esperado:** `Teste-WSL1` aparece em amarelo, com o aviso "Em WSL1: converta para WSL2 antes de usar o Docker". No fim da tabela aparece "Há distros em WSL1".

- [ ] Passou

---

## C. Opção 2: instalar Docker em uma nova distro

### C1. Ubuntu no local padrão (só apertando Enter)

1. Opção **2**. Aperte Enter em tudo, menos no nome da distro: digite `Teste-Ubuntu`.
2. Quando pedir, defina a senha do usuário Linux.

**Esperado:**
- As etapas numeradas vão de `[1/6]` até `[6/6]` e terminam com "O Docker funcionou: o container hello-world rodou sem sudo."
- O resumo mostra a distro, o caminho do disco em `%LOCALAPPDATA%\wsl\...`, o usuário e os próximos passos.

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Ubuntu -Usuario <seu_usuario_em_minusculas>
```

- [ ] Passou

### C2. Debian em outro disco

1. Opção **2** → Debian → nome `Teste-Debian` → escolha a opção `D:\WSL\Teste-Debian`.

**Esperado:** antes de escolher, a lista mostra o espaço livre de cada disco. O resumo mostra `D:\WSL\Teste-Debian\ext4.vhdx`.

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Debian -LocalEsperado D:\WSL\Teste-Debian
```

- [ ] Passou

### C3. Alpine em outro disco

1. Opção **2** → Alpine → nome `Teste-Alpine` → pasta `D:\WSL\Teste-Alpine`.

**Esperado:** o script baixa o minirootfs oficial do Alpine, importa a distro e configura a inicialização pelo OpenRC.

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Alpine -LocalEsperado D:\WSL\Teste-Alpine
```

- [ ] Passou

### C4. Validações das perguntas

Na opção **2**, digite valores inválidos e confira se o script recusa e pergunta de novo:

| Pergunta | Valor | Mensagem esperada |
|---|---|---|
| Nome da distro | `Teste Ubuntu` (com espaço) | "Use letras, números..." |
| Nome da distro | `Teste-Ubuntu` (já existe) | "Já existe uma distro chamada..." |
| Opção de distro | `9` | "Digite um número de 1 a 3." |
| Outra pasta | `WSL\x` (relativo) | "Informe um caminho completo..." |
| Outra pasta | `Z:\WSL` (disco inexistente) | "O disco Z:\ não existe." |
| Outra pasta | `C:\Windows` | "Essa pasta não está vazia..." |
| Usuário do Linux | `Maria Silva` | "Use só letras minúsculas..." |
| Usuário do Linux | `root` | "Escolha um usuário diferente de root." |
| Continuar? | `n` | "Instalação cancelada." Nada é criado. |

- [ ] Passou

### C5. Comando `docker` no Windows

1. Opção **2** → nome `Teste-Win` → responda **S** a "Quer usar o comando docker direto no PowerShell/CMD do Windows?".
2. Abra um **novo** terminal.

**Esperado:** `docker ps` e `docker run --rm hello-world` funcionam no PowerShell e no CMD. `Get-Command docker` aponta para `%LOCALAPPDATA%\docker-wsl\bin\docker.cmd`.

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Win -ComandoWindows
```

- [ ] Passou

### C6. Modo silencioso

```powershell
.\docker-wsl.ps1 -Acao Instalar -Distro Ubuntu -Nome Teste-Silent -Local D:\WSL -Usuario dev -Silent
```

**Esperado:** nenhuma pergunta é feita. A distro fica em `D:\WSL\Teste-Silent`, e aparece o aviso de que a senha não foi definida.

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Silent -LocalEsperado D:\WSL\Teste-Silent -Usuario dev
```

- [ ] Passou

### C7. Idempotência

1. Rode **o mesmo comando do C6** de novo.

**Esperado:** aparece "A distro 'Teste-Silent' já existe; vou só garantir que o Docker esteja instalado e funcionando nela." Nenhuma distro nova é criada (`wsl -l` mostra a mesma lista), e o `hello-world` passa de novo.

- [ ] Passou

---

## D. Opção 3: instalar Docker em uma distro existente

### D1. Distro sem Docker, com usuário root

1. Crie uma distro sem usuário comum:

   ```powershell
   wsl --install -d Debian --name Teste-Existente --no-launch
   ```

2. Opção **3**.

**Esperado:**
- A lista mostra **só** distros sem Docker (as `Teste-*` das seções anteriores não aparecem), cada uma com o local onde está.
- A pergunta "Quer mover a distro para outro disco antes de instalar?" tem **Não** como padrão.
- Como o usuário padrão é root, o script oferece criar um usuário comum (padrão: Sim).

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Existente
```

- [ ] Passou

### D2. Conversão de WSL1 para WSL2

1. Opção **3** → escolha `Teste-WSL1` (do B2).

**Esperado:** o script pede confirmação para converter. Responda **S**: a conversão roda e a instalação segue.

**Variação:** responda **N**. O resultado deve ser "Instalação cancelada.", e a distro continua em WSL1.

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-WSL1
```

- [ ] Passou

### D3. Mover antes de instalar

1. Crie outra distro sem Docker: `wsl --install -d Ubuntu --name Teste-Mover3 --no-launch`.
2. Opção **3** → `Teste-Mover3` → responda **S** para mover → escolha `D:\WSL\Teste-Mover3`.

**Esperado:** a etapa "Movendo a distro" roda antes da instalação do Docker.

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Mover3 -LocalEsperado D:\WSL\Teste-Mover3
```

- [ ] Passou

### D4. Distro que já tem Docker (idempotência)

```powershell
.\docker-wsl.ps1 -Acao InstalarExistente -Distro Teste-Debian -Silent
```

**Esperado:** o script só confere e repara: "já existe; vou só garantir...". O `hello-world` passa.

- [ ] Passou

---

## E. Opção 4: mover uma distro para outro disco

### E1. Mover preservando os dados

1. Crie dados de teste dentro da distro:

   ```powershell
   wsl -d Teste-Ubuntu -- sh -c "echo marcador > ~/marcador.txt; docker pull alpine; docker volume create teste-vol"
   ```

2. Opção **4** → `Teste-Ubuntu` → `D:\WSL\Teste-Ubuntu` → confirme.

**Esperado:**
- Antes de mover, o script mostra a origem, o destino, o espaço livre e o espaço necessário.
- Ele avisa que a distro será desligada e pede confirmação.
- No fim aparece "Distro 'Teste-Ubuntu' movida para D:\WSL\Teste-Ubuntu".

**Verificação:**

```powershell
wsl -d Teste-Ubuntu -- sh -c "cat ~/marcador.txt; docker image ls alpine; docker volume ls"
.\tests\verificar.ps1 -Distro Teste-Ubuntu -LocalEsperado D:\WSL\Teste-Ubuntu
```

O `marcador.txt`, a imagem `alpine` e o volume `teste-vol` continuam lá, e o usuário padrão não virou root.

- [ ] Passou

### E2. Cancelar

1. Opção **4** → qualquer distro `Teste-*` → responda **N** na confirmação.

**Esperado:** aparece "Movimentação cancelada." O caminho na opção 1 continua o mesmo.

- [ ] Passou

### E3. Destino inválido

1. Crie uma pasta com um arquivo: `New-Item -Force D:\WSL\Ocupada\x.txt`.
2. Opção **4** → `Teste-Debian` → "Outra pasta" → `D:\WSL\Ocupada`.

**Esperado:** aparece "Essa pasta não está vazia..." e o script pergunta de novo.

- [ ] Passou

### E4. Espaço insuficiente *(opcional)*

1. Crie um disco pequeno de 1 GB no Gerenciamento de Disco (Ação → Criar VHD → 1 GB, inicialize e formate como `X:`).
2. Opção **4** → `Teste-Ubuntu` → "Outra pasta" → `X:\WSL\Teste-Ubuntu`.

**Esperado:** aparece "Espaço insuficiente em X:\..." antes de desligar ou alterar a distro.

- [ ] Passou

### E5. Mover pelo parâmetro

```powershell
.\docker-wsl.ps1 -Acao Mover -Distro Teste-Alpine -Local D:\WSL\Movida -Silent
```

**Esperado:** a distro vai para `D:\WSL\Movida\Teste-Alpine` sem perguntas.

- [ ] Passou

---

## F. Opção 5: desinstalar Docker de uma distro

### F1. Remover só os pacotes, mantendo os dados

1. Opção **5** → `Teste-Debian`.
2. Confirme a remoção, responda **N** para apagar dados e **N** para remover a distro.

**Esperado:**
- A lista mostra **só** distros com Docker.
- Antes de confirmar, aparece um resumo do tipo "N imagens, N containers, N volumes".
- O script termina com "A distro foi mantida."

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Debian -SemDocker
```

Na saída, "Dados em /var/lib/docker" deve aparecer como **mantidos**.

- [ ] Passou

### F2. Remover pacotes e dados

1. Opção **5** → `Teste-Ubuntu` → confirme → **S** para apagar dados → digite `APAGAR`.

**Esperado:** a etapa de remoção apaga `/var/lib/docker`.

**Verificação:**

```powershell
.\tests\verificar.ps1 -Distro Teste-Ubuntu -SemDocker
```

Na saída, "Dados em /var/lib/docker" deve aparecer como **apagados**.

- [ ] Passou

### F3. Palavra de confirmação errada

1. Opção **5** → `Teste-Silent` → confirme → **S** para apagar dados → digite `apagar` (minúsculo) ou só aperte Enter.

**Esperado:** os dados **não** são apagados, porque a confirmação diferencia maiúsculas e minúsculas.

- [ ] Passou

### F4. Remover a distro inteira e o comando do Windows

1. Opção **5** → `Teste-Win` → confirme → **N** para apagar dados → **S** para remover a distro → digite `Teste-Win`.

**Esperado:** aparece "Comando docker do Windows removido.", e a distro some do `wsl -l`. `%LOCALAPPDATA%\docker-wsl\bin\docker.cmd` não existe mais.

- [ ] Passou

### F5. Silencioso exige a distro

```powershell
.\docker-wsl.ps1 -Acao Desinstalar -Silent
```

**Esperado:** o script recusa com "No modo -Silent, informe a distro com -Distro." Nenhuma distro é alterada.

- [ ] Passou

---

## G. Log e erros

### G1. Log

1. Abra o log mais recente:

   ```powershell
   Get-ChildItem $env:LOCALAPPDATA\docker-wsl\logs | Sort-Object LastWriteTime | Select-Object -Last 1 | Invoke-Item
   ```

**Esperado:** o log tem os parâmetros, cada etapa `[n/N]`, cada comando executado (`> wsl.exe ...`), a saída e o código de saída, com acentos corretos.

- [ ] Passou

### G2. Sem internet no meio da instalação

1. Opção **2** → nome `Teste-Rede`. Desligue a rede (Wi-Fi/cabo) assim que aparecer a etapa "Instalando Docker Engine...".

**Esperado:** o script para com uma mensagem clara, por exemplo "falha no apt-get update. Verifique a conexão com a internet.", e aponta o log.

2. Religue a rede e rode `.\docker-wsl.ps1 -Acao InstalarExistente -Distro Teste-Rede`.

**Esperado:** a instalação termina sem erro.

- [ ] Passou

### G3. Interromper com Ctrl+C

1. Opção **2** → nome `Teste-Ctrl`. Aperte Ctrl+C durante a instalação do Docker.
2. Rode `.\docker-wsl.ps1 -Acao InstalarExistente -Distro Teste-Ctrl`.

**Esperado:** a segunda execução completa a instalação. Se o `apt` reclamar de lock, o erro aparece no log com a orientação.

- [ ] Passou

---

## H. Uso depois de instalado

### H1. VS Code

1. Com a extensão **WSL** instalada, rode `wsl -d Teste-Existente` e, dentro da distro, `mkdir ~/app && cd ~/app && code .`.
2. No terminal integrado do VS Code, rode `docker run --rm hello-world`.

**Esperado:** o VS Code abre conectado a "WSL: Teste-Existente", e o `docker` funciona sem `sudo`.

- [ ] Passou

### H2. Porta acessível no Windows

```powershell
wsl -d Teste-Existente -- docker run -d --rm -p 8080:80 --name web nginx
Start-Process http://localhost:8080
```

**Esperado:** o navegador do Windows mostra a página "Welcome to nginx!". Depois, rode `wsl -d Teste-Existente -- docker stop web`.

- [ ] Passou

### H3. Compose

```powershell
wsl -d Teste-Existente -- sh -c "mkdir -p ~/compose && cd ~/compose && printf 'services:\n  web:\n    image: nginx\n    ports: [\"8081:80\"]\n' > compose.yaml && docker compose up -d && docker compose ps && docker compose down"
```

**Esperado:** o serviço `web` sobe, aparece como `running` e é removido.

- [ ] Passou

---

## Limpeza

Remova tudo o que os testes criaram:

```powershell
wsl --list --quiet | Where-Object { $_ -like 'Teste-*' } | ForEach-Object { wsl --unregister $_.Trim() }
Remove-Item -Recurse -Force D:\WSL\Teste-*, D:\WSL\Movida, D:\WSL\Ocupada -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $env:LOCALAPPDATA\docker-wsl -ErrorAction SilentlyContinue
Unregister-ScheduledTask docker-wsl-retomar -Confirm:$false -ErrorAction SilentlyContinue
wsl --list --verbose     # compare com o antes.txt
```

Se você usou o C5, tire também `%LOCALAPPDATA%\docker-wsl\bin` do `PATH` do usuário.

---

## Registro do resultado

| Caso | Resultado | Observação |
|---|---|---|
| A1 Elevação | | |
| A2 One-liner | | |
| A3 Reinício e retomada | | |
| A4 Retomada manual | | |
| A5 Sem virtualização | | |
| A6 Ajuda | | |
| B1 Tabela | | |
| B2 WSL1 | | |
| C1 Ubuntu padrão | | |
| C2 Debian em D: | | |
| C3 Alpine | | |
| C4 Validações | | |
| C5 Comando Windows | | |
| C6 Silencioso | | |
| C7 Idempotência | | |
| D1 Existente com root | | |
| D2 Conversão WSL1 | | |
| D3 Mover antes | | |
| D4 Já tem Docker | | |
| E1 Mover com dados | | |
| E2 Cancelar | | |
| E3 Destino inválido | | |
| E4 Sem espaço | | |
| E5 Mover silencioso | | |
| F1 Remover mantendo dados | | |
| F2 Remover com dados | | |
| F3 Confirmação errada | | |
| F4 Remover distro | | |
| F5 Silencioso sem distro | | |
| G1 Log | | |
| G2 Sem internet | | |
| G3 Ctrl+C | | |
| H1 VS Code | | |
| H2 Porta | | |
| H3 Compose | | |

Versões usadas: Windows `____`, WSL (`wsl --version`) `____`, data `____`.
