# =============================================================================
# GHOULSec Home Lab — DC Post-Promotion Configuration Script
# Script:  02-post-promotion.ps1
# Author:  AmintheGHOUL
# Domain:  ghoul.local
# DC:      GHOUL-DC01 (192.168.10.10)
# =============================================================================
# Run this script AFTER 01-pre-promotion.ps1 has completed and the server
# has rebooted into the ghoul.local domain.
#
# Prerequisites:
#   1. 01-pre-promotion.ps1 completed successfully
#   2. Server rebooted
#   3. Logged in as GHOUL\Administrator
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  GHOULSec Lab — Post-Promotion Script" -ForegroundColor Cyan
Write-Host "  02-post-promotion.ps1" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# PHASE 1 — DNS CLEANUP
# =============================================================================
Write-Host "[*] Phase 1 — DNS Cleanup" -ForegroundColor Yellow

# Disable DNS registration on NAT adapter if it still exists
foreach ($alias in @("Ethernet1", "Ethernet 1")) {
    try {
        Set-DnsClient -InterfaceAlias $alias -RegisterThisConnectionsAddress $false -ErrorAction Stop
        Write-Host "    [+] DNS registration disabled on $alias" -ForegroundColor Green
    } catch {
        # Adapter not present — skip silently
    }
}

# Flush and re-register DNS
ipconfig /flushdns | Out-Null
ipconfig /registerdns | Out-Null
Start-Sleep -Seconds 8

# Remove any stale NAT IPs from the DNS zone
$badIPs = @("192.168.117.129", "192.168.128.1", "192.168.101.1", "192.168.117.1")
foreach ($ip in $badIPs) {
    try {
        $records = Get-DnsServerResourceRecord -ZoneName "ghoul.local" -RRType A -ErrorAction SilentlyContinue |
            Where-Object { $_.RecordData.IPv4Address.IPAddressToString -eq $ip }
        foreach ($record in $records) {
            Remove-DnsServerResourceRecord -ZoneName "ghoul.local" -InputObject $record -Force
            Write-Host "    [+] Removed stale DNS record: $ip" -ForegroundColor Green
        }
    } catch {
        # No record — skip silently
    }
}

Write-Host "    [+] DNS cleanup complete" -ForegroundColor Green
Write-Host ""

# Verify DNS is clean
$dnsCheck = Resolve-DnsName "ghoul.local" -ErrorAction SilentlyContinue
Write-Host "    ghoul.local resolves to:" -ForegroundColor Cyan
$dnsCheck | Select-Object -ExpandProperty IPAddress | ForEach-Object {
    Write-Host "    $_" -ForegroundColor White
}
Write-Host ""

# =============================================================================
# PHASE 2 — FIREWALL — ICMP
# =============================================================================
Write-Host "[*] Phase 2 — Firewall Configuration" -ForegroundColor Yellow

# Remove existing rules first to avoid duplicates
netsh advfirewall firewall delete rule name="GhoulLab ICMP In" | Out-Null
netsh advfirewall firewall delete rule name="GhoulLab ICMP Out" | Out-Null

netsh advfirewall firewall add rule name="GhoulLab ICMP In" `
    protocol=icmpv4:8,any dir=in action=allow | Out-Null
netsh advfirewall firewall add rule name="GhoulLab ICMP Out" `
    protocol=icmpv4:8,any dir=out action=allow | Out-Null

Write-Host "    [+] ICMP inbound and outbound rules added" -ForegroundColor Green
Write-Host ""

# =============================================================================
# PHASE 3 — ORGANIZATIONAL UNITS
# =============================================================================
Write-Host "[*] Phase 3 — Creating Organizational Units" -ForegroundColor Yellow

$OUs = @(
    @{ Name = "GhoulCorp";       Path = "DC=ghoul,DC=local" },
    @{ Name = "IT";              Path = "OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "Finance";         Path = "OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "HR";              Path = "OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "Management";      Path = "OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "ServiceAccounts"; Path = "OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "AdminAccounts";   Path = "OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "Users";           Path = "OU=IT,OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "Computers";       Path = "OU=IT,OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "Users";           Path = "OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "Computers";       Path = "OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "Users";           Path = "OU=HR,OU=GhoulCorp,DC=ghoul,DC=local" },
    @{ Name = "Users";           Path = "OU=Management,OU=GhoulCorp,DC=ghoul,DC=local" }
)

foreach ($OU in $OUs) {
    try {
        New-ADOrganizationalUnit -Name $OU.Name -Path $OU.Path -ErrorAction Stop
        Write-Host "    [+] Created: OU=$($OU.Name),$($OU.Path)" -ForegroundColor Green
    } catch [Microsoft.ActiveDirectory.Management.ADIdentityAlreadyExistsException] {
        Write-Host "    [!] Already exists: OU=$($OU.Name) — skipping" -ForegroundColor DarkYellow
    } catch {
        Write-Host "    [!] Error creating OU=$($OU.Name): $_" -ForegroundColor Red
    }
}

Write-Host ""

# =============================================================================
# PHASE 4 — USER ACCOUNTS
# =============================================================================
Write-Host "[*] Phase 4 — Creating User Accounts" -ForegroundColor Yellow

$Users = @(
    @{
        Name           = "John Smith"
        SamAccountName = "jsmith"
        Password       = "Welcome1!"
        Path           = "OU=Users,OU=IT,OU=GhoulCorp,DC=ghoul,DC=local"
        Department     = "IT"
        Title          = "Helpdesk Technician"
        Description    = "IT Helpdesk - low privilege foothold account"
    },
    @{
        Name           = "Jane Doe"
        SamAccountName = "jdoe"
        Password       = "Summer2024!"
        Path           = "OU=Users,OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local"
        Department     = "Finance"
        Title          = "Financial Analyst"
        Description    = "Finance dept - lateral movement target"
    },
    @{
        Name           = "Bob Williams"
        SamAccountName = "bwilliams"
        Password       = "HR@2024!"
        Path           = "OU=Users,OU=HR,OU=GhoulCorp,DC=ghoul,DC=local"
        Department     = "HR"
        Title          = "HR Coordinator"
        Description    = "HR dept - phishing target"
    },
    @{
        Name           = "Sarah Connor"
        SamAccountName = "sconnor"
        Password       = "Manager2024!"
        Path           = "OU=Users,OU=Management,OU=GhoulCorp,DC=ghoul,DC=local"
        Department     = "Management"
        Title          = "IT Manager"
        Description    = "Management - high value target"
    },
    @{
        Name           = "SQL Service"
        SamAccountName = "svc-sql"
        Password       = "Password123!"
        Path           = "OU=ServiceAccounts,OU=GhoulCorp,DC=ghoul,DC=local"
        Department     = ""
        Title          = ""
        Description    = "SQL Server service account - Kerberoasting target"
    },
    @{
        Name           = "IT Admin"
        SamAccountName = "itadmin"
        Password       = "ITAdm1n@GhoulCorp#24"
        Path           = "OU=AdminAccounts,OU=GhoulCorp,DC=ghoul,DC=local"
        Department     = ""
        Title          = ""
        Description    = "IT Admin - Domain Admin target"
    }
)

foreach ($User in $Users) {
    try {
        $SecurePass = ConvertTo-SecureString $User.Password -AsPlainText -Force
        $Params = @{
            Name            = $User.Name
            SamAccountName  = $User.SamAccountName
            AccountPassword = $SecurePass
            Path            = $User.Path
            Description     = $User.Description
            Company         = "GhoulCorp"
            Enabled         = $true
        }
        if ($User.Department -ne "") { $Params.Department = $User.Department }
        if ($User.Title -ne "")      { $Params.Title      = $User.Title }

        New-ADUser @Params -ErrorAction Stop
        Write-Host "    [+] Created: $($User.SamAccountName) ($($User.Name))" -ForegroundColor Green

    } catch [Microsoft.ActiveDirectory.Management.ADIdentityAlreadyExistsException] {
        $SecurePass = ConvertTo-SecureString $User.Password -AsPlainText -Force
        Set-ADAccountPassword -Identity $User.SamAccountName -NewPassword $SecurePass -Reset
        Enable-ADAccount -Identity $User.SamAccountName
        Write-Host "    [!] Already exists: $($User.SamAccountName) — password reset, account enabled" -ForegroundColor DarkYellow

    } catch {
        Write-Host "    [!] Error creating $($User.SamAccountName): $_" -ForegroundColor Red
    }
}

Write-Host ""

# =============================================================================
# PHASE 5 — SECURITY GROUPS
# =============================================================================
Write-Host "[*] Phase 5 — Creating Security Groups" -ForegroundColor Yellow

$Groups = @(
    @{ Name = "IT-Staff";      Path = "OU=IT,OU=GhoulCorp,DC=ghoul,DC=local";            Members = @("jsmith") },
    @{ Name = "Finance-Staff"; Path = "OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local";       Members = @("jdoe") },
    @{ Name = "IT-Admins";     Path = "OU=AdminAccounts,OU=GhoulCorp,DC=ghoul,DC=local"; Members = @("itadmin") }
)

foreach ($Group in $Groups) {
    try {
        New-ADGroup -Name $Group.Name -GroupScope Global -Path $Group.Path -ErrorAction Stop
        Write-Host "    [+] Created group: $($Group.Name)" -ForegroundColor Green
    } catch [Microsoft.ActiveDirectory.Management.ADIdentityAlreadyExistsException] {
        Write-Host "    [!] Group already exists: $($Group.Name) — skipping" -ForegroundColor DarkYellow
    } catch {
        Write-Host "    [!] Error creating group $($Group.Name): $_" -ForegroundColor Red
    }

    foreach ($Member in $Group.Members) {
        try {
            Add-ADGroupMember -Identity $Group.Name -Members $Member -ErrorAction Stop
            Write-Host "    [+] Added $Member to $($Group.Name)" -ForegroundColor Green
        } catch {
            Write-Host "    [!] Could not add $Member to $($Group.Name) (may already be a member)" -ForegroundColor DarkYellow
        }
    }
}

# Add itadmin to Domain Admins
try {
    Add-ADGroupMember -Identity "Domain Admins" -Members "itadmin" -ErrorAction Stop
    Write-Host "    [+] Added itadmin to Domain Admins" -ForegroundColor Green
} catch {
    Write-Host "    [!] itadmin already in Domain Admins — skipping" -ForegroundColor DarkYellow
}

Write-Host ""

# =============================================================================
# PHASE 6 — ADCS INSTALLATION
# =============================================================================
Write-Host "[*] Phase 6 — Installing ADCS" -ForegroundColor Yellow

$adcsFeature = Get-WindowsFeature -Name ADCS-Cert-Authority
if ($adcsFeature.Installed) {
    Write-Host "    [!] ADCS role already installed — skipping role install" -ForegroundColor DarkYellow
} else {
    Write-Host "    [*] Installing ADCS-Cert-Authority (this may take a few minutes)..." -ForegroundColor Cyan
    Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools | Out-Null
    Write-Host "    [+] ADCS role installed" -ForegroundColor Green
}

# Configure CA — skip if already configured
try {
    Install-AdcsCertificationAuthority `
        -CAType EnterpriseRootCA `
        -CACommonName "GhoulCorp-CA" `
        -KeyLength 2048 `
        -HashAlgorithmName SHA256 `
        -ValidityPeriod Years `
        -ValidityPeriodUnits 5 `
        -Force -ErrorAction Stop
    Write-Host "    [+] GhoulCorp-CA configured" -ForegroundColor Green
} catch {
    if ($_.Exception.Message -like "*already installed*" -or $_.Exception.Message -like "*already exists*") {
        Write-Host "    [!] CA already configured — skipping" -ForegroundColor DarkYellow
    } else {
        Write-Host "    [!] CA configuration error: $_" -ForegroundColor Red
    }
}

# Enable CA audit logging
try {
    certutil -setreg CA\AuditFilter 127 2>&1 | Out-Null
    Restart-Service certsvc -Force
    Write-Host "    [+] CA audit logging enabled" -ForegroundColor Green
} catch {
    Write-Host "    [!] Could not set CA audit logging: $_" -ForegroundColor DarkYellow
}

Write-Host ""

# =============================================================================
# PHASE 7 — AUDIT POLICIES AND POWERSHELL LOGGING
# =============================================================================
Write-Host "[*] Phase 7 — Enabling Audit Policies and PowerShell Logging" -ForegroundColor Yellow

# Advanced audit policies
$AuditPolicies = @(
    @{ Sub = "Kerberos Authentication Service";    Flags = "/success:enable /failure:enable" },
    @{ Sub = "Kerberos Service Ticket Operations"; Flags = "/success:enable /failure:enable" },
    @{ Sub = "Directory Service Access";           Flags = "/success:enable" },
    @{ Sub = "Directory Service Changes";          Flags = "/success:enable" },
    @{ Sub = "Logon";                              Flags = "/success:enable /failure:enable" },
    @{ Sub = "Account Logon";                      Flags = "/success:enable /failure:enable" },
    @{ Sub = "Sensitive Privilege Use";            Flags = "/success:enable /failure:enable" },
    @{ Sub = "Process Creation";                   Flags = "/success:enable" }
)

foreach ($policy in $AuditPolicies) {
    $cmd = "auditpol /set /subcategory:`"$($policy.Sub)`" $($policy.Flags)"
    $result = cmd /c $cmd 2>&1
    Write-Host "    [+] Audit enabled: $($policy.Sub)" -ForegroundColor Green
}

# PowerShell Script Block Logging
$sbPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
New-Item -Path $sbPath -Force | Out-Null
Set-ItemProperty -Path $sbPath -Name "EnableScriptBlockLogging" -Value 1 -Type DWord
Write-Host "    [+] PowerShell ScriptBlock logging enabled (Event ID 4104)" -ForegroundColor Green

# PowerShell Module Logging
$modPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging"
New-Item -Path $modPath -Force | Out-Null
Set-ItemProperty -Path $modPath -Name "EnableModuleLogging" -Value 1 -Type DWord
New-Item -Path "$modPath\ModuleNames" -Force | Out-Null
Set-ItemProperty -Path "$modPath\ModuleNames" -Name "*" -Value "*" -Type String
Write-Host "    [+] PowerShell Module logging enabled" -ForegroundColor Green

# PowerShell Transcription
$transPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription"
New-Item -Path $transPath -Force | Out-Null
Set-ItemProperty -Path $transPath -Name "EnableTranscripting"   -Value 1      -Type DWord
Set-ItemProperty -Path $transPath -Name "OutputDirectory"       -Value "C:\PSTranscripts" -Type String
Set-ItemProperty -Path $transPath -Name "EnableInvocationHeader"-Value 1      -Type DWord
New-Item -ItemType Directory -Path "C:\PSTranscripts" -Force | Out-Null
Write-Host "    [+] PowerShell Transcription enabled → C:\PSTranscripts" -ForegroundColor Green

Write-Host ""

# =============================================================================
# PHASE 8 — VERIFICATION
# =============================================================================
Write-Host "[*] Phase 8 — Verification" -ForegroundColor Yellow
Write-Host ""

Write-Host "    --- Domain Info ---" -ForegroundColor Cyan
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode | Format-List

Write-Host "    --- AD Computers ---" -ForegroundColor Cyan
Get-ADComputer -Filter * | Select-Object Name | Format-Table -AutoSize

Write-Host "    --- AD Users in GhoulCorp ---" -ForegroundColor Cyan
Get-ADUser -Filter * -SearchBase "OU=GhoulCorp,DC=ghoul,DC=local" `
    -Properties Department, Title |
    Select-Object Name, SamAccountName, Department, Title |
    Format-Table -AutoSize

Write-Host "    --- Domain Admins ---" -ForegroundColor Cyan
Get-ADGroupMember -Identity "Domain Admins" |
    Select-Object Name, SamAccountName |
    Format-Table -AutoSize

Write-Host "    --- ADCS CA Status ---" -ForegroundColor Cyan
try {
    Get-Service certsvc | Select-Object Name, Status | Format-Table -AutoSize
} catch {
    Write-Host "    [!] certsvc not found" -ForegroundColor DarkYellow
}

Write-Host "    --- Audit Policy (Kerberos) ---" -ForegroundColor Cyan
cmd /c "auditpol /get /subcategory:`"Kerberos Authentication Service`"" 2>&1

Write-Host ""

# =============================================================================
# DONE
# =============================================================================
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  DC Configuration Complete" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next steps (manual):" -ForegroundColor White
Write-Host "  1. Create VulnTemplate1 in ADCS GUI (ESC1 misconfiguration)" -ForegroundColor White
Write-Host "     certmgr → Certificate Templates → Duplicate 'User' template" -ForegroundColor White
Write-Host "     Subject Name tab: Supply in the request" -ForegroundColor White
Write-Host "     Security tab: Domain Users → Allow Enroll" -ForegroundColor White
Write-Host ""
Write-Host "  2. Join GHOUL-WS1 (192.168.10.100) to ghoul.local" -ForegroundColor White
Write-Host "  3. Join GHOUL-WS2 (192.168.10.101) to ghoul.local" -ForegroundColor White
Write-Host "  4. Log in as ghoul\jsmith on WS1 to cache credentials" -ForegroundColor White
Write-Host "  5. Log in as ghoul\jdoe  on WS2 to cache credentials" -ForegroundColor White
Write-Host "  6. Apply misconfigurations manually (see 02-misconfigurations.md)" -ForegroundColor White
Write-Host "  7. Take snapshot: 'DC Config Complete'" -ForegroundColor White
Write-Host ""
