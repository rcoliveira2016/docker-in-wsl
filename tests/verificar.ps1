<#
.SYNOPSIS
    Confere se uma distro ficou como o docker-wsl.ps1 promete.

.PARAMETER Distro
    Nome da distro a verificar.

.PARAMETER LocalEsperado
    Pasta onde a distro deveria estar (ex.: D:\WSL\Teste-Debian).

.PARAMETER Usuario
    Usuário Linux padrão esperado.

.PARAMETER SemDocker
    Verifica o contrário: que o Docker foi removido da distro.

.PARAMETER ComandoWindows
    Verifica também o comando "docker" no PowerShell/CMD do Windows.

.PARAMETER SemReinicio
    Não reinicia a distro para testar se o Docker sobe sozinho.

.EXAMPLE
    .\tests\verificar.ps1 -Distro Teste-Debian -LocalEsperado D:\WSL\Teste-Debian -Usuario ramon
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Distro,
    [string]$LocalEsperado,
    [string]$Usuario,
    [switch]$SemDocker,
    [switch]$ComandoWindows,
    [switch]$SemReinicio
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$Script:Resultados = New-Object System.Collections.Generic.List[object]

function Add-Resultado {
    param([string]$Teste, [bool]$Ok, [string]$Detalhe = '')
    $Script:Resultados.Add([pscustomobject]@{ Teste = $Teste; Ok = $Ok; Detalhe = $Detalhe })
    $marca = '[FALHOU]'
    $cor = 'Red'
    if ($Ok) { $marca = '[OK]    '; $cor = 'Green' }
    Write-Host ("  {0} {1}" -f $marca, $Teste) -ForegroundColor $cor -NoNewline
    if ($Detalhe) { Write-Host "  ($Detalhe)" -ForegroundColor DarkGray } else { Write-Host '' }
}

function Invoke-Distro {
    param([string]$Comando, [string]$Como)
    $argumentos = @('-d', $Distro)
    if ($Como) { $argumentos += @('-u', $Como) }
    $argumentos += @('--exec', 'sh', '-c', $Comando)
    $anterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $saida = & wsl.exe @argumentos 2>&1 | ForEach-Object { ("$_" -replace "`0", '').TrimEnd() } | Where-Object { $_ }
        $codigo = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $anterior
    }
    return [pscustomobject]@{ Codigo = $codigo; Saida = (@($saida) -join ' | ') }
}

Write-Host ''
Write-Host "  Verificando a distro '$Distro'" -ForegroundColor Cyan
Write-Host ''

$chave = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath } |
    Where-Object { $_.PSObject.Properties.Name -contains 'DistributionName' -and $_.DistributionName -eq $Distro } |
    Select-Object -First 1

Add-Resultado 'Distro registrada no WSL' ([bool]$chave)
if (-not $chave) {
    Write-Host ''
    Write-Host '  A distro não existe; os demais testes foram pulados.' -ForegroundColor Red
    exit 1
}

$pasta = "$($chave.BasePath)" -replace '^\\\\\?\\', ''
Add-Resultado 'Distro em WSL2' ($chave.Version -ge 2) "versão $($chave.Version)"

if ($LocalEsperado) {
    $esperado = [IO.Path]::GetFullPath($LocalEsperado).TrimEnd('\')
    Add-Resultado 'Armazenada no local escolhido' ($pasta.TrimEnd('\') -ieq $esperado) $pasta
} else {
    Write-Host "  [info]   Armazenada em $pasta" -ForegroundColor DarkGray
}
if ($chave.Version -ge 2) {
    $vhd = Join-Path $pasta 'ext4.vhdx'
    Add-Resultado 'Disco virtual ext4.vhdx existe' (Test-Path -LiteralPath $vhd) $vhd
}

$os = Invoke-Distro '. /etc/os-release; echo $ID $ID_LIKE'
$alpine = $os.Saida -match '\balpine\b'
Write-Host "  [info]   Sistema: $($os.Saida)" -ForegroundColor DarkGray

$padrao = (Invoke-Distro 'id -un').Saida
if ($Usuario) {
    Add-Resultado 'Usuário padrão é o esperado' ($padrao -eq $Usuario) "padrão: $padrao"
} else {
    Add-Resultado 'Usuário padrão não é root' ($padrao -ne 'root') "padrão: $padrao"
}

if ($alpine) {
    $boot = Invoke-Distro 'grep -q wsl-docker-boot /etc/wsl.conf' 'root'
    if (-not $SemDocker) { Add-Resultado 'Inicialização automática no /etc/wsl.conf ([boot] command)' ($boot.Codigo -eq 0) }
} else {
    $conf = Invoke-Distro 'grep -Eq ''^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true'' /etc/wsl.conf' 'root'
    Add-Resultado 'systemd=true no /etc/wsl.conf' ($conf.Codigo -eq 0)
    $pid1 = (Invoke-Distro 'cat /proc/1/comm').Saida
    Add-Resultado 'systemd rodando como PID 1' ($pid1 -eq 'systemd') "PID 1: $pid1"
}

if ($SemDocker) {
    $docker = Invoke-Distro 'command -v docker'
    Add-Resultado 'Comando docker removido' ($docker.Codigo -ne 0) $docker.Saida
    $dockerd = Invoke-Distro 'pidof dockerd || pgrep -x dockerd' 'root'
    Add-Resultado 'Serviço do Docker parado' ($dockerd.Codigo -ne 0)
    if (-not $alpine) {
        $repo = Invoke-Distro 'test ! -e /etc/apt/sources.list.d/docker.list' 'root'
        Add-Resultado 'Repositório do Docker removido do apt' ($repo.Codigo -eq 0)
    }
    $dados = Invoke-Distro 'test -d /var/lib/docker && du -sh /var/lib/docker | cut -f1' 'root'
    $textoDados = 'apagados'
    if ($dados.Codigo -eq 0) { $textoDados = "mantidos ($($dados.Saida))" }
    Write-Host "  [info]   Dados em /var/lib/docker: $textoDados" -ForegroundColor DarkGray
} else {
    $versao = Invoke-Distro 'docker --version'
    Add-Resultado 'Docker Engine instalado' ($versao.Codigo -eq 0) $versao.Saida
    $compose = Invoke-Distro 'docker compose version --short'
    Add-Resultado 'Docker Compose v2 instalado' ($compose.Codigo -eq 0) $compose.Saida
    $buildx = Invoke-Distro 'docker buildx version'
    Add-Resultado 'Buildx instalado' ($buildx.Codigo -eq 0) $buildx.Saida
    if ($alpine) {
        $pacote = Invoke-Distro 'apk info -e docker' 'root'
        Add-Resultado 'Pacote docker do repositório do Alpine' ($pacote.Codigo -eq 0)
    } else {
        $oficial = Invoke-Distro 'dpkg -s docker-ce >/dev/null 2>&1 && grep -q download.docker.com /etc/apt/sources.list.d/docker.list' 'root'
        Add-Resultado 'docker-ce do repositório oficial (download.docker.com)' ($oficial.Codigo -eq 0)
        $antigo = Invoke-Distro 'dpkg -s docker.io >/dev/null 2>&1' 'root'
        Add-Resultado 'Pacote antigo docker.io ausente' ($antigo.Codigo -ne 0)
    }
    $servico = Invoke-Distro 'pidof dockerd || pgrep -x dockerd' 'root'
    Add-Resultado 'Serviço do Docker ativo' ($servico.Codigo -eq 0)
    if ($padrao -ne 'root') {
        $grupo = Invoke-Distro "id -nG $padrao"
        Add-Resultado "Usuário '$padrao' no grupo docker" ($grupo.Saida -match '\bdocker\b') $grupo.Saida
    }
    $hello = Invoke-Distro 'docker run --rm hello-world'
    Add-Resultado 'docker run hello-world sem sudo' ($hello.Codigo -eq 0 -and $hello.Saida -match 'Hello from Docker') "código $($hello.Codigo)"

    if (-not $SemReinicio) {
        Write-Host "  [info]   Reiniciando a distro para testar a subida automática..." -ForegroundColor DarkGray
        & wsl.exe --terminate $Distro | Out-Null
        $volta = Invoke-Distro 'i=0; while [ $i -lt 20 ]; do docker info >/dev/null 2>&1 && exit 0; sleep 1; i=$((i+1)); done; exit 1'
        Add-Resultado 'Docker sobe sozinho depois de reiniciar a distro' ($volta.Codigo -eq 0)
    }
}

if ($ComandoWindows) {
    $cmd = Join-Path $env:LOCALAPPDATA 'docker-wsl\bin\docker.cmd'
    Add-Resultado 'docker.cmd criado' (Test-Path $cmd) $cmd
    $caminhoUsuario = (Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    Add-Resultado 'Pasta bin no PATH do usuário' (($caminhoUsuario -split ';') -contains (Split-Path $cmd)) ''
    if (Test-Path $cmd) {
        $anterior = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $saida = & $cmd version --format '{{.Server.Version}}' 2>&1
        $ErrorActionPreference = $anterior
        Add-Resultado 'docker version pelo CMD do Windows' ($LASTEXITCODE -eq 0) "$saida"
    }
}

$falhas = @($Script:Resultados | Where-Object { -not $_.Ok })
Write-Host ''
if ($falhas.Count -eq 0) {
    Write-Host "  Tudo certo: $($Script:Resultados.Count) verificações passaram." -ForegroundColor Green
    exit 0
}
Write-Host "  $($falhas.Count) de $($Script:Resultados.Count) verificações falharam:" -ForegroundColor Red
$falhas | ForEach-Object { Write-Host "    - $($_.Teste)" -ForegroundColor Red }
exit 1
