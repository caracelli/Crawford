@echo off
rem LTDEV-2 - so VERIFICA a configuracao do servico (nao instala). Duplo clique ou: LTDEV2-verificar
rem Usa a pasta do servico desta maquina e envia o resultado ao git.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LTDEV-2 - Instalar servico (producao).ps1" -Pasta "%USERPROFILE%\Service-ClaimEmailAutomation\EmailIndexingService\bin\Debug\netcoreapp3.1" -SoVerificar
git add "LTDEV-2 - Instalar servico (producao).saida.txt"
git commit -q -m "LTDEV-2: verificacao producao (%COMPUTERNAME%)"
git pull -q --rebase
git push -q
echo.
echo Pronto. Avise o Claude.
pause
