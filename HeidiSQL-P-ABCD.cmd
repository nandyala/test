@echo off
setlocal
rem Starts HeidiSQL so that its network logins (SQL Server "Use Windows authentication")
rem use an account of another domain, like NTLM to p-abcd.com while logged in to abcd.com.
rem Your local Windows session is not changed. Same as: runas /netonly /user:DOMAIN\user heidisql.exe
rem Encryption: in the HeidiSQL session, set Port to 0 and Hostname to
rem   yourserver.p-abcd.com,1433;Use Encryption for Data=true;Trust Server Certificate=true

set "DOMAIN=P-ABCD"
set "SQLUSER=%USERNAME%"

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

set /p "DOMAIN=Domain [%DOMAIN%]: "
set /p "SQLUSER=User in %DOMAIN% [%SQLUSER%]: "

echo.
echo Starting %HEIDI%
echo as %DOMAIN%\%SQLUSER% for network logins. Enter that account's password below.
echo The password is only checked when HeidiSQL connects to SQL Server.
runas /netonly /user:%DOMAIN%\%SQLUSER% "\"%HEIDI%\""
if errorlevel 1 pause
