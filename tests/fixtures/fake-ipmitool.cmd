@echo off
rem fake-ipmitool.cmd - multi-mode BMC simulator driven by FAKE_IPMI_MODE
rem modes: ok (default) / unreachable / auth / verify-transition / verify-flat / verify-off / verify-cycle-off
rem usage: set FAKE_IPMI_MODE=<mode> then & tests\fixtures\fake-ipmitool.cmd <args> <subcmd>
setlocal

if "%FAKE_IPMI_MODE%"=="" set "FAKE_IPMI_MODE=ok"

rem unreachable/auth: every subcommand returns the mode's stderr message + exit 1
if "%FAKE_IPMI_MODE%"=="unreachable" (
    (echo Could not open socket!) 1>&2
    exit /b 1
)
if "%FAKE_IPMI_MODE%"=="auth" (
    (echo Invalid password) 1>&2
    exit /b 1
)

rem dispatch by subcommand, most specific substring first
echo %* | findstr /C:"chassis power cycle" >nul
if not errorlevel 1 goto :chassis_power_cycle
echo %* | findstr /C:"chassis power status" >nul
if not errorlevel 1 goto :chassis_power_status
echo %* | findstr /C:"chassis status" >nul
if not errorlevel 1 goto :chassis_status
echo %* | findstr /C:"mc info" >nul
if not errorlevel 1 goto :mc_info
echo %* | findstr /C:"sdr elist" >nul
if not errorlevel 1 goto :sdr_elist
echo %* | findstr /C:"sol deactivate" >nul
if not errorlevel 1 goto :sol_deactivate
echo %* | findstr /C:"sol activate" >nul
if not errorlevel 1 goto :sol_activate
echo %* | findstr /C:"lan print" >nul
if not errorlevel 1 goto :lan_print

rem unknown subcommand: no output, exit 0
exit /b 0

:chassis_power_cycle
echo Chassis Power Control: Cycle
exit /b 0

:chassis_power_status
if "%FAKE_IPMI_MODE%"=="verify-transition" goto :status_transition
if "%FAKE_IPMI_MODE%"=="verify-cycle-off" goto :status_cycle_off
if "%FAKE_IPMI_MODE%"=="verify-off" (
    echo Chassis Power is off
    exit /b 0
)
echo Chassis Power is on
exit /b 0

:status_cycle_off
rem file-persisted counter: call 1 -> on, call >=2 -> off (cycle 下发后恒 off，不回 on)
set "countfile=%TEMP%\fake_ipmi_pwrcount"
set /a c=0
if not exist "%countfile%" goto :cycle_off_write
set /p c=<"%countfile%"
:cycle_off_write
set /a c+=1
> "%countfile%" echo %c%
if %c%==1 (
    echo Chassis Power is on
) else (
    echo Chassis Power is off
)
exit /b 0

:status_transition
rem file-persisted counter: call 1 -> on, call 2 -> off, call >=3 -> on
set "countfile=%TEMP%\fake_ipmi_pwrcount"
set /a c=0
if not exist "%countfile%" goto :transition_write
set /p c=<"%countfile%"
:transition_write
set /a c+=1
> "%countfile%" echo %c%
if %c%==2 (
    echo Chassis Power is off
) else (
    echo Chassis Power is on
)
exit /b 0

:chassis_status
echo Chassis Power is on
exit /b 0

:mc_info
echo Manufacturer: FakeCorp
echo Firmware Revision: 1.0
exit /b 0

:sdr_elist
echo Inlet Temp ^| 01h ^| ok ^| 26.0 ^| degrees C
exit /b 0

:sol_deactivate
exit /b 0

:sol_activate
echo SOL: connected
exit /b 0

:lan_print
if "%FAKE_IPMI_MODE%"=="preflight-lanfail" (
    (echo lan print failed) 1>&2
    exit /b 1
)
if "%FAKE_IPMI_MODE%"=="preflight-dhcp" (
    echo IP Address Source : DHCP Address
    exit /b 0
)
echo IP Address Source : Static Address
exit /b 0
