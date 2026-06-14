# Define source and destination root paths
#$SourceFolder = "E:\"
#$DestinationFolder = "F:\"

# Read paths from environment variables set by the batch file

try {
    $SourceFolder = [Environment]::GetEnvironmentVariable('ENV_SOURCE_DIR')
    $DestinationFolder = [Environment]::GetEnvironmentVariable('ENV_DESTINATION_DIR')

    if ([string]::IsNullOrWhiteSpace($SourceFolder)) {
        throw "Environment variable ENV_SOURCE_DIR is not defined."
    }

    if ([string]::IsNullOrWhiteSpace($DestinationFolder)) {
        throw "Environment variable ENV_DESTINATION_DIR is not defined."
    }
}
catch {
    Write-Error "Failed to read path configuration: $($_.Exception.Message)"
    exit 1
}


# Write-Host "Source:      [$SourceFolder]"
# Write-Host "Destination: [$DestinationFolder]"


#  ======================================= CODE START =========================================
# Fetch top-level directories from both roots
$SourceDirs = Get-ChildItem -Path $SourceFolder -Directory | Select-Object -ExpandProperty Name
$DestinationDirs = Get-ChildItem -Path $DestinationFolder -Directory | Select-Object -ExpandProperty Name

# --- BLOCK 1: Find directories present in Source but missing in Destination ---
$MissingInDest = Compare-Object -ReferenceObject $SourceDirs -DifferenceObject $DestinationDirs -PassThru | 
    Where-Object { $DestinationDirs -notcontains $_ }

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Comparison 1 complete." -ForegroundColor Cyan
Write-Host "Source Root: $SourceFolder"
Write-Host "Destination Root: $DestinationFolder"
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

if ($MissingInDest) {
    Write-Host "The following folders are missing in `"$DestinationFolder`":" -ForegroundColor Yellow
    foreach ($Dir in $MissingInDest) {
        Write-Host $Dir -ForegroundColor Red
    }
} else {
    Write-Host "No missing directories found in Destination." -ForegroundColor Green
}


# Adding empty lines between the two blocks
Write-Host ""
Write-Host ""


# --- BLOCK 2: Find directories present in Destination but missing in Source ---
$MissingInSource = Compare-Object -ReferenceObject $DestinationDirs -DifferenceObject $SourceDirs -PassThru | 
    Where-Object { $SourceDirs -notcontains $_ }

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Comparison 2 complete (Reverse)." -ForegroundColor Cyan
Write-Host "Destination Root: $DestinationFolder"
Write-Host "Source Root: $SourceFolder"
Write-Host "--------------------------------------------------" -ForegroundColor Cyan

if ($MissingInSource) {
    Write-Host "The following folders are missing in `"$SourceFolder`":" -ForegroundColor Yellow
    foreach ($Dir in $MissingInSource) {
        Write-Host $Dir -ForegroundColor Red
    }
} else {
    Write-Host "No missing directories found in Source." -ForegroundColor Green
}

Write-Host "--------------------------------------------------" -ForegroundColor Cyan
Write-Host "Press any key to exit..." -ForegroundColor Cyan
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
