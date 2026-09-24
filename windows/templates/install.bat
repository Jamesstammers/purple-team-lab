@echo off
REM ============================================================
REM  Purple Team Lab — Windows target provisioning
REM  Runs automatically on first boot (dockur /oem hook).
REM  Values ${...} are injected by the config-render service.
REM  Uses curl.exe (built into Windows Server 2022) for robust,
REM  resumable downloads.
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

REM ---------- 2. Sysmon (SwiftOnSecurity config) ----------
echo [*] Downloading Sysmon >> %LOG%
curl.exe -L --retry 5 --retry-delay 5 -o "%TOOLS%\Sysmon.zip" "https://download.sysinternals.com/files/Sysmon.zip" >> %LOG% 2>&1
powershell -NoProfile -Command "Expand-Archive -Force -Path '%TOOLS%\Sysmon.zip' -DestinationPath '%TOOLS%\Sysmon'" >> %LOG% 2>&1
echo [*] Downloading Sysmon config >> %LOG%
curl.exe -L --retry 5 --retry-delay 5 -o "%TOOLS%\sysmonconfig.xml" "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" >> %LOG% 2>&1
"%TOOLS%\Sysmon\Sysmon64.exe" -accepteula -i "%TOOLS%\sysmonconfig.xml" >> %LOG% 2>&1

REM ---------- 3. Winlogbeat -> Elasticsearch ----------
echo [*] Downloading Winlogbeat %STACKVER% >> %LOG%
curl.exe -L --retry 5 --retry-delay 5 -C - -o "%TOOLS%\winlogbeat.zip" "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-%STACKVER%-windows-x86_64.zip" >> %LOG% 2>&1
echo [*] Extracting Winlogbeat >> %LOG%
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
