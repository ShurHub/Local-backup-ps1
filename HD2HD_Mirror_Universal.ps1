# =============================================================================
# RCLONE MIRROR BACKUP WIN10 Local HD_SATA > HD_SATA/NVME
# =============================================================================
#
# Script synchronises a local source directory to a local destination
# using rclone. All settings are stored in a dedicated "backup config folder".
#
# --- Backup config folder ---
# A folder containing exactly three files:
#   rclone_paths.txt      Ц SOURCE, DEST, DryRun, Mode, and folder list
#   rclone_arguments.txt  Ц rclone command-line flags
#   rclone_filters.txt    Ц file/directory exclusion rules (global)
# The folder can be located anywhere; its name becomes the job identifier
# used in the log file name.
#
# --- Run script command ---
#   powershell -File <THIS SCRIPT NAME>.ps1 -ConfigFolder "<PATH_TO_CONFIG_FOLDER>"
#   The <PATH_TO_CONFIG_FOLDER> can be specified as:
#     - Absolute: "C:\BackupConfigs\<Config_Folder>"
#     - Relative to script: ".\Configs\<Config_Folder>" or just "Configs\<Config_Folder>"
#
# --- Logs ---
# All logs are written to a "logs" subfolder next to the script.
# =============================================================================


param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigFolder
)


# If the path is relative (does not start with a drive letter like C:\),
# force it to be absolute relative to the LOCATION OF THIS SCRIPT.
if (-not [System.IO.Path]::IsPathRooted($ConfigFolder)) {
    $ConfigFolder = Join-Path $PSScriptRoot $ConfigFolder
}


# Validate and resolve Config folder
if (-not (Test-Path $ConfigFolder -PathType Container)) {
    Write-Host "ERROR: Config folder does not exist: $ConfigFolder" -ForegroundColor Red
    exit 1
}
$ConfigFolder = (Resolve-Path $ConfigFolder).Path

# -----------------------------------------------------------------------------
# READ TASK CONFIGURATION FILES Ц mandatory checks
# -----------------------------------------------------------------------------
$pathsFile   = Join-Path $ConfigFolder "rclone_paths.txt"
$argsFile    = Join-Path $ConfigFolder "rclone_arguments.txt"
$filterFile  = Join-Path $ConfigFolder "rclone_filters.txt"

# All three files must exist Ц hard stop otherwise
foreach ($file in @($pathsFile, $argsFile, $filterFile)) {
    if (-not (Test-Path $file)) {
        Write-Host "ERROR: Required config file not found: $file" -ForegroundColor Red
        exit 1
    }
}

# -----------------------------------------------------------------------------
# PARSE rclone_paths.txt (new key=value style)
# -----------------------------------------------------------------------------
$rawLines = Get-Content -Path $pathsFile |
    Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^\s*[#;]' } |
    ForEach-Object { $_.Trim() }

$config = @{}
$currentKey = $null

foreach ($line in $rawLines) {
    if ($line -match '^([^=]+)=\s*(.*)$') {
        $key = $matches[1].Trim()
        $value = $matches[2].Trim()

        # --- Modified key handling: separate Include/Exclude/Unused Folders ---
        if ($key -eq 'Include Folders' -or $key -eq 'Exclude Folders') {
            # These keys store an array of folder names
            if ($value -ne '') {
                $config[$key] = @($value)
            } else {
                $config[$key] = @()
            }
            $currentKey = $key
        }
        elseif ($key -eq 'Unused Folders') {
            # Ignore this section entirely Ц do not store anything
            $currentKey = 'Unused Folders'
        }
        else {
            # All other keys (Source, Destination, DryRun, Mode, etc.)
            if ($value -ne '') {
                $config[$key] = $value
            } else {
                $config[$key] = $null
            }
            $currentKey = $key
        }
    } else {
        # Continuation of previous multi-line key
        if ($currentKey) {
            if ($currentKey -eq 'Include Folders' -or $currentKey -eq 'Exclude Folders') {
                $config[$currentKey] += @($line)
            }
            elseif ($currentKey -eq 'Unused Folders') {
                # Ignore continuation lines for Unused Folders
            }
            else {
                if ($null -eq $config[$currentKey]) {
                    $config[$currentKey] = $line
                } else {
                    $config[$currentKey] += "`n$line"
                }
            }
        }
    }
}

# Extract mandatory parameters
$SOURCE  = $config['Source']
$DEST    = $config['Destination']
$Mode    = $config['Mode']

# DryRun handling: from config, default to $false
$DryRun = $false
if ($config.ContainsKey('DryRun')) {
    if ($config['DryRun'] -eq 'On') {
        $DryRun = $true
    } elseif ($config['DryRun'] -eq 'Off') {
        $DryRun = $false
    } else {
        Write-Host "ERROR: Invalid DryRun value. Allowed: On, Off" -ForegroundColor Red
        exit 1
    }
}

# Validate Mode
if (-not $Mode) {
    Write-Host "ERROR: Mode not specified in rclone_paths.txt" -ForegroundColor Red
    exit 1
}
$Mode = $Mode.ToLower()
if (($Mode -ne 'include') -and ($Mode -ne 'exclude')) {
    Write-Host "ERROR: Invalid Mode '$Mode'. Allowed: Include, Exclude" -ForegroundColor Red
    exit 1
}

# --- Determine folder list based on Mode (Include / Exclude) ---
if ($Mode -eq 'include') {
    if (-not $config.ContainsKey('Include Folders')) {
        Write-Host "ERROR: Required key 'Include Folders' not found in config" -ForegroundColor Red
        exit 1
    }
    $ConfigFolders = $config['Include Folders']
}
else {
    if (-not $config.ContainsKey('Exclude Folders')) {
        Write-Host "ERROR: Required key 'Exclude Folders' not found in config" -ForegroundColor Red
        exit 1
    }
    $ConfigFolders = $config['Exclude Folders']
}

# Ensure folders list is an array even if empty
if (-not $ConfigFolders) {
    $ConfigFolders = @()
}

# Automatic log name: use the Config folder's leaf name
$LOGNAME = Split-Path $ConfigFolder -Leaf

$RCLONE = "rclone"
$LOG_DIR = Join-Path $PSScriptRoot "logs"

if (!(Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}

# Timestamped log file (name based on Config folder name)
$LOG_FILE = Join-Path $LOG_DIR "rclone_mirr_$LOGNAME.log"

# =============================================================================
# SAFETY CHECKS
# =============================================================================

if ([string]::IsNullOrWhiteSpace($SOURCE) -or
    [string]::IsNullOrWhiteSpace($DEST)) {

    Write-Host "ERROR: SOURCE or DEST is empty" -ForegroundColor Red
    exit 1
}

# Fix bare drive letters (e.g., "D:") Ц append backslash to make it a root
if ($SOURCE -match '^[A-Za-z]:$') { $SOURCE += '\' }
if ($DEST -match '^[A-Za-z]:$')   { $DEST += '\' }

# Normalize paths
$srcFull  = [System.IO.Path]::GetFullPath($SOURCE)
$destFull = [System.IO.Path]::GetFullPath($DEST)

# Prevent identical paths
if ($srcFull.TrimEnd('\') -ieq $destFull.TrimEnd('\')) {
    Write-Host "ERROR: SOURCE and DEST cannot be the same" -ForegroundColor Red
    exit 1
}

# Source root drive warning check (kept as an informational message)
if ($srcFull -match '^[A-Z]:\\?$') {
    Write-Host "WARNING: Source path is the root of the drive!" -ForegroundColor Red
    Write-Host "All folders from the source drive root will be synced." -ForegroundColor Yellow
    Write-Host ""
}

# Destination root warning (now in red)
if ($destFull -match '^[A-Z]:\\?$') {
    Write-Host "NOTE: Destination is a drive root. Folders will be created/synced inside it." -ForegroundColor Red
    Write-Host ""
}

# Prevent nested sync disasters
if ($destFull.StartsWith($srcFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "ERROR: DEST cannot be inside SOURCE" -ForegroundColor Red
    exit 1
}

if ($srcFull.StartsWith($destFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "ERROR: SOURCE cannot be inside DEST" -ForegroundColor Red
    exit 1
}

# Check SOURCE existence
if (-not (Test-Path $srcFull)) {
    Write-Host "ERROR: SOURCE does not exist" -ForegroundColor Red
    exit 1
}

# Create DEST if missing
if (-not (Test-Path $destFull)) {
    Write-Host "DEST does not exist. Creating..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $destFull -Force | Out-Null
}

# Check rclone availability
if (-not (Get-Command $RCLONE -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: rclone not found in PATH" -ForegroundColor Red
    exit 1
}

# Create log directory
if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}

# =============================================================================
# READ EXTERNAL ARGUMENTS AND FILTERS (with comment support)
# =============================================================================

# Ignore empty lines and lines starting with # or ; (comments)
$externalArgs = Get-Content -Path $argsFile |
    Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^\s*[#;]' } |
    ForEach-Object { $_.Trim() }

$filterLines = Get-Content -Path $filterFile |
    Where-Object { $_ -notmatch '^\s*$' -and $_ -notmatch '^\s*[#;]' } |
    ForEach-Object { $_.Trim() }

# =============================================================================
# CONFIG INFO Ц Task identity, active filter rules, and rclone arguments
# =============================================================================

Write-Host ""
Write-Host "========================================================" -ForegroundColor Gray
Write-Host "CONFIG INFO" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Gray
Write-Host "Configs folder : $ConfigFolder" -ForegroundColor White
Write-Host "Log file       : $LOG_FILE" -ForegroundColor White
Write-Host ""

Write-Host "--- rclone_filters.txt (global filter rules) ---" -ForegroundColor Yellow
$filterLines | ForEach-Object { Write-Host $_ }

Write-Host ""
Write-Host "--- RCLONE ARGUMENTS ---" -ForegroundColor Cyan
Write-Host ""

# Build an array of common arguments (for display purposes only; not used directly in sync)
$commonArgs = @()
$commonArgs += "--log-file=$LOG_FILE"
foreach ($argLine in $externalArgs) {
    if ($argLine -match '^--log-file') { continue }
    $line = $argLine -replace '%LOG_FILE%', $LOG_FILE
    $commonArgs += $line
}
# Indicate that a global filter file will be used (per folder filters are added later)
$commonArgs += "--filter-from"
$commonArgs += $filterFile
if ($DryRun) {
    $commonArgs += "--dry-run"
}

foreach ($arg in $commonArgs) {
    Write-Host $arg
}
Write-Host ""
Write-Host "========================================================" -ForegroundColor Gray
Write-Host ""

# =============================================================================
# DETERMINE FOLDERS TO SYNC
# =============================================================================

# List all first-level directories in source
$AllSourceFolders = Get-ChildItem -Path $srcFull -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name

if ($Mode -eq 'include') {
    # Include only folders that exist in source
    $FoldersToSync = @()
    foreach ($f in $ConfigFolders) {
        if ($f -in $AllSourceFolders) {
            $FoldersToSync += $f
        } else {
            Write-Host "WARNING: Folder listed in config not found in source: $f" -ForegroundColor Yellow
        }
    }
    if ($FoldersToSync.Count -eq 0) {
        Write-Host "No folders to sync in Include mode. Exiting." -ForegroundColor Yellow
        exit 0
    }
} else {
    # Exclude mode
    if ($ConfigFolders.Count -eq 0) {
        Write-Host "Sync mode: Mirror ALL folders from source!" -ForegroundColor Red
        $FoldersToSync = $AllSourceFolders
    } else {
        # Exclude listed folders (remove from list, even if they don't exist)
        $FoldersToSync = $AllSourceFolders | Where-Object { $_ -notin $ConfigFolders }
        if ($FoldersToSync.Count -eq 0) {
            Write-Host "All source folders are excluded. Nothing to sync." -ForegroundColor Yellow
            exit 0
        }
    }
}

# Validate each folder to sync (no empty, ., .., etc.)
foreach ($folder in $FoldersToSync) {
    if ([string]::IsNullOrWhiteSpace($folder) -or $folder -eq '.' -or $folder -eq '..') {
        Write-Host "ERROR: Invalid folder name encountered: '$folder'" -ForegroundColor Red
        exit 1
    }
    $fullSrcFolder = Join-Path $srcFull $folder
    if ($fullSrcFolder.TrimEnd('\') -eq $srcFull.TrimEnd('\')) {
        Write-Host "ERROR: Attempt to sync root itself detected for folder: $folder" -ForegroundColor Red
        exit 1
    }
}

# =============================================================================
# DETECT FOLDER-SPECIFIC FILTER FILES
# =============================================================================
# For each folder we look for a file named "<FolderName>_filters.txt"
# in the Config folder. If present, it will be applied BEFORE the global
# rclone_filters.txt so that it can override or extend global rules (e.g.,
# reincluding items excluded globally).
$specificFilter = @{}   # key = folder name, value = path to its specific filter file (or $null)

foreach ($folder in $FoldersToSync) {
    $candidate = Join-Path $ConfigFolder "$folder`_filters.txt"
    if (Test-Path $candidate) {
        $specificFilter[$folder] = $candidate
    } else {
        $specificFilter[$folder] = $null
    }
}

# =============================================================================
# CONFIRMATION (updated to show per-folder filter status)
# =============================================================================

Write-Host ""
Write-Host "SOURCE : $srcFull"
Write-Host "DEST   : $destFull"
Write-Host ""

if ($DryRun) {
    Write-Host "MODE   : DRY RUN" -ForegroundColor Yellow
} else {
    Write-Host "MODE   : FULL MIRROR" -ForegroundColor Cyan
}

Write-Host "Sync mode: $Mode" -ForegroundColor White
Write-Host "Folders to sync ($($FoldersToSync.Count)):" -ForegroundColor White
foreach ($f in $FoldersToSync) {
    $specificPath = $specificFilter[$f]
    if ($specificPath) {
        $filterName = Split-Path $specificPath -Leaf
        Write-Host "  $f  (specific filter: $filterName + global)" -ForegroundColor Magenta
    } else {
        Write-Host "  $f  (global filter only)" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "Inside each folder, rclone sync will mirror contents." -ForegroundColor Yellow
Write-Host "Files missing in source will be DELETED within those folders." -ForegroundColor Yellow
Write-Host "Other folders on destination will remain untouched." -ForegroundColor Yellow
Write-Host ""

# "Y" confirmation (case-insensitive)
$confirm = Read-Host "Type Y to continue"

if ($confirm -ne "y") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit
}

# =============================================================================
# EXECUTION
# =============================================================================

Write-Host ""
Write-Host "Starting backup..." -ForegroundColor Green
Write-Host "Log file: $LOG_FILE"
Write-Host ""

# Remove old log if exists (fresh log for this session)
if (Test-Path $LOG_FILE) {
    Remove-Item $LOG_FILE -Force
}

$overallExitCode = 0
$criticalStop = $false
$criticalFolder = ""

foreach ($folder in $FoldersToSync) {
    $srcPath = Join-Path $srcFull $folder
    $dstPath = Join-Path $destFull $folder

    # Build rclone arguments for this folder
    $folderArgs = @(
        "sync",
        $srcPath,
        $dstPath
    )

    # Always include log file (rclone appends by default if the file already exists)
    $folderArgs += "--log-file=$LOG_FILE"

    # Append arguments from rclone_arguments.txt, replacing log file placeholder
    foreach ($argLine in $externalArgs) {
        # Skip user-supplied log-file to avoid duplicates (ours takes precedence)
        if ($argLine -match '^--log-file') { continue }
        $line = $argLine -replace '%LOG_FILE%', $LOG_FILE
        $folderArgs += $line
    }

    # --- Folder-specific filter chain (specific first, then global) ---
    $specificPath = $specificFilter[$folder]
    if ($specificPath) {
        # Apply the folder-specific filter BEFORE the global one,
        # allowing rules like "+ /Folder/..." to take effect early.
        $folderArgs += @("--filter-from", $specificPath)
        Write-Host "  [Filter] Using specific: $(Split-Path $specificPath -Leaf)" -ForegroundColor DarkGray
    }
    # Always apply the global filter file after any specific one
    $folderArgs += @("--filter-from", $filterFile)

    # Dry run if enabled
    if ($DryRun) {
        $folderArgs += "--dry-run"
    }

    Write-Host "Syncing folder: $folder" -ForegroundColor Cyan

    # Prepare a temporary file in the logs folder to capture stderr
    $tempErrorFile = Join-Path $LOG_DIR "rclone_stderr_$([System.Guid]::NewGuid().ToString('N')).tmp"
    try {
        & $RCLONE @folderArgs 2>"$tempErrorFile"
        $exitCode = $LASTEXITCODE

        # Read stderr content to check for disk full errors
        $errorOutput = Get-Content -Path $tempErrorFile -Raw -ErrorAction SilentlyContinue

        # Check for critical "no space" condition based on error text only
        $diskFull = $false
        if ($errorOutput -match 'no space left on device|disk full|not enough space|insufficient disk space|недостаточно места|нет места на диске') {
            $diskFull = $true
        }

        if ($diskFull) {
            Write-Host "CRITICAL: Insufficient disk space on destination detected while syncing folder '$folder'." -ForegroundColor Red
            Write-Host "Stopping backup. Remaining folders will not be processed." -ForegroundColor Red
            $criticalStop = $true
            $criticalFolder = $folder
            $overallExitCode = $exitCode
            break
        }

        # Non-zero exit code without disk full Ц continue with next folder
        if ($exitCode -ne 0) {
            Write-Host "WARNING: rclone returned exit code $exitCode for folder '$folder'" -ForegroundColor Red
            $overallExitCode = 1
        }
    }
    finally {
        # Clean up temporary error file
        if (Test-Path $tempErrorFile) {
            Remove-Item $tempErrorFile -Force
        }
    }
}

# =============================================================================
# RESULT
# =============================================================================

# Clear any leftover progress bar artifacts
Write-Host ""
Write-Host ""

if ($criticalStop) {
    Write-Host "BACKUP STOPPED Ц insufficient disk space on destination (folder '$criticalFolder')." -ForegroundColor Red
}
elseif ($overallExitCode -eq 0) {
    Write-Host "SUCCESS" -ForegroundColor Green
}
else {
    Write-Host "FAILED (one or more folder syncs had errors)" -ForegroundColor Red
}

Write-Host "========================================================" -ForegroundColor Gray
Write-Host ""

# Display the latest statistics lines from rclone log
if (Test-Path $LOG_FILE) {
    Write-Host "Final Statistics:" -ForegroundColor Cyan
    Write-Host ""
    $logTail = Get-Content -Path $LOG_FILE -Tail 6
    foreach ($line in $logTail) {
        Write-Host $line
    }
    Write-Host ""
    Write-Host "========================================================" -ForegroundColor Gray
    Write-Host ""

    # Search and display all errors and file failures (ERROR or Failed)
    $logErrors = Get-Content -Path $LOG_FILE | Where-Object { $_ -match "ERROR :" -or $_ -match "Failed to" }
    
    if ($logErrors) {
        Write-Host "FOUND ERRORS / FAILED FILES IN LOG:" -ForegroundColor Red
        Write-Host ""
        
        foreach ($errorLine in $logErrors) {
            Write-Host $errorLine -ForegroundColor DarkRed
            Write-Host ""
        }
        
        Write-Host "========================================================" -ForegroundColor Gray
        Write-Host ""
    }
    else {
        Write-Host "No errors or failed files found in the log." -ForegroundColor Green
        Write-Host ""
        Write-Host "========================================================" -ForegroundColor Gray
        Write-Host ""
    }
}

if ($criticalStop -or $overallExitCode -ne 0) {
    Write-Host "Check the full log for details: $LOG_FILE" -ForegroundColor Yellow
    Write-Host ""
}

Read-Host "Press Enter to exit"