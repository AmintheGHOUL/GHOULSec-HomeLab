# C-05 — Password Spray → Entra ID Compromise → Directory Enumeration

**Tactic:** Credential Access → Discovery  
**MITRE:** T1110.003 · T1087.004  
**Severity:** High  
**Platform:** Microsoft Entra ID (Azure AD)  
**Tools:** MSOLSpray, ROADrecon, Kali Linux

---

## Overview

Password spraying is one of the most common initial access techniques against cloud identity providers. Unlike brute force — which tries many passwords against one account — spraying tries one password against many accounts. This stays under lockout thresholds while maximising the chance of hitting a valid credential.

Microsoft Entra ID (formerly Azure AD) is a primary target because it authenticates to every Microsoft 365 service, Azure resources, and — critically in hybrid environments — on-premises Active Directory. A single compromised cloud account can be the entry point to an entire enterprise.

In this scenario, the attacker uses MSOLSpray to compromise `jsmith`, a GhoulCorp IT Administrator with Global Reader role in Entra ID. They then use ROADrecon to dump the entire directory — all users, service principals, role assignments, and tenant configuration — in under 5 seconds.

---

## GHOULSec Lab Environment

| Component | Value |
|---|---|
| Target tenant | `<your-tenant>.onmicrosoft.com` |
| Target accounts | `bjones@<your-tenant>.onmicrosoft.com` (Finance Manager) |
| | `jsmith@<your-tenant>.onmicrosoft.com` (IT Administrator) |
| jsmith role | Global Reader |
| MFA status | Disabled (no Conditional Access policies) |
| Attacker machine | Kali Linux |
| Tools | MSOLSpray, ROADrecon |

---

## Intentional Misconfigurations

These misconfigurations were deliberately introduced to simulate a realistic enterprise environment:

**No MFA enforcement** — Security defaults disabled, no Conditional Access policies requiring MFA. This is common in organisations that haven't completed their MFA rollout or have exempted certain accounts.

**Weak password** — `jsmith` has password `<SprayPassword!>` — a predictable company-name-plus-year pattern that appears in targeted wordlists.

**Global Reader role on jsmith** — IT Administrator accounts frequently have elevated read permissions. Global Reader allows enumeration of the entire Entra directory including all users, groups, roles, and service principals.

**User consent enabled** — Default user role permissions allow users to consent to applications and read other users — visible in ROADrecon under Authorization Policy.

---

## Attack Walkthrough

### Stage 1 — Target Preparation

The attacker prepares a targeted user list and password wordlist based on OSINT — company name, common patterns, and year combinations.

**users.txt:**
```
bjones@<your-tenant>.onmicrosoft.com
jsmith@<your-tenant>.onmicrosoft.com
```

**passwords.txt:**
```
<SprayPassword!>
Summer2024!
Winter2024!
Welcome2024!
Ghoul@2024
```

The wordlist is deliberately short — password spraying requires staying under lockout thresholds. Entra ID default lockout triggers after 10 failures. Testing one password per account per spray cycle keeps the attack invisible.

> **Screenshot 1:** Kali terminal showing users.txt and passwords.txt contents

---

### Stage 2 — Password Spray Execution

MSOLSpray authenticates directly against the Microsoft Online authentication endpoint (`login.microsoftonline.com`) — the same endpoint used by Office 365 and Azure portal logins.

```powershell
Import-Module ./MSOLSpray.ps1
Invoke-MSOLSpray -UserList ./users.txt -Password "<SprayPassword!>" -Verbose
```

**Output:**
```
[*] There are 2 total users to spray.
[*] Now spraying Microsoft Online.
[*] Current date and time: 06/14/2026 15:08:48
VERBOSE: Requested HTTP/1.1 POST with 207-byte payload
VERBOSE: Received HTTP/1.1 480-byte response of content type application/json
VERBOSE: Requested HTTP/1.1 POST with 207-byte payload
VERBOSE: Received HTTP/1.1 4425-byte response of content type application/json
[*] SUCCESS! jsmith@<your-tenant>.onmicrosoft.com : <SprayPassword!>
```

Valid credential found: `jsmith@<your-tenant>.onmicrosoft.com : <SprayPassword!>`

The 480-byte response for bjones indicates an authentication failure. The 4425-byte response for jsmith indicates a successful token issuance — the size difference alone leaks which account succeeded before the SUCCESS line appears.

> **Screenshot 2:** Kali terminal showing MSOLSpray SUCCESS output

---

### Stage 3 — Token Acquisition

The attacker uses the compromised credentials to obtain an OAuth2 access token via ROADrecon. This token grants API access to Microsoft Graph and other Entra-connected services.

```bash
roadrecon auth -u jsmith@<your-tenant>.onmicrosoft.com -p <SprayPassword!>
```

**Output:**
```
Tokens were written to .roadtools_auth
```

The token is stored locally and used for all subsequent API calls. No MFA challenge was triggered — the account had no Conditional Access policy requiring it.

> **Screenshot 3:** Kali terminal showing token written to .roadtools_auth

---

### Stage 4 — Directory Enumeration

ROADrecon uses the stolen token to issue 717 Microsoft Graph API requests, pulling the entire Entra directory into a local SQLite database.

```bash
roadrecon gather
```

**Output:**
```
Starting data gathering phase 1 of 2 (collecting objects)
Starting data gathering phase 2 of 2 (collecting properties and relationships)
Data gathering complete - Performing data pre-analysis: calculating CA policy scopes
ROADrecon gather executed in 4.12 seconds and issued 717 HTTP requests.
```

**4.12 seconds.** The entire directory of a corporate Entra tenant dumped in under 5 seconds using a single compromised read-only account.

> **Screenshot 4:** Kali terminal showing ROADrecon gather output with 717 HTTP requests

---

### Stage 5 — Directory Analysis

ROADrecon provides a web GUI for analyzing the dumped data.

```bash
roadrecon gui
```

Browser: `http://localhost:5000`

**Tenant information discovered:**

| Field | Value |
|---|---|
| Tenant name | Default Directory |
| Tenant ID | `<your-tenant-id>` |
| Syncs from AD | No (not yet — AD Connect not configured) |
| Users | 3 |
| Service Principals | 135 |
| Applications | 0 |

**Authorization Policy — critical findings:**

| Setting | Value | Risk |
|---|---|---|
| Self-service password reset | Yes | Users can reset passwords without admin |
| MSOnline PowerShell blocked | No | Legacy auth still available |
| allowedToCreateApps | Yes | Any user can register OAuth apps |
| allowedToReadOtherUsers | Yes | Any user can enumerate all users |
| Application consent | User consent allowed | Consent grant attacks possible |

> **Screenshot 5:** ROADrecon dashboard showing tenant stats and authorization policy

---

### Stage 6 — User Enumeration

The Users tab reveals all accounts in the directory with their properties.

**Users discovered:**

| Name | UPN | Department | Job Title | Status |
|---|---|---|---|---|
| amin sammar | admin account | — | — | Enabled |
| Bob Jones | bjones@... | Finance | Finance Manager | Enabled |
| John Smith | jsmith@... | IT | IT Administrator | Enabled |

Bob Jones profile exposed:
- ObjectId: `<user-object-id>`
- Department: Finance
- Account source: Cloud-only
- Last password change: 2026-06-14

> **Screenshot 6:** ROADrecon Users tab showing all three accounts
> **Screenshot 7:** Bob Jones profile showing ObjectId, department, and account details

---

### Stage 7 — What the Attacker Does Next

With the directory dumped the attacker has everything needed for follow-on attacks:

**Immediate value:**
- All user ObjectIds — needed for targeted attacks and role assignments
- 135 service principals — attacker looks for over-permissioned apps and legacy service accounts
- Tenant ID — required for all subsequent Entra API calls
- Confirmation that user consent is enabled — consent grant attack is viable

**Next steps an attacker takes:**
- Check Directory roles for any over-permissioned accounts
- Look for service principals with client secrets that haven't been rotated
- Target bjones for consent grant — Finance Manager likely has access to sensitive data
- Register malicious OAuth app and generate consent URL targeting jsmith or bjones
- If AD Connect is later configured — find MSOL sync account for DCSync pivot

---

## Kill Chain Summary

```
[Attacker on Kali]
        │
        ▼
[MSOLSpray → login.microsoftonline.com]
  2 users × 5 passwords = 10 requests
  Stay under lockout threshold
        │
        ▼
[SUCCESS: jsmith:<SprayPassword!>]
  No MFA · No Conditional Access
        │
        ▼
[ROADrecon auth → OAuth2 token acquired]
        │
        ▼
[ROADrecon gather → 717 Graph API requests in 4.12s]
  All users · All service principals · Tenant config
        │
        ▼
[Directory fully mapped]
  Tenant ID · ObjectIds · Role assignments
  Auth policy · Consent settings · 135 service principals
```

| Stage | MITRE Technique | Tool |
|---|---|---|
| Password spray | T1110.003 — Password Spraying | MSOLSpray |
| Token acquisition | T1528 — Steal Application Access Token | ROADrecon |
| User enumeration | T1087.004 — Cloud Account Discovery | ROADrecon |
| Tenant recon | T1526 — Cloud Service Discovery | ROADrecon GUI |

---

## Log Evidence

### Entra Sign-in Logs — Sentinel KQL

```kql
SigninLogs
| where TimeGenerated > ago(1h)
| where UserPrincipalName has_any ("bjones", "jsmith")
| project TimeGenerated, UserPrincipalName, ResultType, ResultDescription, IPAddress, AppDisplayName
| sort by TimeGenerated desc
```

**Expected results:**
- Multiple `ResultType: 50126` (invalid credentials) for bjones
- `ResultType: 0` (success) for jsmith from Kali IP
- App: `Microsoft Office` or `Azure Active Directory PowerShell`

### Graph API Audit Logs

```kql
AuditLogs
| where TimeGenerated > ago(1h)
| where InitiatedBy.user.userPrincipalName has "jsmith"
| project TimeGenerated, OperationName, TargetResources, ResultReason
| sort by TimeGenerated desc
```

---

## Detection Rules (Sentinel)

### Rule 1 — Password Spray Detection
**Name:** `Entra ID Password Spray — Multiple Failures Single IP`  
**Severity:** High  
**MITRE:** T1110.003

```kql
SigninLogs
| where TimeGenerated > ago(10m)
| where ResultType != "0"
| where ResultType != "50074"
| summarize
    FailCount = count(),
    UniqueUsers = dcount(UserPrincipalName),
    UserList = make_set(UserPrincipalName, 20)
    by IPAddress, bin(TimeGenerated, 5m)
| where UniqueUsers >= 2 and FailCount >= 5
| extend Alert = strcat("Password spray from ", IPAddress, " targeting ", UniqueUsers, " accounts")
```

### Rule 2 — Successful Spray Followed by Directory Enumeration
**Name:** `Entra ID — Post-Spray Directory Enumeration`  
**Severity:** High  
**MITRE:** T1087.004

```kql
let spray_ips = SigninLogs
    | where TimeGenerated > ago(1h)
    | where ResultType != "0"
    | summarize FailCount=count() by IPAddress
    | where FailCount >= 3
    | project IPAddress;
SigninLogs
| where TimeGenerated > ago(1h)
| where ResultType == "0"
| where IPAddress in (spray_ips)
| project TimeGenerated, UserPrincipalName, IPAddress, AppDisplayName
// Alert: successful login from IP that previously sprayed
```

---

## Remediation

**Fix 1 — Enforce MFA via Conditional Access (highest priority)**

```
Entra ID → Protection → Conditional Access → New policy
Name: Require MFA for all users
Users: All users
Cloud apps: All cloud apps
Grant: Require multifactor authentication
```

This single control defeats password spraying entirely — even a valid credential is useless without the second factor.

**Fix 2 — Enable Smart Lockout tuning**

```
Entra ID → Protection → Authentication methods → Password protection
Lockout threshold: 5 (default 10 — lower it)
Lockout duration: 60 seconds
Enable custom banned passwords: Yes
Add: GhoulCorp, Ghoul, company name variants
```

**Fix 3 — Block legacy authentication**

MSOLSpray uses legacy auth endpoints. Block them:
```
Conditional Access → New policy
Cloud apps: All
Conditions → Client apps: Exchange ActiveSync + Other clients
Grant: Block
```

**Fix 4 — Restrict user consent**

```
Entra ID → Enterprise applications → Consent and permissions
User consent for apps: Do not allow user consent
```

This prevents consent grant attacks which are the next step after directory enumeration.

**Fix 5 — Restrict directory read permissions**

```
Entra ID → User settings → Default user role permissions
Restrict access to Entra admin center: Yes
Users can read other users: No (requires P1 license)
```

---

## Comparison: Real-World Context

Password spraying against Microsoft Online is one of the most commonly observed initial access techniques in nation-state campaigns. Microsoft's 2023 threat intelligence reports documented Midnight Blizzard (APT29/Cozy Bear) using exactly this technique — low-and-slow password spraying against Microsoft's own corporate Entra tenant, leading to email access for senior leadership.

The GhoulCorp scenario demonstrates the same pattern at lab scale:
- No MFA → spray succeeds
- Global Reader role → full directory access
- User consent enabled → consent grant attack viable as next step

The fix is always the same: MFA. A single Conditional Access policy requiring MFA makes password spraying irrelevant regardless of password strength.

---

*GHOULSec Home Lab — Cloud Attack Scenario C-05*  
*github.com/AmintheGHOUL/GHOULSec-HomeLab*
