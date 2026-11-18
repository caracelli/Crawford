@echo off
rem EmailIndexingService - verifica a configuracao e instala como servico do Windows.
rem
rem Como usar:
rem   1. Copie este arquivo e o "Instalar EmailIndexingService.ps1" para a pasta publicada do servico
rem      (a mesma pasta do EmailIndexingService.exe, appsettings.json e NLog.config).
rem   2. Botao direito neste arquivo > Executar como administrador.
rem   3. Se houver ERRO, nada e instalado: corrija o que for apontado e rode de novo.
rem   O resultado fica em "Instalar EmailIndexingService.saida.txt", nesta mesma pasta.
rem
rem So verificar, sem instalar: rode com o parametro /verificar (nao precisa de administrador).
rem Desinstalar: rode como administrador com o parametro /desinstalar.

cd /d "%~dp0"
set OPCAO=
if /i "%~1"=="/verificar"   set OPCAO=-SoVerificar
if /i "%~1"=="/desinstalar" set OPCAO=-Desinstalar

if not "%OPCAO%"=="-SoVerificar" (
    net session >nul 2>&1
    if errorlevel 1 (
        echo Precisa rodar como administrador: botao direito no arquivo ^> Executar como administrador.
        pause
        exit /b 1
    )
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar EmailIndexingService.ps1" -Pasta "%~dp0." %OPCAO%
echo.
pause
