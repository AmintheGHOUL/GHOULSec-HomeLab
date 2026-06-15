# GHOULSec Home Lab — Misconfigurations

**Author:** AmintheGHOUL  
**Domain:** ghoul.local  
**Purpose:** Documents every intentional misconfiguration in the lab, why it exists in real enterprises, how it is vulnerable, and which attack scenario exploits it.

---

## Overview

Every misconfiguration in this lab mirrors a real-world finding from enterprise penetration tests and breach investigations. None of these require zero-days or exploits — they are configuration mistakes made by real administrators that attackers abuse using legitimate tools and protocols.

---

## 1 — SMB Signing Disabled

### What Was Configured

```powershell
Set-SmbServerConfiguration -RequireSecuritySignature $false `
  -EnableSecuritySignature $false -Force
```

### What It Does

SMB signing is a security feature that cryptographically signs every SMB packet exchanged between a client and server. When disabled, SMB traffic can be intercepted and tampered with by a man-in-the-middle attacker on the same network segment.

### Why It Exists in Real Environments

SMB signing adds CPU overhead and latency — in older environments with large file shares or legacy applications, administrators disabled it to improve performance. Many environments running Windows Server 2008/2012 era infrastructure still have this disabled and it was never re-enabled.

### Why It Is Vulnerable

Without signing, an attacker running Responder and ntlmrelayx can:

1. Intercept an NTLMv2 authentication attempt triggered by LLMNR poisoning
2. Relay that authentication to another machine on the network in real time
3. Authenticate as the victim user without ever knowing their password
4. Receive a shell on the target machine

The relay works because the target machine accepts the relayed authentication as legitimate — there is no signature to verify, so it has no way to detect the man-in-the-middle.

### Attack Scenario

```
Scenario:   SMB Relay → Shell
Tool:       Responder + ntlmrelayx (Impacket)
MITRE:      T1557.001 — Adversary-in-the-Middle: LLMNR/NBT-NS Poisoning and SMB Relay
```

### Detection

```
Event ID 4624  — Logon from unexpected source IP
Event ID 4648  — Explicit credential logon
Sysmon EID 3   — Network connection from ntlmrelayx process
```

### Remediation

```powershell
Set-SmbServerConfiguration -RequireSecuritySignature $true `
  -EnableSecuritySignature $true -Force
```

---

## 2 — LLMNR Enabled

### What Was Configured

```
GPO: GhoulCorp-Misconfigs
Path: Computer Config → Admin Templates → Network → DNS Client
Setting: Turn off multicast name resolution → Disabled
```

### What It Does

LLMNR (Link-Local Multicast Name Resolution) is a protocol that allows Windows machines to resolve hostnames on the local network when DNS fails. When a machine cannot resolve a hostname via DNS, it broadcasts an LLMNR query to all machines on the subnet asking "does anyone know where \\hostname is?"

### Why It Exists in Real Environments

LLMNR is enabled by default in all Windows versions. Most organisations never disable it because it is not obviously dangerous and turning it off can break legacy applications and mapped drives that rely on NetBIOS name resolution.

### Why It Is Vulnerable

An attacker running Responder on the same network segment listens for these broadcast queries and responds to every one of them claiming to be the requested host. The victim machine then sends an NTLMv2 authentication attempt directly to the attacker's machine.

The attacker now has:
- The victim's username
- The victim's NTLMv2 hash (crackable offline)
- Optionally a relay target if SMB signing is also disabled

### Attack Scenario

```
Scenario:   LLMNR Poisoning → NTLMv2 Capture → Hash Crack
Tool:       Responder
MITRE:      T1557.001 — Adversary-in-the-Middle: LLMNR/NBT-NS Poisoning
```

### Detection

```
Wazuh custom rule  — multiple LLMNR responses from a single non-DC host
Sysmon EID 3       — inbound connections to port 5355 (LLMNR)
Event ID 4625      — failed logon attempts from unknown hosts
```

### Remediation

```
GPO: Computer Config → Admin Templates → Network → DNS Client
Setting: Turn off multicast name resolution → Enabled
```

---

## 3 — DCSync Rights Granted to Low-Privilege User

### What Was Configured

```powershell
$sid = (Get-ADUser jsmith).SID
$acl = Get-Acl "AD:DC=ghoul,DC=local"

$rule1 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
  $sid, "ExtendedRight", "Allow",
  [GUID]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2")  # Replicating Directory Changes

$rule2 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
  $sid, "ExtendedRight", "Allow",
  [GUID]"1131f6ab-9c07-11d1-f79f-00c04fc2dcd2")  # Replicating Directory Changes All

$acl.AddAccessRule($rule1)
$acl.AddAccessRule($rule2)
Set-Acl "AD:DC=ghoul,DC=local" $acl
```

### What It Does

The two GUIDs above are Active Directory extended rights that allow an account to replicate directory data — specifically:

```
1131f6aa  →  Replicating Directory Changes
1131f6ab  →  Replicating Directory Changes All
```

These rights are normally only held by Domain Controllers and Domain Admins. They were granted to `jsmith`, a Helpdesk Technician with no administrative role.

### Why It Exists in Real Environments

This misconfiguration typically happens when:
- An admin grants replication rights to a monitoring or backup account without understanding the security implications
- A third-party AD sync tool (Azure AD Connect, identity management platforms) is configured with excessive permissions
- Rights are granted temporarily for a project and never revoked

### Why It Is Vulnerable

DCSync is an attack that uses the legitimate AD replication protocol to request password hashes from a Domain Controller. Any account with these two replication rights can call the `MS-DRSR` (Directory Replication Service Remote Protocol) and ask the DC to replicate all user objects including their NTLM password hashes, Kerberos keys, and the krbtgt hash.

This means `jsmith` — a helpdesk account — can extract every password hash in the domain without touching the DC, without running any exploit, and without triggering most AV products because it uses a legitimate Windows protocol.

### Attack Scenario

```
Scenario:   DCSync → Full Domain Hash Dump
Tool:       secretsdump.py (Impacket)
Command:    secretsdump.py ghoul.local/jsmith:'<LabPassword1!>'@192.168.10.10 -just-dc
MITRE:      T1003.006 — OS Credential Dumping: DCSync
```

### Detection

```
Event ID 4662  — Object access with replication GUIDs
                 (filter for: 1131f6aa or 1131f6ab in Properties field)
Event ID 4624  — Logon from non-DC machine using replication rights
```

This is one of the most important detections in the lab. Event 4662 with the specific replication GUIDs is the canonical DCSync detection used in enterprise SOC environments.

### Remediation

```powershell
# Remove DCSync rights from jsmith
$sid = (Get-ADUser jsmith).SID
$acl = Get-Acl "AD:DC=ghoul,DC=local"
$acl.RemoveAccessRuleSpecific(
  (New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $sid, "ExtendedRight", "Allow",
    [GUID]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2")))
Set-Acl "AD:DC=ghoul,DC=local" $acl
```

Run BloodHound regularly to audit accounts with unexpected replication rights.

---

## 4 — Kerberoastable Service Account

### What Was Configured

```powershell
# Weak password on service account
New-ADUser -Name "SQL Service" -SamAccountName "svc-sql" `
  -AccountPassword (ConvertTo-SecureString "<WeakSvcPassword!>" -AsPlainText -Force) `
  -Enabled $true

# SPN registered — makes it Kerberoastable
Set-ADUser -Identity "svc-sql" -ServicePrincipalNames `
  @{Add="MSSQLSvc/ghoul-dc01.ghoul.local:1433"}
```

### What It Does

Registering a Service Principal Name (SPN) on a user account tells Kerberos that this account runs a service. Any authenticated domain user can request a Ticket Granting Service (TGS) ticket for any SPN. That ticket is encrypted with the service account's password hash.

### Why It Exists in Real Environments

Service accounts with SPNs are extremely common — SQL Server, IIS, SharePoint, and many enterprise applications require them. The vulnerability is not the SPN itself but the combination of a user account (not a gMSA) with a weak, manually set password that never rotates.

### Why It Is Vulnerable

Any authenticated domain user — including `jsmith` — can request a TGS ticket for `svc-sql` without any special permissions. The ticket is returned encrypted with `svc-sql`'s NTLM hash. The attacker takes the ticket offline and cracks it with a wordlist. Since the password is `<WeakSvcPassword!>` it cracks in seconds.

The attack generates no failed logon events and requires no elevated privileges — it uses normal Kerberos functionality.

### Attack Scenario

```
Scenario:   Kerberoasting → Offline Hash Crack
Tool:       Rubeus (in-memory) or GetUserSPNs.py (Impacket)
MITRE:      T1558.003 — Steal or Forge Kerberos Tickets: Kerberoasting
```

### Detection

```
Event ID 4769  — Kerberos TGS request
                 Filter for: Ticket Encryption Type = 0x17 (RC4)
                 RC4 instead of AES indicates a Kerberoasting attempt
                 against a legacy-configured service account
```

### Remediation

```
1. Use Group Managed Service Accounts (gMSA) — passwords are 
   120 characters, auto-rotate, cannot be Kerberoasted

2. If user accounts must be used, set a 25+ character random 
   password that is rotated every 30 days

3. Enable AES encryption on service accounts:
   Set-ADUser svc-sql -KerberosEncryptionType AES256
   (RC4 TGS requests then become anomalous and detectable)
```

---

## 5 — Defender Misconfigured (Active but Blind)

### What Was Configured

```powershell
# Cloud protection disabled
Set-MpPreference -MAPSReporting Disabled
Set-MpPreference -SubmitSamplesConsent NeverSend
Set-MpPreference -DisableBlockAtFirstSeen $true

# Exclusions added
Add-MpPreference -ExclusionPath "C:\Tools"
Add-MpPreference -ExclusionPath "C:\Users\Public\Downloads"
Add-MpPreference -ExclusionExtension ".ps1"
```

### What It Does

Windows Defender is left running and appears healthy in the Security Center dashboard. However the cloud intelligence feed is cut, unknown files are not blocked on first sight, and three broad exclusions create blind spots across the entire machine.

### Why It Exists in Real Environments

```
MAPSReporting Disabled      → common in air-gapped environments or
                              orgs with strict data privacy policies

ExclusionPath C:\Tools      → admins add this to stop Defender flagging
                              IT tools like PsExec, scripts, deployment agents

ExclusionExtension .ps1     → added to stop Defender blocking legitimate
                              PowerShell automation scripts
                              (extremely common in enterprise environments)

DisableBlockAtFirstSeen     → sometimes disabled because it causes
                              user complaints when new software is blocked
```

### Why It Is Vulnerable

An attacker who knows these exclusions exist (discoverable via `Get-MpPreference` with any user account) can:
- Drop any payload into `C:\Tools` or `C:\Users\Public\Downloads` with no scanning
- Deliver any `.ps1` script anywhere on the machine without Defender inspection
- Use new/unknown tools without cloud verdict blocking them

Defender will report green status in the dashboard while being effectively blind to the attack.

### Attack Scenarios Enabled

```
All PowerShell-based attacks  → .ps1 exclusion bypasses script scanning
AMSI bypass scripts           → land in C:\Tools undetected
Rubeus, SharpHound            → run from C:\Tools without AV hit
ClickFix payload delivery     → .ps1 payload executed without scan
```

### Detection

```
PowerShell ScriptBlock Logging  — Event ID 4104 catches script content
                                  even when Defender misses the file
Sysmon EID 1                    — process creation from excluded paths
                                  is still logged regardless of Defender
```

### Remediation

```powershell
# Remove exclusions
Remove-MpPreference -ExclusionPath "C:\Tools"
Remove-MpPreference -ExclusionPath "C:\Users\Public\Downloads"
Remove-MpPreference -ExclusionExtension ".ps1"

# Re-enable cloud protection
Set-MpPreference -MAPSReporting Advanced
Set-MpPreference -SubmitSamplesConsent SendSafeSamples
Set-MpPreference -DisableBlockAtFirstSeen $false
```

Audit Defender exclusions quarterly. Any exclusion covering a writable path or a script extension is a high-risk finding.

---

## 6 — ADCS ESC1 — Vulnerable Certificate Template

### What Was Configured

```
Template Name:    VulnTemplate1
Duplicated from:  User (built-in)
CA:               GhoulCorp-CA

Misconfiguration 1:
  Subject Name tab → "Supply in the request"
  (requester controls the identity on the cert)

Misconfiguration 2:
  Security tab → Domain Users → Enroll = Allow
  (any domain account can request this cert)
```

### What It Does

Active Directory Certificate Services (ADCS) is Microsoft's PKI system. Certificate templates define what a cert can be used for and who can request one. This template has two misconfigurations that combine into a critical privilege escalation path.

### Why It Exists in Real Environments

ADCS is complex and poorly understood by most administrators. The "Supply in the request" setting is sometimes enabled to allow flexibility — for example, letting users request certs for different email addresses or service names. Granting Domain Users enrollment rights is done to avoid managing individual permissions. Neither setting is obviously dangerous in isolation, which is why this misconfiguration pattern appears in a large percentage of enterprise environments with ADCS deployed.

### Why It Is Vulnerable

**Misconfiguration 1 — Supply in the request:**  
Normally the CA controls what identity (UPN) appears on a certificate. With this setting enabled, the requester specifies the UPN themselves. There is no validation that the requester actually owns the identity they are claiming.

**Misconfiguration 2 — Domain Users can enroll:**  
Any authenticated domain account — including `jsmith` the Helpdesk Technician — can submit a certificate request to this template.

**Combined attack path:**  
`jsmith` submits a certificate request to VulnTemplate1 and specifies `administrator@ghoul.local` as the UPN. The CA issues the certificate without questioning the identity claim. `jsmith` then uses this certificate to authenticate to the DC as Administrator via PKINIT (Kerberos certificate authentication). The DC validates the certificate (it was issued by the trusted GhoulCorp-CA), accepts it, and returns a TGT for the Administrator account.

A Helpdesk Technician has achieved full Domain Admin access using only a certificate request — no exploits, no malware, no password required.

### Attack Scenario

```
Scenario:   ADCS ESC1 → Domain Admin via Forged Certificate
Tool:       Certipy
MITRE:      T1649 — Steal or Forge Authentication Certificates

# Enumerate vulnerable templates
certipy find -u jsmith@ghoul.local -p '<LabPassword1!>' \
  -dc-ip 192.168.10.10 -vulnerable -stdout

# Request cert claiming to be Administrator
certipy req -u jsmith@ghoul.local -p '<LabPassword1!>' \
  -ca GhoulCorp-CA \
  -template VulnTemplate1 \
  -upn administrator@ghoul.local \
  -dc-ip 192.168.10.10

# Authenticate as Domain Admin using the cert
certipy auth -pfx administrator.pfx -dc-ip 192.168.10.10
```

### Detection

```
Event ID 4886  — Certificate request received by CA
Event ID 4887  — Certificate issued by CA
                 Filter for: VulnTemplate1 + requester != the UPN in the cert
                 (jsmith requesting a cert for administrator is the anomaly)

CA audit logs  — Enable via:
                 certutil -setreg CA\AuditFilter 127
                 Restart-Service certsvc
```

### Remediation

```
1. Open Certificate Authority console
2. Right-click VulnTemplate1 → Properties → Subject Name tab
3. Change "Supply in the request" to "Build from Active Directory"

4. Restrict enrollment:
   Security tab → Remove "Domain Users"
   Add only the specific group that needs this cert type

5. Run Certipy or PingCastle regularly to audit all templates:
   certipy find -u <user> -p <pass> -dc-ip <DC IP> -vulnerable
```

---

## Misconfiguration Summary

| # | Misconfiguration | Enabled Attack | MITRE Technique | Severity |
|---|---|---|---|---|
| 1 | SMB Signing Disabled | SMB Relay | T1557.001 | Critical |
| 2 | LLMNR Enabled | LLMNR Poisoning / Hash Capture | T1557.001 | High |
| 3 | DCSync Rights on jsmith | DCSync — Full Hash Dump | T1003.006 | Critical |
| 4 | Kerberoastable svc-sql | Kerberoasting | T1558.003 | High |
| 5 | Defender Exclusions | AV Bypass — All PS1/Tool Attacks | T1562.001 | High |
| 6 | ADCS ESC1 Template | Certificate Forgery → Domain Admin | T1649 | Critical |

---

## Attack Chain — How Misconfigs Connect

These misconfigurations do not exist in isolation. A real attacker chains them together in a single intrusion:

```
Initial Access
└── LLMNR Poisoning (#2)
    └── Capture jsmith NTLMv2 hash
        └── Crack offline → <LabPassword1!>

Execution
└── Defender exclusions (#5)
    └── Drop Rubeus to C:\Tools
        └── Run without AV detection

Credential Access
├── Kerberoasting (#4)
│   └── Crack svc-sql → <WeakSvcPassword!>
├── DCSync (#3)
│   └── Dump all domain hashes using jsmith
└── ADCS ESC1 (#6)
    └── Forge Administrator cert using jsmith

Lateral Movement
└── SMB Relay (#1)
    └── Relay jsmith hash → shell on GHOUL-WS2

Persistence
└── DCSync (#3)
    └── Extract krbtgt hash → Golden Ticket
        └── Forge TGTs indefinitely even after password reset
```

A single low-privilege Helpdesk account (`jsmith`) with a weak password (`<LabPassword1!>`) is sufficient to achieve full domain compromise through this chain.
