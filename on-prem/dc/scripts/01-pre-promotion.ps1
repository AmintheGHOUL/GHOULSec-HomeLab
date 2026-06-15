# =============================================================================
# GHOULSec Home Lab — DC Pre-Promotion Script
# Script:  01-pre-promotion.ps1
# Author:  AmintheGHOUL
# Run on:  Fresh Windows Server 2019 — before domain exists
# Follows: GHOUL-DC01 Setup document
# =============================================================================
# What this script does:
#   1. Renames the machine to GHOUL-DC01
#   2. Sets static IP 192.168.10.10
#   3. Installs AD DS role
#   4. Promotes server to Domain Controller (ghoul.local)
#   5. Server reboots automatically
#
# After reboot run: 02-post-promotion.ps1
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  GHOULSec Lab — Pre-Promotion Script" -ForegroundColor Cyan
Write-Host "  01-pre-promotion.ps1" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This script will:" -ForegroundColor White
Write-Host "  1. Rename machine to GHOUL-DC01" -ForegroundColor White
Write-Host "  2. Set static IP 192.168.10.10" -ForegroundColor White
Write-Host "  3. Install AD DS role" -ForegroundColor White
Write-Host "  4. Promote to Domain Controller (ghoul.local)" -ForegroundColor White
Write-Host "  5. Reboot automatically" -ForegroundColor White
Write-Host ""
Write-Host "  After reboot, run 02-post-promotion.ps1" -ForegroundColor Yellow
Write-Host ""

# Confirm before proceeding
$confirm = Read-Host "  Type YES to continue"
if ($confirm -ne "YES") {
    Write-Host "  Aborted." -ForegroundColor Red
    exit
}

Write-Host ""

# =============================================================================
# PHASE 1 — RENAME MACHINE
# =============================================================================
Write-Host "[*] Phase 1 — Renaming machine to GHOUL-DC01" -ForegroundColor Yellow

$currentName = $env:COMPUTERNAME
if ($currentName -eq "GHOUL-DC01") {
    Write-Host "    [!] Machine is already named GHOUL-DC01 — skipping" -ForegroundColor DarkYellow
} else {
    Rename-Computer -NewName "GHOUL-DC01" -Force
    Write-Host "    [+] Renamed from $currentName to GHOUL-DC01" -ForegroundColor Green
    Write-Host "    [!] Name takes effect after reboot at end of script" -ForegroundColor DarkYellow
}

Write-Host ""

# =============================================================================
# PHASE 2 — STATIC IP CONFIGURATION
# =============================================================================
Write-Host "[*] Phase 2 — Configuring Static IP" -ForegroundColor Yellow

# Find the active non-loopback adapter connected to VMnet1
# Prefer adapter already on 192.168.10.x, otherwise take first active one
$adapter = Get-NetAdapter | Where-Object {
    $_.Status -eq "Up" -and $_.Name -notlike "*Loopback*"
} | ForEach-Object {
    $ip = (Get-NetIPAddress -InterfaceAlias $_.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    [PSCustomObject]@{ Adapter = $_; IP = $ip }
} | Where-Object { $_.IP -like "192.168.10.*" } | Select-Object -First 1

# If no 192.168.10.x adapter found, fall back to first active adapter
if (-not $adapter) {
    $adapter = Get-NetAdapter | Where-Object {
        $_.Status -eq "Up" -and $_.Name -notlike "*Loopback*"
    } | Select-Object -First 1
    $adapterName = $adapter.Name
} else {
    $adapterName = $adapter.Adapter.Name
}

Write-Host "    [*] Using adapter: $adapterName" -ForegroundColor Cyan

# Remove existing IP configuration cleanly
Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

Get-NetRoute -InterfaceAlias $adapterName -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "    [+] Cleared existing IP configuration" -ForegroundColor Green

# Set static IP
New-NetIPAddress `
    -InterfaceAlias $adapterName `
    -IPAddress "192.168.10.10" `
    -PrefixLength 24 `
    -DefaultGateway "192.168.10.1"

# DNS must point to self for AD DS promotion
Set-DnsClientServerAddress `
    -InterfaceAlias $adapterName `
    -ServerAddresses "127.0.0.1"

Write-Host "    [+] Static IP set: 192.168.10.10/24" -ForegroundColor Green
Write-Host "    [+] Gateway:       192.168.10.1" -ForegroundColor Green
Write-Host "    [+] DNS:           127.0.0.1 (self)" -ForegroundColor Green

# Verify
$ipCheck = Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4
Write-Host ""
Write-Host "    Verification:" -ForegroundColor Cyan
Write-Host "    IP:     $($ipCheck.IPAddress)" -ForegroundColor White
Write-Host "    Prefix: /$($ipCheck.PrefixLength)" -ForegroundColor White

Write-Host ""

# =============================================================================
# PHASE 3 — INSTALL AD DS ROLE
# =============================================================================
Write-Host "[*] Phase 3 — Installing AD DS Role" -ForegroundColor Yellow

$feature = Get-WindowsFeature -Name AD-Domain-Services
if ($feature.Installed) {
    Write-Host "    [!] AD DS role already installed — skipping" -ForegroundColor DarkYellow
} else {
    Write-Host "    [*] Installing AD-Domain-Services (this takes a few minutes)..." -ForegroundColor Cyan
    $result = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
    if ($result.Success) {
        Write-Host "    [+] AD DS role installed successfully" -ForegroundColor Green
    } else {
        Write-Host "    [!] AD DS install failed — check Windows Update and retry" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""

# =============================================================================
# PHASE 4 — PROMOTE TO DOMAIN CONTROLLER
# =============================================================================
Write-Host "[*] Phase 4 — Promoting to Domain Controller" -ForegroundColor Yellow
Write-Host ""
Write-Host "    Domain:         ghoul.local" -ForegroundColor White
Write-Host "    NetBIOS:        GHOUL" -ForegroundColor White
Write-Host "    Forest Mode:    WinThreshold (Windows Server 2016)" -ForegroundColor White
Write-Host "    Domain Mode:    WinThreshold (Windows Server 2016)" -ForegroundColor White
Write-Host "    DNS:            Enabled" -ForegroundColor White
Write-Host "    Global Catalog: Enabled" -ForegroundColor White
Write-Host "    DSRM Password:  P@ssw0rd123!" -ForegroundColor White
Write-Host ""
Write-Host "    [!] Server reboots automatically on completion" -ForegroundColor Yellow
Write-Host "    [!] After reboot log in as GHOUL\Administrator" -ForegroundColor Yellow
Write-Host "    [!] Then run: 02-post-promotion.ps1" -ForegroundColor Yellow
Write-Host ""

# Import ADDSDeployment — available now that AD DS role is installed
Import-Module ADDSDeployment

$DSRMPassword = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force

Install-ADDSForest `
    -DomainName "ghoul.local" `
    -DomainNetbiosName "GHOUL" `
    -ForestMode "WinThreshold" `
    -DomainMode "WinThreshold" `
    -InstallDns:$true `
    -SafeModeAdministratorPassword $DSRMPassword `
    -Force:$true `
    -NoRebootOnCompletion:$false

# Script ends here — server reboots automatically
