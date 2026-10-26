# LTDEV-2 - roda no banco de HOMOLOGACAO os scripts do LTDEV-2 e configura o ParameterRoot, usando as
# connection strings do appsettings.json do servico DESTA maquina (mesmo servidor, banco e acesso).
#
# Rodar num PowerShell (nao precisa ser administrador), na pasta deste script:
#   powershell -ExecutionPolicy Bypass -File "LTDEV-2 - Scripts de banco (HML).ps1"
# Opcoes:
#   -Servico  pasta do EmailIndexingService.exe (onde esta o appsettings.json usado pelo servico)
#   -Backend  pasta do repositorio BRSCloud-Backend (branch staging-latam), de onde saem os scripts
# Pede confirmacao antes de alterar o banco. Grava "LTDEV-2 - Scripts de banco (HML).saida.txt" e envia ao git.

param(
    [string]$Servico = (Join-Path $env:USERPROFILE 'Service-ClaimEmailAutomation\EmailIndexingService\bin\Debug\netcoreapp3.1'),
    [string]$Backend = (Join-Path $env:USERPROFILE 'BRSCloud-Backend')
)

$ErrorActionPreference = 'Stop'
$docs  = $PSScriptRoot
$saida = Join-Path $docs 'LTDEV-2 - Scripts de banco (HML).saida.txt'
Start-Transcript -Path $saida -Force | Out-Null
Add-Type -AssemblyName System.Security

function Titulo($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

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

# valor criptografado com DPAPI (AQAAANCM...) e aberto como o servico faria
function Abrir([string]$v) {
    if ($v -and $v.StartsWith('AQAAANCM')) {
        return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($v), $null, 'LocalMachine'))
    }
    $v
}

function Descreve([string]$cs) {
    $b = New-Object Data.SqlClient.SqlConnectionStringBuilder($cs)
    "servidor $($b.DataSource), banco $($b.InitialCatalog), " + $(if ($b.IntegratedSecurity) { 'Integrated Security' } else { "usuario SQL $($b.UserID)" })
}

# Executa um script .sql (blocos separados por GO) mostrando PRINTs e mensagens.
# $ajustar: scriptblock opcional que recebe o texto e devolve o texto adaptado ao banco.
function RodarScript([string]$cs, [string]$arquivo, [scriptblock]$ajustar = $null) {
    $texto = [IO.File]::ReadAllText($arquivo, [Text.Encoding]::UTF8)
    if ($ajustar) { $texto = & $ajustar $texto }
    $blocos = [regex]::Split($texto, '(?im)^\s*GO\s*;?\s*$') | Where-Object { $_.Trim() }
    $cn = New-Object Data.SqlClient.SqlConnection($cs)
    $cn.add_InfoMessage({ param($s, $e) foreach ($m in $e.Errors) { "   [sql] $($m.Message)" | Write-Host } })
    $cn.Open()
    try {
        $n = 0
        foreach ($b in $blocos) {
            $n++
            $cmd = $cn.CreateCommand(); $cmd.CommandText = $b; $cmd.CommandTimeout = 900
            try { [void]$cmd.ExecuteNonQuery() }
            catch { throw "bloco $n de $([IO.Path]::GetFileName($arquivo)): $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
        }
        "   OK ($n blocos)"
    } finally { $cn.Close() }
}

function Consulta([string]$cs, [string]$sql) {
    $cn = New-Object Data.SqlClient.SqlConnection($cs); $cn.Open()
    try {
        $da = New-Object Data.SqlClient.SqlDataAdapter($sql, $cn); $t = New-Object Data.DataTable; [void]$da.Fill($t); , $t
    } finally { $cn.Close() }
}

function Valor([string]$cs, [string]$sql) {
    $cn = New-Object Data.SqlClient.SqlConnection($cs); $cn.Open()
    try { $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.ExecuteScalar() } finally { $cn.Close() }
}

function Pergunta([string]$texto, $padrao) {
    $r = Read-Host "$texto [$padrao]"
    if ([string]::IsNullOrWhiteSpace($r)) { $padrao } else { $r.Trim() }
}

try {
    # ------------------------------------------------------------------ configuracao do servico
    Titulo 'Configuracao (appsettings.json do servico desta maquina)'
    $cfgArq = Join-Path $Servico 'appsettings.json'
    if (-not (Test-Path $cfgArq)) { throw "appsettings.json nao encontrado em $Servico (use -Servico)." }
    $cfg = SemComentarios (Get-Content $cfgArq -Raw -Encoding UTF8) | ConvertFrom-Json
    $csMain = Abrir $cfg.ConnectionStrings.DefaultConnection
    if (-not $csMain) { $csMain = Abrir $cfg.ConnectionStrings.BRSCloudConnection }
    $csLoc  = Abrir $cfg.ConnectionStrings.LocalizationsConnection
    $csLog  = Abrir $cfg.ConnectionStrings.LogConnection
    $userGuid = $cfg.ServiceUser.UserName
    if (-not $csMain) { throw 'Sem DefaultConnection/BRSCloudConnection no appsettings.' }
    if (-not $csLoc)  { throw 'Sem LocalizationsConnection no appsettings.' }
    "Banco principal (OneCrawford): " + (Descreve $csMain)
    "Banco de traducoes:            " + (Descreve $csLoc)
    "Banco de log:                  " + $(if ($csLog) { Descreve $csLog } else { '(sem LogConnection)' })
    "Usuario de servico (GUID):     $userGuid"

    # ------------------------------------------------------------------ scripts
    $exec = Join-Path $Backend 'OneCrawford.Infra.Database.SqlServer\_executar'
    $pre  = Join-Path $Backend 'OneCrawford.Infra.Database.SqlServer\scripts\2026\DEVLATAM-523 OneCrawfordDB.sql'
    $scripts = @(
        @{ Arq = 'LTDEV-2 OneCrawfordDB.sql';             Cs = $csMain },
        @{ Arq = 'LTDEV-2 Index OneCrawfordDB.sql';       Cs = $csMain },
        @{ Arq = 'LTDEV-2 LocalizationsDB.sql';           Cs = $csLoc  },
        @{ Arq = 'LTDEV-2 Export Tags OneCrawfordDB.sql'; Cs = $csMain })
    Titulo "Scripts (repositorio $Backend)"
    'Branch do backend: ' + (git.exe -C $Backend branch --show-current 2>$null) + ' (precisa ser staging-latam)'
    foreach ($s in $scripts) {
        $p = Join-Path $exec $s.Arq
        if (-not (Test-Path $p)) { throw "Script nao encontrado: $p" }
        "   $($s.Arq)"
    }

    # ------------------------------------------------------------------ situacao atual
    Titulo 'Situacao atual do banco principal'
    $temCountry = Valor $csMain "select COL_LENGTH('ParameterRoot','CountryCode')"
    $temLtdev2  = Valor $csMain "select COL_LENGTH('ParameterRoot','EmailIndexingMailbox')"
    'ParameterRoot.CountryCode (DEVLATAM-523): ' + $(if ($temCountry -is [DBNull]) { 'NAO existe' } else { 'existe' })
    'Colunas do LTDEV-2:                      ' + $(if ($temLtdev2 -is [DBNull]) { 'NAO existem' } else { 'existem (os scripts sao idempotentes: rodar de novo nao muda nada)' })

    Write-Host "`nVai ALTERAR o banco acima (homologacao)." -ForegroundColor Yellow
    if ((Read-Host 'Confirma? Digite S para continuar') -notmatch '^[sS]') { throw 'Cancelado pelo usuario.' }

    # ------------------------------------------------------------------ executar
    if ($temCountry -is [DBNull]) {
        Titulo 'Pre-requisito DEVLATAM-523 (ParameterRoot.CountryCode)'
        if (-not (Test-Path $pre)) { throw "Pre-requisito nao encontrado: $pre" }
        RodarScript $csMain $pre
    }
    foreach ($s in $scripts) {
        Titulo $s.Arq
        if ($s.Cs -eq $csLoc) {
            # traducoes sao opcionais para o teste: sem acesso ao banco, as mensagens saem com a chave
            try { RodarScript $s.Cs (Join-Path $exec $s.Arq) }
            catch { Write-Host "ATENCAO: traducoes NAO aplicadas (sem acesso ao banco de traducoes?): $($_.Exception.Message). O servico funciona; as mensagens saem com a chave (ex.: EmailIndexing.ClaimCode.NotFound)." -ForegroundColor Yellow }
        } elseif ($s.Arq -eq 'LTDEV-2 OneCrawfordDB.sql' -and
                  (Valor $csMain "select COL_LENGTH('AttachmentFolder','IsIntermediateDocument')") -is [DBNull]) {
            # Banco de HML anterior ao card "Data Relatorio Interino": AttachmentFolder sem IsIntermediateDocument.
            # O insert das pastas mestre roda sem essa coluna; o resto do script fica igual.
            Write-Host 'ATENCAO: AttachmentFolder.IsIntermediateDocument nao existe neste banco (banco desatualizado); pastas mestre criadas sem ela.' -ForegroundColor Yellow
            RodarScript $s.Cs (Join-Path $exec $s.Arq) {
                param($t)
                $a = 'IsBasicDocument, IsPreliminarDocument, IsFinalDocument, IsIntermediateDocument)'
                $b = 'null, 1, 1, null, 0, 0, 0, 0'
                if (-not $t.Contains($a) -or -not $t.Contains($b)) { throw 'Trecho das pastas mestre nao encontrado no script; ajuste manual necessario.' }
                $t.Replace($a, 'IsBasicDocument, IsPreliminarDocument, IsFinalDocument)').Replace($b, 'null, 1, 1, null, 0, 0, 0')
            }
        } else {
            RodarScript $s.Cs (Join-Path $exec $s.Arq)
        }
    }

    # ------------------------------------------------------------------ ParameterRoot do pais do usuario de servico
    Titulo 'ParameterRoot do pais do usuario de servico'
    $root = Valor $csMain "select RootId from usr.UserX where UniqueId = '$($userGuid -replace "'", '')'"
    if ($null -eq $root -or $root -is [DBNull]) {
        Write-Host "ATENCAO: o usuario de servico $userGuid nao existe neste banco. Ajuste ServiceUser.UserName no appsettings." -ForegroundColor Yellow
    } else {
        $atual = (Consulta $csMain "select RootId, CountryCode, EmailIndexingMailbox, EmailIndexingManualBox, EmailIndexingStore, EmailIndexingStoreDays, EmailIndexingLocalDomains, EmailIndexingAlertBox from ParameterRoot where RootId = $root").Rows[0]
        'Valores atuais:'; $atual | Format-List | Out-String
        $mailbox = Pergunta 'Caixa monitorada (EmailIndexingMailbox)' $(if ($atual.EmailIndexingMailbox -isnot [DBNull]) { $atual.EmailIndexingMailbox } else { 'central.recebimento@crawfordbrasil.com.br' })
        $manual  = Pergunta 'Quem recebe os recusados (EmailIndexingManualBox)' $(if ($atual.EmailIndexingManualBox -isnot [DBNull]) { $atual.EmailIndexingManualBox } else { 'nelson.diniz.contractor@crawfordbrasil.com.br' })
        $alerta  = Pergunta 'Quem recebe o aviso de erro critico (EmailIndexingAlertBox)' $(if ($atual.EmailIndexingAlertBox -isnot [DBNull]) { $atual.EmailIndexingAlertBox } else { 'nelson.diniz.contractor@crawfordbrasil.com.br' })
        $dominio = Pergunta 'Dominios internos (EmailIndexingLocalDomains)' $(if ($atual.EmailIndexingLocalDomains -isnot [DBNull]) { $atual.EmailIndexingLocalDomains } else { 'crawfordbrasil.com.br' })
        $cn = New-Object Data.SqlClient.SqlConnection($csMain); $cn.Open()
        try {
            $c = $cn.CreateCommand()
            $c.CommandText = @'
update ParameterRoot set
    EmailIndexingMailbox      = @mailbox,
    EmailIndexingManualBox    = @manual,
    EmailIndexingStore        = isnull(EmailIndexingStore, 1),
    EmailIndexingStoreDays    = isnull(EmailIndexingStoreDays, 0),
    EmailIndexingLocalDomains = @dominio,
    EmailIndexingAlertBox     = @alerta
where RootId = @root
'@
            [void]$c.Parameters.AddWithValue('@mailbox', $mailbox)
            [void]$c.Parameters.AddWithValue('@manual', $manual)
            [void]$c.Parameters.AddWithValue('@dominio', $dominio)
            [void]$c.Parameters.AddWithValue('@alerta', $alerta)
            [void]$c.Parameters.AddWithValue('@root', [int]$root)
            "Linhas atualizadas: " + $c.ExecuteNonQuery()
        } finally { $cn.Close() }
        (Consulta $csMain "select RootId, CountryCode, hasFile, EmailIndexingMailbox, EmailIndexingManualBox, EmailIndexingStore, EmailIndexingStoreDays, EmailIndexingLocalDomains, EmailIndexingAlertBox from ParameterRoot where RootId = $root") | Format-List | Out-String
    }

    # ------------------------------------------------------------------ tabela de log
    Titulo 'Tabela dbo.Logs no banco de log'
    if ($csLog) {
        try {
            $existe = Valor $csLog "select object_id('dbo.Logs')"
            if ($existe -is [DBNull]) {
                $cn = New-Object Data.SqlClient.SqlConnection($csLog); $cn.Open()
                try {
                    $c = $cn.CreateCommand()
                    $c.CommandText = 'create table dbo.Logs (Id int identity(1,1) not null, CreateDate datetimeoffset(7) not null, MachineName nvarchar(200) not null, ServiceName nvarchar(100) not null, Logged datetimeoffset(7) not null, Level nvarchar(10) not null, Message nvarchar(max) not null, Logger nvarchar(300) null, Properties nvarchar(max) null, CallSite nvarchar(300) null, Exception nvarchar(max) null, constraint PK_LogsId primary key (Id))'
                    [void]$c.ExecuteNonQuery(); 'dbo.Logs criada.'
                } finally { $cn.Close() }
            } else { 'dbo.Logs ja existe.' }
        } catch {
            Write-Host "ATENCAO: nao foi possivel acessar o banco de log ($($_.Exception.InnerException.Message)$($_.Exception.Message)). O log continua no arquivo; para ir ao banco, ajuste LogConnection ou o acesso." -ForegroundColor Yellow
        }
    }

    # ------------------------------------------------------------------ conferencia
    Titulo 'Conferencia'
    'Cronologia (LastEmailReceivedDoneDate): ' + -not ((Valor $csMain "select COL_LENGTH('ClaimChronology','LastEmailReceivedDoneDate')") -is [DBNull])
    'Anexo (ExternalMessageId):              ' + -not ((Valor $csMain "select COL_LENGTH('AttachmentClaim','ExternalMessageId')") -is [DBNull])
    try { 'Traducoes EmailIndexing.*:              ' + (Valor $csLoc "select count(*) from Localizations where ResourceId like 'EmailIndexing.%'") }
    catch { 'Traducoes EmailIndexing.*:              (sem acesso ao banco de traducoes)' }
    Write-Host "`nPronto. O servico rele o ParameterRoot a cada varredura (nao precisa reiniciar)." -ForegroundColor Green
}
catch {
    Write-Host "`nFALHA: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "`nEnviando o resultado ao git..." -ForegroundColor Cyan
    git.exe -C $docs add -- (Split-Path $saida -Leaf)
    git.exe -C $docs commit -m "LTDEV-2: scripts de banco HML ($env:COMPUTERNAME)" | Out-Null
    git.exe -C $docs pull --rebase -q
    git.exe -C $docs push -q
    Write-Host 'Pronto. Avise o Claude.' -ForegroundColor Green
}
