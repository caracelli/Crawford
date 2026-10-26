@echo off
rem LTDEV-2 - VERIFICA e INSTALA o servico (pede confirmacao e a senha da conta).
rem Botao direito > Executar como administrador. Envia o resultado ao git.
net session >nul 2>&1
if errorlevel 1 (
    echo Precisa rodar como administrador: botao direito no arquivo ^> Executar como administrador.
    pause
    exit /b 1
)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LTDEV-2 - Instalar servico (producao).ps1" -Pasta "%USERPROFILE%\Service-ClaimEmailAutomation\EmailIndexingService\bin\Debug\netcoreapp3.1"
git add "LTDEV-2 - Instalar servico (producao).saida.txt"
git commit -q -m "LTDEV-2: instalacao producao (%COMPUTERNAME%)"
git pull -q --rebase
git push -q
echo.
echo Pronto. Avise o Claude.
pause
