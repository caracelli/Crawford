# LTDEV-2 - diagnostico da instalacao do RabbitMQ (somente leitura: nao altera nada).
# Rodar num PowerShell aberto como administrador:
#   powershell -ExecutionPolicy Bypass -File "<pasta>\LTDEV-2 - Diagnostico RabbitMQ.ps1"
# O resultado aparece na tela e fica em "LTDEV-2 - Diagnostico RabbitMQ.saida.txt", na mesma pasta.

$ErrorActionPreference = 'Continue'
$saida = Join-Path $PSScriptRoot 'LTDEV-2 - Diagnostico RabbitMQ.saida.txt'
Start-Transcript -Path $saida -Force | Out-Null

function Titulo($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

Titulo 'Maquina'
"$env:COMPUTERNAME | usuario $env:USERNAME | admin: " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Titulo 'Servico RabbitMQ'
$svc = Get-CimInstance Win32_Service -Filter "Name='RabbitMQ'" -ErrorAction SilentlyContinue
if ($svc) { $svc | Select-Object Name, State, StartMode, StartName, PathName | Format-List | Out-String } else { 'servico RabbitMQ NAO existe' }

Titulo 'Erlang e RabbitMQ instalados'
'erl.exe existe: ' + (Test-Path 'C:\Program Files\Erlang OTP\bin\erl.exe')
Get-ChildItem 'C:\Program Files' -Directory -ErrorAction SilentlyContinue | Where-Object Name -match 'Erlang|RabbitMQ' | ForEach-Object { $_.FullName }
Get-ChildItem 'C:\Program Files\Erlang OTP\releases' -Directory -ErrorAction SilentlyContinue | ForEach-Object { 'OTP ' + (Get-Content (Join-Path $_.FullName 'OTP_VERSION') -ErrorAction SilentlyContinue) }
Get-ChildItem 'C:\Program Files\RabbitMQ Server' -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }

Titulo 'Instaladores baixados (%TEMP%\ltdev2-rabbitmq)'
$tmp = Join-Path $env:TEMP 'ltdev2-rabbitmq'
if (Test-Path $tmp) { Get-ChildItem $tmp | ForEach-Object { '{0}  {1:N1} MB' -f $_.Name, ($_.Length / 1MB) } } else { 'pasta nao existe (nada baixado)' }

Titulo 'Configuracao (%APPDATA%\RabbitMQ)'
$cfg = Join-Path $env:APPDATA 'RabbitMQ'
if (Test-Path $cfg) {
    Get-ChildItem $cfg | ForEach-Object { $_.Name }
    foreach ($f in 'rabbitmq.conf', 'enabled_plugins') { "-- $f"; Get-Content (Join-Path $cfg $f) -ErrorAction SilentlyContinue }
} else { 'pasta nao existe' }
'ERLANG_HOME: ' + [Environment]::GetEnvironmentVariable('ERLANG_HOME', 'Machine')
'RABBITMQ_BASE: ' + [Environment]::GetEnvironmentVariable('RABBITMQ_BASE', 'Machine')

Titulo 'Cookie do Erlang (o CLI precisa do mesmo do servico)'
try {
    $c1 = 'C:\Windows\System32\config\systemprofile\.erlang.cookie'
    $c2 = Join-Path $env:USERPROFILE '.erlang.cookie'
    'cookie do servico existe: ' + (Test-Path $c1 -ErrorAction Stop)
    'cookie do usuario existe: ' + (Test-Path $c2 -ErrorAction Stop)
    if ((Test-Path $c1) -and (Test-Path $c2)) { 'cookies iguais: ' + ((Get-FileHash $c1).Hash -eq (Get-FileHash $c2).Hash) }
} catch { 'nao foi possivel ler o cookie do servico (rodar como administrador): ' + $_.Exception.Message }

Titulo 'Portas'
'5672 (AMQP): '   + (Test-NetConnection localhost -Port 5672 -InformationLevel Quiet -WarningAction SilentlyContinue)
'15672 (painel): ' + (Test-NetConnection localhost -Port 15672 -InformationLevel Quiet -WarningAction SilentlyContinue)

Titulo 'rabbitmqctl status / vhosts / usuarios'
$ctl = Get-ChildItem 'C:\Program Files\RabbitMQ Server' -Recurse -Filter rabbitmqctl.bat -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ctl) {
    & $ctl.FullName status 2>&1 | Select-Object -First 15
    & $ctl.FullName list_vhosts 2>&1
    & $ctl.FullName list_users 2>&1
    & $ctl.FullName list_permissions -p enviroment 2>&1
} else { 'rabbitmqctl nao encontrado' }

Titulo 'Ultimos erros do RabbitMQ/Erlang no Visualizador de Eventos (24h)'
Get-WinEvent -FilterHashtable @{LogName = 'Application'; StartTime = (Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'RabbitMQ|Erlang|erl' -or $_.Message -match 'RabbitMQ|erl\.exe' } |
    Select-Object -First 5 | ForEach-Object { '{0} | {1} | {2}' -f $_.TimeCreated, $_.ProviderName, (($_.Message -replace '\s+', ' ').Substring(0, [Math]::Min(300, ($_.Message -replace '\s+', ' ').Length))) }

Titulo 'Log do RabbitMQ (ultimas linhas)'
$logDir = Join-Path $cfg 'log'
Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 |
    ForEach-Object { "-- $($_.Name)"; Get-Content $_.FullName -Tail 20 }

Stop-Transcript | Out-Null
Write-Host "`nResultado salvo em: $saida" -ForegroundColor Green
