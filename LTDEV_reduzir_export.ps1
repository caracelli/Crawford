<#
.SINOPSE
    Reduz um export de .sql (SSMS "um arquivo por objeto", schema + dados) para um
    tamanho que cabe no git. NAO le banco: trabalha so nos arquivos ja exportados.

    Para cada .sql:
      - arquivo pequeno (<= -LimiteKB)      -> copiado inteiro (schema + dados);
      - arquivo grande                      -> mantem TODO o schema e as demais
                                               instrucoes, e guarda apenas as
                                               primeiras -MaxInserts linhas INSERT,
                                               descartando o resto dos dados.

    Como so recorta INSERTs que ja existem (nao gera nada), o resultado continua
    sendo SQL valido. Opcionalmente faz git add/commit/push ao final.

.AVISO
    Cada tabela grande fica com as primeiras N linhas, independentemente das outras
    - a amostra NAO garante integridade referencial entre tabelas (as N linhas de
    Claim podem nao casar com as N de AttachmentClaim). Serve para subir o schema e
    ter massa de fumaca. Para um sinistro completo e consistente, use a exportacao
    ancorada por ClaimId (script separado, que le o banco).

.EXEMPLO
    # dry-run: mostra o que cortaria, sem escrever
    .\LTDEV_reduzir_export.ps1 -Origem "D:\export_600mb" -Destino "C:\repo-temp\LTDEV-seed" -Simular

    # valendo (gera os arquivos reduzidos)
    .\LTDEV_reduzir_export.ps1 -Origem "D:\export_600mb" -Destino "C:\repo-temp\LTDEV-seed"

    # gera e ja commita/empurra
    .\LTDEV_reduzir_export.ps1 -Origem "D:\export_600mb" -Destino "C:\repo-temp\LTDEV-seed" -RepoDir "C:\repo-temp" -Push
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Origem,
    [Parameter(Mandatory = $true)] [string] $Destino,

    # Arquivos ate este tamanho vao inteiros.
    [int] $LimiteKB = 200,
    # Nas tabelas grandes, quantas linhas INSERT manter.
    [int] $MaxInserts = 50,

    # Para commitar/empurrar (opcional).
    [string] $RepoDir,
    [string] $Branch = 'main',
    [string] $MensagemCommit = 'LTDEV: seed reduzido para ambiente de teste',
    [switch] $Push,

    [switch] $Simular
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Origem)) { throw "Origem nao encontrada: $Origem" }

# reconhece o inicio de uma instrucao INSERT (INSERT [dbo].[T]..., INSERT INTO ...)
$reInsert = '^\s*INSERT\s'

$arquivos = Get-ChildItem -Path $Origem -Filter *.sql -Recurse -File
Write-Host ""
Write-Host "Arquivos .sql na origem: $($arquivos.Count)" -ForegroundColor Cyan
Write-Host "Corte: <= $LimiteKB KB inteiro; acima, mantem $MaxInserts INSERTs" -ForegroundColor Cyan
if ($Simular) { Write-Host "MODO: SIMULACAO (nao escreve)" -ForegroundColor Yellow }
Write-Host ""

if (-not $Simular) { New-Item -ItemType Directory -Path $Destino -Force | Out-Null }

$resumo = New-Object System.Collections.ArrayList
$totalOrig = 0.0; $totalNovo = 0.0

foreach ($a in $arquivos) {
    $kb = [math]::Round($a.Length / 1KB, 1)
    $totalOrig += $kb
    $rel = $a.FullName.Substring($Origem.Length).TrimStart('\','/')
    $alvo = Join-Path $Destino $rel

    if ($a.Length -le ($LimiteKB * 1KB)) {
        if (-not $Simular) {
            New-Item -ItemType Directory -Path (Split-Path $alvo) -Force | Out-Null
            Copy-Item $a.FullName $alvo -Force
        }
        $totalNovo += $kb
        [void]$resumo.Add([pscustomobject]@{ Arquivo=$rel; De="$kb KB"; Acao='inteiro' })
        continue
    }

    # arquivo grande: recorta INSERTs
    $mantidas = New-Object System.Collections.Generic.List[string]
    $qtdInsert = 0; $cortadas = 0
    foreach ($linha in [IO.File]::ReadLines($a.FullName)) {
        if ($linha -match $reInsert) {
            if ($qtdInsert -lt $MaxInserts) { $mantidas.Add($linha); $qtdInsert++ }
            else { $cortadas++ }
        } else {
            $mantidas.Add($linha)
        }
    }
    if ($cortadas -gt 0) {
        $mantidas.Add("-- LTDEV: $cortadas linhas INSERT descartadas (amostra de $MaxInserts).")
    }
    if (-not $Simular) {
        New-Item -ItemType Directory -Path (Split-Path $alvo) -Force | Out-Null
        [IO.File]::WriteAllLines($alvo, $mantidas, [Text.UTF8Encoding]::new($false))
        $totalNovo += [math]::Round((Get-Item $alvo).Length / 1KB, 1)
    }
    [void]$resumo.Add([pscustomobject]@{ Arquivo=$rel; De="$kb KB"; Acao="cortado ($qtdInsert de $($qtdInsert+$cortadas) INSERTs)" })
}

Write-Host "=== ARQUIVOS GRANDES CORTADOS ===" -ForegroundColor Yellow
$resumo | Where-Object { $_.Acao -like 'cortado*' } | Format-Table -AutoSize
$qInteiros = @($resumo | Where-Object { $_.Acao -eq 'inteiro' }).Count
$qCortados = @($resumo | Where-Object { $_.Acao -like 'cortado*' }).Count
Write-Host "Total: $($resumo.Count) arquivos | inteiros: $qInteiros | cortados: $qCortados"
Write-Host ("Tamanho origem: {0:N1} MB" -f ($totalOrig/1024)) -ForegroundColor Cyan
if (-not $Simular) { Write-Host ("Tamanho reduzido: {0:N1} MB" -f ($totalNovo/1024)) -ForegroundColor Green }

if ($Simular) { Write-Host ""; Write-Host "SIMULACAO: nada escrito." -ForegroundColor Yellow; return }

if ($Push) {
    if (-not $RepoDir) { throw "-Push exige -RepoDir." }
    Write-Host ""; Write-Host "=== GIT ===" -ForegroundColor Cyan
    Push-Location $RepoDir
    try {
        & git add -A -- "$Destino"
        & git commit -m "$MensagemCommit"
        & git push origin $Branch
        if ($LASTEXITCODE -eq 0) { Write-Host "Push OK para origin/$Branch." -ForegroundColor Green }
        else { Write-Host "Push falhou - verifique remoto/credenciais/tamanho." -ForegroundColor Red }
    } finally { Pop-Location }
}
