@echo off
setlocal
rem Starts HeidiSQL so that SQL Server "Use Windows authentication" logs in (NTLM) with an account
rem of the picked domain, without changing your Windows session. Same as: runas /netonly /user:DOMAIN\user heidisql.exe
rem Before that, creates/updates one HeidiSQL session per server listed in servers-prod.txt or
rem servers-pat.txt (next to this script), with encryption and trusted server certificate.
rem After that, watches the network to the domain and the SQL Servers in this window until HeidiSQL exits.

rem Short (NetBIOS) domain names, for the login. Change if yours differ.
set "PROD_DOMAIN=ABCD"
set "PAT_DOMAIN=P-ABCD"
rem Full DNS domain names, for the network monitor
set "PROD_DNS=abcd.com"
set "PAT_DNS=p-abcd.com"
set "SQLUSER=%USERNAME%"
rem HeidiSQL pings each open session with SELECT 1 every this many seconds, keeping the connection alive
set "KEEPALIVE=10"
rem The network monitor checks the domain and SQL Servers every this many seconds
set "MONITOR_INTERVAL=10"
set "SESSIONS=HKCU\Software\HeidiSQL\Servers"

rem Find heidisql.exe: next to this script (portable), then the default install folders
set "HEIDI="
for %%E in ("%~dp0heidisql.exe" "%ProgramFiles%\HeidiSQL\heidisql.exe" "%ProgramFiles(x86)%\HeidiSQL\heidisql.exe") do (
  if not defined HEIDI if exist %%E set "HEIDI=%%~E"
)
if not defined HEIDI (
  echo heidisql.exe not found. Put this script next to heidisql.exe, or install HeidiSQL.
  exit /b 1
)

:askenv
set "ENV=pat"
set /p "ENV=Environment - prod (abcd.com) or pat (p-abcd.com) [pat]: "
if /i "%ENV%"=="prod" (
  set "DOMAIN=%PROD_DOMAIN%"
  set "DNSDOMAIN=%PROD_DNS%"
  set "FOLDER=PROD"
) else if /i "%ENV%"=="pat" (
  set "DOMAIN=%PAT_DOMAIN%"
  set "DNSDOMAIN=%PAT_DNS%"
  set "FOLDER=PAT"
) else (
  echo Please type prod or pat.
  goto askenv
)

rem Newest installed OLE DB driver; the old SQLOLEDB ignores the encryption settings
set "LIB="
reg query HKCR\MSOLEDBSQL19 >nul 2>&1 && set "LIB=MSOLEDBSQL19"
if not defined LIB reg query HKCR\MSOLEDBSQL >nul 2>&1 && set "LIB=MSOLEDBSQL"
if not defined LIB echo WARNING: "Microsoft OLE DB Driver for SQL Server" not found, sessions keep HeidiSQL's default library.

set "SERVERLIST=%~dp0servers-%FOLDER%.txt"
set "LIST=%SERVERLIST%"
for %%H in ("%HEIDI%") do if exist "%%~dpHportable_settings.txt" (
  echo Portable HeidiSQL keeps sessions in portable_settings.txt, server list not loaded.
  set "LIST="
)
if defined LIST if exist "%LIST%" call :loadsessions
if defined LIST if not exist "%LIST%" echo No server list found, no sessions loaded: %LIST%

set /p "SQLUSER=User in %DOMAIN% [%SQLUSER%]: "

echo.
echo Starting %HEIDI%
echo as %DOMAIN%\%SQLUSER% for network logins. Enter that account's password below.
echo The password is only checked when HeidiSQL connects to SQL Server.
runas /netonly /user:%DOMAIN%\%SQLUSER% "\"%HEIDI%\""
if errorlevel 1 exit /b 1

echo.
echo Watching the network until HeidiSQL closes. Ctrl+C stops watching, HeidiSQL keeps running.
rem Runs the PowerShell part at the end of this file; it reads DNSDOMAIN, SERVERLIST and MONITOR_INTERVAL
set "SELF=%~f0"
powershell -NoProfile -Command "$s = Get-Content -LiteralPath $env:SELF -Raw; Invoke-Expression ($s -split '(?m)^#MONITOR#\r?$')[-1]"
exit /b


rem One line per server: name or name,port (default 1433). Lines starting with # are skipped.
:loadsessions
reg add "%SESSIONS%\%FOLDER%" /v Folder /t REG_DWORD /d 1 /f >nul
set "COUNT=0"
for /f "usebackq eol=# tokens=1,2 delims=, " %%G in ("%LIST%") do call :addsession "%%G" "%%H"
echo Loaded %COUNT% server(s) from %LIST% into HeidiSQL session folder %FOLDER%.
exit /b

rem Port must be 0, else HeidiSQL appends ",port" behind the encryption keywords in Host.
rem NetType 4 = Microsoft SQL Server (TCP/IP).
:addsession
set "SRV=%~1"
set "SRVPORT=%~2"
if not defined SRVPORT set "SRVPORT=1433"
set "KEY=%SESSIONS%\%FOLDER%\%SRV%"
reg add "%KEY%" /v Host /t REG_SZ /d "%SRV%,%SRVPORT%;Use Encryption for Data=true;Trust Server Certificate=true" /f >nul
reg add "%KEY%" /v Port /t REG_SZ /d 0 /f >nul
reg add "%KEY%" /v NetType /t REG_DWORD /d 4 /f >nul
reg add "%KEY%" /v WindowsAuth /t REG_DWORD /d 1 /f >nul
if defined LIB reg add "%KEY%" /v Library /t REG_SZ /d "%LIB%" /f >nul
reg add "%KEY%" /v KeepAlive /t REG_DWORD /d %KEEPALIVE% /f >nul
set /a COUNT+=1
exit /b


rem ===== Below is PowerShell, never run by cmd (every path above ends in exit /b) =====
#MONITOR#
# Checks every few seconds whether the domain and the SQL Servers are reachable, prints and logs
# every check, beeps when one goes down, and ends when HeidiSQL exits. Windows PowerShell 5.1, no admin rights needed.
$Interval = [int]$env:MONITOR_INTERVAL
$TimeoutMs = 2000
$Log = Join-Path $env:TEMP 'heidisql-netmonitor.log'

# Domain: a domain controller answering LDAP. SQL Servers: their SQL port, like HeidiSQL connects.
$targets = @([pscustomobject]@{ Name = "$env:DNSDOMAIN (domain controller)"; HostName = $env:DNSDOMAIN; Port = 389 })
if ($env:SERVERLIST -and (Test-Path -LiteralPath $env:SERVERLIST)) {
  foreach ($line in Get-Content -LiteralPath $env:SERVERLIST) {
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $parts = $line -split '[,\s]+'
    $port = 1433
    if ($parts.Count -gt 1) { $port = [int]$parts[1] }
    $targets += [pscustomobject]@{ Name = $parts[0]; HostName = $parts[0]; Port = $port }
  }
}

function Test-Target($t) {
  try {
    $ips = [System.Net.Dns]::GetHostAddresses($t.HostName)
  } catch {
    $ips = @()
  }
  # Prefer IPv4, VPNs often do not route IPv6
  $ip = $ips | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
  if (-not $ip) { $ip = $ips | Select-Object -First 1 }
  if (-not $ip) { return @{ Status = 'DNS FAIL'; Detail = 'name does not resolve' } }
  $client = New-Object System.Net.Sockets.TcpClient($ip.AddressFamily)
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $connected = $client.ConnectAsync($ip, $t.Port).Wait($TimeoutMs) -and $client.Connected
  } catch {
    $connected = $false
  } finally {
    $client.Dispose()
  }
  if ($connected) {
    return @{ Status = 'OK'; Detail = "$ip port $($t.Port), $($watch.ElapsedMilliseconds) ms" }
  }
  return @{ Status = 'NO CONNECT'; Detail = "$ip port $($t.Port), no answer within $TimeoutMs ms" }
}

function Write-Log($text) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text
  Add-Content -LiteralPath $Log -Value $line
  return $line
}

Write-Host (Write-Log "Monitor started for $env:DNSDOMAIN, $($targets.Count) target(s), log: $Log")
$last = @{}
$seenHeidi = $false
while ($true) {
  # runas returns right after starting HeidiSQL; stop only once it ran and exited
  if (Get-Process -Name heidisql -ErrorAction SilentlyContinue) {
    $seenHeidi = $true
  } elseif ($seenHeidi) {
    Write-Host (Write-Log 'HeidiSQL closed, monitor stopped.')
    break
  }

  foreach ($t in $targets) {
    $r = Test-Target $t
    $color = if ($r.Status -eq 'OK') { 'Green' } else { 'Red' }
    Write-Host (Write-Log ('{0,-10} {1} ({2})' -f $r.Status, $t.Name, $r.Detail)) -ForegroundColor $color
    if ($last.ContainsKey($t.Name) -and $last[$t.Name] -eq 'OK' -and $r.Status -ne 'OK') { [console]::Beep(800, 300) }
    $last[$t.Name] = $r.Status
  }
  Start-Sleep -Seconds $Interval
}
