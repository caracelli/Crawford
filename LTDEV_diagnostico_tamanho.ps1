<#
.SINOPSE
    Diagnostico SOMENTE LEITURA: lista quantas linhas e quantos MB cada tabela
    da CarolOneCrawfordDB ocupa. Serve para decidir, antes de exportar, o que
    trazer inteiro (tabelas pequenas de dominio) e o que so em amostra.

    Usa o sqlcmd (o mesmo motor do SSMS), com:
      -E  autenticacao integrada do Windows
      -N  criptografia obrigatoria
      -C  confiar no certificado do servidor
    Isso espelha exatamente a conexao do SSMS e evita o erro do driver legado
    do PowerShell em servidor com criptografia obrigatoria.

.EXEMPLO
    .\LTDEV_diagnostico_tamanho.ps1
    .\LTDEV_diagnostico_tamanho.ps1 -SaidaCsv ".\tamanhos.csv"
#>

[CmdletBinding()]
param(
    # Mesmo servidor/base que o SSMS usa. Ja preenchidos.
    [string] $Servidor = '10.122.0.11',
    [string] $Banco = 'CarolOneCrawfordDB',
    # Salva o resultado completo neste arquivo, alem de mostrar na tela.
    [string] $SaidaCsv
)

$ErrorActionPreference = 'Stop'

# sqlcmd disponivel?
$sqlcmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
if (-not $sqlcmd) {
    Write-Host "sqlcmd nao encontrado no PATH." -ForegroundColor Red
    Write-Host "Ele vem com o SSMS / 'SQL Server Command Line Utilities'. Abra o" -ForegroundColor Yellow
    Write-Host '"Developer Command Prompt" ou instale as ferramentas de linha de comando.' -ForegroundColor Yellow
    return
}

# Forca o protocolo TCP (tcp:). Sem isso o ODBC tenta Named Pipes e da erro 64
# em servidor que so aceita TCP - que e como o SSMS conecta.
if ($Servidor -notmatch '^(tcp:|np:|lpc:)') { $Alvo = "tcp:$Servidor" } else { $Alvo = $Servidor }

Write-Host ""
Write-Host "Conectando: $Banco @ $Alvo (Windows auth, criptografia obrigatoria)" -ForegroundColor Cyan

# 1) teste de conexao curto, com mensagem clara.
# Junta a saida num texto so antes de testar: com -notmatch num array o
# PowerShell devolvia os elementos que nao casavam (ex.: "1 rows affected"),
# o que dava falso "FALHA" mesmo com o OK= presente.
$teste = & sqlcmd -S $Alvo -d $Banco -E -N -C -b -h -1 -W -Q "SELECT 'OK='+DB_NAME();" 2>&1
$testeTxt = ($teste | Out-String)
if ($LASTEXITCODE -ne 0 -or ($testeTxt -notmatch 'OK=')) {
    Write-Host "FALHA ao conectar:" -ForegroundColor Red
    ($teste | Where-Object { $_ -and $_ -notmatch '^\s*$' }) | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkRed }
    Write-Host ""
    Write-Host "Confira o 'Server name' exato do SSMS e rode com -Servidor 'valor'." -ForegroundColor Yellow
    return
}
Write-Host "Conexao OK." -ForegroundColor Green

# 2) tamanho por tabela. Separador ';' para virar CSV direto.
$q = @"
SET NOCOUNT ON;
SELECT s.name + '.' + t.name AS Tabela,
       SUM(ps.row_count) AS Linhas,
       CAST(SUM(ps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(12,1)) AS MB
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats ps ON ps.object_id = t.object_id AND ps.index_id IN (0,1)
GROUP BY s.name, t.name
ORDER BY MB DESC;
"@

$saida = & sqlcmd -S $Alvo -d $Banco -E -N -C -b -s ";" -W -Q $q 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Erro na consulta:" -ForegroundColor Red
    $saida | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkRed }
    return
}

# sqlcmd devolve: linha de cabecalho, linha de tracos, dados, e um rodape em branco.
$linhas = $saida | Where-Object { $_ -match ';' -and $_ -notmatch '^-+;' }
# a primeira linha com ';' e o cabecalho (Tabela;Linhas;MB)
$dados = $linhas | Select-Object -Skip 1 | ForEach-Object {
    $c = $_ -split ';'
    if ($c.Count -ge 3) {
        [pscustomobject]@{
            Tabela = $c[0].Trim()
            Linhas = [int64]($c[1].Trim())
            MB     = [decimal]($c[2].Trim() -replace ',', '.')
        }
    }
} | Where-Object { $_ }

$totalMB = ($dados | Measure-Object MB -Sum).Sum
Write-Host ""
Write-Host "CarolOneCrawfordDB - $($dados.Count) tabelas, $([math]::Round($totalMB,1)) MB no total" -ForegroundColor Cyan
Write-Host ""
Write-Host "=== 25 MAIORES (candidatas a amostra) ===" -ForegroundColor Yellow
$dados | Select-Object -First 25 | Format-Table Tabela, Linhas, MB -AutoSize

$pequenas = $dados | Where-Object { $_.MB -le 5 }
Write-Host "Tabelas <= 5 MB (viriam inteiras): $($pequenas.Count), somando $([math]::Round(($pequenas | Measure-Object MB -Sum).Sum,1)) MB" -ForegroundColor Green

if ($SaidaCsv) {
    $dados | Export-Csv -Path $SaidaCsv -Delimiter ';' -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Salvo em: $SaidaCsv" -ForegroundColor Cyan
}
