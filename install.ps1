# Mantido so com ASCII, porque o irm do Windows PowerShell 5.1 decodifica texto UTF-8 de forma errada.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $base = 'https://raw.githubusercontent.com/rcoliveira2016/docker-in-wsl/main'
    $pasta = Join-Path $env:LOCALAPPDATA 'docker-wsl'
    $script = Join-Path $pasta 'docker-wsl.ps1'
    $linux = Join-Path $pasta 'scripts\wsl-docker.sh'

    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $linux) | Out-Null
        Write-Host '  Baixando o docker-wsl...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri "$base/docker-wsl.ps1" -OutFile $script -UseBasicParsing
        Invoke-WebRequest -Uri "$base/scripts/wsl-docker.sh" -OutFile $linux -UseBasicParsing
    } catch {
        Write-Host "  Falha ao baixar o docker-wsl: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  Confira a conexao com a internet e tente de novo.' -ForegroundColor Red
        return
    }

    $powershell = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if (-not $powershell) { $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $script @args
} @args
