<#
.SINOPSE
    Varre a pasta do backup separado (um .sql por objeto), separa apenas os
    arquivos que o projeto da branch usa, joga numa pasta com o nome da branch
    e compacta, pronto para commit.

.DESCRICAO
    Le o manifesto LTDEV-2_objetos.csv, procura na pasta atual (ou na informada
    em -Origem) o .sql de cada objeto da lista e organiza a copia em:

        <Destino>\<Branch>\
            Tables\
            Views\
            Procedures\
            Triggers\
            Scripts_LTDEV-2\        (se usar -IncluirScriptsRepo)
            _MANIFESTO.txt          (o que veio, o que faltou, o que e manual)

    e depois gera <Destino>\<Branch>.zip.

    Por padrao COPIA os arquivos. Use -Mover para de fato mover (tira do backup
    de origem). O padrao e copiar porque mover altera o backup e nao da para
    rodar de novo se a lista mudar.

.EXEMPLO
    # 1) sempre primeiro: nao escreve nada, so mostra o que achou e o que falta
    cd D:\backup_crawford
    .\LTDEV-2_coletar.ps1 -Simular

    # 2) valendo, copiando (recomendado)
    .\LTDEV-2_coletar.ps1

    # 3) movendo de verdade, como voce pediu
    .\LTDEV-2_coletar.ps1 -Mover

    # 4) escopo completo (auditoria + service broker) e nome da branch pelo repo
    .\LTDEV-2_coletar.ps1 -Nivel Completo -Repo "C:\...\Crawford\BRSCloud-Backend"
#>

[CmdletBinding()]
param(
    # Pasta raiz do backup separado. Padrao: a pasta onde voce esta.
    [string] $Origem = (Get-Location).Path,

    # Onde criar a pasta da branch e o .zip. Padrao: a mesma pasta de origem.
    [string] $Destino,

    # Nome da branch = nome da pasta. Se -Repo for informado, e lido do git.
    [string] $Branch = 'LTDEV-2',

    # Repositorio git de onde ler o nome da branch atual (opcional).
    [string] $Repo,

    # Manifesto. Padrao: o CSV ao lado deste script.
    [string] $Manifesto,

    # Minimo   = so o nucleo do fluxo
    # Padrao   = nucleo + joins de sinistro e permissao   <- recomendado
    # Completo = tudo, inclusive auditoria e service broker
    [ValidateSet('Minimo', 'Padrao', 'Completo')]
    [string] $Nivel = 'Padrao',

    # Mover em vez de copiar. ATENCAO: remove os arquivos da pasta de origem.
    [switch] $Mover,

    # Inclui tambem os 3 scripts do LTDEV-2 que estao no repositorio.
    [switch] $IncluirScriptsRepo,

    [string] $ScriptsLtdev2 = 'C:\Users\user\OneDrive\Backup Note\Projetos\Antlia\Crawford\BRSCloud-Backend\OneCrawford.Infra.Database.SqlServer\scripts\2026',

    # Nao escreve nada: so relata.
    [switch] $Simular,

    # Sobrescreve a pasta/zip se ja existirem.
    [switch] $Forcar
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ preparacao
$raizScript = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $Manifesto) { $Manifesto = Join-Path $raizScript 'LTDEV-2_objetos.csv' }
if (-not $Destino)   { $Destino   = $Origem }

if (-not (Test-Path $Manifesto)) { throw "Manifesto nao encontrado: $Manifesto" }
if (-not (Test-Path $Origem))    { throw "Pasta de origem nao encontrada: $Origem" }

# Nome da branch a partir do git, se pedido.
if ($Repo) {
    if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "Nao parece um repositorio git: $Repo" }
    $branchGit = (& git -C $Repo rev-parse --abbrev-ref HEAD) 2>$null
    if ($LASTEXITCODE -eq 0 -and $branchGit) {
        $Branch = $branchGit.Trim()
    } else {
        Write-Warning "Nao consegui ler a branch do git; usando '$Branch'."
    }
}

# Nome de pasta seguro (branch pode ter barra, ex.: feature/LTDEV-2).
$branchPasta = ($Branch -replace '[\\/:*?"<>|]', '-')

$pastaDestino = Join-Path $Destino $branchPasta
$arquivoZip   = Join-Path $Destino ($branchPasta + '.zip')

function Escrever {
    param([string] $Texto, [string] $Cor = 'Gray')
    Write-Host $Texto -ForegroundColor $Cor
}

Escrever '================================================================' 'Cyan'
Escrever ' Coleta dos .sql do projeto -> pasta da branch -> zip' 'Cyan'
Escrever " Origem  : $Origem"
Escrever " Destino : $pastaDestino"
Escrever " Zip     : $arquivoZip"
Escrever " Branch  : $Branch"
Escrever " Nivel   : $Nivel"
if ($Mover)   { Escrever ' MODO    : MOVER (os arquivos SAEM da origem)' 'Yellow' }
else          { Escrever ' MODO    : COPIAR (a origem fica intacta; use -Mover para mover)' }
if ($Simular) { Escrever ' SIMULACAO: nada sera escrito' 'Yellow' }
Escrever '================================================================' 'Cyan'

# ------------------------------------------------------- indice dos arquivos
Escrever ''
Escrever 'Indexando os .sql da origem (pode demorar num backup grande)...'
$arquivos = Get-ChildItem -Path $Origem -Filter *.sql -Recurse -File |
    Where-Object { $_.FullName -notlike "$pastaDestino*" }   # nao reindexar o proprio destino
Escrever "  $($arquivos.Count) arquivos .sql encontrados."

# SSMS nomeia "schema.Objeto.Tipo.sql". Indexamos por cada segmento do nome,
# deduplicado, para casar tanto esse formato quanto "Objeto.sql".
$indice = @{}
foreach ($a in $arquivos) {
    $baseNome = [System.IO.Path]::GetFileNameWithoutExtension($a.Name)
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
    if ($Schema) {
        $k = "$Schema.$Objeto".ToLowerInvariant()
        if ($indice.ContainsKey($k)) { return $indice[$k] }
    }
    $k = $Objeto.ToLowerInvariant()
    if ($indice.ContainsKey($k)) { return $indice[$k] }
    return $null
}

# Subpasta de destino por tipo de objeto.
function Subpasta-De {
    param([string] $Tipo)
    switch ($Tipo) {
        'TABLE'         { return 'Tables' }
        'VIEW'          { return 'Views' }
        'PROCEDURE'     { return 'Procedures' }
        'FUNCTION'      { return 'Functions' }
        'TRIGGER'       { return 'Triggers' }
        'SCRIPT_LTDEV2' { return "Scripts_$branchPasta" }
        default         { return 'Outros' }
    }
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

# ------------------------------------------------------------- planejamento
$aCopiar    = New-Object System.Collections.ArrayList
$naoAchados = New-Object System.Collections.ArrayList
$ambiguos   = New-Object System.Collections.ArrayList
$manuais    = New-Object System.Collections.ArrayList

foreach ($linha in $selecionadas) {

    if ($linha.tipo -in @('DATABASE', 'SCHEMA', 'BROKER_PREREQ', 'MESSAGE_TYPE', 'CONTRACT', 'QUEUE', 'SERVICE')) {
        [void] $manuais.Add($linha)
        continue
    }

    if ($linha.tipo -eq 'SCRIPT_LTDEV2') {
        if (-not $IncluirScriptsRepo) { continue }
        $caminho = Join-Path $ScriptsLtdev2 $linha.objeto
        if (Test-Path $caminho) {
            [void] $aCopiar.Add([pscustomobject]@{
                Ordem = [int] $linha.ordem; Tipo = $linha.tipo; Objeto = $linha.objeto
                Banco = $linha.banco; Arquivo = (Get-Item $caminho); DoRepo = $true
            })
        } else {
            [void] $naoAchados.Add($linha)
        }
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
    [void] $aCopiar.Add([pscustomobject]@{
        Ordem = [int] $linha.ordem; Tipo = $linha.tipo; Objeto = $linha.objeto
        Banco = $linha.banco; Arquivo = $achados[0]; DoRepo = $false
    })
}

Escrever ''
Escrever '--- PLANO -------------------------------------------------------' 'Cyan'
if ($Mover) { $verboPlano = 'mover ' } else { $verboPlano = 'copiar' }
Escrever "  Arquivos a $verboPlano : $($aCopiar.Count)"
Escrever "  Nao encontrados   : $($naoAchados.Count)"
Escrever "  Nome ambiguo      : $($ambiguos.Count)"
Escrever "  Tratamento manual : $($manuais.Count)"

if ($naoAchados.Count -gt 0) {
    Escrever ''
    Escrever 'NAO ENCONTRADOS na origem (nome pode diferir no ambiente real):' 'Yellow'
    foreach ($n in $naoAchados) { Escrever "   [$($n.tipo)] $($n.schema).$($n.objeto)" 'Yellow' }
}

if ($ambiguos.Count -gt 0) {
    Escrever ''
    Escrever 'NOME AMBIGUO - mais de um arquivo casou. Sera usado o primeiro:' 'Yellow'
    foreach ($am in $ambiguos) {
        Escrever "   $($am.Linha.objeto):" 'Yellow'
        foreach ($f in $am.Arquivos) { Escrever "      $($f.FullName)" 'DarkYellow' }
    }
}

if ($Simular) {
    Escrever ''
    Escrever 'Seria montado assim:' 'Cyan'
    foreach ($item in ($aCopiar | Sort-Object Ordem)) {
        Escrever ("   {0}\{1}  <- {2}" -f (Subpasta-De $item.Tipo), $item.Arquivo.Name, $item.Arquivo.FullName)
    }
    Escrever ''
    Escrever 'SIMULACAO: nada foi escrito.' 'Yellow'
    return
}

if ($aCopiar.Count -eq 0) { throw 'Nenhum arquivo encontrado para coletar. Confira -Origem e o formato do backup.' }

# ------------------------------------------------------------ pasta destino
if (Test-Path $pastaDestino) {
    if (-not $Forcar) { throw "A pasta ja existe: $pastaDestino`nUse -Forcar para sobrescrever." }
    Escrever ''
    Escrever "Removendo pasta anterior: $pastaDestino" 'Yellow'
    Remove-Item $pastaDestino -Recurse -Force
}
New-Item -ItemType Directory -Path $pastaDestino -Force | Out-Null

Escrever ''
Escrever '--- COLETA ------------------------------------------------------' 'Cyan'

$copiados = New-Object System.Collections.ArrayList
foreach ($item in ($aCopiar | Sort-Object Ordem)) {
    $sub = Subpasta-De $item.Tipo
    $pastaSub = Join-Path $pastaDestino $sub
    if (-not (Test-Path $pastaSub)) { New-Item -ItemType Directory -Path $pastaSub -Force | Out-Null }
    $alvo = Join-Path $pastaSub $item.Arquivo.Name

    # Nunca mover os scripts do repositorio - eles sao versionados la.
    if ($Mover -and -not $item.DoRepo) {
        Move-Item -LiteralPath $item.Arquivo.FullName -Destination $alvo -Force
        $verbo = 'MOVIDO '
    } else {
        Copy-Item -LiteralPath $item.Arquivo.FullName -Destination $alvo -Force
        $verbo = 'COPIADO'
    }
    Escrever "   $verbo [$($item.Tipo)] $($item.Objeto)"
    [void] $copiados.Add([pscustomobject]@{
        Tipo = $item.Tipo; Objeto = $item.Objeto; Banco = $item.Banco
        Destino = "$sub\$($item.Arquivo.Name)"; OrigemCompleta = $item.Arquivo.FullName
    })
}

# ------------------------------------------------------------- manifesto txt
$linhasManifesto = New-Object System.Collections.ArrayList
[void] $linhasManifesto.Add('================================================================')
[void] $linhasManifesto.Add(" Pacote SQL - branch $Branch")
[void] $linhasManifesto.Add('================================================================')
[void] $linhasManifesto.Add("Gerado em : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
[void] $linhasManifesto.Add("Origem    : $Origem")
[void] $linhasManifesto.Add("Nivel     : $Nivel")
if ($Mover) { [void] $linhasManifesto.Add('Modo      : MOVER (arquivos retirados da origem)') }
else        { [void] $linhasManifesto.Add('Modo      : COPIAR') }
[void] $linhasManifesto.Add('')
[void] $linhasManifesto.Add("ARQUIVOS NO PACOTE ($($copiados.Count))")
[void] $linhasManifesto.Add('----------------------------------------------------------------')
foreach ($c in $copiados) {
    [void] $linhasManifesto.Add(("  [{0}] {1}  ->  {2}   (banco: {3})" -f $c.Tipo, $c.Objeto, $c.Destino, $c.Banco))
}
if ($naoAchados.Count -gt 0) {
    [void] $linhasManifesto.Add('')
    [void] $linhasManifesto.Add("NAO ENCONTRADOS NA ORIGEM ($($naoAchados.Count))")
    [void] $linhasManifesto.Add('----------------------------------------------------------------')
    foreach ($n in $naoAchados) { [void] $linhasManifesto.Add(("  [{0}] {1}.{2}   -- {3}" -f $n.tipo, $n.schema, $n.objeto, $n.observacao)) }
}
if ($manuais.Count -gt 0) {
    [void] $linhasManifesto.Add('')
    [void] $linhasManifesto.Add("NAO SAO ARQUIVOS - TRATAMENTO MANUAL ($($manuais.Count))")
    [void] $linhasManifesto.Add('----------------------------------------------------------------')
    foreach ($m in $manuais) { [void] $linhasManifesto.Add(("  [{0}] {1}   -- {2}" -f $m.tipo, $m.objeto, $m.observacao)) }
    [void] $linhasManifesto.Add('')
    [void] $linhasManifesto.Add('  Service Broker: scripts em')
    [void] $linhasManifesto.Add('  BRSCloud-Backend\OneCrawford.Infra.Database.SqlServer\MessageBroker\')
    [void] $linhasManifesto.Add('  Sem o broker habilitado, as triggers de auditoria fazem a gravacao')
    [void] $linhasManifesto.Add('  do anexo FALHAR.')
}
[void] $linhasManifesto.Add('')
[void] $linhasManifesto.Add('ATENCAO: estes arquivos vem de backup de maquina de cliente e podem')
[void] $linhasManifesto.Add('conter dado pessoal nos INSERTs. Confira antes de commitar.')
[void] $linhasManifesto.Add('================================================================')

$caminhoManifesto = Join-Path $pastaDestino '_MANIFESTO.txt'
Set-Content -Path $caminhoManifesto -Value $linhasManifesto -Encoding utf8

# -------------------------------------------------------------------- zip
Escrever ''
Escrever 'Compactando...'
if (Test-Path $arquivoZip) {
    if (-not $Forcar) { throw "O zip ja existe: $arquivoZip`nUse -Forcar para sobrescrever." }
    Remove-Item $arquivoZip -Force
}
Compress-Archive -Path (Join-Path $pastaDestino '*') -DestinationPath $arquivoZip -CompressionLevel Optimal

$tamanhoMb = [math]::Round((Get-Item $arquivoZip).Length / 1MB, 2)

# ----------------------------------------------------------------- resumo
Escrever ''
Escrever '--- RESUMO ------------------------------------------------------' 'Cyan'
Escrever "  Pasta      : $pastaDestino"
Escrever "  Zip        : $arquivoZip  ($tamanhoMb MB)"
Escrever "  Arquivos   : $($copiados.Count)"
Escrever "  Faltando   : $($naoAchados.Count)"
Escrever "  Manual     : $($manuais.Count)"
Escrever "  Manifesto  : $caminhoManifesto"
if ($naoAchados.Count -gt 0) {
    Escrever ''
    Escrever "  $($naoAchados.Count) objeto(s) da lista nao foram achados - veja o _MANIFESTO.txt." 'Yellow'
}
Escrever ''
Escrever '  Antes de commitar: confira se ha dado pessoal do cliente nos INSERTs.' 'Yellow'
