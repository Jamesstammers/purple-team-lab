@echo off
REM ============================================================
REM  Purple Team Lab — Windows target provisioning
REM  Runs automatically on first boot (dockur /oem hook).
REM  Values ${...} are injected by the config-render service.
REM  INGEST = winlogbeat | elastic-agent
REM ============================================================
setlocal
set LOG=C:\lab-provision.log
echo [%date% %time%] Starting provisioning > %LOG%

set ESHOST=${ESHOST}
set KBHOST=${KBHOST}
set FLEETHOST=${FLEETHOST}
set INGEST=${INGEST}
set ESPASS=${ELASTIC_PASSWORD}
set STACKVER=${STACK_VERSION}
set TOOLS=C:\LabTools
mkdir %TOOLS% 2>nul

REM ---------- 0. Clock: treat the VM hardware clock as UTC + set timezone ----------
REM  QEMU presents the RTC as UTC; Windows assumes local time by default, which
REM  puts every Sysmon UtcTime hours into the future. RealTimeIsUniversal fixes it.
echo [*] Fixing clock (RTC=UTC) and timezone >> %LOG%
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f >> %LOG% 2>&1
tzutil /s "GMT Standard Time" >> %LOG% 2>&1
sc config w32time start= auto >> %LOG% 2>&1
net start w32time >> %LOG% 2>&1
w32tm /resync /force >> %LOG% 2>&1

REM ---------- 1. OpenSSH Server (headless access) ----------
echo [*] Enabling OpenSSH Server >> %LOG%
powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >> %LOG% 2>&1
powershell -NoProfile -Command "Set-Service -Name sshd -StartupType Automatic; Start-Service sshd" >> %LOG% 2>&1
powershell -NoProfile -Command "New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22" >> %LOG% 2>&1

REM ---------- 2. Sysmon (needed for both ingest modes) ----------
echo [*] Downloading Sysmon >> %LOG%
curl.exe -L --retry 5 --retry-delay 5 -o "%TOOLS%\Sysmon.zip" "https://download.sysinternals.com/files/Sysmon.zip" >> %LOG% 2>&1
powershell -NoProfile -Command "Expand-Archive -Force -Path '%TOOLS%\Sysmon.zip' -DestinationPath '%TOOLS%\Sysmon'" >> %LOG% 2>&1
curl.exe -L --retry 5 --retry-delay 5 -o "%TOOLS%\sysmonconfig.xml" "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" >> %LOG% 2>&1
"%TOOLS%\Sysmon\Sysmon64.exe" -accepteula -i "%TOOLS%\sysmonconfig.xml" >> %LOG% 2>&1

if /I "%INGEST%"=="elastic-agent" goto AGENT

REM ================= WINLOGBEAT MODE =================
echo [*] Ingest mode: winlogbeat %STACKVER% >> %LOG%
curl.exe -L --retry 5 --retry-delay 5 -C - -o "%TOOLS%\winlogbeat.zip" "https://artifacts.elastic.co/downloads/beats/winlogbeat/winlogbeat-%STACKVER%-windows-x86_64.zip" >> %LOG% 2>&1
powershell -NoProfile -Command "Expand-Archive -Force -Path '%TOOLS%\winlogbeat.zip' -DestinationPath '%TOOLS%'" >> %LOG% 2>&1
if exist "C:\Program Files\Winlogbeat" rmdir /s /q "C:\Program Files\Winlogbeat"
move "%TOOLS%\winlogbeat-%STACKVER%-windows-x86_64" "C:\Program Files\Winlogbeat" >> %LOG% 2>&1
copy /Y "C:\oem\winlogbeat.yml" "C:\Program Files\Winlogbeat\winlogbeat.yml" >> %LOG% 2>&1
cd /d "C:\Program Files\Winlogbeat"
powershell -NoProfile -ExecutionPolicy Bypass -File ".\install-service-winlogbeat.ps1" >> %LOG% 2>&1
sc config winlogbeat start= auto >> %LOG% 2>&1
.\winlogbeat.exe setup -e >> %LOG% 2>&1
powershell -NoProfile -Command "Start-Service winlogbeat" >> %LOG% 2>&1
goto DONE

REM ================= ELASTIC AGENT (FLEET) MODE =================
:AGENT
echo [*] Ingest mode: elastic-agent %STACKVER% >> %LOG%
curl.exe -L --retry 5 --retry-delay 5 -o "%TOOLS%\agent.zip" "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-%STACKVER%-windows-x86_64.zip" >> %LOG% 2>&1
powershell -NoProfile -Command "Expand-Archive -Force -Path '%TOOLS%\agent.zip' -DestinationPath '%TOOLS%'" >> %LOG% 2>&1

echo [*] Fetching enrollment token from Kibana (waits for Fleet to be ready) >> %LOG%
powershell -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $b=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('elastic:%ESPASS%')); $h=@{Authorization=('Basic '+$b);'kbn-xsrf'='true';'elastic-api-version'='2023-10-31'}; for($i=0;$i -lt 60;$i++){ try { $r=Invoke-RestMethod -Uri 'http://%KBHOST%:5601/api/fleet/enrollment_api_keys?kuery=policy_id:pl-windows' -Headers $h; $k=($r.items | Select-Object -First 1).api_key; if($k){ $k | Out-File -Encoding ascii C:\LabTools\enroll.txt; break } } catch {}; Start-Sleep 10 }" >> %LOG% 2>&1
set /p ENROLL=<C:\LabTools\enroll.txt

if "%ENROLL%"=="" (
  echo [!] Could not get enrollment token - is Fleet up? Enroll manually later. >> %LOG%
  goto DONE
)
echo [*] Enrolling Elastic Agent to Fleet at http://%FLEETHOST%:8220 >> %LOG%
"%TOOLS%\elastic-agent-%STACKVER%-windows-x86_64\elastic-agent.exe" install -f --url=http://%FLEETHOST%:8220 --enrollment-token=%ENROLL% --insecure >> %LOG% 2>&1
goto DONE

:DONE
echo [%date% %time%] Provisioning complete >> %LOG%
endlocal
