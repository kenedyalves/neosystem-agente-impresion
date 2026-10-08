@echo off
REM ---------------------------------------------------------------------------
REM Agente de impresion NEOSYSTEM.
REM
REM Mantiene el agente corriendo: si se cae (se corto la red, se reinicio el ERP,
REM PHP murio), vuelve a levantarlo solo a los 5 segundos.
REM
REM Para que arranque con Windows, cree un acceso directo a este archivo en:
REM   Win+R  ->  shell:startup
REM
REM Si PHP no esta en el PATH, complete la ruta completa en PHP_EXE.
REM ---------------------------------------------------------------------------

setlocal

set "PHP_EXE=php"
REM Ejemplo con PHP portable:
REM set "PHP_EXE=C:\Server\Php\php.exe"

cd /d "%~dp0"

if not exist "agente.ini" (
    echo.
    echo  FALTA agente.ini
    echo.
    echo  Copie agente.ini.example a agente.ini y complete la URL y el token.
    echo.
    pause
    exit /b 1
)

:loop
echo [%date% %time%] Iniciando agente...
"%PHP_EXE%" agente.php
echo [%date% %time%] El agente se detuvo. Reintentando en 5 segundos...
timeout /t 5 /nobreak >nul
goto loop
