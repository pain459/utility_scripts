# Windows Performance Maintenance Script
# Requires elevated privileges (Run as Administrator)

# 1. Disk Cleanup
Write-Output "Starting disk cleanup..."
Start-Process cleanmgr /sagerun:1 -NoNewWindow -Wait

# 2. Windows Update Check
Write-Output "Checking for Windows Updates..."

# Ensure PSWindowsUpdate module is available
try {
    Import-Module PSWindowsUpdate -ErrorAction Stop
} catch {
    Write-Error "PSWindowsUpdate module not found.\n\nTo install: Install-Module PSWindowsUpdate -Force -Scope CurrentUser\nRun this in an elevated PowerShell window (Run as Administrator)"
    exit 1
}

# Get and install updates
try {
    Get-WindowsUpdate -Install -AcceptAll -AutoReboot
} catch {
    Write-Error "Windows update failed: $_"
    exit 1
}

# 3. Disk Defragment (skips SSDs)
$drives = Get-Volume | Where-Object {
    $_.DriveType -eq 'Fixed' -and $_.FileSystem -ne $null
}

foreach ($drive in $drives) {
    if (-not $drive.IsCompressed -and $drive.DriveLetter -ne $null) {
        $driveLetter = $drive.DriveLetter + ":"
        $diskType = (Get-PhysicalDisk -UniqueId $drive.UniqueId).MediaType

        if ($diskType -eq 'HDD') {
            Write-Output "Defragging $driveLetter..."
            Optimize-Volume -DriveLetter $driveLetter -Defrag
        }
    }
}

# 4. Clear Temporary Files
Write-Output "Clearing temporary files..."
try {
    Clear-Item -Path $env:TEMP -Recurse -Force -ErrorAction Stop
    Clear-Item -Path "C:\$Windows.~BT" -Recurse -Force -ErrorAction Ignore
    Clear-Item -Path "C:\$Windows.~LS" -Recurse -Force -ErrorAction Ignore
} catch {
    Write-Warning "Could not clear all temporary files"
}

# 5. System File Checker
Write-Output "Running System File Checker..."
Start-Process sfc /scannow -NoNewWindow -Wait

# 6. Check Execution Policy
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq "Restricted") {
    Write-Output "Consider running:
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
}

Write-Output "Maintenance completed successfully"