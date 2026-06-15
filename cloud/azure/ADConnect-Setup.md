# AD Connect — Hybrid Identity Setup

**Type:** Infrastructure Configuration  
**Platform:** GHOUL-DC01 (Windows Server 2019) → Microsoft Entra ID  
**Purpose:** Sync ghoul.local to Entra ID for hybrid identity attack scenarios

---

## Prerequisites

### Network Configuration

DC01 requires internet access for AD Connect to reach Azure. The VM is configured with two network adapters:

- **Network Adapter 1** — VMnet1 (Host-only) — lab subnet `192.168.10.0/24`
- **Network Adapter 2** — NAT — internet access via host machine

> **Screenshot 1:** VMware VM settings showing dual NIC — VMnet1 (lab) + NAT (internet)

Confirm internet connectivity from DC01:

```powershell
Test-NetConnection -ComputerName login.microsoftonline.com -Port 443
```

> **Screenshot 2:** PowerShell showing `TcpTestSucceeded: True` via Ethernet1 (192.168.101.131)

---

### Enable TLS 1.2

AD Connect requires TLS 1.2. Run this on DC01 as Administrator before installation:

```powershell
# WinHTTP
New-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' -Name 'DefaultSecureProtocols' -Value '0x00000800' -Type DWord

New-Item 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' -Name 'DefaultSecureProtocols' -Value '0x00000800' -Type DWord

# SCHANNEL TLS 1.2 Server
New-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Name 'Enabled' -Value '1' -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -Name 'DisabledByDefault' -Value '0' -Type DWord

# SCHANNEL TLS 1.2 Client
New-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -Name 'Enabled' -Value '1' -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -Name 'DisabledByDefault' -Value '0' -Type DWord

# .NET Framework
New-Item 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SystemDefaultTlsVersions' -Value '1' -Type DWord

New-Item 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319' -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319' -Name 'SystemDefaultTlsVersions' -Value '1' -Type DWord

Restart-Computer -Force
```

DC01 will restart automatically. After reboot, proceed with installation.

---

### Create Sync Admin Account in Entra

AD Connect requires a native Entra account (not a guest/Gmail account) with Hybrid Identity Administrator role.

1. Go to `entra.microsoft.com` → **Users → + New user → Create new user**
2. Set:
   - UPN: `syncadmin@<your-tenant>.onmicrosoft.com`
   - Display name: `Sync Admin`
   - Uncheck "Require password change on next login"
3. Assign role: **Hybrid Identity Administrator** (or Global Administrator)
4. Complete MFA enrollment if prompted

---

## Installation

Download AD Connect on DC01:

```
https://aka.ms/AADConnectDownload
```

Run the installer → accept license → click **"Use express settings"**.

**Express settings configures:**
- Password Hash Synchronisation
- Sync all users and groups from `ghoul.local`
- Auto-upgrade enabled
- Sync interval: 30 minutes

**Connect to Microsoft Entra ID:**

| Field | Value |
|---|---|
| Username | `syncadmin@<your-tenant>.onmicrosoft.com` |
| Password | syncadmin password |

**Connect to AD DS:**

| Field | Value |
|---|---|
| Username | `GHOUL\Administrator` |
| Password | DC01 Administrator password |

**UPN suffix warning:** `ghoul.local` is non-routable — click through, this is expected. Users will sync with `@<your-tenant>.onmicrosoft.com` UPN suffix.

Click **Install** — configuration completes in about 2 minutes.

---

## Verify Sync

After installation, the initial sync runs automatically. Verify in Entra ID:

Go to `entra.microsoft.com` → **Users → All users**

> **Screenshot 3:** Entra ID Users page showing 11 synced accounts from ghoul.local

**Confirmed synced accounts:**

| Display Name | Source | Notes |
|---|---|---|
| Bob Jones | ghoul.local | Finance Manager — attack target |
| Bob Williams | ghoul.local | |
| IT Admin | ghoul.local | |
| Jane Doe | ghoul.local | Finance department |
| John Smith (jsmith6951) | ghoul.local | IT — synced version |
| On-Premises Directory Sync | AD Connect | Sync service account |
| Sarah Connor | ghoul.local | |
| SQL Service | ghoul.local | Kerberoastable SPN |

---

## MSOL Account Verification

AD Connect creates `MSOL_xxxxxxxx` in on-prem AD with DS-Replication rights. Confirm on DC01:

```powershell
Get-ADUser -Filter {Name -like "MSOL*"} | Select Name, SamAccountName, DistinguishedName
```

**Output:**
```
Name              SamAccountName    DistinguishedName
----              --------------    -----------------
MSOL_<auto-generated-id> MSOL_<auto-generated-id> CN=MSOL_<auto-generated-id>,CN=Users,DC=ghoul,DC=local
```

Confirm DCSync rights:

```powershell
$acl = Get-ACL "AD:\DC=ghoul,DC=local"
$acl.Access | Where-Object {
    $_.IdentityReference -like "*MSOL*" -and 
    $_.ActiveDirectoryRights -like "*ExtendedRight*"
} | Select IdentityReference, ActiveDirectoryRights, ObjectType
```

**Output:**
```
IdentityReference           ActiveDirectoryRights  ObjectType
-----------------           ---------------------  ----------
GHOUL\MSOL_<auto-generated-id>     ExtendedRight  1131f6aa-9c07-11d1-f79f-00c04fc2dcd2
GHOUL\MSOL_<auto-generated-id>     ExtendedRight  1131f6ad-9c07-11d1-f79f-00c04fc2dcd2
GHOUL\MSOL_<auto-generated-id>     ExtendedRight  00299570-246d-11d0-a768-00aa006e0529
```

> **Screenshot 4:** PowerShell confirming MSOL_<auto-generated-id> has both DCSync GUIDs

| GUID | Right |
|---|---|
| `1131f6aa...` | DS-Replication-Get-Changes ✓ |
| `1131f6ad...` | DS-Replication-Get-Changes-All ✓ |
| `00299570...` | User-Force-Change-Password ✓ |

---

## ADSync Service

Confirm the ADSync service is running:

```powershell
Get-WmiObject Win32_Service | Where-Object {$_.Name -like "*ADSync*"} | Select Name, StartName, State
```

**Output:**
```
Name   StartName             State
----   ---------             -----
ADSync GHOUL\ADSyncMSA<id>$ Running
```

ADSync runs as a Group Managed Service Account (`ADSyncMSA<id>$`) — automatically managed password.

---

## Sync Configuration

```powershell
# Check sync status
Get-ADSyncConnector | Select Name, ConnectorTypeName, State
```

| Parameter | Value |
|---|---|
| Sync interval | PT30M (every 30 minutes) |
| Password Hash Sync | Enabled |
| Total objects synced | 16 |
| Database | `.\ADSync2019` LocalDB |
| DB path | `C:\Program Files\Microsoft Azure AD Sync\Data\ADSync2019\ADSync.mdf` |

---

## Force Manual Sync

To trigger an immediate sync cycle:

```powershell
Import-Module ADSync
Start-ADSyncSyncCycle -PolicyType Delta
```

For a full sync:

```powershell
Start-ADSyncSyncCycle -PolicyType Initial
```

---

## Summary

| Component | Status |
|---|---|
| TLS 1.2 enabled on DC01 | ✓ |
| AD Connect installed | ✓ |
| Password Hash Sync active | ✓ |
| 11 users synced to Entra | ✓ |
| MSOL_<auto-generated-id> created | ✓ |
| DCSync rights confirmed | ✓ |
| ADSync service running | ✓ |

Hybrid identity bridge is fully operational. The attack scenarios that depend on this setup are documented in:

- `C-07-MSOL-Credential-Extraction.md` — extracting MSOL credentials from Azure
- `C-08-DCSync-AV-Evasion.md` — DCSync with AMSI bypass and Mimikatz evasion
- `C-09-Golden-Ticket.md` — KRBTGT extraction and Golden Ticket forgery

---

*GHOULSec Home Lab — Infrastructure Setup*  
*github.com/AmintheGHOUL/GHOULSec-HomeLab*
