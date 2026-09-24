<#
.SINOPSE
    Diagnostico SOMENTE LEITURA: lista quantas linhas e quantos MB cada tabela
    da CarolOneCrawfordDB ocupa. Serve para decidir, antes de exportar, quais
    tabelas trazer inteiras (as pequenas de dominio) e quais so em amostra
    (as grandes de dado transacional).

    Nao escreve nada no banco. Usa metadados (sys.dm_db_partition_stats), entao
    e rapido mesmo em base grande - nao faz varredura de dados.

.EXEMPLO
    # autenticacao integrada do Windows
    .\LTDEV_diagnostico_tamanho.ps1 -Servidor "localhost"

    # usuario/senha SQL
    .\LTDEV_diagnostico_tamanho.ps1 -Servidor "10.122.0.11" -Usuario sa -Senha "..."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Servidor,

    [string] $Banco = 'CarolOneCrawfordDB',

    [string] $Usuario,
    [string] $Senha,

    # Se informado, salva a saida tambem neste arquivo (alem de mostrar na tela).
    [string] $SaidaCsv
)

$ErrorActionPreference = 'Stop'

# String de conexao: integrada por padrao, ou usuario/senha se informados.
if ($Usuario) {
    $connStr = "Server=$Servidor;Database=$Banco;User Id=$Usuario;Password=$Senha;TrustServerCertificate=True;Encrypt=True"
} else {
    $connStr = "Server=$Servidor;Database=$Banco;Integrated Security=True;TrustServerCertificate=True;Encrypt=True"
}

$sql = @"
SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    SUM(ps.row_count) AS [Rows],
    CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(12,1)) AS MB
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats ps
    ON ps.object_id = t.object_id AND ps.index_id IN (0,1)
GROUP BY s.name, t.name
ORDER BY MB DESC;
"@

$conn = New-Object System.Data.SqlClient.SqlConnection $connStr
try {
    $conn.Open()
} catch {
    Write-Host "FALHA ao conectar em $Banco @ $Servidor" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkRed
    return
}

$cmd = $conn.CreateCommand()
$cmd.CommandText = $sql
$cmd.CommandTimeout = 120
$rd = $cmd.ExecuteReader()

$linhas = New-Object System.Collections.ArrayList
while ($rd.Read()) {
    [void] $linhas.Add([pscustomobject]@{
        Schema = $rd['SchemaName']
        Tabela = $rd['TableName']
        Linhas = [int64]$rd['Rows']
        MB     = [decimal]$rd['MB']
    })
}
$rd.Close(); $conn.Close()

$totalMB = ($linhas | Measure-Object MB -Sum).Sum
$totalTab = $linhas.Count

Write-Host ""
Write-Host "CarolOneCrawfordDB - $totalTab tabelas, $([math]::Round($totalMB,1)) MB no total" -ForegroundColor Cyan
Write-Host ""
Write-Host "=== 25 MAIORES (as candidatas a amostra) ===" -ForegroundColor Yellow
$linhas | Select-Object -First 25 |
    Format-Table Schema, Tabela, Linhas, MB -AutoSize

Write-Host "=== tabelas pequenas: quantas cabem inteiras ===" -ForegroundColor Green
$pequenas = $linhas | Where-Object { $_.MB -le 5 }
Write-Host "  $($pequenas.Count) tabelas com <= 5 MB, somando $([math]::Round(($pequenas | Measure-Object MB -Sum).Sum,1)) MB"

if ($SaidaCsv) {
    $linhas | Export-Csv -Path $SaidaCsv -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Saida completa salva em: $SaidaCsv" -ForegroundColor Cyan
}
