@echo off
REM ============================================================
REM  Purple Team Lab — Windows target provisioning
REM  Runs automatically on first boot (dockur /oem hook).
REM  Values ${...} are injected by the config-render service.
REM ============================================================
setlocal enabledelayedexpansion
set LOG=C:\lab-provision.log
echo [%date% %time%] Starting provisioning > %LOG%

set ESHOST=${ESHOST}
set KBHOST=${KBHOST}
set ESPASS=${ELASTIC_PASSWORD}
set STACKVER=${STACK_VERSION}
set TOOLS=C:\LabTools
mkdir %TOOLS% 2>nul

REM ---------- 1. OpenSSH Server (headless access) ----------
echo [*] Enabling OpenSSH Server >> %LOG%
powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >> %LOG% 2>&1
powershell -NoProfile -Command "Set-Service -Name sshd -StartupType Automatic; Start-Service sshd" >> %LOG% 2>&1
powershell -NoProfile -Command "New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22" >> %LOG% 2>&1

REM ---------- 2. Sysmon (Olaf Hartong sysmon-modular config) ----------
echo [*] Installing Sysmon >> %LOG%
powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -Uri 'https://download.sysinternals.com/files/Sysmon.zip' -OutFile '%TOOLS%\Sysmon.zip'" >> %LOG% 2>&1
powershell -NoProfile -Command "Expand-Archive -Force -Path '%TOOLS%\Sysmon.zip' -DestinationPath '%TOOLS%\Sysmon'" >> %LOG% 2>&1
powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/olafhartong/sysmon-modular/master/sysmonconfig.xml' -OutFile '%TOOLS%\sysmonconfig.xml'" >> %LOG% 2>&1
"%TOOLS%\Sysmon\Sysmon64.exe" -accepteula -i "%TOOLS%\sysmonconfig.xml" >> %LOG% 2>&1

REM ---------- 3. Winlogbeat -> Elasticsearch ----------
echo [*] Installing Winlogbeat %STACKVER% >> %LOG%
powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -Uri 'https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-%STACKVER%-windows-x86_64.zip' -OutFile '%TOOLS%\winlogbeat.zip'" >> %LOG% 2>&1
powershell -NoProfile -Command "Expand-Archive -Force -Path '%TOOLS%\winlogbeat.zip' -DestinationPath '%TOOLS%'" >> %LOG% 2>&1
if exist "C:\Program Files\Winlogbeat" rmdir /s /q "C:\Program Files\Winlogbeat"
move "%TOOLS%\winlogbeat-%STACKVER%-windows-x86_64" "C:\Program Files\Winlogbeat" >> %LOG% 2>&1
copy /Y "C:\oem\winlogbeat.yml" "C:\Program Files\Winlogbeat\winlogbeat.yml" >> %LOG% 2>&1

cd /d "C:\Program Files\Winlogbeat"
echo [*] Registering Winlogbeat service >> %LOG%
powershell -NoProfile -ExecutionPolicy Bypass -File ".\install-service-winlogbeat.ps1" >> %LOG% 2>&1

echo [*] Loading index template / assets (winlogbeat setup) >> %LOG%
.\winlogbeat.exe setup -e >> %LOG% 2>&1

echo [*] Starting Winlogbeat >> %LOG%
powershell -NoProfile -Command "Start-Service winlogbeat" >> %LOG% 2>&1

echo [%date% %time%] Provisioning complete >> %LOG%
endlocal
