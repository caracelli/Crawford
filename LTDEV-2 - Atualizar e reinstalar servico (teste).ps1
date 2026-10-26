#Requires -RunAsAdministrator
# LTDEV-2 - na maquina de TESTE: desinstala o servico, atualiza o codigo para a PR #4
# (LTDEV-2-brscloud-connection), mantem o appsettings.json da maquina, troca o NLog.config pelo de staging,
# compila, reinstala como servico (com o contorno da IGCCSVC_DB), inicia e mostra o log.
#
# Rodar num PowerShell aberto como administrador, na pasta deste script:
#   powershell -ExecutionPolicy Bypass -File "LTDEV-2 - Atualizar e reinstalar servico (teste).ps1"
# O resultado vai para "LTDEV-2 - Atualizar e reinstalar servico (teste).saida.txt" e e enviado ao git.

param(
    [string]$Repo   = (Join-Path $env:USERPROFILE 'Service-ClaimEmailAutomation'),
    [string]$Branch = 'LTDEV-2-brscloud-connection'
)

$ErrorActionPreference = 'Stop'
$docs   = $PSScriptRoot
$saida  = Join-Path $docs 'LTDEV-2 - Atualizar e reinstalar servico (teste).saida.txt'
Start-Transcript -Path $saida -Force | Out-Null

# contorno IGCCSVC_DB (Intel) tambem para os processos deste script (install/uninstall executam o servico)
$env:IGCCSVC_DB = 'nao-usado-pelo-EmailIndexingService'

$proj   = Join-Path $Repo 'EmailIndexingService'
$bin    = Join-Path $proj 'bin\Debug\netcoreapp3.1'
$exe    = Join-Path $bin 'EmailIndexingService.exe'
$backup = Join-Path $env:USERPROFILE ('ltdev2-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Titulo($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function GitOk { & git.exe -C $Repo @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') falhou ($LASTEXITCODE)" } }

# Remove comentarios // de JSON (o .NET aceita, o ConvertFrom-Json nao), sem mexer no que esta entre aspas
function SemComentarios([string]$t) {
    $sb = New-Object Text.StringBuilder; $i = 0; $aspas = $false
    while ($i -lt $t.Length) {
        $c = $t[$i]
        if ($aspas) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $t.Length) { [void]$sb.Append($t[$i + 1]); $i += 2; continue }
            if ($c -eq '"') { $aspas = $false }
        } elseif ($c -eq '"') { $aspas = $true; [void]$sb.Append($c) }
        elseif ($c -eq '/' -and $i + 1 -lt $t.Length -and $t[$i + 1] -eq '/') {
            while ($i -lt $t.Length -and $t[$i] -ne "`n") { $i++ }; continue
        } else { [void]$sb.Append($c) }
        $i++
    }
    $sb.ToString()
}

try {
    if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "Repositorio nao encontrado em $Repo (use -Repo)." }

    # ------------------------------------------------------------------ 1. desinstalar o servico atual
    Titulo '1. Desinstalando o servico atual'
    $atuais = Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'EmailIndexingService\.exe' }
    foreach ($s in $atuais) {
        "Removendo '$($s.Name)'"
        Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
        $exeAtual = $s.PathName -replace '^"([^"]+)".*$', '$1'
        & $exeAtual uninstall | Out-Null
        if (Get-Service -Name $s.Name -ErrorAction SilentlyContinue) { sc.exe delete "$($s.Name)" | Out-Null }
    }
    if (-not $atuais) { 'Nenhum servico instalado.' }
    Start-Sleep -Seconds 3

    # ------------------------------------------------------------------ 2. guardar configuracao e alteracoes locais
    Titulo "2. Guardando configuracao em $backup"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($f in 'appsettings.json', 'NLog.config') {
        if (Test-Path (Join-Path $proj $f)) { Copy-Item (Join-Path $proj $f) (Join-Path $backup "projeto-$f") }
        if (Test-Path (Join-Path $bin $f))  { Copy-Item (Join-Path $bin $f)  (Join-Path $backup "bin-$f") }
    }
    Get-ChildItem $backup | ForEach-Object { "   $($_.Name)" }
    $appsettings = if (Test-Path (Join-Path $backup 'projeto-appsettings.json')) { Join-Path $backup 'projeto-appsettings.json' }
                   elseif (Test-Path (Join-Path $backup 'bin-appsettings.json')) { Join-Path $backup 'bin-appsettings.json' }
                   else { throw 'Nenhum appsettings.json encontrado na maquina para preservar.' }
    "appsettings preservado: $appsettings"

    'Alteracoes locais antes:'
    git.exe -C $Repo status --short | ForEach-Object { "   $_" }
    # o appsettings.json e o NLog.config ja estao copiados; saem do caminho para a troca de branch
    Remove-Item (Join-Path $proj 'appsettings.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $proj 'NLog.config') -Force -ErrorAction SilentlyContinue
    $temAlteracao = [bool](git.exe -C $Repo status --porcelain)
    if ($temAlteracao) {
        $msg = 'ltdev2-antes-da-PR4-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        GitOk stash push -u -m $msg
        "Alteracoes locais guardadas no stash '$msg' (recuperar com: git stash list / git stash apply)."
    }

    # ------------------------------------------------------------------ 3. codigo da PR #4
    Titulo "3. Atualizando o codigo para a branch $Branch"
    GitOk fetch origin
    $existe = git.exe -C $Repo branch --list $Branch
    if ($existe) { GitOk checkout $Branch; GitOk reset --hard "origin/$Branch" }
    else { GitOk checkout -b $Branch "origin/$Branch" }
    '   commit: ' + (git.exe -C $Repo log -1 --format='%h %s')

    # appsettings.json da maquina por cima do versionado (fica como alteracao local; NAO commitar)
    Copy-Item $appsettings (Join-Path $proj 'appsettings.json') -Force
    'appsettings.json da maquina restaurado.'

    # ------------------------------------------------------------------ 4. NLog.config de staging
    Titulo '4. NLog.config de staging'
    $nlog = Join-Path $docs 'LTDEV-2 NLog staging.config'
    if (-not (Test-Path $nlog)) { throw "Nao encontrei $nlog (rodar git pull na pasta dos docs)." }
    Copy-Item $nlog (Join-Path $proj 'NLog.config') -Force
    Select-String -Path (Join-Path $proj 'NLog.config') -Pattern "fileName|ServiceName'|writeTo" | ForEach-Object { '   ' + $_.Line.Trim() }

    # ------------------------------------------------------------------ 5. compilar
    Titulo '5. Compilando'
    'Backend usado na compilacao: ' + (git.exe -C (Join-Path (Split-Path $Repo) 'BRSCloud-Backend') branch --show-current 2>$null) + ' (precisa ser staging-latam)'
    dotnet build (Join-Path $proj 'EmailIndexingService.csproj') -c Debug -v q -nologo
    if ($LASTEXITCODE -ne 0) { throw 'A compilacao falhou (ver erros acima).' }
    if (-not (Test-Path $exe)) { throw "Nao encontrei $exe depois da compilacao." }

    # ------------------------------------------------------------------ 6. reinstalar
    $json = SemComentarios (Get-Content (Join-Path $bin 'appsettings.json') -Raw -Encoding UTF8) | ConvertFrom-Json
    $nome = $json.ServiceConfiguration.ServiceName
    Titulo "6. Instalando '$nome'"
    $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'Senha da sua conta (o servico roda com ela)'
    & $exe install -username "$($cred.UserName)" -password "$($cred.GetNetworkCredential().Password)"
    if ($LASTEXITCODE -ne 0) { throw "install retornou $LASTEXITCODE" }
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$nome" -Name Environment -PropertyType MultiString -Force `
        -Value @('IGCCSVC_DB=nao-usado-pelo-EmailIndexingService') | Out-Null
    'Contorno IGCCSVC_DB aplicado.'

    # ------------------------------------------------------------------ 7. iniciar e conferir
    Titulo '7. Iniciando e aguardando a primeira varredura (90 s)'
    Remove-Item (Join-Path $bin 'log\*') -Force -ErrorAction SilentlyContinue
    Start-Service -Name $nome
    Start-Sleep -Seconds 90
    Get-CimInstance Win32_Service -Filter "Name='$nome'" | Format-List Name, State, StartName | Out-String
    Get-ChildItem (Join-Path $bin 'log') -ErrorAction SilentlyContinue | ForEach-Object {
        "-- log\$($_.Name)"; Get-Content $_.FullName -Tail 20
    }
}
catch {
    Write-Host "`nFALHA: $($_.Exception.Message)" -ForegroundColor Red
    Get-WinEvent -FilterHashtable @{LogName = 'Application'; StartTime = (Get-Date).AddMinutes(-10)} -MaxEvents 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'EmailIndexing|\.NET Runtime|Application Error' } |
        ForEach-Object { $m = $_.Message -replace '\s+', ' '; "$($_.ProviderName): " + $m.Substring(0, [Math]::Min(900, $m.Length)) }
}
finally {
    "Backup da configuracao: $backup"
    Stop-Transcript | Out-Null
    Write-Host "`nEnviando o resultado ao git..." -ForegroundColor Cyan
    git.exe -C $docs add -- (Split-Path $saida -Leaf)
    git.exe -C $docs commit -m "LTDEV-2: atualizar e reinstalar servico ($env:COMPUTERNAME)" | Out-Null
    git.exe -C $docs pull --rebase -q
    git.exe -C $docs push -q
    Write-Host 'Pronto. Avise o Claude.' -ForegroundColor Green
}
