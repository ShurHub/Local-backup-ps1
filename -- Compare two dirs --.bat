@echo off
setlocal

set "ENV_SOURCE_DIR=D:\"
set "ENV_DESTINATION_DIR=r:\!!! Backup D !!!\"

::echo ENV_SOURCE_DIR=[%ENV_SOURCE_DIR%]
::echo ENV_DESTINATION_DIR=[%ENV_DESTINATION_DIR%]

powershell -ExecutionPolicy Bypass -File "Compare dirs.ps1"

endlocal
