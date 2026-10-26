#Requires -RunAsAdministrator
# LTDEV-2 - na maquina de TESTE: aplica o NLog.config SEM banco de log (so arquivo e console) na pasta do
# projeto e na pasta do servico, reinicia o servico, espera uma varredura e procura onde o log foi gravado.
#
# Rodar num PowerShell aberto como administrador, na pasta deste script:
#   powershell -ExecutionPolicy Bypass -File "LTDEV-2 - Aplicar NLog sem banco.ps1"
# Grava "LTDEV-2 - Aplicar NLog sem banco.saida.txt" e envia ao git.

param([string]$Repo = (Join-Path $env:USERPROFILE 'Service-ClaimEmailAutomation'))

$ErrorActionPreference = 'Stop'
$docs  = $PSScriptRoot
$saida = Join-Path $docs 'LTDEV-2 - Aplicar NLog sem banco.saida.txt'
Start-Transcript -Path $saida -Force | Out-Null
function Titulo($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

try {
    $origem = Join-Path $docs 'LTDEV-2 NLog sem banco.config'
    if (-not (Test-Path $origem)) { throw "Nao encontrei $origem (rodar git pull na pasta dos docs)." }
    $proj = Join-Path $Repo 'EmailIndexingService'

    # pasta de onde o servico roda (pelo servico instalado), ou a bin padrao
    $svc = Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'EmailIndexingService\.exe' } | Select-Object -First 1
    $bin = if ($svc) { Split-Path ($svc.PathName -replace '^"([^"]+)".*$', '$1') } else { Join-Path $proj 'bin\Debug\netcoreapp3.1' }

    Titulo 'Aplicando o NLog.config sem banco'
    foreach ($destino in (Join-Path $proj 'NLog.config'), (Join-Path $bin 'NLog.config')) {
        Copy-Item $origem $destino -Force
        "   $destino"
    }
    Select-String -Path (Join-Path $bin 'NLog.config') -Pattern 'fileName|writeTo|internalLogFile' | ForEach-Object { '   ' + $_.Line.Trim() }

    if ($svc) {
        Titulo "Reiniciando '$($svc.Name)' (conta $($svc.StartName))"
        $inicio = Get-Date
        Restart-Service -Name $svc.Name -Force
        Start-Sleep -Seconds 75
        Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" | Format-List Name, State, StartName | Out-String
    } else {
        Write-Host 'Nenhum servico EmailIndexing instalado: so o arquivo foi aplicado.' -ForegroundColor Yellow
        $inicio = (Get-Date).AddHours(-1)
    }

    Titulo 'Onde ha log do EmailIndexingService (pastas log/logs)'
    $pastas = @($bin, $proj, $docs, 'C:\Windows\System32', 'C:\Windows\SysWOW64', $env:USERPROFILE, 'C:\antlia', 'C:\antlia\crawford') | Select-Object -Unique
    $achou = $false
    foreach ($p in $pastas) {
        foreach ($d in 'log', 'logs') {
            $dir = Join-Path $p $d
            Get-ChildItem $dir -Filter '*.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'emailindexing|internal-nlog|Debug' } |
                ForEach-Object { $achou = $true; "   {0}  {1} bytes  {2}" -f $_.FullName, $_.Length, $_.LastWriteTime }
        }
    }
    if (-not $achou) { '   nenhum arquivo de log encontrado' }

    Titulo 'Ultimas linhas do log da pasta do servico'
    Get-ChildItem (Join-Path $bin 'log') -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $inicio.AddMinutes(-1) |
        ForEach-Object { "-- $($_.Name)"; Get-Content $_.FullName -Tail 20 }

    Titulo 'Erros recentes no Visualizador de Eventos'
    Get-WinEvent -FilterHashtable @{LogName = 'Application'; StartTime = $inicio.AddMinutes(-1)} -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'EmailIndexing|\.NET Runtime|Application Error' } | Select-Object -First 4 |
        ForEach-Object { $m = $_.Message -replace '\s+', ' '; "$($_.TimeCreated) | $($_.ProviderName) | " + $m.Substring(0, [Math]::Min(600, $m.Length)) }
}
catch { Write-Host "`nFALHA: $($_.Exception.Message)" -ForegroundColor Red }
finally {
    Stop-Transcript | Out-Null
    Write-Host "`nEnviando o resultado ao git..." -ForegroundColor Cyan
    git.exe -C $docs add -- (Split-Path $saida -Leaf)
    git.exe -C $docs commit -m "LTDEV-2: aplicar NLog sem banco ($env:COMPUTERNAME)" | Out-Null
    git.exe -C $docs pull --rebase -q
    git.exe -C $docs push -q
    Write-Host 'Pronto. Avise o Claude.' -ForegroundColor Green
}
