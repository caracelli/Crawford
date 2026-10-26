#Requires -RunAsAdministrator
# LTDEV-2 - instala o EmailIndexingService como servico do Windows na maquina de TESTE, ja com o contorno
# da variavel IGCCSVC_DB (Intel Graphics), sem alterar o codigo.
#
# Rodar num PowerShell aberto como administrador:
#   powershell -ExecutionPolicy Bypass -File "<pasta>\LTDEV-2 - Instalar servico (teste).ps1"
#   powershell -ExecutionPolicy Bypass -File "<pasta>\LTDEV-2 - Instalar servico (teste).ps1" -Pasta "D:\outra\pasta"
#   powershell -ExecutionPolicy Bypass -File "<pasta>\LTDEV-2 - Instalar servico (teste).ps1" -Desinstalar
#
# -Pasta: pasta onde esta o EmailIndexingService.exe (com appsettings.json e NLog.config).
# A saida fica em "LTDEV-2 - Instalar servico (teste).saida.txt", ao lado deste script.

param(
    [string]$Pasta = (Join-Path $env:USERPROFILE 'Service-ClaimEmailAutomation\EmailIndexingService\bin\Debug\netcoreapp3.1'),
    [switch]$Desinstalar
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path (Join-Path $PSScriptRoot 'LTDEV-2 - Instalar servico (teste).saida.txt') -Force | Out-Null

# Contorno IGCCSVC_DB tambem para ESTE processo: o "EmailIndexingService.exe install/uninstall" executa o
# proprio servico (le a configuracao antes de instalar) e herda as variaveis deste PowerShell
$env:IGCCSVC_DB = 'nao-usado-pelo-EmailIndexingService'

function Titulo($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

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
function Aviso($t)  { Write-Host "ATENCAO: $t" -ForegroundColor Yellow }

try {
    $exe = Join-Path $Pasta 'EmailIndexingService.exe'
    $cfg = Join-Path $Pasta 'appsettings.json'
    if (-not (Test-Path $exe)) { throw "EmailIndexingService.exe nao encontrado em $Pasta (use -Pasta)." }
    if (-not (Test-Path $cfg)) { throw "appsettings.json nao encontrado em $Pasta." }

    # appsettings pode ter comentarios // (o .NET aceita, o ConvertFrom-Json nao): remove so para ler aqui
    $json  = SemComentarios (Get-Content $cfg -Raw -Encoding UTF8) | ConvertFrom-Json
    $nome  = $json.ServiceConfiguration.ServiceName
    if (-not $nome) { throw 'ServiceConfiguration.ServiceName vazio no appsettings.json.' }

    # ------------------------------------------------------------------ desinstalar
    if ($Desinstalar) {
        Titulo "Desinstalando '$nome'"
        Stop-Service -Name $nome -ErrorAction SilentlyContinue
        & $exe uninstall
        return
    }

    # ------------------------------------------------------------------ conferencia da configuracao
    Titulo 'Configuracao (appsettings.json da pasta do servico)'
    "Pasta:        $Pasta"
    "Servico:      $nome"
    "NLog.config:  " + (Test-Path (Join-Path $Pasta 'NLog.config'))
    $rmq = $json.RabbitMQ
    "RabbitMQ:     Host=$($rmq.Host) | Username=$($rmq.Username) | Password=" + $(if ($rmq.Password) { 'preenchida' } else { 'vazia (vem dos User Secrets da conta)' })
    "Graph:        TenantId=" + [bool]$json.Graph.TenantId + ' | ClientId=' + [bool]$json.Graph.ClientId + ' | ClientSecret=' + $(if ($json.Graph.ClientSecret) { 'preenchido' } else { 'vazio (vem dos User Secrets da conta)' })
    foreach ($p in $json.ConnectionStrings.PSObject.Properties) {
        $srv = if ($p.Value -match '(?i)(server|data source)\s*=\s*([^;]+)') { $matches[2] } else { '?' }
        $db  = if ($p.Value -match '(?i)(database|initial catalog)\s*=\s*([^;]+)') { $matches[2] } else { '?' }
        "Conexao:      $($p.Name) -> servidor $srv, banco $db"
    }
    if (-not ($json.ConnectionStrings.DefaultConnection -or $json.ConnectionStrings.BRSCloudConnection)) {
        Aviso 'sem ConnectionStrings.DefaultConnection nem BRSCloudConnection.'
    }

    # vhost do RabbitMQ local
    if ($rmq.Host -match '^rabbitmq://(localhost|127\.0\.0\.1)/(.+)$') {
        $vhost = $matches[2]
        $env:ERLANG_HOME = [Environment]::GetEnvironmentVariable('ERLANG_HOME', 'Machine')
        $ctl = Get-ChildItem 'C:\Program Files\RabbitMQ Server' -Recurse -Filter rabbitmqctl.bat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ctl) {
            $vhosts = & $ctl.FullName list_vhosts --silent 2>$null
            if ($vhosts -notcontains $vhost) { Aviso "o vhost '$vhost' do appsettings NAO existe no RabbitMQ local (existem: $($vhosts -join ', ')). Ajuste RabbitMQ.Host/Username no appsettings." }
        }
        'Porta 5672:   ' + (Test-NetConnection localhost -Port 5672 -InformationLevel Quiet -WarningAction SilentlyContinue)
    }

    # ------------------------------------------------------------------ conta do servico
    Titulo 'Conta do servico'
    'Com a sua conta: o servico acessa o SQL (Integrated Security) e le os seus User Secrets.'
    $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'Conta que vai rodar o servico (a sua, com senha)'
    $conta = $cred.UserName
    $senhaConta = $cred.GetNetworkCredential().Password
    if (-not $senhaConta) { throw 'Conta sem senha: o Windows nao permite servico com conta sem senha.' }

    # direito "Fazer logon como servico" (SeServiceLogonRight)
    $sid = (New-Object Security.Principal.NTAccount($conta)).Translate([Security.Principal.SecurityIdentifier]).Value
    $tmp = Join-Path $env:TEMP 'ltdev2-secedit'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    secedit /export /cfg "$tmp\atual.inf" /areas USER_RIGHTS | Out-Null
    $linha = Get-Content "$tmp\atual.inf" | Where-Object { $_ -like 'SeServiceLogonRight*' }
    if ($linha -and $linha -match [regex]::Escape("*$sid")) {
        "Direito 'Fazer logon como servico': ja existe para $conta"
    } else {
        $nova = if ($linha) { "$linha,*$sid" } else { "SeServiceLogonRight = *$sid" }
        @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1', '[Privilege Rights]', $nova) |
            Set-Content "$tmp\novo.inf" -Encoding Unicode
        secedit /configure /db "$tmp\novo.sdb" /cfg "$tmp\novo.inf" /areas USER_RIGHTS /quiet | Out-Null
        "Direito 'Fazer logon como servico': concedido para $conta"
    }

    # ------------------------------------------------------------------ instalacao
    if (Get-Service -Name $nome -ErrorAction SilentlyContinue) {
        Titulo "Servico '$nome' ja existe: removendo para reinstalar"
        Stop-Service -Name $nome -ErrorAction SilentlyContinue
        & $exe uninstall | Out-Null
        Start-Sleep -Seconds 2
    }

    Titulo "Instalando '$nome' com a conta $conta"
    & $exe install -username "$conta" -password "$senhaConta"
    if ($LASTEXITCODE -ne 0) { throw "install retornou $LASTEXITCODE" }
    $senhaConta = $null

    # contorno IGCCSVC_DB: so para este servico, a variavel da Intel ganha um valor que nao e DPAPI
    # (o DpapiConfigurationProvider tenta abrir todo valor que comeca com AQAAANCM e derruba o servico)
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$nome" -Name Environment -PropertyType MultiString -Force `
        -Value @('IGCCSVC_DB=nao-usado-pelo-EmailIndexingService') | Out-Null
    'Contorno IGCCSVC_DB aplicado ao servico.'

    # ------------------------------------------------------------------ execucao
    $inicio = Get-Date
    Titulo 'Iniciando (aguarda 2 varreduras)'
    Start-Service -Name $nome
    $intervalo = [int]$json.Indexing.IntervalMinutes; if ($intervalo -lt 1) { $intervalo = 10 }
    $espera = [Math]::Min(150, 30 + 60 * $intervalo)
    "Aguardando $espera segundos..."
    Start-Sleep -Seconds $espera

    Titulo 'Status'
    Get-CimInstance Win32_Service -Filter "Name='$nome'" | Select-Object Name, State, StartMode, StartName | Format-List | Out-String

    Titulo 'Log (pasta log ao lado do .exe)'
    Get-ChildItem (Join-Path $Pasta 'log') -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $inicio |
        ForEach-Object { "-- $($_.Name)"; Get-Content $_.FullName -Tail 15 }
}
catch {
    Write-Host "`nFALHA: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($nome -and -not $Desinstalar) {
        $svc = Get-Service -Name $nome -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Host "`nO servico '$nome' NAO ficou instalado." -ForegroundColor Red
        } else {
            if ($svc.Status -ne 'Running') {
                Titulo 'Servico nao esta rodando: ultimo erro no Visualizador de Eventos'
                Get-WinEvent -FilterHashtable @{LogName = 'Application'; ProviderName = $nome} -MaxEvents 1 -ErrorAction SilentlyContinue |
                    ForEach-Object { $m = $_.Message -replace '\s+', ' '; $m.Substring(0, [Math]::Min(900, $m.Length)) }
            }
            Write-Host "`nO servico '$nome' esta instalado (status: $($svc.Status)). Para remover:" -ForegroundColor Green
            Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Pasta `"$Pasta`" -Desinstalar" -ForegroundColor Green
        }
    }
    Stop-Transcript | Out-Null
}
