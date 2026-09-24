<#
.SINOPSE
    Restaura seletivamente os objetos do LTDEV-2 a partir de um backup gerado
    pelo SSMS no modo "um arquivo .sql por objeto".

.DESCRICAO
    Le o manifesto LTDEV-2_objetos.csv, localiza o .sql de cada objeto dentro da
    pasta do backup e executa via sqlcmd, na ordem do manifesto.

    Executa em varias passadas: se um arquivo falhar por dependencia (FK, view
    que referencia tabela ainda nao criada), ele volta para a fila e e tentado de
    novo na passada seguinte. Isso resolve a maior parte dos problemas de ordem
    sem precisar desabilitar constraint.

.EXEMPLO
    # 1) sempre comece assim: nao executa nada, so mostra o que achou e o que falta
    .\LTDEV-2_restaurar.ps1 -Origem "D:\backup_crawford" -Servidor "localhost" -Simular

    # 2) restauracao do conjunto minimo
    .\LTDEV-2_restaurar.ps1 -Origem "D:\backup_crawford" -Servidor "localhost"

    # 3) conjunto completo, incluindo auditoria/service broker
    .\LTDEV-2_restaurar.ps1 -Origem "D:\backup_crawford" -Servidor "localhost" -Nivel Completo

    # 4) com usuario e senha em vez de autenticacao integrada
    .\LTDEV-2_restaurar.ps1 -Origem "D:\backup_crawford" -Servidor "10.122.0.11" -Usuario sa
#>

[CmdletBinding()]
param(
    # Pasta raiz do backup separado (a busca e recursiva).
    [Parameter(Mandatory = $true)]
    [string] $Origem,

    # Instancia do SQL Server.
    [Parameter(Mandatory = $true)]
    [string] $Servidor,

    # Manifesto. Por padrao, o CSV ao lado deste script.
    [string] $Manifesto,

    # Nome real dos bancos no seu ambiente.
    [string] $BancoPrincipal = 'OneCrawfordDB',
    [string] $BancoLocalizations = 'LocalizationsDB',

    # Pasta dos scripts do proprio LTDEV-2 (no repositorio).
    [string] $ScriptsLtdev2 = 'C:\Users\user\OneDrive\Backup Note\Projetos\Antlia\Crawford\BRSCloud-Backend\OneCrawford.Infra.Database.SqlServer\scripts\2026',

    # Minimo   = so o que esta marcado "sim" (nucleo do fluxo)
    # Padrao   = "sim" + "medio" (inclui joins de sinistro e permissao)  <- recomendado
    # Completo = tudo, inclusive auditoria e service broker
    [ValidateSet('Minimo', 'Padrao', 'Completo')]
    [string] $Nivel = 'Padrao',

    # Autenticacao SQL. Se omitido, usa autenticacao integrada do Windows.
    [string] $Usuario,
    [string] $Senha,

    # Nao executa nada: so relata o que seria feito e o que nao foi encontrado.
    [switch] $Simular,

    # Quantas passadas de retentativa para resolver dependencias.
    [int] $Passadas = 3,

    # Pasta onde gravar o log da execucao.
    [string] $PastaLog
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ preparacao
$raizScript = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $Manifesto) { $Manifesto = Join-Path $raizScript 'LTDEV-2_objetos.csv' }
if (-not $PastaLog)  { $PastaLog  = Join-Path $raizScript 'log_restauracao' }

if (-not (Test-Path $Manifesto)) { throw "Manifesto nao encontrado: $Manifesto" }
if (-not (Test-Path $Origem))    { throw "Pasta de origem nao encontrada: $Origem" }

$sqlcmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
if (-not $sqlcmd) { throw 'sqlcmd.exe nao encontrado no PATH. Instale as SQL Server Command Line Utilities.' }

if (-not (Test-Path $PastaLog)) { New-Item -ItemType Directory -Path $PastaLog -Force | Out-Null }
$carimbo = Get-Date -Format 'yyyyMMdd-HHmmss'
$arquivoLog = Join-Path $PastaLog "restauracao-$carimbo.log"

function Escrever {
    param([string] $Texto, [string] $Cor = 'Gray')
    Write-Host $Texto -ForegroundColor $Cor
    Add-Content -Path $arquivoLog -Value $Texto -Encoding utf8
}

Escrever "================================================================" 'Cyan'
Escrever " LTDEV-2 - restauracao seletiva" 'Cyan'
Escrever " Origem   : $Origem"
Escrever " Servidor : $Servidor"
Escrever " Nivel    : $Nivel"
if ($Simular) { Escrever " MODO     : SIMULACAO (nada sera executado)" 'Yellow' }
Escrever " Log      : $arquivoLog"
Escrever "================================================================" 'Cyan'

# ------------------------------------------------------- indice dos arquivos
Escrever ''
Escrever 'Indexando os .sql da pasta de origem...'
$arquivos = Get-ChildItem -Path $Origem -Filter *.sql -Recurse -File
Escrever "  $($arquivos.Count) arquivos .sql encontrados."

# SSMS nomeia como "schema.Objeto.Tipo.sql" (ex.: dbo.Attachment.Table.sql).
# Indexamos por cada segmento do nome, para casar tanto "dbo.Attachment.Table.sql"
# quanto "Attachment.sql".
$indice = @{}
foreach ($a in $arquivos) {
    $baseNome = [System.IO.Path]::GetFileNameWithoutExtension($a.Name)
    # Deduplica: um nome sem pontos gera o mesmo segmento duas vezes e, sem isso,
    # o arquivo apareceria como "ambiguo" consigo mesmo.
    $segmentos = @($baseNome) + ($baseNome -split '\.') |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.ToLowerInvariant() } |
        Select-Object -Unique
    foreach ($chave in $segmentos) {
        if (-not $indice.ContainsKey($chave)) { $indice[$chave] = New-Object System.Collections.ArrayList }
        if (-not $indice[$chave].Contains($a)) { [void] $indice[$chave].Add($a) }
    }
}

function Localizar-Arquivo {
    param([string] $Objeto, [string] $Schema)

    # 1) tenta "schema.objeto"
    if ($Schema) {
        $k = "$Schema.$Objeto".ToLowerInvariant()
        if ($indice.ContainsKey($k)) { return $indice[$k] }
    }
    # 2) tenta so o nome do objeto
    $k = $Objeto.ToLowerInvariant()
    if ($indice.ContainsKey($k)) { return $indice[$k] }
    return $null
}

# --------------------------------------------------------- selecao do escopo
$niveisAceitos = switch ($Nivel) {
    'Minimo'   { @('sim') }
    'Padrao'   { @('sim', 'medio') }
    'Completo' { @('sim', 'medio', 'condicional') }
}

$linhas = Import-Csv -Path $Manifesto -Delimiter ';' -Encoding UTF8
$selecionadas = $linhas |
    Where-Object { $niveisAceitos -contains $_.obrigatorio } |
    Sort-Object { [int] $_.ordem }

Escrever ''
Escrever "Manifesto: $($linhas.Count) linhas | selecionadas para o nivel '$Nivel': $($selecionadas.Count)"

function Resolver-Banco {
    param([string] $NomeNoManifesto)
    if ($NomeNoManifesto -eq 'LocalizationsDB') { return $BancoLocalizations }
    if ($NomeNoManifesto -eq 'LogDB')           { return 'LogDB' }
    return $BancoPrincipal
}

function Executar-Sql {
    param([string] $Caminho, [string] $Banco)

    $argumentos = @('-S', $Servidor, '-d', $Banco, '-i', $Caminho, '-b')
    if ($Usuario) {
        $argumentos += @('-U', $Usuario)
        if ($Senha) { $argumentos += @('-P', $Senha) }
    } else {
        $argumentos += '-E'
    }
    $saida = & sqlcmd.exe @argumentos 2>&1
    return [pscustomobject]@{
        Ok    = ($LASTEXITCODE -eq 0)
        Saida = ($saida | Out-String).Trim()
    }
}

# ------------------------------------------------------------- planejamento
$fila        = New-Object System.Collections.ArrayList
$naoAchados  = New-Object System.Collections.ArrayList
$ambiguos    = New-Object System.Collections.ArrayList
$manuais     = New-Object System.Collections.ArrayList

foreach ($linha in $selecionadas) {

    # Linhas que nao correspondem a um arquivo do backup.
    if ($linha.tipo -in @('DATABASE', 'SCHEMA', 'BROKER_PREREQ')) {
        [void] $manuais.Add($linha)
        continue
    }

    # Scripts do proprio LTDEV-2: vem do repositorio, nao do backup.
    if ($linha.tipo -eq 'SCRIPT_LTDEV2') {
        $caminho = Join-Path $ScriptsLtdev2 $linha.objeto
        if (Test-Path $caminho) {
            [void] $fila.Add([pscustomobject]@{
                Ordem = [int] $linha.ordem; Tipo = $linha.tipo; Objeto = $linha.objeto
                Banco = (Resolver-Banco $linha.banco); Caminho = $caminho
            })
        } else {
            [void] $naoAchados.Add($linha)
        }
        continue
    }

    # Service Broker: os objetos estao nos scripts MessageBroker do repositorio,
    # nao no backup por objeto. Sinalizamos para tratamento manual.
    if ($linha.tipo -in @('MESSAGE_TYPE', 'CONTRACT', 'QUEUE', 'SERVICE')) {
        [void] $manuais.Add($linha)
        continue
    }

    $achados = Localizar-Arquivo -Objeto $linha.objeto -Schema $linha.schema
    if (-not $achados) {
        [void] $naoAchados.Add($linha)
        continue
    }
    if ($achados.Count -gt 1) {
        [void] $ambiguos.Add([pscustomobject]@{ Linha = $linha; Arquivos = $achados })
    }
    [void] $fila.Add([pscustomobject]@{
        Ordem = [int] $linha.ordem; Tipo = $linha.tipo; Objeto = $linha.objeto
        Banco = (Resolver-Banco $linha.banco); Caminho = $achados[0].FullName
    })
}

Escrever ''
Escrever '--- PLANO -------------------------------------------------------' 'Cyan'
Escrever "  Arquivos a executar : $($fila.Count)"
Escrever "  Nao encontrados     : $($naoAchados.Count)"
Escrever "  Nome ambiguo        : $($ambiguos.Count)"
Escrever "  Tratamento manual   : $($manuais.Count)"

if ($naoAchados.Count -gt 0) {
    Escrever ''
    Escrever 'NAO ENCONTRADOS no backup (confira se o nome difere no ambiente real):' 'Yellow'
    foreach ($n in $naoAchados) { Escrever "   [$($n.tipo)] $($n.schema).$($n.objeto)   -- $($n.observacao)" 'Yellow' }
}

if ($ambiguos.Count -gt 0) {
    Escrever ''
    Escrever 'NOME AMBIGUO - mais de um arquivo casou. Sera usado o primeiro:' 'Yellow'
    foreach ($am in $ambiguos) {
        Escrever "   $($am.Linha.objeto):" 'Yellow'
        foreach ($f in $am.Arquivos) { Escrever "      $($f.FullName)" 'DarkYellow' }
    }
}

if ($manuais.Count -gt 0) {
    Escrever ''
    Escrever 'TRATAMENTO MANUAL (nao sao arquivos do backup por objeto):' 'Magenta'
    foreach ($m in $manuais) { Escrever "   [$($m.tipo)] $($m.objeto)   -- $($m.observacao)" 'Magenta' }
    Escrever '   Service Broker: use os scripts em' 'Magenta'
    Escrever '   BRSCloud-Backend\OneCrawford.Infra.Database.SqlServer\MessageBroker\' 'Magenta'
    Escrever '   e habilite o broker antes das triggers:' 'Magenta'
    Escrever "   ALTER DATABASE [$BancoPrincipal] SET ENABLE_BROKER;" 'Magenta'
    Escrever "   ALTER DATABASE [$BancoPrincipal] SET TRUSTWORTHY ON;" 'Magenta'
}

if ($Simular) {
    Escrever ''
    Escrever 'Ordem de execucao que seria usada:' 'Cyan'
    foreach ($item in $fila) { Escrever ("   {0,4}  [{1}] {2} -> {3}" -f $item.Ordem, $item.Tipo, $item.Objeto, $item.Banco) }
    Escrever ''
    Escrever 'SIMULACAO: nada foi executado.' 'Yellow'
    Escrever "Log em: $arquivoLog"
    return
}

# --------------------------------------------------------------- execucao
Escrever ''
Escrever '--- EXECUCAO ----------------------------------------------------' 'Cyan'

$pendentes = $fila
$concluidos = New-Object System.Collections.ArrayList
$falhas = @()

for ($passada = 1; $passada -le $Passadas; $passada++) {

    if ($pendentes.Count -eq 0) { break }

    Escrever ''
    Escrever "Passada $passada de $Passadas  ($($pendentes.Count) pendentes)" 'Cyan'

    $aindaPendentes = New-Object System.Collections.ArrayList
    $falhas = @()

    foreach ($item in $pendentes) {
        $rotulo = "[$($item.Tipo)] $($item.Objeto)"
        $r = Executar-Sql -Caminho $item.Caminho -Banco $item.Banco
        if ($r.Ok) {
            Escrever "   OK    $rotulo" 'Green'
            [void] $concluidos.Add($item)
        } else {
            Escrever "   FALHA $rotulo" 'Red'
            $primeiraLinha = ($r.Saida -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($primeiraLinha) { Escrever "         $($primeiraLinha.Trim())" 'DarkRed' }
            Add-Content -Path $arquivoLog -Value "--- saida completa de $rotulo ---`r`n$($r.Saida)`r`n" -Encoding utf8
            [void] $aindaPendentes.Add($item)
            $falhas += $rotulo
        }
    }

    if ($aindaPendentes.Count -eq $pendentes.Count) {
        Escrever ''
        Escrever "Passada $passada nao resolveu nenhum item novo - parando as retentativas." 'Yellow'
        $pendentes = $aindaPendentes
        break
    }
    $pendentes = $aindaPendentes
}

# ----------------------------------------------------------------- resumo
Escrever ''
Escrever '--- RESUMO ------------------------------------------------------' 'Cyan'
Escrever "  Executados com sucesso : $($concluidos.Count)"
Escrever "  Falharam               : $($pendentes.Count)"
Escrever "  Nao encontrados        : $($naoAchados.Count)"
Escrever "  Tratamento manual      : $($manuais.Count)"

if ($pendentes.Count -gt 0) {
    Escrever ''
    Escrever 'AINDA COM FALHA apos as retentativas:' 'Red'
    foreach ($p in $pendentes) { Escrever "   [$($p.Tipo)] $($p.Objeto)" 'Red' }
    Escrever ''
    Escrever 'Causa mais comum: FK apontando para tabela que ficou fora da lista.' 'Yellow'
    Escrever 'O log tem a mensagem completa de cada falha.' 'Yellow'
}

Escrever ''
Escrever "Log completo em: $arquivoLog" 'Cyan'

if ($pendentes.Count -gt 0) { exit 1 }
exit 0
