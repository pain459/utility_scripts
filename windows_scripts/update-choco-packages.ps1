# Update all Chocolatey packages
# Run this script with elevated privileges
# If execution policy is restricted, run: 'Set-ExecutionPolicy RemoteSigned -Scope CurrentUser' first

# Check execution policy
$policy = Get-ExecutionPolicy -Scope CurrentUser
if ($policy -eq "Restricted") {
    Write-Warning "Current execution policy is Restricted. To fix:
1. Run: 'Set-ExecutionPolicy RemoteSigned -Scope CurrentUser'
2. Or run: 'powershell -ExecutionPolicy Bypass -File $PSCommandPath'"
}

Write-Output "Upgrading all Choco packages..."
choco upgrade all -y

if ($LASTEXITCODE -eq 0) {
    Write-Output "All packages updated successfully"
} else {
    Write-Error "Error updating packages"
}