# Secure Boot 2023 – Zertifikats-Prüfung & Update

Automatisierte Prüfung und Aktualisierung der ablaufenden Windows Secure Boot Zertifikate (KB5062710).

## Hintergrund

Die 2011er Secure-Boot-Zertifikate laufen ab:

| Ablaufendes Zertifikat                    | Ablauf    | Neues Zertifikat                          | Speicherort |
|-------------------------------------------|-----------|-------------------------------------------|-------------|
| Microsoft Corporation KEK CA 2011         | Juni 2026 | Microsoft Corporation KEK 2K CA 2023      | KEK         |
| Microsoft Windows Production PCA 2011     | Okt 2026  | Windows UEFI CA 2023                      | db          |
| Microsoft Corporation UEFI CA 2011        | Juni 2026 | Microsoft UEFI CA 2023                    | db          |
| Microsoft Corporation UEFI CA 2011        | Juni 2026 | Microsoft Option ROM UEFI CA 2023         | db          |

Ohne die neuen 2023-Zertifikate können keine Boot-Sicherheitsupdates
mehr eingespielt werden. Bei aktivem BitLocker muss der Schutz vor dem
Update pausiert werden, da sonst der Recovery-Key abgefragt wird.

> **Referenz:** [KB5062710 – Windows Secure Boot certificate expiration](https://support.microsoft.com/topic/5062710)

---

## Voraussetzungen

- Windows 10 (21H2+) oder Windows 11
- Windows PowerShell 5.1
- **Administratorrechte** (wird automatisch geprüft)
- UEFI Secure Boot muss im BIOS aktiviert sein

---

## Verwendung

### Remote (Einzeiler)

```powershell
irm https://git.bluechip.local/PM/ps-toolbox/raw/branch/master/loader.ps1 | iex

# Nur prüfen (Standard)
Start-PsToolbox SecureBoot

# Prüfen + Update durchführen
Start-PsToolbox SecureBoot -ArgumentList '-ApplyUpdate'
```

### Lokal

```powershell
# Nur prüfen (Standard)
.\Invoke-SecureBootUpdate.ps1

# Prüfen + Update durchführen
.\Invoke-SecureBootUpdate.ps1 -ApplyUpdate
```

Im Standardmodus wird nur eine Analyse durchgeführt. Erst mit `-ApplyUpdate`
werden Änderungen am System vorgenommen:

1. **Administratorrechte prüfen**
2. **Secure Boot Status** – Ist Secure Boot aktiviert?
3. **Zertifikate prüfen** – Sind die 2023-Zertifikate in db und KEK vorhanden?
4. **System Readiness** – Registry-Wert `2023Capable` auswerten (0/1/2)
5. **BitLocker prüfen** – Ist BitLocker auf dem Systemlaufwerk aktiv?
6. **BitLocker pausieren** – Falls aktiv: Schutz für 2 Neustarts aussetzen *(nur mit `-ApplyUpdate`)*
7. **Update triggern** – Registry `AvailableUpdates = 0x100` setzen und Scheduled Task starten *(nur mit `-ApplyUpdate`)*
8. **Neustart anbieten** – Zertifikate werden beim Neustart installiert *(nur mit `-ApplyUpdate`)*

---

## Verwendete Module

### UefiSecureBoot

| Funktion                            | Beschreibung                                        |
|-------------------------------------|-----------------------------------------------------|
| `Test-SecureBootEnabled`            | Prüft ob Secure Boot aktiviert ist                  |
| `Get-SecureBootCertificateStatus`   | Prüft alle 7 Zertifikate in db und KEK              |
| `Get-SecureBootReadiness`           | Liest `2023Capable` Registry-Wert (0/1/2)           |
| `Get-BootManagerSignature`          | Prüft ob bootmgfw.efi mit 2023-Zertifikat signiert  |
| `Start-SecureBootCertificateUpdate` | Setzt AvailableUpdates und startet Update-Task       |
| `Test-AdminPrivileges`              | Prüft Administratorrechte                            |

### BitLockerHelper

| Funktion                       | Beschreibung                                          |
|--------------------------------|-------------------------------------------------------|
| `Get-BitLockerProtectionStatus`| Status aller Laufwerke (Schutz, Verschlüsselung)      |
| `Suspend-BitLockerForUpdate`   | Pausiert Schutz für N Neustarts (Standard: 2)          |
| `Resume-BitLockerAfterUpdate`  | Setzt BitLocker-Schutz fort                            |

---

## Geprüfte Zertifikate

### Neue 2023-Zertifikate (müssen vorhanden sein)

| Zertifikat                             | Speicherort | SHA-1 Hash                               |
|----------------------------------------|-------------|------------------------------------------|
| Windows UEFI CA 2023                   | db          | `45A0FA32604773C82433C3B7D59E7466B3AC0C67`|
| Microsoft Corporation KEK 2K CA 2023   | KEK         | `459AB6FB5E284D272D5E3E6ABC8ED663829D632B`|
| Microsoft UEFI CA 2023                 | db          | `B5EEB4A6706048073F0ED296E7F580A790B59EAA`|
| Microsoft Option ROM UEFI CA 2023      | db          | `3FB39E2B8BD183BF9E4594E72183CA60AFCD4277`|

### Alte 2011-Zertifikate (Kompatibilitätsprüfung)

| Zertifikat                             | Speicherort | Ablauf    |
|----------------------------------------|-------------|-----------|
| Windows Production PCA 2011            | db          | Okt 2026  |
| Microsoft Corporation UEFI CA 2011     | db          | Juni 2026 |
| Microsoft Corporation KEK CA 2011      | KEK         | Juni 2026 |

---

## Beispielausgabe

```
============================================================
  Secure Boot Zertifikats-Pruefung
============================================================
  Computer                                      : DESKTOP-ABC
  Benutzer                                      : DOMAIN\admin
  Datum                                         : 16.02.2026 14:30:00
  Windows-Version                               : Microsoft Windows NT 10.0.26100

============================================================
  Secure Boot Grundstatus
============================================================
  Secure Boot aktiviert                          : [OK]

============================================================
  Zertifikate in UEFI-Datenbanken
============================================================
  Windows UEFI CA 2023 (db)                      : [OK]
  Microsoft Corporation KEK 2K CA 2023 (KEK)     : [OK]
  Microsoft UEFI CA 2023 (db)                    : [FEHLER]
  Microsoft Option ROM UEFI CA 2023 (db)         : [FEHLER]
  Windows Production PCA 2011 (db)               : [OK]
  Microsoft Corporation UEFI CA 2011 (db)        : [OK]
  Microsoft Corporation KEK CA 2011 (KEK)        : [OK]

============================================================
  BitLocker Status
============================================================
  BitLocker Schutz (C:\)                         : On
  Volume-Status                                  : FullyEncrypted

============================================================
  Zusammenfassung
============================================================
  Bestanden: 5  |  Fehlgeschlagen: 2  |  Gesamt: 7
```

---

## Technische Details

### Update-Mechanismus

1. **Registry-Trigger:** `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\AvailableUpdates` wird auf `0x100` gesetzt
2. **Scheduled Task:** `\Microsoft\Windows\PI\Secure-Boot-Update` wird gestartet
3. **Neustart:** Zertifikate werden beim nächsten Boot installiert
4. **Validierung:** `2023Capable` wechselt auf `2` wenn alles installiert ist

### Alternative Verwaltung

- **Lokale Konfiguration:** Registrierungswerte `AvailableUpdatesPolicy` und `HighConfidenceOptOut` unter `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot`
- **MDM/Intune:** Policy CSP `EnableSecurebootCertificateUpdates = 22852`
- **WinCS API:** Ab KB5067036 verfügbar für erweiterte Zertifikatsverwaltung

---

## Encoding-Check fuer CMD/BAT

Vor Verpackung oder Freigabe sollte die Codierung der Batch-Dateien geprüft werden:

```powershell
.\.tools\Test-RepositoryEncoding.ps1
```

Der Check meldet einen Fehler, sobald eine `*.cmd`- oder `*.bat`-Datei nicht als **UTF-8 ohne BOM** oder nicht mit **CRLF** gespeichert ist.

In VS Code kann alternativ die Task **Validate CMD/BAT encoding** ausgeführt werden.

---

## Release-Paket erzeugen

Für die Neuerzeugung der technischen PDF, des SIS-Ordners sowie beider ZIP-Artefakte inklusive Encoding-Check steht ein Release-Wrapper bereit:

```powershell
.\.tools\Build-SecureBootRelease.ps1
```

Der Ablauf umfasst:

1. CMD-/BAT-Encoding validieren
2. technische PDF aus `SecureBootUpdate.html` neu erzeugen
3. Ordner `SIS` mit nur den zwingend erforderlichen Release-Dateien neu erstellen
4. `SecureBootUpdate.zip` mit `Modules/*`, `Scripts/SecureBoot/*` und der technischen PDF im ZIP-Root neu erzeugen
5. `SIS_SecureBoot-Update.zip` aus dem aktuellen `SIS`-Ordner neu erzeugen
6. HTML, PDF, CMD und ZIP-Strukturen technisch prüfen

Die technische Kunden-PDF wird standardmäßig als `Technische-Information_Secure-Boot-Zertifikats-Update.pdf` im Repository-Root erzeugt.

Das resultierende SIS-Paket hat eine flache Startstruktur:

- `SIS\Start-SecureBootUpdate.cmd` startet das Update direkt aus dem Paket-Root
- `SIS\Invoke-SecureBootUpdate.ps1` liegt ebenfalls im Paket-Root
- Logdateien werden beim Ausführen direkt im Root des Ordners `SIS` abgelegt
- Die benötigten PowerShell-Module liegen unter `SIS\Modules`

In VS Code kann alternativ die Task **Build SecureBoot release** verwendet werden.

### BitLocker-Sicherheit

- BitLocker wird **vor** dem Update für **2 Neustarts** pausiert
- Nach 2 Neustarts reaktiviert sich der Schutz **automatisch**
- Wird BitLocker nicht pausiert, löst die Secure-Boot-Änderung eine **Recovery-Key-Abfrage** aus

---

## Quellen

- [KB5062710 – Windows Secure Boot certificate expiration and CA updates](https://support.microsoft.com/topic/5062710)
- [Secure Boot Key Creation and Management Guidance](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-secure-boot-key-creation-and-management-guidance)
- [Policy CSP – SecureBoot](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-secureboot)
- [WinCS APIs for Secure Boot](https://support.microsoft.com/topic/d3e64aa0-6095-4f8a-b8e4-fbfda254a8fe)
- [Microsoft Secure Boot Objects (GitHub)](https://github.com/microsoft/secureboot_objects)

---

## Hinweis

Die zugehörigen Skripte und diese Begleitdokumentation werden als technische Information bereitgestellt. Es handelt sich nicht um eine offizielle Veröffentlichung von Microsoft; maßgeblich sind die jeweils aktuellen Originalquellen von Microsoft.

Microsoft, Windows, Intune, Entra ID und weitere genannte Produktnamen sind Marken der jeweiligen Rechteinhaber und werden hier ausschließlich beschreibend verwendet.
