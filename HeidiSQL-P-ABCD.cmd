@echo off
setlocal
rem Starts HeidiSQL so that its network logins (SQL Server "Use Windows authentication")
rem use an account of another domain, like NTLM to p-abcd.com while logged in to abcd.com.
rem Your local Windows session is not changed. Same as: runas /netonly /user:DOMAIN\user heidisql.exe
rem Also turns on encryption + trust server certificate (Encrypt=true, TrustServerCertificate=true)
rem through the SQL Server client driver settings, as HeidiSQL has no fields for them.

set "DOMAIN=P-ABCD"
set "SQLUSER=%USERNAME%"
set "CLIENTKEY=HKLM\SOFTWARE\Microsoft\MSSQLServer\Client"

rem Elevated re-run of this script, only to write the driver settings
if /i "%~1"=="setflags" (
  call :flags set
  exit /b
)

rem Find heidisql.exe: next to this script (portable), then the default install folders
set "HEIDI="
for %%P in ("%~dp0heidisql.exe" "%ProgramFiles%\HeidiSQL\heidisql.exe" "%ProgramFiles(x86)%\HeidiSQL\heidisql.exe") do (
  if not defined HEIDI if exist %%P set "HEIDI=%%~P"
)
if not defined HEIDI (
  echo heidisql.exe not found. Put this script next to heidisql.exe, or install HeidiSQL.
  pause
  exit /b 1
)

call :flags check
if not defined FOUND (
  echo WARNING: No SQL Server client driver settings found. Install "Microsoft OLE DB Driver for SQL Server",
  echo then pick it as Library in HeidiSQL. Continuing without forced encryption.
) else if defined NEED (
  echo Turning on "Force protocol encryption" and "Trust Server Certificate" for the SQL Server drivers.
  echo This is machine-wide and needs administrator rights once. Confirm the Windows prompt.
  set "SELF=%~f0"
  powershell -NoProfile -Command "Start-Process -FilePath $env:ComSpec -ArgumentList '/c', ('\"' + $env:SELF + '\" setflags') -Verb RunAs -Wait"
  call :flags check
)
if defined NEED (
  echo WARNING: Encryption settings could not be written. Continuing without them.
)

set /p "DOMAIN=Domain [%DOMAIN%]: "
set /p "SQLUSER=User in %DOMAIN% [%SQLUSER%]: "

echo.
echo Starting %HEIDI%
echo as %DOMAIN%\%SQLUSER% for network logins. Enter that account's password below.
echo The password is only checked when HeidiSQL connects to SQL Server.
runas /netonly /user:%DOMAIN%\%SQLUSER% "\"%HEIDI%\""
if errorlevel 1 pause
exit /b

rem check: sets FOUND if the driver settings exist, NEED if one of them is not 1. set: writes 1.
rem Settings are found by their label, as the FlagN numbering differs per driver version (SNI11.0, SNI18.0, ...).
:flags
set "FOUND="
set "NEED="
for %%L in ("Force protocol encryption" "Trust Server Certificate") do (
  for /f "delims=" %%K in ('reg query "%CLIENTKEY%" /s /d /f %%L /reg:64 2^>nul ^| findstr /b HKEY') do (
    set "FOUND=1"
    if /i "%~1"=="set" (
      reg add "%%K" /v Value /t REG_DWORD /d 1 /f /reg:64 >nul
    ) else (
      reg query "%%K" /v Value /reg:64 2>nul | findstr /e "0x1" >nul || set "NEED=1"
    )
  )
)
exit /b
