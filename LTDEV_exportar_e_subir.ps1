<#
.SINOPSE
    Roda na maquina do cliente (terminal do VS Code). Exporta da CarolOneCrawfordDB
    SO O NECESSARIO para montar um ambiente de teste do LTDEV-2/72, gera um .sql
    pequeno (cabe no git) e, se pedido, faz commit e push.

    Estrategia de tamanho (por isso cabe no git):
      - Tabelas pequenas (<= -LimiteLinhas): dados COMPLETOS.
      - Tabelas grandes: apenas uma AMOSTRA (TOP -Amostra linhas), ancorada,
        quando a tabela tem ClaimId, nos sinistros com ClaimCode 'BR' + 8 digitos.
      - Schema (CREATE) sai via SMO, se disponivel, para todos os objetos do manifesto.

.AVISO
    - NAO foi testado contra um SQL Server real na maquina de origem deste script.
      Rode SEMPRE com -Simular primeiro. Sem -Simular, ele faz git add/commit/push.
    - Gera dado de cliente. Use um repositorio PRIVADO e TEMPORARIO, e apague depois.

.EXEMPLO
    # 1) dry-run: gera os .sql e mostra o plano, sem git
    .\LTDEV_exportar_e_subir.ps1 -Servidor "localhost" -RepoDir "C:\repo-temp" -Simular

    # 2) valendo: gera + commit + push
    .\LTDEV_exportar_e_subir.ps1 -Servidor "localhost" -RepoDir "C:\repo-temp"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Servidor,
    [Parameter(Mandatory = $true)] [string] $RepoDir,

    [string] $Banco = 'CarolOneCrawfordDB',
    [string] $Usuario,
    [string] $Senha,

    # Manifesto com a lista de objetos. Default: ao lado deste script.
    [string] $Manifesto,

    # Tabela com ate este numero de linhas vem inteira; acima, so amostra.
    [int] $LimiteLinhas = 2000,
    # Quantas linhas trazer das tabelas grandes.
    [int] $Amostra = 50,

    # Subpasta, dentro do repo, onde os .sql sao gravados.
    [string] $SubPasta = 'LTDEV-seed',

    [string] $Branch = 'main',
    [string] $MensagemCommit = 'LTDEV: seed de dados para ambiente de teste',

    [switch] $Simular
)

$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $Manifesto) { $Manifesto = Join-Path $raiz 'LTDEV_objetos.csv' }
if (-not (Test-Path $Manifesto)) { throw "Manifesto nao encontrado: $Manifesto" }
if (-not (Test-Path $RepoDir))   { throw "RepoDir nao encontrado: $RepoDir" }

if ($Usuario) {
    $connStr = "Server=$Servidor;Database=$Banco;User Id=$Usuario;Password=$Senha;TrustServerCertificate=True;Encrypt=True"
} else {
    $connStr = "Server=$Servidor;Database=$Banco;Integrated Security=True;TrustServerCertificate=True;Encrypt=True"
}

$destino = Join-Path $RepoDir $SubPasta
New-Item -ItemType Directory -Path $destino -Force | Out-Null
$arqDados = Join-Path $destino 'seed_dados.sql'

function Log($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }

Log "================================================================" Cyan
Log " LTDEV - exportar seed + (commit/push)" Cyan
Log "  Banco   : $Banco @ $Servidor"
Log "  RepoDir : $RepoDir  (subpasta $SubPasta)"
Log "  Corte   : <= $LimiteLinhas linhas = tabela inteira; acima = TOP $Amostra"
if ($Simular) { Log "  MODO    : SIMULACAO (gera .sql, NAO faz git)" Yellow }
Log "================================================================" Cyan

# --- conexao -----------------------------------------------------------------
$conn = New-Object System.Data.SqlClient.SqlConnection $connStr
try { $conn.Open() }
catch { Log "FALHA ao conectar: $($_.Exception.Message)" Red; return }

function Consulta($sql) {
    $c = $conn.CreateCommand(); $c.CommandText = $sql; $c.CommandTimeout = 300
    $t = New-Object System.Data.DataTable
    (New-Object System.Data.SqlClient.SqlDataAdapter $c).Fill($t) | Out-Null
    return $t
}

# --- tabelas do manifesto ----------------------------------------------------
$tabelas = Import-Csv $Manifesto -Delimiter ';' -Encoding UTF8 |
    Where-Object { $_.tipo -eq 'TABLE' -and $_.obrigatorio -in @('sim','medio') } |
    ForEach-Object { @{ schema = ($_.schema); nome = $_.objeto } }

Log ""
Log "Tabelas candidatas no manifesto: $($tabelas.Count)"

# --- formata um valor como literal T-SQL ------------------------------------
function Literal($valor, $tipo) {
    if ($valor -eq $null -or $valor -is [System.DBNull]) { return 'NULL' }
    switch -Regex ($tipo) {
        'bit'                             { if ([bool]$valor) { return '1' } else { return '0' } }
        'int|decimal|numeric|money|float|real|smallmoney|tinyint|bigint|smallint' { return ([string]$valor).Replace(',', '.') }
        'uniqueidentifier'                { return "'$valor'" }
        'binary|image|timestamp|rowversion' {
            $b = [byte[]]$valor
            return '0x' + (($b | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        'date|time'                       {
            $d = [datetime]$valor
            return "'" + $d.ToString('yyyy-MM-ddTHH:mm:ss.fff') + "'"
        }
        default {
            return "N'" + ([string]$valor).Replace("'", "''") + "'"
        }
    }
}

# --- gera o seed -------------------------------------------------------------
$sw = New-Object System.IO.StreamWriter($arqDados, $false, [Text.UTF8Encoding]::new($false))
$sw.WriteLine("-- LTDEV seed de dados - gerado $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$sw.WriteLine("-- Origem: $Banco. Amostra: tabelas > $LimiteLinhas linhas trazem apenas TOP $Amostra.")
$sw.WriteLine("SET NOCOUNT ON;")
$sw.WriteLine("EXEC sp_MSforeachtable 'ALTER TABLE ? NOCHECK CONSTRAINT ALL';")
$sw.WriteLine("GO")

$resumo = New-Object System.Collections.ArrayList
foreach ($t in $tabelas) {
    $full = "[$($t.schema)].[$($t.nome)]"
    # existe? conta linhas
    $chk = Consulta "IF OBJECT_ID('$full','U') IS NOT NULL SELECT p.rows FROM sys.partitions p WHERE p.object_id=OBJECT_ID('$full') AND p.index_id IN (0,1);"
    if ($chk.Rows.Count -eq 0) { [void]$resumo.Add([pscustomobject]@{ Tabela=$full; Linhas='-'; Modo='NAO EXISTE' }); continue }
    $n = [int64]$chk.Rows[0][0]

    $temClaimId = (Consulta "SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('$full') AND name='ClaimId'").Rows.Count -gt 0
    if ($n -le $LimiteLinhas) { $where = ''; $top = ''; $modo = "inteira ($n)" }
    elseif ($temClaimId) {
        $where = "WHERE ClaimId IN (SELECT TOP $Amostra Id FROM [$($t.schema)].[Claim] WHERE ClaimCode LIKE 'BR________' ORDER BY Id DESC)"
        $top = ''; $modo = "amostra por ClaimId"
    } else { $where = ''; $top = "TOP $Amostra"; $modo = "TOP $Amostra de $n" }

    [void]$resumo.Add([pscustomobject]@{ Tabela=$full; Linhas=$n; Modo=$modo })
    if ($Simular) { continue }

    $dados = Consulta "SELECT $top * FROM $full $where"
    if ($dados.Rows.Count -eq 0) { continue }
    $cols = @($dados.Columns | ForEach-Object { $_.ColumnName })
    $tipos = @($dados.Columns | ForEach-Object { $_.DataType.Name })
    $temIdentity = (Consulta "SELECT 1 FROM sys.identity_columns WHERE object_id=OBJECT_ID('$full')").Rows.Count -gt 0

    $sw.WriteLine("-- $full : $($dados.Rows.Count) linhas")
    if ($temIdentity) { $sw.WriteLine("SET IDENTITY_INSERT $full ON;") }
    $colList = ($cols | ForEach-Object { "[$_]" }) -join ', '
    foreach ($row in $dados.Rows) {
        $vals = for ($i = 0; $i -lt $cols.Count; $i++) { Literal $row[$i] $dados.Columns[$i].DataType.Name }
        $sw.WriteLine("INSERT INTO $full ($colList) VALUES (" + ($vals -join ', ') + ");")
    }
    if ($temIdentity) { $sw.WriteLine("SET IDENTITY_INSERT $full OFF;") }
    $sw.WriteLine("GO")
}
$sw.WriteLine("EXEC sp_MSforeachtable 'ALTER TABLE ? WITH CHECK CHECK CONSTRAINT ALL';")
$sw.WriteLine("GO")
$sw.Close()
$conn.Close()

Log ""
Log "=== PLANO POR TABELA ===" Cyan
$resumo | Format-Table -AutoSize
if (-not $Simular) {
    $mb = [math]::Round((Get-Item $arqDados).Length / 1MB, 2)
    Log "seed_dados.sql gerado: $mb MB" Green
}

# --- git ---------------------------------------------------------------------
if ($Simular) {
    Log ""
    Log "SIMULACAO: nada foi gerado nem commitado. Rode sem -Simular para valer." Yellow
    return
}

Log ""
Log "=== GIT ===" Cyan
Push-Location $RepoDir
try {
    & git add -- "$SubPasta"
    & git commit -m "$MensagemCommit"
    if ($LASTEXITCODE -ne 0) { Log "Nada a commitar ou commit falhou." Yellow }
    & git push origin $Branch
    if ($LASTEXITCODE -eq 0) { Log "Push OK para origin/$Branch." Green }
    else { Log "Push falhou - verifique o remoto/credenciais." Red }
} finally { Pop-Location }
