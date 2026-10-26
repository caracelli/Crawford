# LTDEV-2 - EmailIndexingService: VERIFICA a configuracao e INSTALA como servico do Windows.
# Para producao: nao altera banco, nao envia e-mail e nao compila. So le a configuracao, confere o ambiente
# e, se nao houver ERRO e voce confirmar, instala, inicia e mostra o resultado.
#
# Uso (PowerShell como ADMINISTRADOR, para instalar):
#   powershell -ExecutionPolicy Bypass -File "LTDEV-2 - Instalar servico (producao).ps1" -Pasta "D:\...\publish"
#   powershell -ExecutionPolicy Bypass -File "LTDEV-2 - Instalar servico (producao).ps1" -Pasta "D:\...\publish" -SoVerificar
#   powershell -ExecutionPolicy Bypass -File "LTDEV-2 - Instalar servico (producao).ps1" -Pasta "D:\...\publish" -Desinstalar
#
# -Pasta        pasta publicada (EmailIndexingService.exe, appsettings.json, NLog.config). Padrao: pasta atual.
# -SoVerificar  so as verificacoes (nao instala; nao precisa de administrador).
# -Desinstalar  para e remove o servico.
# O resultado fica em "LTDEV-2 - Instalar servico (producao).saida.txt", ao lado deste script.

param(
    [string]$Pasta = (Get-Location).Path,
    [switch]$SoVerificar,
    [switch]$Desinstalar
)

$ErrorActionPreference = 'Stop'
$saida = Join-Path $PSScriptRoot 'LTDEV-2 - Instalar servico (producao).saida.txt'
Start-Transcript -Path $saida -Force | Out-Null
Add-Type -AssemblyName System.Security
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:erros = 0; $script:avisos = 0
function Titulo($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "  [OK]      $t" -ForegroundColor Green }
function Aviso($t) { Write-Host "  [ATENCAO] $t" -ForegroundColor Yellow; $script:avisos++ }
function Erro($t)  { Write-Host "  [ERRO]    $t" -ForegroundColor Red; $script:erros++ }

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

# Abre um valor DPAPI (AQAAANCM...) como o servico faria. Devolve @{ Ok; Valor; Cripto }.
function Segredo([string]$v) {
    if (-not $v) { return @{ Ok = $true; Valor = $null; Cripto = $false } }
    if (-not $v.StartsWith('AQAAANCM')) { return @{ Ok = $true; Valor = $v; Cripto = $false } }
    try {
        $t = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($v), $null, 'LocalMachine'))
        @{ Ok = $true; Valor = $t; Cripto = $true }
    } catch { @{ Ok = $false; Valor = $null; Cripto = $true } }
}

function Escalar([string]$cs, [string]$sql, [hashtable]$p = @{}) {
    $cn = New-Object Data.SqlClient.SqlConnection($cs); $cn.Open()
    try {
        $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 30
        foreach ($k in $p.Keys) { [void]$c.Parameters.AddWithValue($k, $p[$k]) }
        $c.ExecuteScalar()
    } finally { $cn.Close() }
}
function DescreveCs([string]$cs) {
    $b = New-Object Data.SqlClient.SqlConnectionStringBuilder($cs); "$($b.DataSource) / $($b.InitialCatalog)"
}

try {
    $Pasta = (Resolve-Path $Pasta).Path
    $exe  = Join-Path $Pasta 'EmailIndexingService.exe'
    $cfgF = Join-Path $Pasta 'appsettings.json'
    $nlgF = Join-Path $Pasta 'NLog.config'
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    Titulo 'Pasta'
    "$Pasta | maquina $env:COMPUTERNAME | usuario $env:USERDOMAIN\$env:USERNAME | administrador: $admin"
    foreach ($f in $exe, $cfgF, $nlgF) { if (Test-Path $f) { Ok (Split-Path $f -Leaf) } else { Erro "$(Split-Path $f -Leaf) nao encontrado" } }
    if ($script:erros) { throw 'Arquivos obrigatorios faltando na pasta (use -Pasta).' }

    $cfg  = SemComentarios (Get-Content $cfgF -Raw -Encoding UTF8) | ConvertFrom-Json
    $nome = $cfg.ServiceConfiguration.ServiceName

    # contorno IGCCSVC_DB tambem para este processo (o install executa o proprio servico)
    $igcc = [Environment]::GetEnvironmentVariable('IGCCSVC_DB', 'Machine'); if (-not $igcc) { $igcc = [Environment]::GetEnvironmentVariable('IGCCSVC_DB', 'User') }
    $env:IGCCSVC_DB = 'nao-usado-pelo-EmailIndexingService'

    if ($Desinstalar) {
        Titulo "Desinstalando '$nome'"
        if (-not $admin) { throw 'Precisa de PowerShell como administrador.' }
        Stop-Service -Name $nome -Force -ErrorAction SilentlyContinue
        & $exe uninstall
        return
    }

    # ------------------------------------------------------------------ appsettings.json
    Titulo 'appsettings.json'
    if ($nome) { Ok "ServiceName: $nome" } else { Erro 'ServiceConfiguration.ServiceName vazio' }
    if ($nome -match '(?i)staging') { Aviso "ServiceName contem 'Staging' (em producao, tirar o prefixo)" }

    $chave = if ($cfg.ConnectionStrings.DefaultConnection) { 'DefaultConnection' } elseif ($cfg.ConnectionStrings.BRSCloudConnection) { 'BRSCloudConnection' } else { $null }
    if (-not $chave) { Erro 'ConnectionStrings sem DefaultConnection nem BRSCloudConnection' }
    $cs = @{}
    foreach ($k in @($chave, 'LogConnection', 'LocalizationsConnection') | Where-Object { $_ }) {
        $s = Segredo $cfg.ConnectionStrings.$k
        if (-not $s.Ok) { Erro "ConnectionStrings.$k criptografada e NAO abre nesta maquina (gerar de novo aqui)"; continue }
        if (-not $s.Valor) { if ($k -eq $chave) { Erro "ConnectionStrings.$k vazia" } else { Aviso "ConnectionStrings.$k vazia" }; continue }
        $cs[$k] = $s.Valor
        Ok "ConnectionStrings.$k -> $(DescreveCs $s.Valor)"
        if ($s.Valor -match '(?i)database\s*=\s*[^;]*staging') { Aviso "ConnectionStrings.$k aponta para banco de STAGING" }
        if ($s.Valor -match '(?i)(password|pwd)\s*=' -and -not $s.Cripto) { Aviso "ConnectionStrings.$k tem senha em texto puro (criptografar com DPAPI)" }
    }

    $rmq = $cfg.RabbitMQ
    if ($rmq.Host -match '^rabbitmq://([^/:]+)(:\d+)?/?(.*)$') {
        $rmqServidor = $matches[1]; $rmqVhost = if ($matches[3]) { $matches[3] } else { '/' }
        Ok "RabbitMQ: servidor $rmqServidor, vhost $rmqVhost, usuario $($rmq.Username)"
        if ($rmqVhost -match '(?i)staging') { Aviso "RabbitMQ vhost '$rmqVhost' (de staging?)" }
    } else { Erro "RabbitMQ.Host invalido: '$($rmq.Host)'" }
    $p = Segredo $rmq.Password
    if (-not $p.Ok) { Erro 'RabbitMQ.Password criptografada e NAO abre nesta maquina (gerar de novo aqui)' }
    elseif (-not $p.Valor) { if ($env:RabbitMQ__Password) { Ok 'RabbitMQ.Password via variavel de ambiente' } else { Erro 'RabbitMQ.Password vazia (como servico nao ha User Secrets: criptografar no appsettings)' } }
    elseif (-not $p.Cripto) { Aviso 'RabbitMQ.Password em texto puro (recomendado: criptografar com DPAPI)' }
    else { Ok 'RabbitMQ.Password criptografada e abre nesta maquina' }

    $g = $cfg.Graph
    if ($g.TenantId -and $g.ClientId) { Ok 'Graph TenantId e ClientId preenchidos' } else { Erro 'Graph TenantId/ClientId vazios' }
    $gs = Segredo $g.ClientSecret
    if ($g.CertificateThumbprint) { Ok 'Graph usa certificado (CertificateThumbprint)' }
    elseif (-not $gs.Ok) { Erro 'Graph.ClientSecret criptografado e NAO abre nesta maquina (gerar de novo aqui)' }
    elseif (-not $gs.Valor) { if ($env:Graph__ClientSecret) { Ok 'Graph.ClientSecret via variavel de ambiente' } else { Erro 'Graph.ClientSecret vazio (como servico nao ha User Secrets)' } }
    elseif (-not $gs.Cripto) { Aviso 'Graph.ClientSecret em texto puro (recomendado: criptografar com DPAPI)' }
    else { Ok 'Graph.ClientSecret criptografado e abre nesta maquina' }

    foreach ($k in 'Temp', 'Attachments') {
        $dir = $cfg.Files.$k
        if (-not $dir) { Erro "Files.$k vazio"; continue }
        if (-not (Test-Path $dir)) { Erro "Files.$k nao existe: $dir"; continue }
        try { $t = Join-Path $dir ('ltdev2-teste-' + [guid]::NewGuid() + '.tmp'); Set-Content $t 'x'; Remove-Item $t; Ok "Files.$k existe e aceita escrita (com a conta atual): $dir" }
        catch { Erro "Files.$k sem permissao de escrita: $dir" }
    }
    if ($cfg.Integration -and (($cfg.Integration.PSObject.Properties.Value) -match 'localhost')) { Aviso 'Integration.*Url com localhost (usar as URLs do ambiente)' }

    $guid = $cfg.ServiceUser.UserName
    if ($guid -match '^[0-9a-fA-F-]{36}$') { Ok "ServiceUser.UserName: $guid" } else { Erro "ServiceUser.UserName nao e um GUID: '$guid'" }

    # ------------------------------------------------------------------ NLog.config
    Titulo 'NLog.config'
    $nlogTexto = Get-Content $nlgF -Raw -Encoding UTF8
    try {
        [xml]$nx = $nlogTexto
        $ns = New-Object Xml.XmlNamespaceManager($nx.NameTable); $ns.AddNamespace('n', 'http://www.nlog-project.org/schemas/NLog.xsd')
        $targets = @($nx.SelectNodes('//n:targets/n:target', $ns) | ForEach-Object { $_.name })
        $regras  = @($nx.SelectNodes('//n:rules/n:logger', $ns))
        Ok "destinos: $($targets -join ', ')"
        if (-not $regras) { Erro 'nenhuma regra <logger> ativa: nada sera gravado' }
        foreach ($r in $regras) {
            $faltam = @($r.writeTo -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $targets -notcontains $_ })
            if ($faltam) { Erro "regra writeTo='$($r.writeTo)' aponta para destino(s) inexistente(s): $($faltam -join ', ') (nada e gravado neles)" }
            else { Ok "regra minlevel=$($r.minlevel) writeTo=$($r.writeTo)" }
        }
        $db = $nx.SelectSingleNode("//n:targets/n:target[@name='database' or contains(@*[local-name()='type'],'Database')]", $ns)
        if ($db) {
            if ($db.commandText -match "@MachineName,\s*'([^']*)'") {
                $svcLog = $matches[1]
                if ($svcLog -match '(?i)EmailIndexing') { Ok "ServiceName no LogDB: '$svcLog'" } else { Erro "ServiceName no LogDB e '$svcLog' (de outro servico): usar 'EmailIndexingService'" }
            }
        }
        $arq = $nx.SelectNodes('//n:targets/n:target', $ns) | Where-Object { $_.Attributes['xsi:type'].Value -eq 'File' -or $_.OuterXml -match 'xsi:type="File"' } | Select-Object -First 1
        if ($arq -and ($arq.archiveEvery -eq 'Minute')) { Aviso "archiveEvery='Minute': so os ultimos $($arq.maxArchiveFiles) minutos de log ficam (usar 'Day')" }
        if ($nx.nlog.internalLogLevel -eq 'Debug' -or $nx.nlog.internalLogLevel -eq 'Trace') { Aviso "internalLogLevel='$($nx.nlog.internalLogLevel)' (usar 'Warn')" }
        if ($nlogTexto -match 'NLog\.Web\.AspNetCore') { Erro 'extensao NLog.Web.AspNetCore: o servico nao e ASP.NET (remover o bloco <extensions>)' }
    } catch { Erro "NLog.config invalido: $($_.Exception.Message)" }

    # ------------------------------------------------------------------ bancos (somente leitura)
    Titulo "Bancos (somente leitura, com a conta atual: $env:USERDOMAIN\$env:USERNAME)"
    if ($cs[$chave]) {
        try {
            [void](Escalar $cs[$chave] 'select 1'); Ok "acesso ao banco principal ($(DescreveCs $cs[$chave]))"
            if ((Escalar $cs[$chave] "select COL_LENGTH('ParameterRoot','EmailIndexingMailbox')") -is [DBNull]) { Erro 'scripts do LTDEV-2 nao executados neste banco (ParameterRoot sem EmailIndexing*)' }
            else {
                $u = Escalar $cs[$chave] 'select count(*) from usr.UserX where UniqueId = @g and IsActive = 1' @{ '@g' = $guid }
                if ($u -eq 0) { Erro "usuario de servico $guid nao existe ou esta inativo neste banco" }
                else {
                    $login = Escalar $cs[$chave] 'select UserName from usr.UserX where UniqueId = @g' @{ '@g' = $guid }
                    Ok "usuario de servico: $login"
                    $ops = Escalar $cs[$chave] @'
select count(distinct goa.OperationId) from usr.GroupUserOperationAccess goa
join usr.GroupUser gu on gu.Id = goa.GroupUserId join usr.GroupUserAccess gua on gua.GroupUserId = gu.Id
where goa.IsDeleted = 0 and gua.IsDeleted = 0 and gua.UserId = (select Id from usr.UserX where UniqueId = @g)
'@ @{ '@g' = $guid }
                    if ($ops -eq 0) { Erro "usuario de servico sem acesso a NENHUMA operacao (nao encontra nenhum sinistro)" } else { Ok "usuario de servico com acesso a $ops operacao(oes)" }
                    $mb = Escalar $cs[$chave] 'select EmailIndexingMailbox from ParameterRoot where RootId = (select RootId from usr.UserX where UniqueId = @g)' @{ '@g' = $guid }
                    if ($mb -is [DBNull] -or -not $mb) { Erro 'ParameterRoot do pais sem EmailIndexingMailbox (o servico nao varre)' } else { Ok "caixa monitorada: $mb" }
                }
            }
        } catch { Erro "banco principal: $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
    }
    if ($cs['LogConnection']) {
        try {
            if ((Escalar $cs['LogConnection'] "select object_id('dbo.Logs')") -is [DBNull]) { Aviso 'banco de log sem a tabela dbo.Logs' } else { Ok "banco de log com dbo.Logs ($(DescreveCs $cs['LogConnection']))" }
        } catch { Aviso "banco de log inacessivel com a conta atual: $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
    }
    if ($cs['LocalizationsConnection']) {
        try { [void](Escalar $cs['LocalizationsConnection'] 'select 1'); Ok "banco de traducoes ($(DescreveCs $cs['LocalizationsConnection']))" }
        catch { Aviso "banco de traducoes inacessivel com a conta atual (mensagens sairiam com a chave): $($_.Exception.InnerException.Message)$($_.Exception.Message)" }
    }

    # ------------------------------------------------------------------ servidor
    Titulo 'Servidor'
    if ($rmqServidor) {
        if (Test-NetConnection $rmqServidor -Port 5672 -InformationLevel Quiet -WarningAction SilentlyContinue) { Ok "RabbitMQ responde em ${rmqServidor}:5672" } else { Erro "RabbitMQ NAO responde em ${rmqServidor}:5672" }
    }
    if ($igcc) { Aviso 'variavel IGCCSVC_DB (Intel) presente: o contorno sera aplicado ao servico' } else { Ok 'sem a variavel IGCCSVC_DB (Intel)' }
    $existente = Get-Service -Name $nome -ErrorAction SilentlyContinue
    if ($existente) { Aviso "servico '$nome' ja instalado (status $($existente.Status)): sera reinstalado" }

    # ------------------------------------------------------------------ resumo
    Titulo 'Resumo'
    "ERROS: $script:erros | ATENCAO: $script:avisos"
    if ($SoVerificar) { Write-Host "`nSo verificacao (-SoVerificar): nada foi instalado." -ForegroundColor Green; return }
    if ($script:erros) { throw 'Ha ERROS: corrija e rode de novo (nada foi instalado).' }
    if (-not $admin) { throw 'Para instalar, abra o PowerShell como administrador.' }
    if ((Read-Host "Instalar '$nome' agora? Digite S para continuar") -notmatch '^[sS]') { throw 'Cancelado pelo usuario.' }

    # ------------------------------------------------------------------ instalacao
    Titulo 'Instalacao'
    $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" -Message 'Conta do servico (com acesso aos bancos; precisa ter senha)'
    if (-not $cred.GetNetworkCredential().Password) { throw 'Conta sem senha: o Windows nao permite servico com conta sem senha.' }
    $sid = (New-Object Security.Principal.NTAccount($cred.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
    $tmp = Join-Path $env:TEMP 'ltdev2-secedit'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    secedit /export /cfg "$tmp\atual.inf" /areas USER_RIGHTS | Out-Null
    $linha = Get-Content "$tmp\atual.inf" | Where-Object { $_ -like 'SeServiceLogonRight*' }
    if (-not ($linha -and $linha -match [regex]::Escape("*$sid"))) {
        $nova = if ($linha) { "$linha,*$sid" } else { "SeServiceLogonRight = *$sid" }
        @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1', '[Privilege Rights]', $nova) | Set-Content "$tmp\novo.inf" -Encoding Unicode
        secedit /configure /db "$tmp\novo.sdb" /cfg "$tmp\novo.inf" /areas USER_RIGHTS /quiet | Out-Null
        Ok "direito 'Fazer logon como servico' concedido a $($cred.UserName)"
    }
    if ($existente) { Stop-Service -Name $nome -Force -ErrorAction SilentlyContinue; & $exe uninstall | Out-Null; Start-Sleep -Seconds 2 }
    & $exe install -username "$($cred.UserName)" -password "$($cred.GetNetworkCredential().Password)"
    if ($LASTEXITCODE -ne 0) { throw "install retornou $LASTEXITCODE" }
    if ($igcc) {
        New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$nome" -Name Environment -PropertyType MultiString -Force -Value @('IGCCSVC_DB=nao-usado-pelo-EmailIndexingService') | Out-Null
        Ok 'contorno IGCCSVC_DB aplicado ao servico'
    }

    Titulo 'Inicio e primeira varredura (aguarda 60 s)'
    $inicio = Get-Date
    Start-Service -Name $nome
    Start-Sleep -Seconds 60
    Get-CimInstance Win32_Service -Filter "Name='$nome'" | Format-List Name, State, StartMode, StartName | Out-String
    Get-ChildItem (Join-Path $Pasta 'log') -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $inicio -and $_.Name -notmatch 'internal' } |
        ForEach-Object { "-- log\$($_.Name)"; Get-Content $_.FullName -Tail 15 }
    $int = Join-Path $Pasta 'log\internal-nlog.txt'
    if ((Test-Path $int) -and (Get-Item $int).LastWriteTime -ge $inicio) { '-- log\internal-nlog.txt (problemas do NLog)'; Get-Content $int -Tail 8 }
    Get-WinEvent -FilterHashtable @{LogName = 'Application'; StartTime = $inicio} -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'EmailIndexing|\.NET Runtime|Application Error' -and $_.LevelDisplayName -ne 'Informações' -and $_.Level -le 3 } |
        Select-Object -First 3 | ForEach-Object { $m = $_.Message -replace '\s+', ' '; "Evento: " + $m.Substring(0, [Math]::Min(700, $m.Length)) }
    Write-Host "`nInstalado. Para remover: -Desinstalar" -ForegroundColor Green
}
catch { Write-Host "`nFALHA: $($_.Exception.Message)" -ForegroundColor Red }
finally {
    Stop-Transcript | Out-Null
    Write-Host "Resultado salvo em: $saida" -ForegroundColor Green
}
