@echo off
REM =============================================================================
REM One-click launcher for a backup task.
REM Instructions:
REM   1. Set CONFIG_NAME to the exact name of the BackUp config folder (e.g., __Config_BackUp_1).
REM   2. Double-click this file to run the backup.
REM The script backup.ps1 and all task folders must be in the same directory.
REM =============================================================================




:: ############################################################

:: ----- USER CONFIG: Enter the config folder name here -----

set "CONFIG_NAME=Config_D2R"

:: --------------------------------------------------------

:: ############################################################







REM Build full path to the config folder (relative to this bat file)
set "CONFIG_FOLDER=%~dp0%CONFIG_NAME%"

REM Run the backup script
powershell -ExecutionPolicy Bypass -File "%~dp0HD2HD_Mirror_Universal.ps1" -ConfigFolder "%CONFIG_FOLDER%"

REM Keep the window open to read the final messages
::pause