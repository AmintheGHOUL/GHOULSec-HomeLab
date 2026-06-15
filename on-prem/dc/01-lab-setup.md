# GHOULSec Home Lab — Setup Documentation

**Author:** AmintheGHOUL  
**Domain:** `ghoul.local`  
**Network:** `192.168.10.0/24`  
**Platform:** VMware Workstation Pro using `VMnet1` Host-only  

---

## What You Are Building

In this lab, you are building a small Windows Active Directory environment that looks like a basic enterprise network.

The goal is to understand how a domain controller, workstations, users, groups, OUs, DNS, ADCS, and basic lab misconfigurations fit together.

By the end of this setup, you will have:

- One Windows Server 2019 domain controller named `GHOUL-DC01`
- One Active Directory domain named `ghoul.local`
- Two Windows 11 workstations joined to the domain
- A realistic OU structure for departments, users, computers, service accounts, and admin accounts
- Test users and groups for lab scenarios
- ADCS installed as an Enterprise Root CA
- A foundation for later detection, monitoring, and security practice

---

## Network Architecture

All VMs are isolated on a host-only VMware network. This keeps the lab separate from your real home network and the internet.

Think of `VMnet1` as a private virtual switch. All lab machines connect to this same private switch so they can communicate with each other.

| Hostname     |       IP Address | Role                        | OS                         |
| ------------ | ---------------: | --------------------------- | -------------------------- |
| `GHOUL-DC01` |  `192.168.10.10` | Domain Controller           | Windows Server 2019        |
| `GHOUL-WS1`  | `192.168.10.100` | Workstation 1, IT Dept      | Windows 11 Enterprise LTSC |
| `GHOUL-WS2`  | `192.168.10.101` | Workstation 2, Finance Dept | Windows 11 Enterprise LTSC |
| `Kali`       |  `192.168.10.50` | Security testing machine    | Kali Linux, pending        |
| `Wazuh`      |  `192.168.10.20` | SIEM                        | Ubuntu 22.04, pending      |

---

## VMware Network Configuration

Before installing or configuring the domain, create the isolated VMware network.

Open **Virtual Network Editor** and configure `VMnet1` like this:

```text
VMnet1
Type:    Host-only
Subnet:  192.168.10.0
Mask:    255.255.255.0
DHCP:    Disabled
```

Each VM should have a single network adapter connected to `VMnet1`.

The NAT adapter was removed from the lab machines to avoid routing and DNS conflicts. This is important because the domain controller should be the main DNS server for the lab.

---

## Domain Controller — GHOUL-DC01

The domain controller is the most important machine in the lab. It stores Active Directory, handles domain logons, hosts DNS, and later supports certificate services.

### Specifications

```text
OS:      Windows Server 2019 Evaluation
RAM:     4GB
CPU:     2 cores
Disk:    60GB
IP:      192.168.10.10 static
DNS:     192.168.10.10 self
```

---

## Step 1 — Run the Pre-Promotion Script

The first script prepares the Windows Server and promotes it into a domain controller.

Use this script:

```text
01-pre-promotion.ps1
```

Run this script only on a fresh Windows Server 2019 installation, before the `ghoul.local` domain exists.

### What this script does

This script automates the first major setup stage:

```text
- Renames the server to GHOUL-DC01
- Configures the static IP and DNS settings
- Installs the Active Directory Domain Services role
- Promotes the server into a new forest named ghoul.local
- Creates the GHOUL NetBIOS domain
- Installs DNS with the domain controller
- Reboots the server after promotion
```

### Before running it

Confirm these items first:

```text
- The VM is connected to VMnet1.
- VMnet1 is configured as 192.168.10.0/24.
- DHCP is disabled on VMnet1.
- PowerShell is opened as Administrator.
- The local Administrator password is known.
```

### Run the script

Open PowerShell as Administrator and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\01-pre-promotion.ps1
```

When the promotion completes, the server will reboot automatically.

### After reboot

After the reboot, log in as:

```text
GHOUL\Administrator
```

Use the same local Administrator password that existed before promotion.

The DSRM password is separate. It is only used for Directory Services Restore Mode recovery, not for normal domain login.

Do not run `02-post-promotion.ps1` yet unless the server has successfully promoted, rebooted, and allowed you to log in to the domain.

---

## Active Directory Domain

After promotion, the server becomes the domain controller for this domain:

```text
Domain Name:     ghoul.local
NetBIOS Name:    GHOUL
Forest Mode:     Windows2016Domain
PDC Emulator:    GHOUL-DC01.ghoul.local
```

### What these values mean

| Item | Meaning |
|---|---|
| `ghoul.local` | The full DNS name of the Active Directory domain |
| `GHOUL` | The short NetBIOS name used in logons such as `GHOUL\jsmith` |
| `Windows2016Domain` | The functional level used by the domain |
| `GHOUL-DC01.ghoul.local` | The fully qualified name of the domain controller |

---

## DNS Configuration

DNS is hosted on the domain controller.

In Active Directory labs, DNS is critical. Domain-joined machines use DNS to find the domain controller, locate authentication services, and resolve internal hostnames.

The NAT adapter was explicitly excluded from DNS registration to prevent split-brain DNS:

```powershell
Set-DnsClient -InterfaceAlias "Ethernet1" -RegisterThisConnectionsAddress $false
ipconfig /flushdns
ipconfig /registerdns
```

Stale NAT records were manually removed from the DNS zone:

```powershell
Get-DnsServerResourceRecord -ZoneName "ghoul.local" -RRType A |
  Where-Object { $_.RecordData.IPv4Address -eq "<NAT-IP>" } |
  ForEach-Object { Remove-DnsServerResourceRecord -ZoneName "ghoul.local" -InputObject $_ -Force }
```

The important result is that `GHOUL-DC01.ghoul.local` should resolve to:

```text
192.168.10.10
```

---

## Active Directory Structure

Now that the domain exists, the next step is to organize Active Directory.

OUs are containers used to organize users, computers, service accounts, and admin accounts. A clean OU structure makes the lab easier to manage and prepares it for Group Policy later.

### Organizational Unit Hierarchy

The OU structure mirrors a simple enterprise environment.

```text
ghoul.local
└── GhoulCorp
    ├── IT
    │   ├── Users        → jsmith
    │   └── Computers    → GHOUL-WS1
    ├── Finance
    │   ├── Users        → jdoe
    │   └── Computers    → GHOUL-WS2
    ├── HR
    │   └── Users        → bwilliams
    ├── Management
    │   └── Users        → sconnor
    ├── ServiceAccounts  → svc-sql
    └── AdminAccounts    → itadmin
```

### Why this structure is useful

| OU | Purpose |
|---|---|
| `GhoulCorp` | Main company container for the lab |
| `IT` | Stores IT users, IT computers, and IT groups |
| `Finance` | Stores Finance users, computers, and groups |
| `HR` | Stores HR users |
| `Management` | Stores management users |
| `ServiceAccounts` | Stores accounts used by services or applications |
| `AdminAccounts` | Stores privileged administration accounts |

---

## User Accounts

The lab uses simple test accounts so you can practice identity, access, logging, and detection scenarios.

| Name | Username | Department | Title | Password |
|---|---|---|---|---|
| John Smith | `jsmith` | IT | Helpdesk Technician | `<LabPassword1!>` |
| Jane Doe | `jdoe` | Finance | Financial Analyst | `<LabPassword2!>` |
| Bob Williams | `bwilliams` | HR | HR Coordinator | `<LabPassword3!>` |
| Sarah Connor | `sconnor` | Management | IT Manager | `<LabPassword4!>` |
| SQL Service | `svc-sql` | — | Service Account | `<WeakSvcPassword!>` |
| IT Admin | `itadmin` | — | Domain Admin | `<StrongAdminPassword!>` |

> **Note:** Replace the password placeholders with your own lab credentials before running setup scripts. These are isolated lab accounts — never reuse passwords outside this environment.

---

## Security Groups

Groups make permissions easier to manage. Instead of assigning access to users one by one, users are placed into groups.

| Group           | Scope    | Members                    |
| --------------- | -------- | -------------------------- |
| `IT-Staff`      | Global   | `jsmith`                   |
| `Finance-Staff` | Global   | `jdoe`                     |
| `IT-Admins`     | Global   | `itadmin`                  |
| `Domain Admins` | Built-in | `Administrator`, `itadmin` |

---

## PowerShell — OU and User Creation

This is the PowerShell version of the OU, user, group, and membership setup.

Use this section to understand what the lab is creating. In practice, these commands are automated by `02-post-promotion.ps1`, which is explained right after this block.

```powershell
# Top level OU
New-ADOrganizationalUnit -Name "GhoulCorp" -Path "DC=ghoul,DC=local"

# Department OUs
New-ADOrganizationalUnit -Name "IT" -Path "OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "Finance" -Path "OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "HR" -Path "OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "Management" -Path "OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "ServiceAccounts" -Path "OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "AdminAccounts" -Path "OU=GhoulCorp,DC=ghoul,DC=local"

# Sub-OUs
New-ADOrganizationalUnit -Name "Users" -Path "OU=IT,OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "Computers" -Path "OU=IT,OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "Users" -Path "OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "Computers" -Path "OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "Users" -Path "OU=HR,OU=GhoulCorp,DC=ghoul,DC=local"
New-ADOrganizationalUnit -Name "Users" -Path "OU=Management,OU=GhoulCorp,DC=ghoul,DC=local"

# Create users (replace <Password> placeholders with your own lab credentials)
New-ADUser -Name "John Smith" -SamAccountName "jsmith" `
  -AccountPassword (ConvertTo-SecureString "<LabPassword1!>" -AsPlainText -Force) `
  -Path "OU=Users,OU=IT,OU=GhoulCorp,DC=ghoul,DC=local" `
  -Department "IT" -Title "Helpdesk Technician" -Company "GhoulCorp" -Enabled $true

New-ADUser -Name "Jane Doe" -SamAccountName "jdoe" `
  -AccountPassword (ConvertTo-SecureString "<LabPassword2!>" -AsPlainText -Force) `
  -Path "OU=Users,OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local" `
  -Department "Finance" -Title "Financial Analyst" -Company "GhoulCorp" -Enabled $true

New-ADUser -Name "Bob Williams" -SamAccountName "bwilliams" `
  -AccountPassword (ConvertTo-SecureString "<LabPassword3!>" -AsPlainText -Force) `
  -Path "OU=Users,OU=HR,OU=GhoulCorp,DC=ghoul,DC=local" `
  -Department "HR" -Title "HR Coordinator" -Company "GhoulCorp" -Enabled $true

New-ADUser -Name "Sarah Connor" -SamAccountName "sconnor" `
  -AccountPassword (ConvertTo-SecureString "<LabPassword4!>" -AsPlainText -Force) `
  -Path "OU=Users,OU=Management,OU=GhoulCorp,DC=ghoul,DC=local" `
  -Department "Management" -Title "IT Manager" -Company "GhoulCorp" -Enabled $true

New-ADUser -Name "SQL Service" -SamAccountName "svc-sql" `
  -AccountPassword (ConvertTo-SecureString "<WeakSvcPassword!>" -AsPlainText -Force) `
  -Path "OU=ServiceAccounts,OU=GhoulCorp,DC=ghoul,DC=local" `
  -Description "SQL Server Service Account" -Enabled $true

New-ADUser -Name "IT Admin" -SamAccountName "itadmin" `
  -AccountPassword (ConvertTo-SecureString "<StrongAdminPassword!>" -AsPlainText -Force) `
  -Path "OU=AdminAccounts,OU=GhoulCorp,DC=ghoul,DC=local" `
  -Description "IT Department Admin" -Enabled $true

# Groups and memberships
New-ADGroup -Name "IT-Staff" -GroupScope Global -Path "OU=IT,OU=GhoulCorp,DC=ghoul,DC=local"
New-ADGroup -Name "Finance-Staff" -GroupScope Global -Path "OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local"
New-ADGroup -Name "IT-Admins" -GroupScope Global -Path "OU=AdminAccounts,OU=GhoulCorp,DC=ghoul,DC=local"

Add-ADGroupMember -Identity "IT-Staff" -Members "jsmith"
Add-ADGroupMember -Identity "Finance-Staff" -Members "jdoe"
Add-ADGroupMember -Identity "IT-Admins" -Members "itadmin"
Add-ADGroupMember -Identity "Domain Admins" -Members "itadmin"

# Move computers to department OUs
Get-ADComputer "GHOUL-WS1" | Move-ADObject -TargetPath "OU=Computers,OU=IT,OU=GhoulCorp,DC=ghoul,DC=local"
Get-ADComputer "GHOUL-WS2" | Move-ADObject -TargetPath "OU=Computers,OU=Finance,OU=GhoulCorp,DC=ghoul,DC=local"
```

---

## Step 2 — Run the Post-Promotion Script

After the domain controller has rebooted and you have logged in as `GHOUL\Administrator`, run the second script:

```text
02-post-promotion.ps1
```

This script builds the lab objects inside the completed `ghoul.local` domain.

### What this script does

```text
- Creates the GhoulCorp OU structure
- Creates department OUs and sub-OUs
- Creates the user accounts
- Creates security groups
- Adds users to the correct groups
- Adds itadmin to Domain Admins
- Moves workstations into their department computer OUs
- Performs DNS cleanup and verification tasks
- Enables ICMP firewall rules
- Installs and configures ADCS
- Enables logging and audit policy settings
- Runs verification checks
```

### Correct script order

Use this order every time you build the lab from a clean Windows Server install:

```text
1. Run 01-pre-promotion.ps1.
2. Let the server reboot.
3. Log in as GHOUL\Administrator.
4. Run 02-post-promotion.ps1.
```

Do not run both scripts back-to-back before the reboot.

The first script creates the domain controller. The second script creates the lab objects inside the domain.

---

## Workstation Configuration — GHOUL-WS1 and GHOUL-WS2

The workstations represent normal domain-joined employee machines.

### Specifications

```text
OS:      Windows 11 Enterprise LTSC Evaluation
RAM:     4GB each
CPU:     2 cores each
Disk:    60GB each
```

| Machine | IP | Assigned User | Department |
|---|---:|---|---|
| `GHOUL-WS1` | `192.168.10.100` | `jsmith` | IT |
| `GHOUL-WS2` | `192.168.10.101` | `jdoe` | Finance |

---

## Workstation Static IP Configuration

Each workstation needs a static IP and must use the domain controller as DNS.

This matters because domain join depends on DNS. If the workstation cannot resolve `ghoul.local`, it will not reliably join the domain.

```powershell
# GHOUL-WS1
New-NetIPAddress -InterfaceAlias "Ethernet0" -IPAddress 192.168.10.100 -PrefixLength 24 -DefaultGateway 192.168.10.10
Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" -ServerAddresses 192.168.10.10

# GHOUL-WS2
New-NetIPAddress -InterfaceAlias "Ethernet0" -IPAddress 192.168.10.101 -PrefixLength 24 -DefaultGateway 192.168.10.10
Set-DnsClientServerAddress -InterfaceAlias "Ethernet0" -ServerAddresses 192.168.10.10
```

---

## Join Workstations to the Domain

Once the DC is running and DNS works, join each workstation to `ghoul.local`.

Run the matching command on each workstation from PowerShell as Administrator.

```powershell
# On the first workstation
Add-Computer -DomainName "ghoul.local" -NewName "GHOUL-WS1" -Credential GHOUL\Administrator -Restart

# On the second workstation
Add-Computer -DomainName "ghoul.local" -NewName "GHOUL-WS2" -Credential GHOUL\Administrator -Restart
```

After each workstation reboots, you can log in using domain accounts such as:

```text
GHOUL\jsmith
GHOUL\jdoe
```

---

## Post-Join Hardening and Lab State

Defender is left **ON**, but some settings are intentionally relaxed to mirror a realistic training environment.

See `02-misconfigurations.md` for the full misconfiguration details.

WinRM was enabled on both workstations for remote administration and lab scenarios:

```powershell
Enable-PSRemoting -Force
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
winrm quickconfig -quiet
```

A tools directory was created and excluded from Defender as an intentional lab misconfiguration:

```powershell
New-Item -ItemType Directory -Path "C:\Tools" -Force
```

---

## Credential Caching

Each assigned domain user logged into their workstation interactively:

```text
GHOUL-WS1 → logged in as ghoul\jsmith
GHOUL-WS2 → logged in as ghoul\jdoe
```

This creates realistic endpoint activity and allows the lab to generate meaningful authentication artifacts during later exercises.

---

## Active Directory Certificate Services — ADCS

ADCS was installed on `GHOUL-DC01` as an Enterprise Root CA.

A certificate authority allows the domain to issue certificates to domain users, computers, and services.

```powershell
Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools

Install-AdcsCertificationAuthority `
  -CAType EnterpriseRootCA `
  -CACommonName "GhoulCorp-CA" `
  -KeyLength 2048 `
  -HashAlgorithmName SHA256 `
  -ValidityPeriod Years `
  -ValidityPeriodUnits 5 `
  -Force
```

This ADCS setup is also handled by `02-post-promotion.ps1`.

A vulnerable certificate template named `VulnTemplate1` was published to the CA. See `02-misconfigurations.md` for the vulnerability details and lab path.

---

## Group Policy Objects

Group Policy is used to apply settings across domain machines and users.

| GPO Name | Linked To | Purpose |
|---|---|---|
| `Default Domain Policy` | `ghoul.local` | Built-in domain baseline |
| `GhoulCorp-Misconfigs` | `GhoulCorp` OU | Lab configuration for training scenarios |

---

## Snapshots

Snapshots are important because they let you reset the lab after testing.

Take snapshots when the environment reaches a clean known-good state.

| Snapshot Name | Taken After |
|---|---|
| `Clean Domain Joined - Pre-Attack` | Domain join and user creation complete |
| `ADCS + LLMNR Misconfigs Complete` | All misconfigurations applied |

---

## Verification Commands

Use these commands after setup to confirm the lab was built correctly.

Run them from PowerShell on `GHOUL-DC01`.

```powershell
# Confirm all machines are in AD
Get-ADComputer -Filter * | Select Name

# Confirm all users exist in the correct OU tree
Get-ADUser -Filter * -SearchBase "OU=GhoulCorp,DC=ghoul,DC=local" -Properties Department,Title | Select Name,SamAccountName,Department,Title

# Confirm Domain Admin membership
Get-ADGroupMember -Identity "Domain Admins" | Select Name,SamAccountName

# Confirm SPN on svc-sql
Get-ADUser svc-sql -Properties ServicePrincipalNames | Select -ExpandProperty ServicePrincipalNames

# Confirm DC services are running
Get-Service adws,kdc,netlogon,dns | Select Name,Status

# Confirm DNS zone exists
Get-DnsServerZone | Where-Object ZoneName -eq "ghoul.local"

# Confirm DC DNS A record resolves
Resolve-DnsName GHOUL-DC01.ghoul.local

# Confirm Certificate Services is running
Get-Service CertSvc
```

### What successful verification should show

```text
- GHOUL-DC01, GHOUL-WS1, and GHOUL-WS2 appear in Active Directory.
- GhoulCorp users appear with the correct usernames, departments, and titles.
- itadmin appears inside Domain Admins.
- DNS resolves GHOUL-DC01.ghoul.local to 192.168.10.10.
- AD DS, Kerberos, Netlogon, DNS, and Certificate Services are running.
```

---

## Build Order Summary

Follow this order from a fresh lab build:

```text
1. Configure VMware VMnet1 as host-only 192.168.10.0/24.
2. Install Windows Server 2019 on GHOUL-DC01.
3. Run 01-pre-promotion.ps1.
4. Let the DC reboot.
5. Log in as GHOUL\Administrator.
6. Run 02-post-promotion.ps1.
7. Configure Windows 11 workstation static IPs.
8. Join GHOUL-WS1 and GHOUL-WS2 to ghoul.local.
9. Log in once as the assigned domain users.
10. Configure or apply misconfigurations from 02-misconfigurations.md.
11. Take clean snapshots.
12. Run verification commands.
```

This gives you a complete Active Directory home lab foundation for Windows administration, identity practice, logging, detection engineering, and controlled security training.
