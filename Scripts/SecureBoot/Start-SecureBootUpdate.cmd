@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  Secure Boot Zertifikats-Update
::  Starter-Menue fuer Invoke-SecureBootUpdate.ps1
:: ============================================================

:: --- Administratorrechte pruefen ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo  Administratorrechte erforderlich.
    echo  Das Skript wird mit erhoehthen Rechten neu gestartet...
    echo.
    powershell -NoProfile -Command ^
        "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c \"%~f0\"' -Verb RunAs"
    exit /b
)

:MENU
cls
echo.
echo  ============================================================
echo    Secure Boot Zertifikats-Update
echo  ============================================================
echo.
echo    [1]  Info         ^-  Systemanalyse (keine Aenderungen)
echo    [2]  Update       ^-  Fehlende Zertifikate aktualisieren
echo    [3]  Check        ^-  Nachkontrolle nach dem Neustart
echo.
echo    [0]  Beenden
echo.
echo  ============================================================
echo.
set /p CHOICE=  Auswahl eingeben [0-3]: 

if "%CHOICE%"=="1" goto INFO
if "%CHOICE%"=="2" goto UPDATE
if "%CHOICE%"=="3" goto CHECK
if "%CHOICE%"=="0" goto END

echo.
echo  Ungueltige Eingabe. Bitte 0, 1, 2 oder 3 eingeben.
timeout /t 2 >nul
goto MENU

:INFO
cls
echo.
echo  Starte Systemanalyse ^(-Info^)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-SecureBootUpdate.ps1" -Info
echo.
echo  ============================================================
pause
goto MENU

:UPDATE
cls
echo.
echo  Starte Zertifikats-Update ^(-ApplyUpdate^)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-SecureBootUpdate.ps1" -ApplyUpdate
echo.
echo  ============================================================
pause
goto MENU

:CHECK
cls
echo.
echo  Starte Nachkontrolle ^(-Check^)...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-SecureBootUpdate.ps1" -Check
echo.
echo  ============================================================
pause
goto MENU

:END
exit /b 0
