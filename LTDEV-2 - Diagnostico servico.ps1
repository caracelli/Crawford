# LTDEV-2 - diagnostico do EmailIndexingService instalado como servico (somente leitura).
# Rodar num PowerShell aberto como administrador, na pasta deste script:
#   powershell -ExecutionPolicy Bypass -File "LTDEV-2 - Diagnostico servico.ps1"
# Grava "LTDEV-2 - Diagnostico servico.saida.txt" ao lado deste script e envia ao git (add/commit/push).

$ErrorActionPreference = 'Continue'
$saida = Join-Path $PSScriptRoot 'LTDEV-2 - Diagnostico servico.saida.txt'

& {
    '== Maquina'
    "$env:COMPUTERNAME | usuario $env:USERDOMAIN\$env:USERNAME | " + (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')

    '== Servicos EmailIndexing instalados'
    $svcs = Get-CimInstance Win32_Service | Where-Object { $_.Name -match 'EmailIndexing' -or $_.PathName -match 'EmailIndexingService\.exe' }
    if (-not $svcs) { 'NENHUM servico EmailIndexing instalado' }
    foreach ($s in $svcs) {
        $s | Format-List Name, DisplayName, State, StartMode, StartName, ExitCode, PathName | Out-String

        $nome  = $s.Name
        $pasta = Split-Path ($s.PathName -replace '^"([^"]+)".*$', '$1' -replace '\s+-.*$', '')

        '-- variaveis de ambiente do servico (registro)'
        (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$nome" -Name Environment -ErrorAction SilentlyContinue).Environment

        "-- pasta do servico: $pasta"
        Get-ChildItem $pasta -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { "   $($_.Name)  $($_.LastWriteTime)" }
        '   NLog.config existe: ' + (Test-Path (Join-Path $pasta 'NLog.config'))
        '   EmailIndexingService.dll: ' + (Get-Item (Join-Path $pasta 'EmailIndexingService.dll') -ErrorAction SilentlyContinue).LastWriteTime

        '-- NLog.config (destinos e regras)'
        Select-String -Path (Join-Path $pasta 'NLog.config') -Pattern 'fileName|internalLogFile|ServiceName|writeTo|<target ' -ErrorAction SilentlyContinue |
            ForEach-Object { '   ' + $_.Line.Trim() }

        '-- arquivos nas pastas log/logs'
        foreach ($d in 'log', 'logs') {
            Get-ChildItem (Join-Path $pasta $d) -ErrorAction SilentlyContinue | ForEach-Object { "   $d\$($_.Name)  $($_.Length) bytes  $($_.LastWriteTime)" }
        }
        foreach ($d in 'log', 'logs') {
            Get-ChildItem (Join-Path $pasta $d) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2 |
                ForEach-Object { "-- ultimas linhas de $d\$($_.Name)"; Get-Content $_.FullName -Tail 25 }
        }

        '-- arquivos de log em C:\Windows\System32\log (se o NLog gravou com o diretorio errado)'
        Get-ChildItem 'C:\Windows\System32\log' -ErrorAction SilentlyContinue | Select-Object -First 5 | ForEach-Object { "   $($_.Name)  $($_.LastWriteTime)" }

        '-- versao do codigo (git) da pasta do projeto'
        $repo = $pasta
        while ($repo -and -not (Test-Path (Join-Path $repo '.git'))) { $repo = Split-Path $repo }
        if ($repo) {
            "   repositorio: $repo"
            '   branch: ' + (git -C $repo branch --show-current 2>&1)
            '   commit: ' + (git -C $repo log -1 --format='%h %s' 2>&1)
            '   alteracoes locais:'
            git -C $repo status --short 2>&1 | ForEach-Object { "     $_" }
        }
    }

    '== Visualizador de Eventos - Aplicativo (ultimas 3h)'
    Get-WinEvent -FilterHashtable @{LogName = 'Application'; StartTime = (Get-Date).AddHours(-3)} -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'EmailIndexing|\.NET Runtime|Application Error' } | Select-Object -First 6 |
        ForEach-Object { $m = $_.Message -replace '\s+', ' '; "$($_.TimeCreated) | $($_.ProviderName) | " + $m.Substring(0, [Math]::Min(900, $m.Length)) }

    '== Visualizador de Eventos - Sistema / Service Control Manager (ultimas 3h)'
    Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddHours(-3)} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'EmailIndexing' } | Select-Object -First 6 |
        ForEach-Object { "$($_.TimeCreated) | $($_.Id) | " + ($_.Message -replace '\s+', ' ') }
} *>&1 | Out-File $saida -Encoding utf8

Get-Content $saida
Write-Host "`nEnviando o resultado ao git..." -ForegroundColor Cyan
git -C $PSScriptRoot add -- (Split-Path $saida -Leaf)
git -C $PSScriptRoot commit -m "LTDEV-2: diagnostico do servico instalado ($env:COMPUTERNAME)" | Out-Null
git -C $PSScriptRoot pull --rebase -q
git -C $PSScriptRoot push -q
Write-Host "Pronto. Avise o Claude." -ForegroundColor Green
