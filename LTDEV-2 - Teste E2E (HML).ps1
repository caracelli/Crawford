#Requires -RunAsAdministrator
# LTDEV-2 - teste ponta a ponta na maquina de TESTE:
#   atualiza o codigo para o main (com a PR #4), desinstala o servico, compila, envia e-mails de teste
#   para a caixa monitorada, reinstala o servico, espera o processamento e confere caixa, banco e log.
# O appsettings.json e o NLog.config da maquina sao mantidos (backup antes).
#
# Rodar num PowerShell aberto como administrador, na pasta deste script:
#   powershell -ExecutionPolicy Bypass -File "LTDEV-2 - Teste E2E (HML).ps1"
# Grava "LTDEV-2 - Teste E2E (HML).saida.txt" e envia ao git.

param(
    [string]$Repo   = (Join-Path $env:USERPROFILE 'Service-ClaimEmailAutomation'),
    [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'
$docs  = $PSScriptRoot
$saida = Join-Path $docs 'LTDEV-2 - Teste E2E (HML).saida.txt'
Start-Transcript -Path $saida -Force | Out-Null
Add-Type -AssemblyName System.Security
$env:IGCCSVC_DB = 'nao-usado-pelo-EmailIndexingService'   # contorno Intel tambem para install/uninstall
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$proj   = Join-Path $Repo 'EmailIndexingService'
$bin    = Join-Path $proj 'bin\Debug\netcoreapp3.1'
$exe    = Join-Path $bin 'EmailIndexingService.exe'
$backup = Join-Path $env:USERPROFILE ('ltdev2-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$marca  = Get-Date -Format 'ddMM-HHmmss'
$restaurarParametro = $null

function Titulo($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function GitOk { & git.exe -C $Repo @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') falhou ($LASTEXITCODE)" } }
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
function Abrir([string]$v) {
    if ($v -and $v.StartsWith('AQAAANCM')) { return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($v), $null, 'LocalMachine')) }
    $v
}
function Sql([string]$cs, [string]$sql, [hashtable]$p = @{}) {
    $cn = New-Object Data.SqlClient.SqlConnection($cs); $cn.Open()
    try {
        $c = $cn.CreateCommand(); $c.CommandText = $sql
        foreach ($k in $p.Keys) { [void]$c.Parameters.AddWithValue($k, $p[$k]) }
        $t = New-Object Data.DataTable; (New-Object Data.SqlClient.SqlDataAdapter($c)).Fill($t) | Out-Null; , $t
    } finally { $cn.Close() }
}

try {
    if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "Repositorio nao encontrado em $Repo." }

    # ------------------------------------------------------------------ 1. backup e configuracao
    Titulo '1. Backup da configuracao da maquina'
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($f in 'appsettings.json', 'NLog.config') {
        if (Test-Path (Join-Path $bin $f))  { Copy-Item (Join-Path $bin $f)  (Join-Path $backup "bin-$f") }
        if (Test-Path (Join-Path $proj $f)) { Copy-Item (Join-Path $proj $f) (Join-Path $backup "projeto-$f") }
    }
    Get-ChildItem $backup | ForEach-Object { "   $($_.Name)" }
    # o appsettings em uso e o da bin (o servico le dali)
    $appsettings = if (Test-Path (Join-Path $backup 'bin-appsettings.json')) { Join-Path $backup 'bin-appsettings.json' } else { Join-Path $backup 'projeto-appsettings.json' }
    $nlog = if (Test-Path (Join-Path $backup 'bin-NLog.config')) { Join-Path $backup 'bin-NLog.config' } else { Join-Path $backup 'projeto-NLog.config' }
    $cfg = SemComentarios (Get-Content $appsettings -Raw -Encoding UTF8) | ConvertFrom-Json
    $cs = Abrir $cfg.ConnectionStrings.DefaultConnection; if (-not $cs) { $cs = Abrir $cfg.ConnectionStrings.BRSCloudConnection }
    $mailboxCfg = $cfg.Graph
    "appsettings usado: $appsettings"
    "banco: " + (New-Object Data.SqlClient.SqlConnectionStringBuilder($cs)).DataSource + ' / ' + (New-Object Data.SqlClient.SqlConnectionStringBuilder($cs)).InitialCatalog
    "Files.Temp: $($cfg.Files.Temp)"

    # ------------------------------------------------------------------ 2. desinstalar
    Titulo '2. Desinstalando o servico'
    foreach ($s in (Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'EmailIndexingService\.exe' })) {
        "Removendo '$($s.Name)'"
        Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
        & ($s.PathName -replace '^"([^"]+)".*$', '$1') uninstall | Out-Null
        if (Get-Service -Name $s.Name -ErrorAction SilentlyContinue) { sc.exe delete "$($s.Name)" | Out-Null }
    }
    Start-Sleep -Seconds 3

    # ------------------------------------------------------------------ 3. codigo e compilacao
    Titulo "3. Codigo: $Branch (com a PR #4)"
    Remove-Item (Join-Path $proj 'appsettings.json'), (Join-Path $proj 'NLog.config') -Force -ErrorAction SilentlyContinue
    if ([bool](git.exe -C $Repo status --porcelain)) { GitOk stash push -u -m ('ltdev2-antes-do-e2e-' + $marca); "alteracoes locais guardadas no stash ltdev2-antes-do-e2e-$marca" }
    GitOk fetch origin
    if (git.exe -C $Repo branch --list $Branch) { GitOk checkout $Branch; GitOk reset --hard "origin/$Branch" } else { GitOk checkout -b $Branch "origin/$Branch" }
    '   commit: ' + (git.exe -C $Repo log -1 --format='%h %s')
    '   tem a PR #4: ' + [bool](git.exe -C $Repo log --oneline -1 --grep 'LTDEV-2: ajustes do teste em staging')
    Copy-Item $appsettings (Join-Path $proj 'appsettings.json') -Force
    Copy-Item $nlog (Join-Path $proj 'NLog.config') -Force
    'appsettings.json e NLog.config da maquina restaurados.'
    'Backend: ' + (git.exe -C (Join-Path (Split-Path $Repo) 'BRSCloud-Backend') branch --show-current 2>$null) + ' (precisa ser staging-latam)'
    dotnet build (Join-Path $proj 'EmailIndexingService.csproj') -c Debug -v q -nologo
    if ($LASTEXITCODE -ne 0) { throw 'A compilacao falhou.' }

    # ------------------------------------------------------------------ 4. sinistro e modo de arquivo
    Titulo '4. Sinistro de teste e modo de gravacao de arquivos'
    $root = (Sql $cs 'select RootId from usr.UserX where UniqueId = @g' @{ '@g' = $cfg.ServiceUser.UserName }).Rows[0].RootId
    $userId = (Sql $cs 'select Id from usr.UserX where UniqueId = @g' @{ '@g' = $cfg.ServiceUser.UserName }).Rows[0].Id
    $claim = (Sql $cs @'
select top 1 c.ClaimCode, c.UniqueId from Claim c
join Situation s on s.Id = c.SituationId
where c.RootId = @r and c.IsDeleted = 0 and s.IsCancelled = 0 and s.IsLast = 0
  and c.OperationId in (select distinct goa.OperationId from usr.GroupUserOperationAccess goa
                        join usr.GroupUser gu on gu.Id = goa.GroupUserId
                        join usr.GroupUserAccess gua on gua.GroupUserId = gu.Id
                        where goa.IsDeleted = 0 and gua.IsDeleted = 0 and gua.UserId = @u)
order by c.Id desc
'@ @{ '@r' = $root; '@u' = $userId }).Rows[0]
    if (-not $claim) { throw 'Nenhum sinistro aberto com acesso do usuario de servico neste banco.' }
    "sinistro de teste: $($claim.ClaimCode)"
    $param = (Sql $cs 'select hasFile, hasFinance, AttachmentFolderPath from ParameterRoot where RootId = @r' @{ '@r' = $root }).Rows[0]
    "ParameterRoot: hasFile=$($param.hasFile) hasFinance=$($param.hasFinance) AttachmentFolderPath=$($param.AttachmentFolderPath)"
    if (-not $param.hasFile) {
        Write-Host "hasFile=0: os arquivos vao pela fila para o servico de integracao de HML, que nao escuta o RabbitMQ local (resultado seria Timeout)." -ForegroundColor Yellow
        if ((Read-Host 'Usar o modo de arquivo local (hasFile=1) SO durante o teste e restaurar no fim? (S/N)') -match '^[sS]') {
            $pasta = 'C:\Temp\BRSCloud Attachments\BRS Brazil'
            New-Item -ItemType Directory -Force -Path $pasta | Out-Null
            $restaurarParametro = @{ hasFile = $param.hasFile; hasFinance = $param.hasFinance; path = $param.AttachmentFolderPath; root = $root }
            Sql $cs 'update ParameterRoot set hasFile = 1, hasFinance = 1, AttachmentFolderPath = @p where RootId = @r' @{ '@p' = $pasta; '@r' = $root } | Out-Null
            "modo de arquivo local ATIVADO (restaurado no fim). Pasta: $pasta"
        }
    }

    # ------------------------------------------------------------------ 5. e-mails de teste
    Titulo '5. Enviando e-mails de teste'
    $secret = Abrir $cfg.Graph.ClientSecret
    if (-not $secret) {
        $sec = Join-Path $env:APPDATA 'Microsoft\UserSecrets\c86bbf91-40a5-4973-b6ce-5d6347e8d290\secrets.json'
        if (Test-Path $sec) { $secret = (Get-Content $sec -Raw | ConvertFrom-Json).'Graph:ClientSecret' }
    }
    if (-not $secret) { throw 'Graph ClientSecret nao encontrado (appsettings nem User Secrets).' }
    $mailbox = (Sql $cs 'select EmailIndexingMailbox from ParameterRoot where RootId = @r' @{ '@r' = $root }).Rows[0].EmailIndexingMailbox
    $tok = (Invoke-RestMethod -Method Post "https://login.microsoftonline.com/$($cfg.Graph.TenantId)/oauth2/v2.0/token" -Body @{
        client_id = $cfg.Graph.ClientId; client_secret = $secret; scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials' }).access_token
    $H = @{ Authorization = "Bearer $tok" }
    $base = "https://graph.microsoft.com/v1.0/users/$mailbox"
    function Png([int]$w, [int]$h, [byte]$r, [byte]$g, [byte]$b) {
        $bmp = New-Object Drawing.Bitmap $w, $h; $gr = [Drawing.Graphics]::FromImage($bmp); $gr.Clear([Drawing.Color]::FromArgb($r, $g, $b))
        $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $gr.Dispose(); $bmp.Dispose(); [Convert]::ToBase64String($ms.ToArray())
    }
    Add-Type -AssemblyName System.Drawing
    $assuntoOk  = "$($claim.ClaimCode) LTDEV-2 E2E $marca"
    $assuntoRej = "LTDEV-2 E2E sem numero $marca"
    $msgOk = @{ message = @{ subject = $assuntoOk; body = @{ contentType = 'HTML'; content = '<p>Teste E2E LTDEV-2.</p><p>--<br/><img src="cid:logo001"/></p>' }
        toRecipients = @(@{ emailAddress = @{ address = $mailbox } })
        attachments = @(
            @{ '@odata.type' = '#microsoft.graph.fileAttachment'; name = 'image001.png'; contentType = 'image/png'; isInline = $true; contentId = 'logo001'; contentBytes = (Png 40 20 0 70 140) },
            @{ '@odata.type' = '#microsoft.graph.fileAttachment'; name = 'foto-e2e.png'; contentType = 'image/png'; isInline = $false; contentId = 'foto001'; contentBytes = (Png 160 120 200 120 40) }) }
        saveToSentItems = $false }
    $msgRej = @{ message = @{ subject = $assuntoRej; body = @{ contentType = 'Text'; content = 'Teste E2E LTDEV-2 sem numero de sinistro.' }
        toRecipients = @(@{ emailAddress = @{ address = $mailbox } }) }; saveToSentItems = $false }
    foreach ($m in $msgOk, $msgRej) {
        Invoke-RestMethod -Method Post "$base/sendMail" -Headers $H -ContentType 'application/json' -Body ($m | ConvertTo-Json -Depth 8) | Out-Null
    }
    "enviados: '$assuntoOk' (com foto e logotipo) e '$assuntoRej'"
    $ids = @{}
    for ($i = 0; $i -lt 12 -and $ids.Count -lt 2; $i++) {
        Start-Sleep -Seconds 5
        foreach ($a in $assuntoOk, $assuntoRej) {
            $f = [uri]::EscapeDataString("subject eq '$a'")
            $r = (Invoke-RestMethod "$base/messages?`$filter=$f&`$select=internetMessageId,receivedDateTime" -Headers $H).value
            if ($r) { $ids[$a] = $r[0].internetMessageId }
        }
    }
    "chegaram na caixa: $($ids.Count) de 2"

    # ------------------------------------------------------------------ 6. instalar e iniciar
    $nome = $cfg.ServiceConfiguration.ServiceName
    Titulo "6. Instalando '$nome'"
    $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'Senha da sua conta (o servico roda com ela)'
    & $exe install -username "$($cred.UserName)" -password "$($cred.GetNetworkCredential().Password)"
    if ($LASTEXITCODE -ne 0) { throw "install retornou $LASTEXITCODE" }
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$nome" -Name Environment -PropertyType MultiString -Force -Value @('IGCCSVC_DB=nao-usado-pelo-EmailIndexingService') | Out-Null
    $inicio = Get-Date
    Start-Service -Name $nome
    'servico iniciado.'

    # ------------------------------------------------------------------ 7. aguardar e conferir
    Titulo '7. Aguardando o processamento (ate 4 minutos)'
    $folders = @{}
    foreach ($fn in 'Processados', 'Rejeitados') {
        $inbox = (Invoke-RestMethod "$base/mailFolders/inbox" -Headers $H).id
        $fid = ((Invoke-RestMethod "$base/mailFolders/$inbox/childFolders" -Headers $H).value | Where-Object displayName -eq $fn).id
        if ($fid) { $folders[$fn] = $fid }
    }
    $onde = @{}
    for ($i = 0; $i -lt 24 -and $onde.Count -lt 2; $i++) {
        Start-Sleep -Seconds 10
        foreach ($a in $assuntoOk, $assuntoRej) {
            if ($onde.ContainsKey($a)) { continue }
            foreach ($fn in $folders.Keys) {
                $f = [uri]::EscapeDataString("subject eq '$a'")
                if ((Invoke-RestMethod "$base/mailFolders/$($folders[$fn])/messages?`$filter=$f&`$select=id" -Headers $H).value) { $onde[$a] = $fn }
            }
        }
    }
    foreach ($a in $assuntoOk, $assuntoRej) { "   '$a' -> " + $(if ($onde[$a]) { $onde[$a] } else { 'ainda na Caixa de Entrada' }) }

    Titulo 'Anexos gravados no sinistro (pelo ExternalMessageId do e-mail)'
    if ($ids[$assuntoOk]) {
        (Sql $cs @'
select a.Id, a.OriginalFileName, a.Description, a.CreateDate, f.Name as Pasta
from AttachmentClaim ac join Attachment a on a.Id = ac.Id left join AttachmentFolder f on f.Id = a.AttachmentFolderId
where ac.ExternalMessageId = @m order by a.Id
'@ @{ '@m' = $ids[$assuntoOk] }) | Format-Table -AutoSize | Out-String -Width 220
    }
    'Cronologia (LastEmailReceivedDoneDate) do sinistro (remetente interno: deve continuar como estava):'
    (Sql $cs 'select cc.LastEmailReceivedDoneDate from ClaimChronology cc join Claim c on c.Id = cc.ClaimId where c.ClaimCode = @c' @{ '@c' = $claim.ClaimCode }) | Format-Table | Out-String

    Titulo 'Encaminhamento da recusa (Itens Enviados nao guardam: conferir no e-mail de EmailIndexingManualBox)'
    'Destino: ' + (Sql $cs 'select EmailIndexingManualBox from ParameterRoot where RootId = @r' @{ '@r' = $root }).Rows[0].EmailIndexingManualBox

    Titulo 'Log do servico'
    Get-ChildItem (Join-Path $bin 'log') -Filter 'emailindexing-*.log' -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $inicio |
        ForEach-Object { Get-Content $_.FullName | Select-String -Pattern 'INFO|WARN|ERROR' | Select-Object -Last 15 | ForEach-Object { $_.Line } }
    Get-CimInstance Win32_Service -Filter "Name='$nome'" | Format-List Name, State, StartName | Out-String
}
catch {
    Write-Host "`nFALHA: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($restaurarParametro) {
        Titulo 'Restaurando o ParameterRoot (modo de arquivo)'
        try {
            Sql $cs 'update ParameterRoot set hasFile = @h, hasFinance = @f, AttachmentFolderPath = @p where RootId = @r' @{
                '@h' = $restaurarParametro.hasFile; '@f' = $restaurarParametro.hasFinance; '@p' = $restaurarParametro.path; '@r' = $restaurarParametro.root } | Out-Null
            (Sql $cs 'select hasFile, hasFinance, AttachmentFolderPath from ParameterRoot where RootId = @r' @{ '@r' = $restaurarParametro.root }) | Format-List | Out-String
        } catch { Write-Host "ATENCAO: nao foi possivel restaurar o ParameterRoot: $($_.Exception.Message)" -ForegroundColor Red }
    }
    "Backup da configuracao: $backup"
    Stop-Transcript | Out-Null
    Write-Host "`nEnviando o resultado ao git..." -ForegroundColor Cyan
    git.exe -C $docs add -- (Split-Path $saida -Leaf)
    git.exe -C $docs commit -m "LTDEV-2: teste E2E HML ($env:COMPUTERNAME)" | Out-Null
    git.exe -C $docs pull --rebase -q
    git.exe -C $docs push -q
    Write-Host 'Pronto. Avise o Claude.' -ForegroundColor Green
}
