<#
.SYNOPSIS
    Instala e gerencia o Docker Engine no WSL2, sem o Docker Desktop.

.DESCRIPTION
    Prepara o Windows (WSL2 e Plataforma de Máquina Virtual), cria ou reaproveita uma distro Linux,
    instala o Docker Engine pelo repositório oficial, o Compose v2 e o Buildx, configura o systemd
    e valida tudo com "docker run hello-world". Também lista, move e desinstala distros.

    Sem parâmetros, abre um menu interativo.

.PARAMETER Acao
    Ação a executar sem passar pelo menu: Menu, Listar, Instalar, InstalarExistente, Mover ou Desinstalar.

.PARAMETER Distro
    Em "Instalar": Ubuntu, Debian ou Alpine. Nas demais ações: nome de uma distro já instalada.

.PARAMETER Nome
    Nome personalizado da nova distro (ação Instalar).

.PARAMETER Local
    Pasta onde os dados da distro ficam armazenados (ex.: D:\WSL). Vazio usa o local padrão do WSL no C:.

.PARAMETER Usuario
    Usuário Linux a criar na nova distro. Padrão: o seu usuário do Windows em minúsculas.

.PARAMETER Mover
    Na ação InstalarExistente, move a distro para -Local antes de instalar o Docker.

.PARAMETER ComandoWindows
    Cria o comando "docker" no PowerShell/CMD do Windows apontando para a distro.

.PARAMETER RemoverDados
    Na desinstalação, apaga também imagens, containers e volumes.

.PARAMETER RemoverDistro
    Na desinstalação, remove a distro inteira (wsl --unregister).

.PARAMETER Silent
    Não faz perguntas: usa os valores informados nos parâmetros ou os padrões.

.PARAMETER Retomar
    Uso interno: retoma a tarefa salva antes da reinicialização do Windows.

.EXAMPLE
    .\docker-wsl.ps1

.EXAMPLE
    .\docker-wsl.ps1 -Acao Instalar -Distro Ubuntu -Local D:\WSL -Silent

.EXAMPLE
    .\docker-wsl.ps1 -Acao Mover -Distro Ubuntu -Local E:\WSL\Ubuntu

.LINK
    https://github.com/rcoliveira2016/docker-in-wsl
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Listar', 'Instalar', 'InstalarExistente', 'Mover', 'Desinstalar')]
    [string]$Acao = 'Menu',
    [string]$Distro,
    [string]$Nome,
    [string]$Local,
    [string]$Usuario,
    [switch]$Mover,
    [switch]$ComandoWindows,
    [switch]$RemoverDados,
    [switch]$RemoverDistro,
    [switch]$Silent,
    [switch]$Retomar,
    [Parameter(DontShow)][switch]$Elevado
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Script:Versao       = '1.0.0'
$Script:RepoRaw      = 'https://raw.githubusercontent.com/rcoliveira2016/docker-in-wsl/main'
$Script:AppDir       = Join-Path $env:LOCALAPPDATA 'docker-wsl'
$Script:LogDir       = Join-Path $Script:AppDir 'logs'
$Script:StateFile    = Join-Path $Script:AppDir 'retomar.json'
$Script:BinDir       = Join-Path $Script:AppDir 'bin'
$Script:TaskName     = 'docker-wsl-retomar'
$Script:LxssKey      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
$Script:LogFile      = $null
$Script:StepAtual    = 0
$Script:StepTotal    = 0
$Script:WslRecursos  = $null
$Script:ScriptLinux  = $null
$Script:Resumo       = New-Object System.Collections.Generic.List[string]

$Script:Catalogo = [ordered]@{
    'Ubuntu' = @{ Online = 'Ubuntu'; Descricao = 'Ubuntu (recomendado, mais compatível)' }
    'Debian' = @{ Online = 'Debian'; Descricao = 'Debian (mais leve)' }
    'Alpine' = @{ Online = $null;    Descricao = 'Alpine (ultraleve, para usuários avançados)' }
}

#region Interface e log ---------------------------------------------------------------------------

function Initialize-Console {
    # wsl.exe escreve em UTF-16 por padrão; WSL_UTF8 faz ele usar UTF-8, que é o que o console vai ler.
    $env:WSL_UTF8 = '1'
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $Global:OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    } catch { }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $Host.UI.RawUI.WindowTitle = "Docker no WSL $Script:Versao"
}

function Initialize-Log {
    New-Item -ItemType Directory -Force -Path $Script:LogDir | Out-Null
    $Script:LogFile = Join-Path $Script:LogDir ("docker-wsl-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    Write-Log "docker-wsl $Script:Versao | PowerShell $($PSVersionTable.PSVersion) | $([Environment]::OSVersion.VersionString)"
    Write-Log "Parâmetros: $(($Script:Parametros.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' ')"
}

function Write-Log {
    param([string]$Mensagem, [string]$Nivel = 'INFO')
    if (-not $Script:LogFile) { return }
    $linha = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Nivel, $Mensagem
    try { Add-Content -Path $Script:LogFile -Value $linha -Encoding UTF8 } catch { }
}

function Write-Info    { param([string]$Texto) Write-Host "  i  $Texto" -ForegroundColor Cyan;     Write-Log $Texto }
function Write-Ok      { param([string]$Texto) Write-Host "  √  $Texto" -ForegroundColor Green;    Write-Log $Texto 'OK' }
function Write-Aviso   { param([string]$Texto) Write-Host "  !  $Texto" -ForegroundColor Yellow;   Write-Log $Texto 'AVISO' }
function Write-Erro    { param([string]$Texto) Write-Host "  x  $Texto" -ForegroundColor Red;      Write-Log $Texto 'ERRO' }
function Write-Detalhe { param([string]$Texto) Write-Host "     $Texto" -ForegroundColor DarkGray; Write-Log $Texto 'SAIDA' }

function Write-Titulo {
    param([string]$Texto)
    $linha = '─' * 64
    Write-Host ''
    Write-Host "  $linha" -ForegroundColor DarkCyan
    Write-Host "   $Texto" -ForegroundColor White
    Write-Host "  $linha" -ForegroundColor DarkCyan
    Write-Log "=== $Texto ==="
}

function Start-Etapas {
    param([int]$Total)
    $Script:StepAtual = 0
    $Script:StepTotal = $Total
}

function Write-Etapa {
    param([string]$Texto)
    $Script:StepAtual++
    if ($Script:StepAtual -gt $Script:StepTotal) { $Script:StepTotal = $Script:StepAtual }
    Write-Host ''
    Write-Host ("  [{0}/{1}] {2}" -f $Script:StepAtual, $Script:StepTotal, $Texto) -ForegroundColor Magenta
    Write-Log ("[{0}/{1}] {2}" -f $Script:StepAtual, $Script:StepTotal, $Texto) 'ETAPA'
}

function Add-Resumo {
    param([string]$Texto)
    $Script:Resumo.Add($Texto)
}

function Show-Banner {
    Clear-Host
    Write-Host ''
    Write-Host '   ____             _                       __        ______  _     ' -ForegroundColor Cyan
    Write-Host '  |  _ \  ___   ___| | _____ _ __   _ __   \ \      / / ___|| |    ' -ForegroundColor Cyan
    Write-Host '  | | | |/ _ \ / __| |/ / _ \ ''__| | ''_ \   \ \ /\ / /\___ \| |    ' -ForegroundColor Cyan
    Write-Host '  | |_| | (_) | (__|   <  __/ |    | | | |   \ V  V /  ___) | |___ ' -ForegroundColor Cyan
    Write-Host '  |____/ \___/ \___|_|\_\___|_|    |_| |_|    \_/\_/  |____/|_____|' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  Docker Engine no WSL2, sem Docker Desktop  ·  v$Script:Versao" -ForegroundColor DarkGray
    Write-Host "  Log: $Script:LogFile" -ForegroundColor DarkGray
}

#endregion

#region Perguntas ---------------------------------------------------------------------------------

function Read-Texto {
    param([string]$Pergunta, [string]$Padrao = '', [scriptblock]$Validar)
    if ($Silent) { return $Padrao }
    while ($true) {
        $sufixo = ''
        if ($Padrao) { $sufixo = " [$Padrao]" }
        Write-Host "  ?  $Pergunta$sufixo`: " -ForegroundColor White -NoNewline
        $resposta = Read-Host
        if ([string]::IsNullOrWhiteSpace($resposta)) { $resposta = $Padrao }
        $resposta = "$resposta".Trim()
        if (-not $Validar) { return $resposta }
        $erro = & $Validar $resposta
        if (-not $erro) { return $resposta }
        Write-Aviso $erro
    }
}

function Read-SimNao {
    param([string]$Pergunta, [bool]$Padrao = $false)
    if ($Silent) { return $Padrao }
    $opcoes = '[s/N]'
    if ($Padrao) { $opcoes = '[S/n]' }
    while ($true) {
        Write-Host "  ?  $Pergunta $opcoes`: " -ForegroundColor White -NoNewline
        $resposta = "$(Read-Host)".Trim().ToLowerInvariant()
        if ($resposta -eq '') { return $Padrao }
        if ($resposta -in @('s', 'sim', 'y', 'yes')) { return $true }
        if ($resposta -in @('n', 'nao', 'não', 'no')) { return $false }
        Write-Aviso 'Responda com S (sim) ou N (não).'
    }
}

function Read-Opcao {
    param([string]$Pergunta, [string[]]$Opcoes, [int]$Padrao = 1)
    if ($Silent) { return $Padrao }
    Write-Host ''
    for ($i = 0; $i -lt $Opcoes.Count; $i++) {
        Write-Host ("    {0}) {1}" -f ($i + 1), $Opcoes[$i])
    }
    $validar = {
        param($r)
        $n = 0
        if (-not [int]::TryParse($r, [ref]$n) -or $n -lt 1 -or $n -gt $Opcoes.Count) { return "Digite um número de 1 a $($Opcoes.Count)." }
    }.GetNewClosure()
    return [int](Read-Texto -Pergunta $Pergunta -Padrao "$Padrao" -Validar $validar)
}

function Confirm-Acao {
    param([string]$Mensagem, [string]$Palavra)
    if ($Silent) { return $true }
    Write-Host ''
    Write-Aviso $Mensagem
    if (-not $Palavra) { return (Read-SimNao 'Confirma?' $false) }
    $resposta = Read-Texto -Pergunta "Para confirmar, digite '$Palavra' (ou Enter para cancelar)"
    return ($resposta -ceq $Palavra)
}

function Wait-Enter {
    if ($Silent) { return }
    Write-Host ''
    Write-Host '  Pressione Enter para continuar...' -ForegroundColor DarkGray -NoNewline
    [void](Read-Host)
}

#endregion

#region Execução de comandos ----------------------------------------------------------------------

function Invoke-Nativo {
    param(
        [Parameter(Mandatory)][string]$Arquivo,
        [string[]]$Argumentos = @(),
        [switch]$Capturar,
        [switch]$Silencioso,
        [switch]$Interativo
    )
    Write-Log "> $Arquivo $($Argumentos -join ' ')" 'CMD'
    if ($Interativo) {
        & $Arquivo @Argumentos
        $codigo = $LASTEXITCODE
        Write-Log "< código de saída $codigo" 'CMD'
        return [pscustomobject]@{ Codigo = $codigo; Saida = @() }
    }
    # Com ErrorActionPreference = Stop, qualquer linha no stderr de um executável vira exceção no PS 5.1.
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $saida = New-Object System.Collections.Generic.List[string]
    try {
        & $Arquivo @Argumentos 2>&1 | ForEach-Object {
            $linha = ("$_" -replace "`0", '').TrimEnd()
            if ($linha -eq '') { return }
            $saida.Add($linha)
            Write-Log $linha 'SAIDA'
            if (-not $Capturar -and -not $Silencioso -and $linha -notmatch '^[A-Z_]+=') { Write-Host "     $linha" -ForegroundColor DarkGray }
        }
        $codigo = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $anterior
    }
    Write-Log "< código de saída $codigo" 'CMD'
    return [pscustomobject]@{ Codigo = $codigo; Saida = $saida.ToArray() }
}

function Invoke-Wsl {
    param([string[]]$Argumentos, [switch]$Capturar, [switch]$Silencioso, [switch]$Interativo)
    Invoke-Nativo -Arquivo 'wsl.exe' -Argumentos $Argumentos -Capturar:$Capturar -Silencioso:$Silencioso -Interativo:$Interativo
}

function ConvertFrom-ChaveValor {
    param([string[]]$Linhas)
    $mapa = @{}
    foreach ($linha in $Linhas) {
        if ($linha -match '^([A-Z_]+)=(.*)$') { $mapa[$Matches[1]] = $Matches[2].Trim() }
    }
    return $mapa
}

#endregion

#region Preparação do ambiente --------------------------------------------------------------------

function Test-Administrador {
    $identidade = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($identidade)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-Arquivo {
    param([string]$Url, [string]$Destino)
    New-Item -ItemType Directory -Force -Path (Split-Path $Destino) | Out-Null
    Write-Log "Baixando $Url"
    $anterior = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destino -UseBasicParsing
    } catch {
        throw "Não consegui baixar $Url. Verifique a conexão com a internet. Detalhe: $($_.Exception.Message)"
    } finally {
        $ProgressPreference = $anterior
    }
}

function Copy-ScriptParaAppDir {
    New-Item -ItemType Directory -Force -Path (Join-Path $Script:AppDir 'scripts') | Out-Null
    $destino = Join-Path $Script:AppDir 'docker-wsl.ps1'
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        if ($PSCommandPath -ne $destino) { Copy-Item -Path $PSCommandPath -Destination $destino -Force }
    } else {
        Save-Arquivo -Url "$Script:RepoRaw/docker-wsl.ps1" -Destino $destino
    }
    [void](Get-ScriptLinux)
    return $destino
}

function Get-ScriptLinux {
    $copia = Join-Path $Script:AppDir 'scripts\wsl-docker.sh'
    $origem = $null
    if ($PSScriptRoot) { $origem = Join-Path $PSScriptRoot 'scripts\wsl-docker.sh' }
    if ($origem -and (Test-Path $origem)) {
        if ($origem -ne $copia) {
            New-Item -ItemType Directory -Force -Path (Split-Path $copia) | Out-Null
            Copy-Item -Path $origem -Destination $copia -Force
        }
    } elseif (-not (Test-Path $copia)) {
        Save-Arquivo -Url "$Script:RepoRaw/scripts/wsl-docker.sh" -Destino $copia
    }
    # O git no Windows pode converter o .sh para CRLF, o que quebra o sh do Linux.
    $conteudo = [IO.File]::ReadAllText($copia) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($copia, $conteudo, (New-Object System.Text.UTF8Encoding($false)))
    return $copia
}

function Format-ArgumentosElevacao {
    param([hashtable]$Parametros)
    $lista = @()
    foreach ($chave in $Parametros.Keys) {
        $valor = $Parametros[$chave]
        if ($valor -is [System.Management.Automation.SwitchParameter] -or $valor -is [bool]) {
            if ([bool]$valor) { $lista += "-$chave" }
        } elseif ("$valor" -ne '') {
            $lista += "-$chave"
            $lista += '"' + ("$valor" -replace '"', '') + '"'
        }
    }
    return $lista
}

function Request-Elevacao {
    param([hashtable]$Parametros)
    if (Test-Administrador) { return $true }
    Write-Aviso 'Este script precisa de permissão de administrador. Vou abrir uma nova janela elevada (confirme no aviso do Windows).'
    $caminho = Copy-ScriptParaAppDir
    $exe = (Get-Process -Id $PID).Path
    $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$caminho`"") + @(Format-ArgumentosElevacao $Parametros) + @('-Elevado')
    try {
        Start-Process -FilePath $exe -ArgumentList $argumentos -Verb RunAs | Out-Null
        Write-Info 'A execução continua na nova janela.'
    } catch {
        Write-Erro 'A elevação foi cancelada. Abra o PowerShell com "Executar como administrador" e rode o script novamente.'
    }
    return $false
}

function Test-VersaoWindows {
    $versao = [Environment]::OSVersion.Version
    Write-Log "Windows build $($versao.Build)"
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'O WSL2 exige Windows 64 bits.'
    }
    if ($versao.Build -lt 19041) {
        throw "Seu Windows (build $($versao.Build)) é antigo demais. É preciso o Windows 10 versão 2004 (build 19041) ou mais novo, ou o Windows 11. Atualize pelo Windows Update."
    }
    $nome = 'Windows 10'
    if ($versao.Build -ge 22000) { $nome = 'Windows 11' }
    Write-Ok "$nome (build $($versao.Build)) é compatível com o WSL2."
}

function Test-Virtualizacao {
    $sistema = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($sistema.HypervisorPresent) {
        Write-Ok 'Virtualização ativa (hypervisor do Windows em execução).'
        return
    }
    $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    if ($cpu.VirtualizationFirmwareEnabled) {
        Write-Ok 'Virtualização habilitada na BIOS/UEFI.'
        return
    }
    throw ('A virtualização está desligada na BIOS/UEFI. Reinicie o PC, entre na configuração da BIOS ' +
        '(geralmente F2, F10, F12 ou Del) e ative "Intel VT-x", "Intel Virtualization Technology", "AMD-V" ou "SVM Mode". ' +
        'Depois rode o script novamente.')
}

function Enable-RecursosWindows {
    $precisaReiniciar = $false
    $recursos = @(
        @{ Nome = 'Microsoft-Windows-Subsystem-Linux'; Descricao = 'Subsistema do Windows para Linux' },
        @{ Nome = 'VirtualMachinePlatform';            Descricao = 'Plataforma de Máquina Virtual' }
    )
    foreach ($recurso in $recursos) {
        $estado = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='$($recurso.Nome)'"
        if ($estado -and $estado.InstallState -eq 1) {
            Write-Ok "$($recurso.Descricao): habilitado."
            continue
        }
        Write-Info "Habilitando $($recurso.Descricao)..."
        $resultado = Invoke-Nativo -Arquivo 'dism.exe' -Argumentos @('/online', '/enable-feature', "/featurename:$($recurso.Nome)", '/all', '/norestart') -Silencioso
        switch ($resultado.Codigo) {
            0       { Write-Ok "$($recurso.Descricao): habilitado." }
            3010    { Write-Ok "$($recurso.Descricao): habilitado (requer reinicialização)."; $precisaReiniciar = $true }
            default { throw "Não consegui habilitar $($recurso.Descricao) (código $($resultado.Codigo)). Veja o log: $Script:LogFile" }
        }
    }
    if (-not $precisaReiniciar -and (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        $teste = Invoke-Wsl -Argumentos @('--status') -Silencioso
        if ($teste.Codigo -ne 0) { $precisaReiniciar = $true }
    }
    return $precisaReiniciar
}

function Save-EstadoRetomada {
    param([hashtable]$Estado)
    New-Item -ItemType Directory -Force -Path $Script:AppDir | Out-Null
    $Estado | ConvertTo-Json | Set-Content -Path $Script:StateFile -Encoding UTF8
    $caminho = Copy-ScriptParaAppDir
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $acao = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$caminho`" -Retomar"
    $gatilho = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $Script:TaskName -Action $acao -Trigger $gatilho -Principal $principal -Force | Out-Null
    Write-Log "Retomada agendada: $($Estado | ConvertTo-Json -Compress)"
}

function Get-EstadoRetomada {
    if (-not (Test-Path $Script:StateFile)) { return $null }
    try {
        $json = Get-Content -Raw -Path $Script:StateFile -Encoding UTF8 | ConvertFrom-Json
        $estado = @{}
        foreach ($p in $json.PSObject.Properties) { $estado[$p.Name] = $p.Value }
        return $estado
    } catch {
        return $null
    }
}

function Clear-EstadoRetomada {
    Remove-Item -Path $Script:StateFile -Force -ErrorAction SilentlyContinue
    try { Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction Stop } catch { }
}

function Request-Reinicio {
    param([hashtable]$Estado)
    Save-EstadoRetomada -Estado $Estado
    Write-Host ''
    Write-Aviso 'O Windows precisa reiniciar para ativar o WSL2.'
    Write-Info 'Depois do reinício, faça login com o mesmo usuário: o script abre sozinho e continua de onde parou.'
    if (Read-SimNao 'Reiniciar agora?' $true) {
        Write-Log 'Reiniciando o Windows.'
        Restart-Computer -Force
    } else {
        Write-Info 'Reinicie quando puder. A instalação continua automaticamente no próximo login.'
    }
}

function Update-Wsl {
    Write-Info 'Atualizando o WSL (pode levar alguns minutos)...'
    $r = Invoke-Wsl -Argumentos @('--update') -Silencioso
    if ($r.Codigo -ne 0) {
        Write-Aviso 'A atualização pela Microsoft Store falhou; tentando baixar direto do GitHub...'
        $r = Invoke-Wsl -Argumentos @('--update', '--web-download') -Silencioso
    }
    if ($r.Codigo -ne 0) {
        Write-Aviso "Não consegui atualizar o WSL (código $($r.Codigo)). Vou continuar com a versão atual."
    }
    $versao = Invoke-Wsl -Argumentos @('--version') -Capturar
    if ($versao.Codigo -eq 0 -and $versao.Saida.Count -gt 0 -and $versao.Saida[0] -match '(\d+\.\d+\.\d+(\.\d+)?)') {
        Write-Ok "WSL versão $($Matches[1])."
        Add-Resumo "WSL atualizado (versão $($Matches[1]))"
    }
    [void](Invoke-Wsl -Argumentos @('--set-default-version', '2') -Silencioso)
    Write-Ok 'WSL2 definido como versão padrão.'
    $Script:WslRecursos = $null
}

function Get-RecursosWsl {
    if ($Script:WslRecursos) { return $Script:WslRecursos }
    $ajuda = (Invoke-Wsl -Argumentos @('--help') -Capturar).Saida -join "`n"
    $Script:WslRecursos = [pscustomobject]@{
        Location = $ajuda -match '--location'
        Name     = $ajuda -match '--name\b'
        Move     = $ajuda -match '--move'
        NoLaunch = $ajuda -match '--no-launch'
    }
    Write-Log "Recursos do WSL: $($Script:WslRecursos | ConvertTo-Json -Compress)"
    return $Script:WslRecursos
}

function Test-DockerDesktop {
    $caminhos = @(
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
    )
    foreach ($c in $caminhos) {
        if (Test-Path $c) {
            Write-Aviso 'O Docker Desktop está instalado. Ele pode disputar o comando "docker" com esta instalação. Recomendo desinstalá-lo ou desligar a integração com o WSL dele.'
            return $true
        }
    }
    return $false
}

function Initialize-Ambiente {
    param([hashtable]$EstadoRetomada)
    Write-Titulo 'Preparando o Windows'
    Start-Etapas 4
    Write-Etapa 'Verificando a versão do Windows'
    Test-VersaoWindows
    Write-Etapa 'Verificando a virtualização'
    Test-Virtualizacao
    Write-Etapa 'Verificando os recursos do WSL e da Plataforma de Máquina Virtual'
    if (Enable-RecursosWindows) {
        Request-Reinicio -Estado $EstadoRetomada
        return $false
    }
    Write-Etapa 'Atualizando o WSL e definindo o WSL2 como padrão'
    Update-Wsl
    [void](Test-DockerDesktop)
    return $true
}

#endregion

#region Distros ----------------------------------------------------------------------------------

function Format-Tamanho {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Get-DistrosEmExecucao {
    $r = Invoke-Wsl -Argumentos @('--list', '--running', '--quiet') -Capturar
    if ($r.Codigo -ne 0) { return @() }
    return @($r.Saida | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Os dados das distros ficam no registro do usuário: um GUID por distro com nome, pasta e versão do WSL.
function Get-Distros {
    if (-not (Test-Path $Script:LxssKey)) { return @() }
    $emExecucao = Get-DistrosEmExecucao
    $padrao = (Get-ItemProperty -Path $Script:LxssKey -ErrorAction SilentlyContinue).DefaultDistribution
    $lista = foreach ($chave in Get-ChildItem -Path $Script:LxssKey) {
        $p = Get-ItemProperty -Path $chave.PSPath
        if (-not ($p.PSObject.Properties.Name -contains 'DistributionName')) { continue }
        if ($p.DistributionName -like 'docker-desktop*') { continue }
        $base = "$($p.BasePath)" -replace '^\\\\\?\\', ''
        $versao = 1
        if ($p.PSObject.Properties.Name -contains 'Version' -and $p.Version -ge 2) { $versao = 2 }
        $arquivo = $null
        $tamanho = 0
        if ($versao -eq 2) {
            $vhd = 'ext4.vhdx'
            if ($p.PSObject.Properties.Name -contains 'VhdFileName' -and $p.VhdFileName) { $vhd = $p.VhdFileName }
            $arquivo = Join-Path $base $vhd
            if (Test-Path -LiteralPath $arquivo) { $tamanho = (Get-Item -LiteralPath $arquivo).Length }
        } else {
            $arquivo = Join-Path $base 'rootfs'
        }
        $uid = 0
        if ($p.PSObject.Properties.Name -contains 'DefaultUid') { $uid = [int]$p.DefaultUid }
        [pscustomobject]@{
            Nome       = $p.DistributionName
            Guid       = $chave.PSChildName
            Versao     = $versao
            EmExecucao = $emExecucao -contains $p.DistributionName
            Padrao     = ($chave.PSChildName -eq $padrao)
            Pasta      = $base
            Disco      = $arquivo
            Tamanho    = $tamanho
            DefaultUid = $uid
        }
    }
    if (-not $lista) { return @() }
    return @($lista | Sort-Object Nome)
}

function Get-Distro {
    param([string]$Nome)
    return Get-Distros | Where-Object { $_.Nome -eq $Nome } | Select-Object -First 1
}

function Get-CaminhoScriptNaDistro {
    param([string]$Nome)
    if (-not $Script:ScriptLinux) { $Script:ScriptLinux = Get-ScriptLinux }
    $local = $Script:ScriptLinux -replace '\\', '/'
    $r = Invoke-Wsl -Argumentos @('-d', $Nome, '-u', 'root', '--exec', 'wslpath', '-a', $local) -Capturar
    if ($r.Codigo -ne 0 -or $r.Saida.Count -eq 0) {
        throw "Não consegui acessar os arquivos do Windows de dentro da distro '$Nome'. Verifique se o [automount] não está desligado no /etc/wsl.conf."
    }
    return $r.Saida[-1].Trim()
}

function Invoke-ScriptNaDistro {
    param(
        [string]$Nome,
        [string]$Comando,
        [string[]]$Argumentos = @(),
        [string]$Usuario = 'root',
        [switch]$Capturar
    )
    $caminho = Get-CaminhoScriptNaDistro -Nome $Nome
    $lista = @('-d', $Nome)
    if ($Usuario) { $lista += @('-u', $Usuario) }
    $lista += @('--exec', 'sh', $caminho, $Comando) + $Argumentos
    $r = Invoke-Wsl -Argumentos $lista -Capturar:$Capturar
    $r | Add-Member -NotePropertyName Dados -NotePropertyValue (ConvertFrom-ChaveValor $r.Saida)
    return $r
}

function Get-StatusDocker {
    param([pscustomobject]$Info)
    $usuario = Get-UsuarioPadrao -Nome $Info.Nome
    $d = @{}
    $consultado = $false
    try {
        $r = Invoke-ScriptNaDistro -Nome $Info.Nome -Comando 'status' -Argumentos @($usuario) -Capturar
        $d = $r.Dados
        $consultado = ($r.Codigo -eq 0)
    } catch {
        Write-Log "Falha ao consultar '$($Info.Nome)': $($_.Exception.Message)" 'AVISO'
    }
    $valor = { param($k) if ($d.ContainsKey($k)) { $d[$k] } else { '' } }
    return [pscustomobject]@{
        Nome          = $Info.Nome
        Versao        = $Info.Versao
        EmExecucao    = $Info.EmExecucao
        Padrao        = $Info.Padrao
        Pasta         = $Info.Pasta
        Disco         = $Info.Disco
        Tamanho       = $Info.Tamanho
        Familia       = & $valor 'FAMILY'
        Sistema       = & $valor 'OS_NAME'
        Usuario       = $usuario
        Docker        = ((& $valor 'DOCKER_INSTALLED') -eq '1')
        DockerVersao  = & $valor 'DOCKER_VERSION'
        ComposeVersao = & $valor 'COMPOSE_VERSION'
        ServicoAtivo  = ((& $valor 'SERVICE_ACTIVE') -eq '1')
        NoGrupo       = ((& $valor 'USER_IN_GROUP') -eq '1')
        Systemd       = ((& $valor 'SYSTEMD') -eq '1')
        Consultado    = $consultado
    }
}

function Get-UsuarioPadrao {
    param([string]$Nome)
    $r = Invoke-Wsl -Argumentos @('-d', $Nome, '--exec', 'id', '-un') -Capturar
    if ($r.Codigo -eq 0 -and $r.Saida.Count -gt 0) { return $r.Saida[-1].Trim() }
    return 'root'
}

function Get-StatusTodas {
    $distros = @(Get-Distros)
    if ($distros.Count -eq 0) { return @() }
    Write-Info 'Consultando o Docker em cada distro (as que estiverem paradas serão iniciadas)...'
    $resultado = foreach ($d in $distros) {
        Write-Host "     · $($d.Nome)" -ForegroundColor DarkGray
        Get-StatusDocker -Info $d
    }
    return @($resultado)
}

function Show-TabelaDistros {
    param([object[]]$Status)
    if (-not $Status -or $Status.Count -eq 0) {
        Write-Aviso 'Nenhuma distro instalada. Use a opção 2 para criar uma já com o Docker.'
        return
    }
    $formato = '  {0,-24} {1,-4} {2,-10} {3,-16} {4,-9} {5,-6}'
    Write-Host ''
    Write-Host ($formato -f 'DISTRO', 'WSL', 'ESTADO', 'DOCKER', 'SERVIÇO', 'GRUPO') -ForegroundColor White
    Write-Host ('  ' + ('─' * 74)) -ForegroundColor DarkGray
    $temWsl1 = $false
    foreach ($s in $Status) {
        $nome = $s.Nome
        if ($s.Padrao) { $nome = "$nome *" }
        $estado = 'Parada'
        if ($s.EmExecucao) { $estado = 'Rodando' }
        $docker = 'Não'
        $servico = '-'
        $grupo = '-'
        if ($s.Docker) {
            $docker = "Sim $($s.DockerVersao)".Trim()
            $servico = 'Parado'
            if ($s.ServicoAtivo) { $servico = 'Ativo' }
            $grupo = 'Não'
            if ($s.NoGrupo) { $grupo = 'Sim' }
        }
        if (-not $s.Consultado) { $docker = '?' }
        $cor = 'Gray'
        if ($s.Docker -and $s.ServicoAtivo -and $s.NoGrupo) { $cor = 'Green' }
        elseif ($s.Docker) { $cor = 'Yellow' }
        if ($s.Versao -eq 1) { $cor = 'Yellow'; $temWsl1 = $true }
        Write-Host ($formato -f $nome, $s.Versao, $estado, $docker, $servico, $grupo) -ForegroundColor $cor
        $local = $s.Disco
        if ($s.Tamanho -gt 0) { $local = "$local ($(Format-Tamanho $s.Tamanho))" }
        Write-Host "    └ $local" -ForegroundColor DarkGray
        if ($s.Versao -eq 1) {
            Write-Host '      ! Em WSL1: converta para WSL2 antes de usar o Docker (opção 3 oferece a conversão).' -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host '  * distro padrão do WSL' -ForegroundColor DarkGray
    if ($temWsl1) { Write-Aviso 'Há distros em WSL1. O Docker Engine só funciona em WSL2.' }
}

function Select-Distro {
    param([object[]]$Lista, [string]$Titulo, [string]$Preferida)
    if ($Preferida) {
        $achada = $Lista | Where-Object { $_.Nome -eq $Preferida } | Select-Object -First 1
        if ($achada) { return $achada }
        if ($Silent) { throw "A distro '$Preferida' não está disponível para esta ação." }
        Write-Aviso "A distro '$Preferida' não está disponível para esta ação."
    }
    if ($Lista.Count -eq 0) { return $null }
    if ($Silent) { throw 'No modo -Silent, informe a distro com -Distro.' }
    $opcoes = foreach ($d in $Lista) {
        $tamanho = ''
        if ($d.Tamanho -gt 0) { $tamanho = ", $(Format-Tamanho $d.Tamanho)" }
        "{0}  (WSL{1}{2})  →  {3}" -f $d.Nome, $d.Versao, $tamanho, $d.Pasta
    }
    $escolha = Read-Opcao -Pergunta $Titulo -Opcoes @($opcoes) -Padrao 1
    return $Lista[$escolha - 1]
}

#endregion

#region Discos e locais de armazenamento ----------------------------------------------------------

function Get-Discos {
    return @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
        Where-Object { $_.Size -gt 0 } |
        Sort-Object DeviceID |
        ForEach-Object {
            [pscustomobject]@{ Letra = $_.DeviceID; Livre = [double]$_.FreeSpace; Total = [double]$_.Size; Rotulo = $_.VolumeName }
        })
}

function Get-EspacoLivre {
    param([string]$Pasta)
    $raiz = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Pasta))
    $disco = Get-Discos | Where-Object { $raiz -like "$($_.Letra)*" } | Select-Object -First 1
    if ($disco) { return $disco.Livre }
    return [double]::MaxValue
}

function Show-Discos {
    Write-Host ''
    Write-Host '  Discos disponíveis:' -ForegroundColor White
    foreach ($d in Get-Discos) {
        $rotulo = ''
        if ($d.Rotulo) { $rotulo = " ($($d.Rotulo))" }
        $pct = 0
        if ($d.Total -gt 0) { $pct = [math]::Round(100 * $d.Livre / $d.Total) }
        $cor = 'Gray'
        if ($d.Livre -lt 20GB) { $cor = 'Yellow' }
        Write-Host ("    {0}{1,-16} {2,10} livres de {3,-10} ({4}% livre)" -f $d.Letra, $rotulo, (Format-Tamanho $d.Livre), (Format-Tamanho $d.Total), $pct) -ForegroundColor $cor
    }
}

function Test-PastaDestino {
    param([string]$Pasta)
    if ($Pasta -notmatch '^[A-Za-z]:\\') { return 'Informe um caminho completo, por exemplo D:\WSL\Ubuntu.' }
    try { $Pasta = [IO.Path]::GetFullPath($Pasta) } catch { return 'Caminho inválido.' }
    $raiz = [IO.Path]::GetPathRoot($Pasta)
    if (-not (Test-Path -LiteralPath $raiz)) { return "O disco $raiz não existe." }
    if (Test-Path -LiteralPath (Join-Path $Pasta 'ext4.vhdx')) { return 'Essa pasta já contém o disco de outra distro. Escolha outra pasta.' }
    if ((Test-Path -LiteralPath $Pasta) -and @(Get-ChildItem -LiteralPath $Pasta -Force).Count -gt 0) {
        return 'Essa pasta não está vazia. Escolha uma pasta nova ou vazia.'
    }
    return $null
}

function Resolve-PastaDistro {
    param([string]$Base, [string]$NomeDistro)
    $cheio = [IO.Path]::GetFullPath($Base)
    if ((Split-Path $cheio -Leaf) -ieq $NomeDistro) { return $cheio }
    return (Join-Path $cheio $NomeDistro)
}

function Select-LocalArmazenamento {
    param([string]$NomeDistro, [string]$Informado, [switch]$SemPadrao)
    if ($Informado) {
        $pasta = Resolve-PastaDistro -Base $Informado -NomeDistro $NomeDistro
        $erro = Test-PastaDestino $pasta
        if ($erro) { throw "Local inválido ($pasta): $erro" }
        return $pasta
    }
    if ($Silent) { return $null }
    Show-Discos
    $opcoes = @()
    $caminhos = @()
    if (-not $SemPadrao) {
        $opcoes += 'Padrão: local padrão do WSL no C: (pasta do seu usuário)'
        $caminhos += $null
    }
    $sistema = $env:SystemDrive.ToUpperInvariant()
    foreach ($d in Get-Discos) {
        if (-not $SemPadrao -and $d.Letra -eq $sistema) { continue }
        $sugestao = "$($d.Letra)\WSL\$NomeDistro"
        $opcoes += "$sugestao  ($(Format-Tamanho $d.Livre) livres)"
        $caminhos += $sugestao
    }
    $opcoes += 'Outra pasta (digitar o caminho)'
    $caminhos += '?'
    $escolha = Read-Opcao -Pergunta 'Onde os dados da distro devem ficar' -Opcoes $opcoes -Padrao 1
    $pasta = $caminhos[$escolha - 1]
    if ($pasta -eq '?') {
        $pasta = Read-Texto -Pergunta 'Caminho completo da pasta' -Padrao "D:\WSL\$NomeDistro" -Validar { param($r) Test-PastaDestino $r }
        $pasta = [IO.Path]::GetFullPath($pasta)
    } elseif ($pasta) {
        $erro = Test-PastaDestino $pasta
        if ($erro) {
            Write-Aviso $erro
            $pasta = Read-Texto -Pergunta 'Caminho completo da pasta' -Padrao "$pasta-2" -Validar { param($r) Test-PastaDestino $r }
            $pasta = [IO.Path]::GetFullPath($pasta)
        }
    }
    return $pasta
}

#endregion

#region Mover distro -----------------------------------------------------------------------------

function Move-WslDistro {
    param([Parameter(Mandatory)][string]$Nome, [Parameter(Mandatory)][string]$Destino, [switch]$SemConfirmar)
    $info = Get-Distro -Nome $Nome
    if (-not $info) { throw "A distro '$Nome' não existe." }
    $Destino = [IO.Path]::GetFullPath($Destino)
    if ($info.Pasta.TrimEnd('\') -ieq $Destino.TrimEnd('\')) {
        Write-Ok "A distro '$Nome' já está em $Destino."
        return $true
    }
    $erro = Test-PastaDestino $Destino
    if ($erro) { throw "Destino inválido ($Destino): $erro" }

    $recursos = Get-RecursosWsl
    $usarMove = $recursos.Move -and $info.Versao -eq 2
    $tamanho = $info.Tamanho
    if ($info.Versao -eq 1) {
        $tamanho = (Get-ChildItem -LiteralPath $info.Pasta -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    }
    $fator = 2.1
    if ($usarMove) { $fator = 1.1 }
    $necessario = [double]$tamanho * $fator
    $livre = Get-EspacoLivre $Destino
    Write-Info "Origem:  $($info.Pasta) ($(Format-Tamanho $tamanho))"
    Write-Info "Destino: $Destino ($(Format-Tamanho $livre) livres; necessário cerca de $(Format-Tamanho $necessario))"
    if ($livre -lt $necessario) {
        throw "Espaço insuficiente em $([IO.Path]::GetPathRoot($Destino)). Libere pelo menos $(Format-Tamanho ($necessario - $livre)) ou escolha outro disco."
    }
    if (-not $SemConfirmar) {
        if (-not (Confirm-Acao "A distro '$Nome' será desligada e movida para $Destino. Terminais abertos nela serão fechados.")) {
            Write-Info 'Movimentação cancelada.'
            return $false
        }
    }

    Write-Info "Desligando a distro '$Nome'..."
    [void](Invoke-Wsl -Argumentos @('--terminate', $Nome) -Silencioso)

    $movido = $false
    if ($usarMove) {
        Write-Info 'Movendo com "wsl --manage --move" (pode levar alguns minutos)...'
        $r = Invoke-Wsl -Argumentos @('--manage', $Nome, '--move', $Destino)
        $movido = ($r.Codigo -eq 0)
        if (-not $movido) { Write-Aviso 'O "wsl --manage --move" falhou; vou usar exportar/importar.' }
    }
    if (-not $movido) {
        Move-PorExportacao -Info $info -Destino $Destino
    }

    $novo = Get-Distro -Nome $Nome
    if (-not $novo -or $novo.Pasta.TrimEnd('\') -ine $Destino.TrimEnd('\')) {
        throw "A distro não aparece no novo local. Veja o log: $Script:LogFile"
    }
    Write-Ok "Distro '$Nome' movida para $Destino."
    Add-Resumo "Distro '$Nome' movida para $Destino"
    return $true
}

function Move-PorExportacao {
    param([pscustomobject]$Info, [string]$Destino)
    New-Item -ItemType Directory -Force -Path $Destino | Out-Null
    $tar = Join-Path $Destino "$($Info.Nome)-backup.tar"
    Write-Info "Exportando a distro para $tar (pode levar vários minutos)..."
    $r = Invoke-Wsl -Argumentos @('--export', $Info.Nome, $tar)
    if ($r.Codigo -ne 0 -or -not (Test-Path -LiteralPath $tar) -or (Get-Item -LiteralPath $tar).Length -eq 0) {
        Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
        throw 'A exportação falhou. Nada foi alterado na distro original.'
    }
    Write-Info 'Removendo o registro antigo...'
    $r = Invoke-Wsl -Argumentos @('--unregister', $Info.Nome) -Silencioso
    if ($r.Codigo -ne 0) { throw "Não consegui remover o registro antigo. O backup está em $tar." }
    Write-Info 'Importando no novo local...'
    $r = Invoke-Wsl -Argumentos @('--import', $Info.Nome, $Destino, $tar, '--version', "$($Info.Versao)")
    if ($r.Codigo -ne 0) {
        throw "A importação falhou. Seus dados estão salvos em $tar. Para restaurar: wsl --import $($Info.Nome) `"$Destino`" `"$tar`""
    }
    $novo = Get-Distro -Nome $Info.Nome
    if ($novo -and $Info.DefaultUid -ne 0) {
        Set-ItemProperty -Path (Join-Path $Script:LxssKey $novo.Guid) -Name DefaultUid -Value $Info.DefaultUid -Type DWord
    }
    if ($Info.Padrao) { [void](Invoke-Wsl -Argumentos @('--set-default', $Info.Nome) -Silencioso) }
    Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
}

#endregion

#region Instalação do Docker ---------------------------------------------------------------------

function Get-UsuarioSugerido {
    $nome = "$env:USERNAME".ToLowerInvariant() -replace '[^a-z0-9_-]', ''
    if ($nome -notmatch '^[a-z_]') { $nome = "dev$nome" }
    if ($nome.Length -gt 32) { $nome = $nome.Substring(0, 32) }
    if (-not $nome) { $nome = 'dev' }
    return $nome
}

function Test-NomeUsuario {
    param([string]$Valor)
    if ($Valor -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { return 'Use só letras minúsculas, números, "-" e "_", começando com letra (ex.: maria).' }
    if ($Valor -eq 'root') { return 'Escolha um usuário diferente de root.' }
    return $null
}

function Set-SenhaUsuario {
    param([string]$Nome, [string]$Usuario)
    if ($Silent) {
        Write-Aviso "Senha não definida (modo silencioso). Para usar o sudo, defina depois com: wsl -d $Nome -u root passwd $Usuario"
        return
    }
    Write-Info "Defina a senha do usuário '$Usuario' no Linux (ela é pedida pelo sudo; os caracteres não aparecem ao digitar)."
    for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
        $r = Invoke-Wsl -Argumentos @('-d', $Nome, '-u', 'root', '--exec', 'passwd', $Usuario) -Interativo
        if ($r.Codigo -eq 0) { Write-Ok 'Senha definida.'; return }
        Write-Aviso 'As senhas não conferem ou são inválidas. Tente de novo.'
    }
    Write-Aviso "Senha não definida. Defina depois com: wsl -d $Nome -u root passwd $Usuario"
}

function New-UsuarioLinux {
    param([string]$Nome, [string]$Usuario)
    $r = Invoke-ScriptNaDistro -Nome $Nome -Comando 'user' -Argumentos @($Usuario)
    if ($r.Codigo -ne 0) { throw "Não consegui criar o usuário '$Usuario'. Veja o log: $Script:LogFile" }
    $uid = Invoke-Wsl -Argumentos @('-d', $Nome, '-u', 'root', '--exec', 'id', '-u', $Usuario) -Capturar
    $info = Get-Distro -Nome $Nome
    if ($info -and $uid.Codigo -eq 0 -and $uid.Saida.Count -gt 0) {
        Set-ItemProperty -Path (Join-Path $Script:LxssKey $info.Guid) -Name DefaultUid -Value ([int]$uid.Saida[-1]) -Type DWord
    }
    Set-SenhaUsuario -Nome $Nome -Usuario $Usuario
    Add-Resumo "Usuário Linux '$Usuario' configurado como padrão"
}

function Install-DockerNaDistro {
    param([string]$Nome, [string]$Usuario)
    Write-Etapa 'Habilitando o systemd'
    $r = Invoke-ScriptNaDistro -Nome $Nome -Comando 'systemd'
    if ($r.Codigo -ne 0) { throw "Não consegui configurar o /etc/wsl.conf. Veja o log: $Script:LogFile" }
    if ($r.Dados['SYSTEMD_CHANGED'] -eq '1') {
        Write-Info 'Reiniciando a distro para ativar o systemd...'
        [void](Invoke-Wsl -Argumentos @('--terminate', $Nome) -Silencioso)
        Add-Resumo 'systemd habilitado no /etc/wsl.conf'
    }

    Write-Etapa 'Instalando Docker Engine, Compose v2 e Buildx (repositório oficial)'
    $r = Invoke-ScriptNaDistro -Nome $Nome -Comando 'install' -Argumentos @($Usuario)
    if ($r.Codigo -ne 0) { throw "A instalação do Docker falhou. As últimas linhas acima mostram o motivo; o log completo está em $Script:LogFile" }
    Add-Resumo 'Docker Engine, Compose v2 e Buildx instalados'
    if ($Usuario -and $Usuario -ne 'root') { Add-Resumo "Usuário '$Usuario' adicionado ao grupo docker (sem sudo)" }

    Write-Etapa 'Iniciando o serviço do Docker'
    if ($r.Dados['RESTART_REQUIRED'] -eq '1') {
        [void](Invoke-Wsl -Argumentos @('--terminate', $Nome) -Silencioso)
    }
    if ($r.Dados['SERVICE_ACTIVE'] -ne '1') {
        $r = Invoke-ScriptNaDistro -Nome $Nome -Comando 'start'
        if ($r.Codigo -ne 0) { throw 'O serviço do Docker não iniciou. Veja "O serviço do Docker não inicia" em docs/troubleshooting.md.' }
    }
    Write-Ok 'Serviço do Docker ativo e configurado para iniciar junto com a distro.'
}

function Test-DockerHelloWorld {
    param([string]$Nome, [string]$Usuario)
    Write-Etapa 'Validando com "docker run hello-world"'
    $argumentos = @('-d', $Nome)
    if ($Usuario) { $argumentos += @('-u', $Usuario) }
    $argumentos += @('--exec', 'docker', 'run', '--rm', 'hello-world')
    $r = Invoke-Wsl -Argumentos $argumentos -Capturar
    if ($r.Codigo -eq 0 -and ($r.Saida -join "`n") -match 'Hello from Docker') {
        Write-Ok 'O Docker funcionou: o container hello-world rodou sem sudo.'
        Add-Resumo 'Teste "docker run hello-world" executado com sucesso'
        return $true
    }
    $r.Saida | Select-Object -Last 5 | ForEach-Object { Write-Detalhe $_ }
    Write-Aviso 'O teste falhou. Veja docs/troubleshooting.md ou rode o script de novo (ele continua de onde parou).'
    return $false
}

function Enable-ComandoWindows {
    param([string]$Nome)
    Write-Etapa 'Criando o comando "docker" para PowerShell e CMD'
    New-Item -ItemType Directory -Force -Path $Script:BinDir | Out-Null
    $cmd = "@echo off`r`nwsl.exe -d $Nome --exec docker %*`r`n"
    [IO.File]::WriteAllText((Join-Path $Script:BinDir 'docker.cmd'), $cmd, (New-Object System.Text.ASCIIEncoding))
    # Lê o PATH sem expandir variáveis, para não trocar %USERPROFILE% por caminhos fixos ao gravar.
    $chave = Get-Item -Path 'HKCU:\Environment'
    $path = "$($chave.GetValue('Path', '', 'DoNotExpandEnvironmentNames'))"
    $itens = @($path -split ';' | Where-Object { $_ })
    if ($itens -notcontains $Script:BinDir) {
        $novo = (@($itens) + $Script:BinDir) -join ';'
        Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value $novo -Type ExpandString
    }
    [Environment]::SetEnvironmentVariable('DOCKER_WSL_DISTRO', $Nome, 'User')
    if (($env:Path -split ';') -notcontains $Script:BinDir) { $env:Path = "$env:Path;$Script:BinDir" }
    Write-Ok "Comando 'docker' disponível no Windows (aponta para a distro '$Nome'). Abra um novo terminal para usar."
    Add-Resumo "Comando 'docker' no PowerShell/CMD apontando para '$Nome' ($Script:BinDir\docker.cmd)"
}

function Remove-ComandoWindows {
    param([string]$Nome)
    $arquivo = Join-Path $Script:BinDir 'docker.cmd'
    if (-not (Test-Path $arquivo)) { return }
    if ((Get-Content -Raw $arquivo) -notmatch ("-d " + [regex]::Escape($Nome) + " ")) { return }
    Remove-Item $arquivo -Force
    [Environment]::SetEnvironmentVariable('DOCKER_WSL_DISTRO', $null, 'User')
    Write-Ok 'Comando "docker" do Windows removido.'
}

function Get-NomeLivre {
    param([string]$Base)
    if (-not (Get-Distro -Nome $Base)) { return $Base }
    $candidato = "$Base-Docker"
    $i = 2
    while (Get-Distro -Nome $candidato) { $candidato = "$Base-Docker-$i"; $i++ }
    return $candidato
}

function Install-Alpine {
    param([string]$Nome, [string]$Pasta)
    $arch = 'x86_64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'aarch64' }
    $base = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$arch"
    $yaml = Join-Path $Script:AppDir 'downloads\alpine-latest.yaml'
    Save-Arquivo -Url "$base/latest-releases.yaml" -Destino $yaml
    $conteudo = Get-Content -Raw -Path $yaml
    if ($conteudo -notmatch "file:\s*(alpine-minirootfs-[\d.]+-$arch\.tar\.gz)") { throw 'Não encontrei a versão mais recente do Alpine no site oficial.' }
    $arquivo = $Matches[1]
    $tar = Join-Path $Script:AppDir "downloads\$arquivo"
    if (-not (Test-Path $tar)) {
        Write-Info "Baixando $arquivo..."
        Save-Arquivo -Url "$base/$arquivo" -Destino $tar
    }
    if (-not $Pasta) { $Pasta = Join-Path $env:LOCALAPPDATA "wsl\$Nome" }
    New-Item -ItemType Directory -Force -Path $Pasta | Out-Null
    Write-Info "Importando o Alpine em $Pasta..."
    $r = Invoke-Wsl -Argumentos @('--import', $Nome, $Pasta, $tar, '--version', '2')
    if ($r.Codigo -ne 0) { throw "Não consegui importar o Alpine. Veja o log: $Script:LogFile" }
}

function Install-DistroNova {
    param([string]$Base, [string]$Nome, [string]$Pasta)
    if ($Base -eq 'Alpine') {
        Install-Alpine -Nome $Nome -Pasta $Pasta
        return $Nome
    }
    $recursos = Get-RecursosWsl
    $online = $Script:Catalogo[$Base].Online
    if (-not $recursos.Name -and $Nome -ne $online) {
        Write-Aviso "Esta versão do WSL não aceita nome personalizado; a distro vai se chamar '$online'."
        $Nome = $online
        if (Get-Distro -Nome $Nome) { throw "Já existe uma distro chamada '$Nome'." }
    }
    $argumentos = @('--install', '-d', $online, '--no-launch')
    if ($recursos.Name) { $argumentos += @('--name', $Nome) }
    $moverDepois = $false
    if ($Pasta) {
        if ($recursos.Location) {
            New-Item -ItemType Directory -Force -Path $Pasta | Out-Null
            $argumentos += @('--location', $Pasta)
        } else {
            $moverDepois = $true
        }
    }
    Write-Info "Baixando e registrando $online (pode levar alguns minutos)..."
    $r = Invoke-Wsl -Argumentos $argumentos
    if (-not (Get-Distro -Nome $Nome)) {
        # Em WSL antigo a distro vem como app da Store e só é registrada ao rodar o lançador dela.
        $lancador = Get-Command "$($online.ToLowerInvariant()).exe" -ErrorAction SilentlyContinue
        if ($lancador) {
            Write-Info 'Registrando a distro pelo lançador da Microsoft Store...'
            [void](Invoke-Nativo -Arquivo $lancador.Source -Argumentos @('install', '--root'))
        }
    }
    if (-not (Get-Distro -Nome $Nome)) {
        throw "A distro não foi registrada (código $($r.Codigo)). Tente 'wsl --install -d $online' manualmente e depois use a opção 3. Log: $Script:LogFile"
    }
    if ($moverDepois) { [void](Move-WslDistro -Nome $Nome -Destino $Pasta -SemConfirmar) }
    return $Nome
}

function Show-Resumo {
    param([string]$Nome, [string]$Usuario, [bool]$Sucesso)
    $info = Get-Distro -Nome $Nome
    Write-Titulo 'Resumo'
    foreach ($item in $Script:Resumo) { Write-Ok $item }
    if ($info) {
        Write-Host ''
        Write-Host "  Distro:        $Nome (WSL$($info.Versao))" -ForegroundColor White
        Write-Host "  Armazenamento: $($info.Disco)" -ForegroundColor White
        if ($Usuario) { Write-Host "  Usuário Linux: $Usuario" -ForegroundColor White }
    }
    Write-Host "  Log:           $Script:LogFile" -ForegroundColor DarkGray
    $Script:Resumo.Clear()
    if (-not $Sucesso) { return }
    Write-Host ''
    Write-Host '  Próximos passos:' -ForegroundColor Cyan
    Write-Host "    1. Abra a distro:            wsl -d $Nome"
    Write-Host '    2. Rode um container:        docker run -d -p 8080:80 nginx   (depois abra http://localhost:8080)'
    Write-Host '    3. Use o Compose:            docker compose up -d'
    Write-Host '    4. No VS Code: instale a extensão "WSL", abra a distro e rode "code ." na pasta do projeto.'
    Write-Host '    5. Guarde seus projetos dentro do Linux (~/projetos), não em /mnt/c: fica muito mais rápido.'
}

function Repair-DockerExistente {
    param([string]$Nome)
    Write-Info "A distro '$Nome' já existe; vou só garantir que o Docker esteja instalado e funcionando nela."
    $status = Get-StatusDocker -Info (Get-Distro -Nome $Nome)
    if ($status.Versao -eq 1) { throw "A distro '$Nome' está em WSL1. Converta com: wsl --set-version $Nome 2" }
    Start-Etapas 4
    Install-DockerNaDistro -Nome $Nome -Usuario $status.Usuario
    $ok = Test-DockerHelloWorld -Nome $Nome -Usuario $status.Usuario
    Show-Resumo -Nome $Nome -Usuario $status.Usuario -Sucesso $ok
}

#endregion

#region Ações do menu -----------------------------------------------------------------------------

function Invoke-Listar {
    Write-Titulo 'Distros e status do Docker'
    Show-TabelaDistros -Status (Get-StatusTodas)
}

function Invoke-InstalarNova {
    Write-Titulo 'Instalar Docker em uma nova distro'
    if (-not (Initialize-Ambiente -EstadoRetomada (Get-ParametrosAtuais))) { return }

    $chaves = @($Script:Catalogo.Keys)
    $base = $null
    if ($Distro) {
        $base = $chaves | Where-Object { $_ -ieq $Distro } | Select-Object -First 1
        if (-not $base) { throw "Distro '$Distro' não suportada. Use Ubuntu, Debian ou Alpine." }
    } else {
        $opcoes = @($chaves | ForEach-Object { $Script:Catalogo[$_].Descricao })
        $base = $chaves[(Read-Opcao -Pergunta 'Qual distro instalar' -Opcoes $opcoes -Padrao 1) - 1]
    }

    $sugestao = $Nome
    if ($Silent -and -not $sugestao) { $sugestao = $base }
    if ($Silent -and (Get-Distro -Nome $sugestao)) {
        Repair-DockerExistente -Nome $sugestao
        return
    }
    if (-not $sugestao) { $sugestao = Get-NomeLivre $base }
    $validarNome = {
        param($r)
        if ($r -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return 'Use letras, números, ".", "-" ou "_" (sem espaços).' }
        if (Get-Distro -Nome $r) { return "Já existe uma distro chamada '$r'." }
    }
    $nomeDistro = Read-Texto -Pergunta 'Nome da distro' -Padrao $sugestao -Validar $validarNome
    $erroNome = & $validarNome $nomeDistro
    if ($erroNome) { throw $erroNome }

    $pasta = Select-LocalArmazenamento -NomeDistro $nomeDistro -Informado $Local
    $usuarioPadrao = $Usuario
    if (-not $usuarioPadrao) { $usuarioPadrao = Get-UsuarioSugerido }
    $usuarioLinux = Read-Texto -Pergunta 'Usuário do Linux' -Padrao $usuarioPadrao -Validar { param($r) Test-NomeUsuario $r }
    if (Test-NomeUsuario $usuarioLinux) { throw (Test-NomeUsuario $usuarioLinux) }
    $comandoWin = [bool]$ComandoWindows
    if (-not $comandoWin) { $comandoWin = Read-SimNao 'Quer usar o comando "docker" direto no PowerShell/CMD do Windows?' $false }

    $localTexto = $pasta
    if (-not $localTexto) { $localTexto = 'local padrão do WSL (C:)' }
    Write-Host ''
    Write-Host '  Vou fazer o seguinte:' -ForegroundColor White
    Write-Host "    Distro:        $base, com o nome '$nomeDistro'"
    Write-Host "    Armazenamento: $localTexto"
    Write-Host "    Usuário Linux: $usuarioLinux"
    if (-not (Read-SimNao 'Continuar?' $true)) { Write-Info 'Instalação cancelada.'; return }

    $total = 6
    if ($comandoWin) { $total = 7 }
    Start-Etapas $total
    Write-Etapa "Instalando a distro $base"
    $nomeDistro = Install-DistroNova -Base $base -Nome $nomeDistro -Pasta $pasta
    Add-Resumo "Distro '$nomeDistro' criada em $((Get-Distro -Nome $nomeDistro).Pasta)"
    Write-Etapa "Criando o usuário '$usuarioLinux'"
    New-UsuarioLinux -Nome $nomeDistro -Usuario $usuarioLinux
    Install-DockerNaDistro -Nome $nomeDistro -Usuario $usuarioLinux
    $ok = Test-DockerHelloWorld -Nome $nomeDistro -Usuario $usuarioLinux
    if ($comandoWin) { Enable-ComandoWindows -Nome $nomeDistro }
    Show-Resumo -Nome $nomeDistro -Usuario $usuarioLinux -Sucesso $ok
}

function Invoke-InstalarExistente {
    Write-Titulo 'Instalar Docker em uma distro existente'
    if (-not (Initialize-Ambiente -EstadoRetomada (Get-ParametrosAtuais))) { return }
    $todas = @(Get-StatusTodas)
    if ($Distro -and ($todas | Where-Object { $_.Nome -eq $Distro -and $_.Docker })) {
        Repair-DockerExistente -Nome $Distro
        return
    }
    $candidatas = @($todas | Where-Object { -not $_.Docker })
    if ($candidatas.Count -eq 0) {
        Write-Info 'Todas as distros já têm o Docker (ou não há distros). Use a opção 2 para criar uma nova.'
        return
    }
    $d = Select-Distro -Lista $candidatas -Titulo 'Em qual distro instalar o Docker' -Preferida $Distro
    if ($d.Familia -notin @('debian', 'alpine')) {
        throw "A distro '$($d.Nome)' ($($d.Sistema)) não é suportada. O script funciona com Ubuntu, Debian e Alpine (e derivados)."
    }
    $converter = ($d.Versao -eq 1)
    if ($converter -and -not (Confirm-Acao "A distro '$($d.Nome)' está em WSL1 e o Docker precisa de WSL2. A conversão pode levar vários minutos e a distro será desligada.")) {
        Write-Info 'Instalação cancelada.'
        return
    }

    $destino = $null
    if ($Local) {
        $destino = Select-LocalArmazenamento -NomeDistro $d.Nome -Informado $Local -SemPadrao
    } elseif ($Mover -and $Silent) {
        throw 'Informe o destino com -Local junto com -Mover.'
    } elseif (-not $Silent -and (Read-SimNao "Quer mover a distro '$($d.Nome)' para outro disco antes de instalar? (hoje em $($d.Pasta))" $false)) {
        $destino = Select-LocalArmazenamento -NomeDistro $d.Nome -SemPadrao
    }

    $usuarioLinux = $d.Usuario
    $criarUsuario = $false
    if ($usuarioLinux -eq 'root' -and ($Usuario -or (Read-SimNao 'A distro usa o root como usuário padrão. Criar um usuário comum (recomendado)?' $true))) {
        $sugerido = $Usuario
        if (-not $sugerido) { $sugerido = Get-UsuarioSugerido }
        $usuarioLinux = Read-Texto -Pergunta 'Usuário do Linux' -Padrao $sugerido -Validar { param($r) Test-NomeUsuario $r }
        $criarUsuario = $true
    }
    $comandoWin = [bool]$ComandoWindows
    if (-not $comandoWin) { $comandoWin = Read-SimNao 'Quer usar o comando "docker" direto no PowerShell/CMD do Windows?' $false }

    $total = 4
    if ($converter) { $total++ }
    if ($destino) { $total++ }
    if ($criarUsuario) { $total++ }
    if ($comandoWin) { $total++ }
    Start-Etapas $total

    if ($converter) {
        Write-Etapa 'Convertendo a distro para WSL2'
        $r = Invoke-Wsl -Argumentos @('--set-version', $d.Nome, '2')
        if ($r.Codigo -ne 0) { throw "A conversão para WSL2 falhou. Veja o log: $Script:LogFile" }
        Write-Ok 'Distro convertida para WSL2.'
        Add-Resumo "Distro '$($d.Nome)' convertida para WSL2"
    }
    if ($destino) {
        Write-Etapa 'Movendo a distro'
        if (-not (Move-WslDistro -Nome $d.Nome -Destino $destino)) { Write-Info 'A distro continua no local atual.' }
    }
    if ($criarUsuario) {
        Write-Etapa "Criando o usuário '$usuarioLinux'"
        New-UsuarioLinux -Nome $d.Nome -Usuario $usuarioLinux
    }

    Install-DockerNaDistro -Nome $d.Nome -Usuario $usuarioLinux
    $ok = Test-DockerHelloWorld -Nome $d.Nome -Usuario $usuarioLinux
    if ($comandoWin) { Enable-ComandoWindows -Nome $d.Nome }
    Show-Resumo -Nome $d.Nome -Usuario $usuarioLinux -Sucesso $ok
}

function Invoke-Mover {
    Write-Titulo 'Mover uma distro para outro disco'
    $distros = @(Get-Distros)
    if ($distros.Count -eq 0) { Write-Aviso 'Nenhuma distro instalada.'; return }
    $d = Select-Distro -Lista $distros -Titulo 'Qual distro mover' -Preferida $Distro
    Write-Info "Local atual: $($d.Disco) ($(Format-Tamanho $d.Tamanho))"
    $destino = Select-LocalArmazenamento -NomeDistro $d.Nome -Informado $Local -SemPadrao
    if (-not $destino) { throw 'Informe o destino com -Local (ex.: -Local D:\WSL).' }
    if (Move-WslDistro -Nome $d.Nome -Destino $destino) {
        Show-Resumo -Nome $d.Nome -Usuario $null -Sucesso $false
    }
}

function Invoke-Desinstalar {
    Write-Titulo 'Desinstalar Docker de uma distro'
    $candidatas = @(Get-StatusTodas | Where-Object { $_.Docker })
    if ($candidatas.Count -eq 0) { Write-Info 'Nenhuma distro tem o Docker instalado.'; return }
    $d = Select-Distro -Lista $candidatas -Titulo 'De qual distro remover o Docker' -Preferida $Distro

    $dados = (Invoke-ScriptNaDistro -Nome $d.Nome -Comando 'data' -Capturar).Dados
    $resumoDados = 'tamanho {0}' -f $dados['DATA_SIZE']
    if ($dados.ContainsKey('IMAGES')) {
        $resumoDados = '{0} imagens, {1} containers, {2} volumes, {3} no total' -f $dados['IMAGES'], $dados['CONTAINERS'], $dados['VOLUMES'], $dados['DATA_SIZE']
    }
    Write-Info "Dados do Docker em '$($d.Nome)': $resumoDados"

    if (-not (Confirm-Acao "Os pacotes do Docker serão removidos da distro '$($d.Nome)'.")) { Write-Info 'Cancelado.'; return }
    $apagarDados = [bool]$RemoverDados
    if (-not $Silent -and -not $apagarDados -and (Read-SimNao 'Apagar também imagens, containers e volumes?' $false)) {
        $apagarDados = Confirm-Acao "Imagens, containers e volumes serão apagados ($resumoDados). Isso NÃO pode ser desfeito." -Palavra 'APAGAR'
    }
    $apagarDistro = [bool]$RemoverDistro
    if (-not $Silent -and -not $apagarDistro -and (Read-SimNao "Remover também a distro '$($d.Nome)' inteira?" $false)) {
        $apagarDistro = Confirm-Acao "Todos os arquivos da distro '$($d.Nome)' serão apagados, não só o Docker." -Palavra $d.Nome
    }

    $total = 2
    if ($apagarDistro) { $total = 3 }
    Start-Etapas $total
    Write-Etapa 'Removendo os pacotes do Docker'
    $argumentos = @()
    if ($apagarDados) { $argumentos = @('--purge') }
    $r = Invoke-ScriptNaDistro -Nome $d.Nome -Comando 'uninstall' -Argumentos $argumentos
    if ($r.Codigo -ne 0) { throw "A remoção falhou. Veja o log: $Script:LogFile" }
    Add-Resumo "Docker removido da distro '$($d.Nome)'"
    if ($apagarDados) { Add-Resumo 'Imagens, containers e volumes apagados' }

    Write-Etapa 'Limpando o comando "docker" do Windows'
    Remove-ComandoWindows -Nome $d.Nome

    if ($apagarDistro) {
        Write-Etapa "Removendo a distro '$($d.Nome)'"
        $r = Invoke-Wsl -Argumentos @('--unregister', $d.Nome)
        if ($r.Codigo -ne 0) { throw "Não consegui remover a distro. Veja o log: $Script:LogFile" }
        Add-Resumo "Distro '$($d.Nome)' removida"
        Write-Titulo 'Resumo'
        foreach ($item in $Script:Resumo) { Write-Ok $item }
        $Script:Resumo.Clear()
        return
    }
    Write-Info 'A distro foi mantida.'
    Show-Resumo -Nome $d.Nome -Usuario $d.Usuario -Sucesso $false
}

#endregion

#region Menu e ponto de entrada -------------------------------------------------------------------

function Get-ParametrosAtuais {
    return @{
        Acao           = $Script:AcaoAtual
        Distro         = $Distro
        Nome           = $Nome
        Local          = $Local
        Usuario        = $Usuario
        Mover          = [bool]$Mover
        ComandoWindows = [bool]$ComandoWindows
        Silent         = [bool]$Silent
    }
}

function Restore-Parametros {
    param([hashtable]$Estado)
    if ($Estado.Acao)    { $Script:Acao = "$($Estado.Acao)" }
    if ($Estado.Distro)  { $Script:Distro = "$($Estado.Distro)" }
    if ($Estado.Nome)    { $Script:Nome = "$($Estado.Nome)" }
    if ($Estado.Local)   { $Script:Local = "$($Estado.Local)" }
    if ($Estado.Usuario) { $Script:Usuario = "$($Estado.Usuario)" }
    $Script:Mover = [bool]$Estado.Mover
    $Script:ComandoWindows = [bool]$Estado.ComandoWindows
    $Script:Silent = [bool]$Estado.Silent
}

function Invoke-Acao {
    param([string]$Nome)
    $Script:AcaoAtual = $Nome
    switch ($Nome) {
        'Listar'            { Invoke-Listar }
        'Instalar'          { Invoke-InstalarNova }
        'InstalarExistente' { Invoke-InstalarExistente }
        'Mover'             { Invoke-Mover }
        'Desinstalar'       { Invoke-Desinstalar }
    }
}

function Show-Menu {
    $acoes = @('Listar', 'Instalar', 'InstalarExistente', 'Mover', 'Desinstalar')
    while ($true) {
        Show-Banner
        Write-Host ''
        Write-Host '  O que você quer fazer?' -ForegroundColor White
        Write-Host ''
        Write-Host '    1) Listar distros e status do Docker'
        Write-Host '    2) Instalar Docker em uma nova distro'
        Write-Host '    3) Instalar Docker em uma distro existente'
        Write-Host '    4) Mover uma distro para outro disco'
        Write-Host '    5) Desinstalar Docker de uma distro'
        Write-Host '    6) Sair'
        Write-Host ''
        Write-Host '  ?  Opção [1]: ' -ForegroundColor White -NoNewline
        $resposta = "$(Read-Host)".Trim()
        if ($resposta -eq '') { $resposta = '1' }
        if ($resposta -eq '6') { return }
        $n = 0
        if (-not [int]::TryParse($resposta, [ref]$n) -or $n -lt 1 -or $n -gt 5) {
            Write-Aviso 'Opção inválida. Digite um número de 1 a 6.'
            Start-Sleep -Seconds 1
            continue
        }
        try {
            Invoke-Acao -Nome $acoes[$n - 1]
        } catch {
            Write-Host ''
            Write-Erro $_.Exception.Message
            Write-Log ($_ | Out-String) 'ERRO'
            Write-Info "Detalhes no log: $Script:LogFile"
        }
        Wait-Enter
    }
}

function Main {
    Initialize-Console
    Initialize-Log
    if (-not (Request-Elevacao -Parametros $Script:Parametros)) { return }

    $janelaNova = [bool]($Retomar -or $Elevado)
    if ($Retomar) {
        $estado = Get-EstadoRetomada
        Clear-EstadoRetomada
        if (-not $estado) { Write-Aviso 'Não há tarefa pendente para retomar.'; Wait-Enter; return }
        Restore-Parametros -Estado $estado
        Write-Info 'Retomando a instalação depois da reinicialização...'
    } elseif ((Test-Path $Script:StateFile) -and -not $Silent) {
        $estado = Get-EstadoRetomada
        if ($estado -and (Read-SimNao 'Há uma instalação interrompida por reinicialização. Retomar agora?' $true)) {
            Restore-Parametros -Estado $estado
        }
        Clear-EstadoRetomada
    }

    try {
        if ($Acao -eq 'Menu') {
            Show-Menu
        } else {
            if (-not $Silent) { Show-Banner }
            Invoke-Acao -Nome $Acao
            if ($janelaNova) { Wait-Enter }
        }
    } catch {
        Write-Host ''
        Write-Erro $_.Exception.Message
        Write-Log ($_ | Out-String) 'ERRO'
        Write-Info "Detalhes no log: $Script:LogFile"
        if ($janelaNova) { Wait-Enter }
        if ($Silent -and $PSCommandPath) { exit 1 }
    }
}

#endregion

$Script:AcaoAtual = $Acao
$Script:Parametros = @{}
foreach ($chave in $PSBoundParameters.Keys) { $Script:Parametros[$chave] = $PSBoundParameters[$chave] }

Main
