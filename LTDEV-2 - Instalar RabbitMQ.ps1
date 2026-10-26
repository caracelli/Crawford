#Requires -RunAsAdministrator
# LTDEV-2 - instala o RabbitMQ igual ao ambiente de teste do Nelson:
#   Erlang/OTP 28.5.0.6 + RabbitMQ 4.3.6, servico do Windows com inicio automatico,
#   plugin de gerenciamento (http://localhost:15672), vhost "enviroment" e usuario "enviroment"
#   (administrator, permissao total no vhost) e rabbitmq.conf com transient_nonexcl_queues liberado
#   (o MassTransit do BRS Cloud usa filas temporarias nao exclusivas no request/response).
#
# Rodar num PowerShell aberto como administrador:
#   powershell -ExecutionPolicy Bypass -File "<caminho>\LTDEV-2 - Instalar RabbitMQ.ps1"
# Pede a senha do usuario "enviroment": usar a mesma do RabbitMQ:Password do appsettings/User Secrets.

$ErrorActionPreference = 'Stop'
# Sem a barra de progresso: no PowerShell 5 ela deixa o Invoke-WebRequest muitas vezes mais lento
$ProgressPreference    = 'SilentlyContinue'
$erlangVersao   = '28.5.0.6'
$rabbitVersao   = '4.3.6'
$vhost          = 'enviroment'
$usuario        = 'enviroment'
$baixar         = Join-Path $env:TEMP 'ltdev2-rabbitmq'
$erlangExe      = Join-Path $baixar "otp_win64_$erlangVersao.exe"
$rabbitExe      = Join-Path $baixar "rabbitmq-server-$rabbitVersao.exe"
$configDir      = Join-Path $env:APPDATA 'RabbitMQ'
New-Item -ItemType Directory -Force -Path $baixar | Out-Null

$senha = Read-Host -AsSecureString "Senha do usuario '$usuario' do RabbitMQ (a mesma do RabbitMQ:Password)"
$senhaTexto = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($senha))
if ([string]::IsNullOrWhiteSpace($senhaTexto)) { throw 'Senha vazia.' }

# ---------------------------------------------------------------- 1. Erlang
if (-not (Test-Path 'C:\Program Files\Erlang OTP\bin\erl.exe')) {
    Write-Host "`n== Baixando e instalando Erlang/OTP $erlangVersao" -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://github.com/erlang/otp/releases/download/OTP-$erlangVersao/otp_win64_$erlangVersao.exe" -OutFile $erlangExe -UseBasicParsing
    Start-Process $erlangExe -ArgumentList '/S' -Wait
} else {
    Write-Host "`n== Erlang ja instalado em C:\Program Files\Erlang OTP" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 2. Configuracao (antes do RabbitMQ)
# O servico do RabbitMQ le a configuracao de %APPDATA%\RabbitMQ do usuario que instala.
Write-Host "`n== Configuracao em $configDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Set-Content -Path (Join-Path $configDir 'rabbitmq.conf') -Encoding ASCII -Value @(
    '# ambiente local LTDEV-2: MassTransit (request/response) usa filas temporarias nao exclusivas',
    'deprecated_features.permit.transient_nonexcl_queues = true')
Set-Content -Path (Join-Path $configDir 'enabled_plugins') -Encoding ASCII -Value '[rabbitmq_management].'
Set-Content -Path (Join-Path $configDir 'advanced.config') -Encoding ASCII -Value '[].'

# ---------------------------------------------------------------- 3. RabbitMQ
if (-not (Get-Service RabbitMQ -ErrorAction SilentlyContinue)) {
    Write-Host "`n== Baixando e instalando RabbitMQ $rabbitVersao" -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://github.com/rabbitmq/rabbitmq-server/releases/download/v$rabbitVersao/rabbitmq-server-$rabbitVersao.exe" -OutFile $rabbitExe -UseBasicParsing
    Start-Process $rabbitExe -ArgumentList '/S' -Wait
} else {
    Write-Host "`n== Servico RabbitMQ ja existe; reiniciando para aplicar a configuracao" -ForegroundColor Yellow
    Restart-Service RabbitMQ
}
Set-Service RabbitMQ -StartupType Automatic
if ((Get-Service RabbitMQ).Status -ne 'Running') { Start-Service RabbitMQ }

# O instalador do Erlang cria ERLANG_HOME para a maquina, mas esta sessao do PowerShell, aberta antes, nao a
# enxerga; sem ela o rabbitmqctl falha com "ERLANG_HOME not set correctly"
$env:ERLANG_HOME = [Environment]::GetEnvironmentVariable('ERLANG_HOME', 'Machine')
if (-not $env:ERLANG_HOME) { $env:ERLANG_HOME = 'C:\Program Files\Erlang OTP' }

$sbin = (Get-ChildItem 'C:\Program Files\RabbitMQ Server' -Recurse -Filter rabbitmqctl.bat | Select-Object -First 1).DirectoryName
$ctl  = Join-Path $sbin 'rabbitmqctl.bat'
$plg  = Join-Path $sbin 'rabbitmq-plugins.bat'

# O CLI precisa do mesmo cookie do servico (que roda como Local System)
$cookieServico = 'C:\Windows\System32\config\systemprofile\.erlang.cookie'
for ($i = 0; $i -lt 30 -and -not (Test-Path $cookieServico); $i++) { Start-Sleep -Seconds 2 }
Copy-Item $cookieServico (Join-Path $env:USERPROFILE '.erlang.cookie') -Force

Write-Host "`n== Aguardando o RabbitMQ responder" -ForegroundColor Cyan
for ($i = 0; $i -lt 30; $i++) {
    & $ctl await_startup 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 3
}

# ---------------------------------------------------------------- 4. vhost, usuario e permissoes
Write-Host "`n== vhost '$vhost' e usuario '$usuario'" -ForegroundColor Cyan
& $plg enable rabbitmq_management | Out-Null
if (-not ((& $ctl list_vhosts --silent) -contains $vhost)) { & $ctl add_vhost $vhost }
if ((& $ctl list_users --silent) -match "^$usuario\s") {
    & $ctl change_password $usuario $senhaTexto | Out-Null
} else {
    & $ctl add_user $usuario $senhaTexto | Out-Null
}
& $ctl set_user_tags $usuario administrator
& $ctl set_permissions -p $vhost $usuario '.*' '.*' '.*'
$senhaTexto = $null

# ---------------------------------------------------------------- 5. Conferencia
Write-Host "`n== Conferencia" -ForegroundColor Cyan
& $ctl list_vhosts
& $ctl list_users
& $ctl list_permissions -p $vhost
& $plg list -e
"porta 5672 (AMQP): "  + (Test-NetConnection localhost -Port 5672 -InformationLevel Quiet)
"porta 15672 (painel): " + (Test-NetConnection localhost -Port 15672 -InformationLevel Quiet)
Write-Host "`nPronto. No appsettings do servico: RabbitMQ.Host = rabbitmq://localhost/$vhost e RabbitMQ.Username = $usuario." -ForegroundColor Green
Write-Host "Painel: http://localhost:15672 (usuario $usuario)." -ForegroundColor Green
