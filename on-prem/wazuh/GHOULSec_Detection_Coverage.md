# GHOULSec Detection Coverage

**Lab:** GHOULSec Home Lab | **SIEM:** Wazuh 4.9 | **GitHub:** AmintheGHOUL

> This document covers the detection engineering layer of the GHOULSec lab — how Sigma rules were converted and deployed into Wazuh for real-time detection, and how Sysmon extends that coverage across Windows endpoints.

---

## Table of Contents

1. [Detection Layers Overview](#1-detection-layers-overview)
2. [Why Sigma Rules](#2-why-sigma-rules)
3. [Sigma → Wazuh Conversion with sigWah](#3-sigma--wazuh-conversion-with-sigwah)
4. [Deploying Rules into Wazuh](#4-deploying-rules-into-wazuh)
5. [Deployed Rule Categories](#5-deployed-rule-categories)
6. [Key Rules for GHOULSec Attack Scenarios](#6-key-rules-for-ghoulSec-attack-scenarios)
7. [Sysmon — Unlocking Full Coverage](#7-sysmon--unlocking-full-coverage)
8. [Sysmon Deployment Guide](#8-sysmon-deployment-guide)
9. [Detection Validation with Atomic Red Team](#9-detection-validation-with-atomic-red-team)
10. [Portfolio Documentation Standard](#10-portfolio-documentation-standard)
11. [False Positive Analysis and Rule Tuning](#11-false-positive-analysis-and-rule-tuning)
12. [Alert Formatting — Clean Readable Output](#12-alert-formatting--clean-readable-output)
13. [Detection Coverage Summary](#13-detection-coverage-summary)

---

## 1. Detection Layers Overview

The GHOULSec lab uses multiple detection layers working together:

| Layer | Tool | Rule Count | Status | What It Detects |
|---|---|---|---|---|
| Wazuh built-in rules | Wazuh default ruleset | ~3,000+ | ✅ Active | Authentication, rootkits, file integrity, Linux events |
| Network IDS | Suricata + Emerging Threats | 66,664 | ✅ Active (ens37) | Network-based attacks, C2 traffic, exploit attempts |
| Sigma rules (Windows) | sigWah converted | 458 files | ✅ Active | Windows attack TTPs — credential theft, lateral movement, persistence |
| Sysmon-based Sigma | sigWah converted | ~80 | ✅ Active — DC01, WS1, WS2 | Process injection, LSASS access, named pipes, DLL loads |

Each layer complements the others. Suricata catches network-level indicators, Wazuh built-ins catch host-level OS events, and Sigma rules provide community-maintained, MITRE ATT&CK-mapped detections written by detection engineers worldwide.

---

## 2. Why Sigma Rules

**Sigma** is the industry-standard format for writing detection rules. It is to detection engineering what Snort/Suricata rules are to network IDS.

Key advantages for this lab:

- **SIEM-agnostic** — one Sigma rule can be converted to Wazuh, Splunk, Elastic, QRadar, and more
- **MITRE ATT&CK mapped** — every rule tags the technique it detects
- **Community-maintained** — thousands of rules written and tested by the global security community at [SigmaHQ](https://github.com/SigmaHQ/sigma)
- **Interview relevance** — detection engineers are expected to know Sigma; having it in your lab demonstrates real-world skill

A Sigma rule looks like this:

```yaml
title: Kerberoasting SPN Enumeration
id: 1234abcd-...
status: stable
description: Detects SPN enumeration activity used in Kerberoasting attacks
tags:
  - attack.credential_access
  - attack.t1558.003
logsource:
  product: windows
  service: security
detection:
  selection:
    EventID: 4769
    TicketEncryptionType: '0x17'
  condition: selection
level: high
```

Wazuh cannot natively load Sigma YAML — it needs an XML format. That is where sigWah comes in.

---

## 3. Sigma → Wazuh Conversion with sigWah

### What is sigWah

[sigWah](https://github.com/SanWieb/sigWah) is a Python tool that converts Sigma YAML rule files into Wazuh/OSSEC-compatible XML rule files. It handles field mapping, regex translation, condition logic, and MITRE tag preservation.

### Installation

```bash
cd ~
git clone https://github.com/SanWieb/sigWah.git
cd sigWah
```

No additional dependencies are required beyond standard Python 3.

### How sigWah Works

sigWah reads each Sigma `.yml` file and outputs a Wazuh `.xml` file:

**Input (Sigma YAML):**
```yaml
detection:
  selection:
    EventID: 4769
    TicketEncryptionType: '0x17'
  condition: selection
level: high
```

**Output (Wazuh XML):**
```xml
<group name="sigma_rules">
<rule id="250010" level="14">
  <if_group>windows_security</if_group>
  <field name="win.system.EventID">^4769$</field>
  <field name="win.eventdata.TicketEncryptionType">0x17</field>
  <description>ATT&CK T1558.003: Kerberoasting SPN Enumeration</description>
  <info type="text">Sigma UUID: 1234abcd-...</info>
  <group>attack.credential_access,attack.t1558.003,MITRE</group>
</rule>
</group>
```

### Sigma Level → Wazuh Level Mapping

| Sigma Level | Wazuh Level | Alert Behavior |
|---|---|---|
| critical | 15 | Dashboard + Slack notification |
| high | 14 | Dashboard + Slack notification |
| medium | 10 | Dashboard only |
| low | 8 | Dashboard only |

### Supported Condition Types

sigWah handles three Sigma condition patterns:

| Pattern | Example | sigWah handling |
|---|---|---|
| OR | `one of selection*` | Multiple `<field>` tags |
| AND | `all of them` | Multiple `<field>` tags, flagged for manual review |
| AND NOT | `selection and not filter` | Two rules: detection rule + level-0 whitelist rule |

Rules with complex conditions are flagged with `Manual check needed!` in the output XML.

### sigWah's Pre-Converted Rules

The sigWah repository ships with a pre-converted and manually reviewed ruleset in `ossec-rules/windows/`:

```
ossec-rules/
└── windows/
    ├── builtin/          # Windows built-in event log detections
    ├── malware/          # Malware family detections
    ├── other/            # Miscellaneous
    ├── powershell/       # PowerShell abuse detections
    ├── process_creation/ # Process creation (Sysmon Event 1)
    └── sysmon/           # Sysmon-specific detections
```

---

## 4. Deploying Rules into Wazuh

### Copy Rules to Wazuh

Copy all pre-converted rule files into Wazuh's custom rules directory:

```bash
sudo cp ~/sigWah/ossec-rules/windows/builtin/*.xml /var/ossec/etc/rules/
sudo cp ~/sigWah/ossec-rules/windows/process_creation/*.xml /var/ossec/etc/rules/
sudo cp ~/sigWah/ossec-rules/windows/powershell/*.xml /var/ossec/etc/rules/
sudo cp ~/sigWah/ossec-rules/windows/sysmon/*.xml /var/ossec/etc/rules/
sudo cp ~/sigWah/ossec-rules/windows/malware/*.xml /var/ossec/etc/rules/
```

### Fix XML Structure

Wazuh requires every rule file to have a `<group>` wrapper as the root element. Some sigWah files are missing this or contain only commented-out rules. Fix them:

**Add missing group wrappers:**

```bash
for f in $(sudo grep -rL "^<group" /var/ossec/etc/rules/); do
  sudo sed -i '1s/^/<group name="sigma_rules">\n/' "$f"
  echo '</group>' | sudo tee -a "$f" > /dev/null
done
```

**Remove empty rule files (rules fully commented out):**

```bash
sudo bash -c '
for f in /var/ossec/etc/rules/*.xml; do
  if [ "$f" != "/var/ossec/etc/rules/local_rules.xml" ]; then
    if ! grep -q "<rule " "$f"; then
      rm "$f"
    fi
  fi
done
'
```

### Validate Syntax

Before restarting Wazuh, test that all rule files parse correctly:

```bash
sudo /var/ossec/bin/wazuh-analysisd -t 2>&1 | tail -5
```

No output means all rules loaded without errors.

### Restart Wazuh Manager

```bash
sudo systemctl restart wazuh-manager
sudo systemctl status wazuh-manager --no-pager | head -5
```

### Verify Rule Count

```bash
sudo bash -c 'ls /var/ossec/etc/rules/*.xml | wc -l'
```

Expected: **459** files (458 Sigma + 1 local_rules.xml).

---

## 5. Deployed Rule Categories

| Category | File Prefix | Count | What It Catches |
|---|---|---|---|
| Suspicious Windows activity | `win_susp_*` | ~80 | LOLBins, recon tools, UAC bypass, evasion |
| Known APT TTPs | `win_apt_*` | ~25 | Turla, APT29, Sofacy, Equation Group, Gallium |
| Malware families | `win_malware_*` / `win_mal_*` | ~20 | WannaCry, Ryuk, Emotet, Cobalt Strike, Dridex |
| Sysmon-based | `sysmon_*` | ~80 | Process injection, LSASS access, named pipes, DLL loads |
| PowerShell abuse | `powershell_*` | ~23 | Obfuscation, download cradles, shellcode, AMSI bypass |
| Hacking tools | `win_hack_*` | ~8 | BloodHound, Rubeus, Impacket, Koadic, SMBExec |
| AD / credential attacks | `win_alert_*` / `win_dcsync*` | ~10 | DCSync, LSASS dump, Kerberoasting, DPAPI |
| Exploit detection | `win_exploit_*` | ~8 | CVE-based exploit patterns |
| Lateral movement | `win_pass_*` / `win_impacket_*` | ~8 | Pass-the-Hash, PtT, WMI lateral movement |
| Persistence | `win_susp_schtask*` / `win_new_service*` | ~10 | Scheduled tasks, services, registry run keys |
| Defense evasion | `win_susp_eventlog_*` / `win_etw_*` | ~6 | Log clearing, ETW evasion, AMSI bypass |
| Ransomware indicators | `win_shadow_copies_*` / `win_crime_*` | ~6 | Shadow copy deletion, backup tampering |

---

## 6. Key Rules for GHOULSec Attack Scenarios

These are the specific rules that will fire during the lab's planned attack simulations:

| Rule File | MITRE Technique | Attack |
|---|---|---|
| `win_dcsync.xml` | T1003.006 | DCSync — extracting credentials via AD replication |
| `win_spn_enum.xml` | T1558.003 | Kerberoasting — SPN enumeration |
| `win_susp_rc4_kerberos.xml` | T1558.003 | Kerberoasting — RC4 downgrade detection |
| `win_alert_mimikatz_keywords.xml` | T1003 | Mimikatz keyword pattern matching |
| `win_mimikatz_command_line.xml` | T1003 | Mimikatz command line detection |
| `win_pass_the_hash.xml` | T1550.002 | Pass-the-Hash |
| `win_overpass_the_hash.xml` | T1550.002 | Overpass-the-Hash |
| `win_hack_bloodhound.xml` | T1069 / T1087 | BloodHound AD enumeration |
| `win_hack_rubeus.xml` | T1558 | Rubeus Kerberos attacks |
| `win_impacket_secretdump.xml` | T1003 | Impacket secretsdump |
| `win_impacket_lateralization.xml` | T1021 | Impacket lateral movement |
| `win_shadow_copies_deletion.xml` | T1490 | Ransomware — shadow copy deletion |
| `win_disable_event_logging.xml` | T1562.002 | Disabling Windows Event Logging |
| `win_susp_crackmapexec_execution.xml` | T1021 | CrackMapExec execution |
| `win_possible_dc_shadow.xml` | T1207 | DCShadow attack |
| `win_account_backdoor_dcsync_rights.xml` | T1098 | Granting DCSync rights as backdoor |
| `sysmon_cred_dump_lsass_access.xml` | T1003.001 | LSASS memory access (Sysmon Event 10) |
| `sysmon_mimikatz_inmemory_detection.xml` | T1003 | In-memory Mimikatz detection |
| `sysmon_cobaltstrike_process_injection.xml` | T1055 | Cobalt Strike process injection |
| `powershell_malicious_commandlets.xml` | T1059.001 | Known malicious PowerShell cmdlets |

---

## 7. Sysmon — Unlocking Full Coverage

### Why Sysmon Is Needed

Approximately 80 deployed Sigma rules use Sysmon event groups (`sysmon_event1`, `sysmon_event10`, etc.). These rules will **not fire** until Sysmon is installed on the Windows endpoints.

Standard Windows Event Logs are limited — they don't capture command line arguments, DLL loads, or network connections at the process level. Sysmon fills this gap.

### What Sysmon Adds

| Sysmon Event ID | Data Provided | Sigma Rules Unlocked |
|---|---|---|
| Event 1 | Process creation with full command line and parent | `sysmon_*`, `win_renamed_*` |
| Event 3 | Network connections with originating process | `sysmon_*_network_*`, `sysmon_notepad_network_connection.xml` |
| Event 7 | DLL image loads with hash and signature | `sysmon_susp_*_dll_load.xml`, `sysmon_unsigned_image_loaded_into_lsass.xml` |
| Event 8 | CreateRemoteThread (process injection) | `sysmon_cobaltstrike_process_injection.xml`, `sysmon_suspicious_remote_thread.xml` |
| Event 10 | Process access — LSASS dump detection | `sysmon_cred_dump_lsass_access.xml`, `sysmon_lsass_memdump.xml` |
| Event 11 | File creation | `sysmon_lsass_memory_dump_file_creation.xml`, `sysmon_cred_dump_tools_dropped_files.xml` |
| Event 12/13 | Registry create/modify | `sysmon_asep_reg_keys_modification.xml`, `sysmon_win_reg_persistence.xml` |
| Event 17/18 | Named pipe create/connect | `sysmon_mal_namedpipes.xml`, `sysmon_cred_dump_tools_named_pipes.xml` |

---

## 8. Sysmon Deployment Guide

### Download Sysmon on GHOUL-WAZUH

```bash
cd ~/Desktop
wget https://download.sysinternals.com/files/Sysmon.zip
unzip Sysmon.zip -d Sysmon
cd Sysmon
```

> The Sysinternals download may redirect through a browser EULA page. If `wget` fails, download manually from `https://learn.microsoft.com/en-us/sysinternals/downloads/sysmon`.

### Create a Compatible Sysmon Config

The sigWah repository includes `sysmonconfig.xml` but it uses schema version 4.22. Sysmon 15.x uses schema 4.91 and will reject the older config. Create a compatible config instead:

```bash
cat > ~/Desktop/Sysmon/sysmonconfig-new.xml << 'EOF'
<Sysmon schemaversion="4.91">
  <HashAlgorithms>md5,sha256,imphash</HashAlgorithms>
  <CheckRevocation/>
  <EventFiltering>
    <RuleGroup name="" groupRelation="or">
      <ProcessCreate onmatch="exclude">
        <Image condition="is">C:\Windows\System32\svchost.exe</Image>
      </ProcessCreate>
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <NetworkConnect onmatch="exclude">
        <Image condition="is">C:\Windows\System32\svchost.exe</Image>
      </NetworkConnect>
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <ProcessAccess onmatch="include">
        <TargetImage condition="contains">lsass.exe</TargetImage>
      </ProcessAccess>
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <RawAccessRead onmatch="include" />
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <FileCreate onmatch="include" />
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <RegistryEvent onmatch="include" />
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <PipeEvent onmatch="include" />
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <CreateRemoteThread onmatch="include" />
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <ImageLoad onmatch="include" />
    </RuleGroup>
    <RuleGroup name="" groupRelation="or">
      <DriverLoad onmatch="include" />
    </RuleGroup>
  </EventFiltering>
</Sysmon>
EOF
```

### Serve Files to Windows Machines

Start an HTTP server on GHOUL-WAZUH:

```bash
cd ~/Desktop/Sysmon
python3 -m http.server 8080
```

### Install Sysmon on Each Windows Machine

Run as Administrator on each Windows machine:

```powershell
# Download Sysmon and config
Invoke-WebRequest -Uri http://192.168.10.20:8080/Sysmon64.exe -OutFile C:\Windows\Temp\Sysmon64.exe
Invoke-WebRequest -Uri http://192.168.10.20:8080/sysmonconfig-new.xml -OutFile C:\Windows\Temp\sysmonconfig-new.xml

# Install with the compatible config
C:\Windows\Temp\Sysmon64.exe -accepteula -i C:\Windows\Temp\sysmonconfig-new.xml
```

> **Windows 11 note:** On some Windows 11 builds you may see a `wevtutil.exe returned failure` error during install. If Sysmon fails to start after install, use the `-d` flag to specify the driver name explicitly:
> ```powershell
> C:\Windows\Temp\Sysmon64.exe -accepteula -i C:\Windows\Temp\sysmonconfig-new.xml -d SysmonDrv
> ```

Verify Sysmon is running:

```powershell
Get-Service | Where-Object {$_.DisplayName -like "*sysmon*"}
```

### Configure Wazuh Agents to Collect Sysmon Logs

On GHOUL-WAZUH, add Sysmon log collection to the agent configuration. The easiest way is to add it centrally via the Wazuh Manager's `agent.conf`:

```bash
sudo nano /var/ossec/etc/shared/default/agent.conf
```

Add:

```xml
<agent_config>
  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
</agent_config>
```

This configuration is automatically pushed to all enrolled agents. Restart Wazuh Manager:

```bash
sudo systemctl restart wazuh-manager
```

### Verify Sysmon Events Arriving in Wazuh

After installing Sysmon on a Windows machine, run a test process on that machine (open Calculator, run `whoami`, etc.) and check the Wazuh dashboard for Sysmon Event ID 1 (process creation) events from that agent.

---

## 9. Detection Validation with Atomic Red Team

[Atomic Red Team](https://github.com/redcanaryco/atomic-red-team) is a library of small, focused tests mapped to MITRE ATT&CK. Each test simulates a specific adversary technique, allowing you to verify your detection rules actually fire.

### Install on GHOUL-WS1

Open PowerShell as Administrator on GHOUL-WS1:

```powershell
Install-Module -Name invoke-atomicredteam -Scope CurrentUser -Force
Import-Module invoke-atomicredteam
IEX (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/redcanaryco/invoke-atomicredteam/master/install-atomicredteam.ps1')
Install-AtomicRedTeam -getAtomics
```

### Validate Key Detections

Run each test and confirm the corresponding Sigma rule fires in Wazuh:

```powershell
# Kerberoasting
Invoke-AtomicTest T1558.003

# LSASS credential dump
Invoke-AtomicTest T1003.001

# DCSync
Invoke-AtomicTest T1003.006

# Scheduled task persistence
Invoke-AtomicTest T1053.005

# Shadow copy deletion
Invoke-AtomicTest T1490

# PowerShell encoded command
Invoke-AtomicTest T1059.001
```

### Validation Checklist

For each test, confirm all three of the following:

- [ ] Alert appears in Wazuh Dashboard with the correct rule name
- [ ] Slack receives a notification (for level 12+ alerts)
- [ ] MITRE ATT&CK technique tag is present in the alert

---

## 10. Portfolio Documentation Standard

For each validated attack scenario, publish a write-up to GitHub (`AmintheGHOUL`) with the following structure:

```
/attacks/
  T1558.003-kerberoasting/
    README.md          ← Full write-up
    screenshots/       ← Wazuh alert, Slack ping, TheHive case
    detection-rule.xml ← The Sigma/Wazuh rule that fired
```

Each `README.md` should contain:

**1. Attack Overview**
- Technique name and MITRE ATT&CK ID
- What the attack does and why it matters

**2. Lab Setup**
- Which machines were involved
- User context (domain admin, standard user, etc.)

**3. Attack Execution**
- Exact tools and commands used
- Atomic Red Team test ID if applicable

**4. Detection Evidence**
- Screenshot of Wazuh alert firing
- Rule ID and rule name
- Screenshot of Slack notification
- TheHive case screenshot

**5. Detection Analysis**
- Which Sigma rule detected it
- What log source and event ID triggered it
- MITRE ATT&CK mapping

**6. Detection Gaps**
- What would have been missed without Sysmon / Sigma rules
- Any false positive considerations

**7. Hardening Recommendations**
- How to prevent or mitigate this technique in a real environment

---

## 11. False Positive Analysis and Rule Tuning

Real-world detection engineering requires tuning rules to eliminate noise while preserving true positive coverage. The following false positives were identified and resolved during initial Sysmon deployment.

### FP 1 — svchost.exe Accessing LSASS (Rule 250110)

**Rule:** `sysmon_cred_dump_lsass_access.xml` — ATT&CK T1003: LSASS Memory Access

**What happened:** Within minutes of Sysmon deployment, rule 250110 began firing continuously at level 14 (Critical) because `svchost.exe` routinely accesses LSASS memory as part of normal Windows operation (LSM service, RPC calls).

**Analysis:** The alert was a false positive. The key indicator is the `SourceImage` — `C:\Windows\system32\svchost.exe`. A real credential dumping attack would show `mimikatz.exe`, `procdump.exe`, `rundll32.exe`, or another attacker-controlled process as the source. The access mask `0x1000` (PROCESS_QUERY_LIMITED_INFORMATION) is also lower-risk than the `0x1F0FFF` or `0x1F1FFF` masks typically used by Mimikatz.

**Fix — Suppression rules added to `sysmon_cred_dump_lsass_access.xml`:**

The suppression rules must live in the same file as rule 250110 — Wazuh loads rule files in alphabetical order and `local_rules.xml` is processed before the Sigma rules directory, making `if_sid` references to Sigma rules invisible at parse time.

```bash
sudo nano /var/ossec/etc/rules/sysmon_cred_dump_lsass_access.xml
```

Add these two rules just before the closing `</group>` tag:

```xml
<!-- Suppress svchost.exe legitimate LSASS access -->
<rule id="250111" level="0">
  <if_sid>250110</if_sid>
  <field name="win.eventdata.sourceImage">svchost.exe</field>
  <description>Suppress: svchost.exe legitimate LSASS access</description>
</rule>

<!-- Suppress Wazuh agent legitimate LSASS access -->
<rule id="250112" level="0">
  <if_sid>250110</if_sid>
  <field name="win.eventdata.sourceImage">wazuh-agent.exe</field>
  <description>Suppress: Wazuh agent legitimate LSASS access</description>
</rule>
```

Also update the `<match>` negation in rule 250110 to include additional known-benign processes:

```xml
<match>!\\wmiprvse.exe$|\\taskmgr.exe$|\\procexp64.exe$|\\procexp.exe$|\\lsm.exe$|\\csrss.exe$|\\wininit.exe$|\\vmtoolsd.exe$|\\svchost.exe$|\\MsMpEng.exe$|\\SecurityHealthService.exe$</match>
```

Validate syntax before restarting:

```bash
sudo /var/ossec/bin/wazuh-analysisd -t 2>&1 | tail -5
sudo systemctl restart wazuh-manager
```

> **Important:** Do not add these suppression rules to `local_rules.xml` — Wazuh processes that file before the custom rules directory, so `if_sid` references to Sigma rule IDs will fail with a "Signature ID not found" warning and the rules will be silently ignored.

**Impact:** Rule 250110 will now only fire when a non-whitelisted process accesses LSASS — exactly what happens when Mimikatz, ProcDump, or other credential dumping tools run.

**Evidence — TheHive Case #143:**

![TheHive Case 143 — LSASS False Positive](./screenshots/thehive-fp-lsass-svchost.png)

---

### FP 2 — dsregcmd.exe Flagged as Renamed Binary (Rule 261180)

**Rule:** `win_susp_renamed_dctask64.xml` — ATT&CK T1036: Renamed Binary

**What happened:** Rule 261180 fired at level 10 (Medium) for `dsregcmd.exe` launched by Task Scheduler with unresolved `$(Arg0) $(Arg1) $(Arg2)` argument placeholders.

**Analysis:** `dsregcmd.exe` is a legitimate Windows binary for Azure AD device registration. The `$(Arg0)` placeholders are normal Task Scheduler behavior when no arguments are defined for a scheduled task. This is not a renamed binary attack.

**Decision:** Rule left active — intentionally not suppressed. The rule correctly fires for actual renamed binary attacks (e.g. Mimikatz renamed as `svchost.exe`). The `dsregcmd.exe` false positive is documented as a known benign trigger for this environment.

**Portfolio note:** Documenting this decision demonstrates the analyst understands the difference between suppressing a noisy rule entirely and accepting known false positives to preserve detection coverage.

**Evidence — TheHive Case #144:**

![TheHive Case 144 — Renamed Binary False Positive](./screenshots/thehive-fp-renamed-binary.png)

---

## 12. Alert Formatting — Clean Readable Output

By default, Wazuh's built-in Slack integration sends raw JSON alert data which is unreadable in a notification context. Both the Slack and TheHive integrations were replaced with custom Python scripts that produce structured, human-readable output.

### Custom Slack Integration (`custom-slack`)

Located at `/var/ossec/integrations/custom-slack`. Fires for level 12+ alerts.

**Output format:**
```
🔴 WAZUH ALERT — HIGH
Administrators Group Changed

• Agent: GHOUL-DC01 (192.168.10.10)
• Rule ID: 60154 | Level: 12
• Time: 2026-06-12T19:18:33
• MITRE: attack.t1484
• Event ID: 4732 | Channel: Security
```

**Key fields extracted:** source process, target process, command line, parent process, access mask, destination IP, registry key, user — only populated fields are shown.

**ossec.conf registration:**

```xml
<integration>
  <name>custom-slack</name>
  <hook_url>https://hooks.slack.com/services/YOUR/WEBHOOK/URL</hook_url>
  <level>12</level>
  <alert_format>json</alert_format>
</integration>
```

### Custom TheHive Integration (`custom-thehive`)

Located at `/var/ossec/integrations/custom-thehive`. Fires for level 8+ alerts.

Case descriptions use structured markdown sections — Alert Summary, Event Details, Log Source — rather than raw JSON dumps. MITRE tags, agent name, rule ID, severity, and key event fields are all extracted and presented cleanly.

**Permissions for both scripts:**
```bash
sudo chmod 755 /var/ossec/integrations/custom-slack
sudo chmod 755 /var/ossec/integrations/custom-thehive
sudo chown root:wazuh /var/ossec/integrations/custom-slack
sudo chown root:wazuh /var/ossec/integrations/custom-thehive
```

---

## 13. Detection Coverage Summary

| Attack Category | Sigma Rules Deployed | Sysmon Required | Status |
|---|---|---|---|
| Credential Access | 15+ | Partial | ✅ Active |
| Lateral Movement | 10+ | No | ✅ Active |
| Persistence | 10+ | Partial | ✅ Active |
| Defense Evasion | 8+ | No | ✅ Active |
| Discovery / Recon | 8+ | No | ✅ Active |
| Execution | 15+ | Partial | ✅ Active |
| Privilege Escalation | 8+ | Partial | ✅ Active |
| Impact (Ransomware) | 6+ | No | ✅ Active |
| Sysmon-specific | ~80 | **Yes** | ✅ Active — DC01, WS1, WS2 |
