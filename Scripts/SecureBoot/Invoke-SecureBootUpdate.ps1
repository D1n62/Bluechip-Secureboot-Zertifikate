<#
.SYNOPSIS
    Prüft und aktualisiert die Windows UEFI Secure Boot 2023 Zertifikate.
.DESCRIPTION
    Hauptskript zur Analyse und Aktualisierung der Secure Boot Zertifikate.
    Prüft db, KEK, Boot-Manager-Signatur, BitLocker-Schutz und triggert
    bei Bedarf das Microsoft Zertifikats-Update.

    Referenz: KB5062710 - Windows Secure Boot certificate expiration and CA updates
    https://support.microsoft.com/topic/5062710

    Benötigte Zertifikate (Ablauf 2026):
    - Windows UEFI CA 2023              (db)  - Boot Loader Signatur
    - Microsoft Corporation KEK 2K CA 2023 (KEK) - DB/DBX Updates
    - Microsoft UEFI CA 2023             (db)  - 3rd-Party Boot Loader
    - Microsoft Option ROM UEFI CA 2023  (db)  - Option ROMs
.NOTES
    Erfordert Administratorrechte.
    Bei aktivem BitLocker wird der Schutz automatisch pausiert.
.EXAMPLE
    .\Invoke-SecureBootUpdate.ps1 -Info
    Zeigt eine vollstaendige Systemanalyse (Zertifikate, BitLocker, Readiness).
.EXAMPLE
    .\Invoke-SecureBootUpdate.ps1 -ApplyUpdate
    Prueft und fuehrt fehlende Zertifikats-Updates durch.
.EXAMPLE
    .\Invoke-SecureBootUpdate.ps1 -Check
    Schnell-Nachkontrolle: Prueft ob die 2023-Zertifikate nach dem Update vorhanden sind.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [switch]$Info,

    [Parameter()]
    [switch]$ApplyUpdate,

    [Parameter()]
    [switch]$Check
)

#region Module laden
$parentPath = Split-Path -Path $PSScriptRoot -Parent
$grandParentPath = if ([string]::IsNullOrWhiteSpace($parentPath)) { $null } else { Split-Path -Path $parentPath -Parent }
$moduleCandidates = @(
    (Join-Path -Path $PSScriptRoot -ChildPath 'Modules'),
    $(if (-not [string]::IsNullOrWhiteSpace($parentPath)) { Join-Path -Path $parentPath -ChildPath 'Modules' }),
    $(if (-not [string]::IsNullOrWhiteSpace($grandParentPath)) { Join-Path -Path $grandParentPath -ChildPath 'Modules' })
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$modulePath = $null
foreach ($candidatePath in $moduleCandidates) {
    if (Test-Path -Path $candidatePath) {
        $modulePath = $candidatePath
        break
    }
}
if (-not $modulePath) {
    throw 'Die Moduldateien wurden nicht gefunden. Erwartet wird ein Ordner "Modules" neben dem Skript, eine Ebene darueber oder im Repo-Root.'
}
Import-Module (Join-Path $modulePath 'ConsoleUI\ConsoleUI.psm1') -Force
Import-Module (Join-Path $modulePath 'UefiSecureBoot\UefiSecureBoot.psm1') -Force
Import-Module (Join-Path $modulePath 'BitLockerHelper\BitLockerHelper.psm1') -Force
#endregion

#region Administratorprüfung
if (-not (Test-AdminPrivileges)) {
    Write-ActionMessage -Message 'Dieses Skript erfordert Administratorrechte. Bitte als Administrator ausfuehren.' -Type Error
    exit 1
}
#endregion

#region Parameterpruefung
if (-not ($Info -or $ApplyUpdate -or $Check)) {
    Write-Host ''
    Write-Host '  Fehler: Kein Modus angegeben.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Verwendung:' -ForegroundColor Yellow
    Write-Host '    -Info         Vollstaendige Systemanalyse anzeigen' -ForegroundColor Yellow
    Write-Host '    -ApplyUpdate  Fehlende Zertifikate aktualisieren' -ForegroundColor Yellow
    Write-Host '    -Check        Schnell-Nachkontrolle nach dem Update' -ForegroundColor Yellow
    exit 1
}
if (($Info.IsPresent -as [int]) + ($ApplyUpdate.IsPresent -as [int]) + ($Check.IsPresent -as [int]) -gt 1) {
    Write-Host ''
    Write-Host '  Fehler: Nur einen Modus gleichzeitig angeben (-Info, -ApplyUpdate oder -Check).' -ForegroundColor Red
    exit 1
}
#endregion

#region Logging
$modeName = if ($Info) { 'Info' } elseif ($ApplyUpdate) { 'ApplyUpdate' } else { 'Check' }
$boardInfo = Get-BoardInfo
$logName   = ($boardInfo.Modell + '_' + $boardInfo.BiosVersion) -replace '[\\/:*?"<>|]', '_'
$logPath   = Join-Path $PSScriptRoot ("{0}-{1}.log" -f $logName, $modeName)
$URL = "https://cim.d1ng2.net/api/empfang"
$TOKEN = "MIB-GMBH-757"
Start-Transcript -Path $logPath -Force | Out-Null
#endregion

try {

#region Schnell-Nachkontrolle (-Check)
if ($Check) {
    Write-SectionHeader -Title 'Schnell-Nachkontrolle: 2023-Zertifikate'
    $certCheck = Get-SecureBootCertificateStatus
    $only2023  = $certCheck | Where-Object { $_.Is2023 }
    foreach ($c in $only2023) {
        $label = '{0} ({1})' -f $c.Name, $c.Store
        Write-StatusLine -Label $label -Status $c.Found
    }
    $stillMissing = $only2023 | Where-Object { -not $_.Found }
    if (($stillMissing | Measure-Object).Count -eq 0) {
        Write-ActionMessage -Message 'Alle 2023-Zertifikate sind vorhanden. Update war erfolgreich.' -Type Success
        # ==================== DATEN SAMMELN ====================
        $daten = @{
            section     = "Secure Boot Zertifikats-Pruefung"
            computer    = $env:COMPUTERNAME
            benutzer    = "$env:USERDOMAIN\$env:USERNAME"
            datum       = Get-Date -Format 'dd.MM.yyyy HH:mm:ss'
            windowsVersion = [System.Environment]::OSVersion.VersionString
            mainboardHersteller = $boardInfo.Hersteller
            mainboardModell     = $boardInfo.Modell
            biosVersion         = $boardInfo.BiosVersion
            biosDatum           = $boardInfo.BiosDatum
            logDatei            = $logPath
            status              = "erfolgreich"
        }

        $headers = @{
            "Authorization" = "Bearer757 $TOKEN"
            "Content-Type"  = "application/json"
        }
        # ======================================================

        try {
            $jsonBody = $daten | ConvertTo-Json -Depth 10

            $response = Invoke-RestMethod -Uri $URL `
                                        -Method Post `
                                        -Body $jsonBody `
                                        -Headers $headers `
                                        -TimeoutSec 5

            Write-Host "✅ Daten erfolgreich an API gesendet" -ForegroundColor Green
            $response | ConvertTo-Json -Depth 3
        }
        catch {
            Write-Host "❌ Fehler beim Senden an API" -ForegroundColor Red
            Write-Host "StatusCode: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Red
            Write-Host "Message: $($_.Exception.Message)" -ForegroundColor Red
            
            if ($_.Exception.Response) {
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $reader.BaseStream.Position = 0
                    $errorResponse = $reader.ReadToEnd()
                    Write-Host "API-Antwort: $errorResponse" -ForegroundColor Yellow
                } catch {}
            }
        }
    }
    else {
        Write-ActionMessage -Message 'Es fehlen noch 2023-Zertifikate. Ggf. ist ein Neustart erforderlich.' -Type Warning
        foreach ($m in $stillMissing) {
            Write-ActionMessage -Message "Fehlt: $($m.Name) ($($m.Store))" -Type Warning
        }
    }
    exit 0
}
#endregion

#region Systeminfo-Header
Write-SectionHeader -Title 'Secure Boot Zertifikats-Pruefung'
Write-InfoLine -Label 'Computer' -Value $env:COMPUTERNAME
Write-InfoLine -Label 'Benutzer' -Value "$env:USERDOMAIN\$env:USERNAME"
Write-InfoLine -Label 'Datum' -Value (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')
Write-InfoLine -Label 'Windows-Version' -Value ([System.Environment]::OSVersion.VersionString)
Write-InfoLine -Label 'Mainboard Hersteller' -Value $boardInfo.Hersteller
Write-InfoLine -Label 'Mainboard Modell' -Value $boardInfo.Modell
Write-InfoLine -Label 'BIOS Version' -Value $boardInfo.BiosVersion
Write-InfoLine -Label 'BIOS Datum' -Value $boardInfo.BiosDatum
Write-InfoLine -Label 'Log-Datei' -Value $logPath
#endregion

#region Secure Boot Status
Write-SectionHeader -Title 'Secure Boot Grundstatus'

$platformStatus = Get-SecureBootPlatformStatus
Write-InfoLine -Label 'Firmware-Modus' -Value $platformStatus.FirmwareType
Write-InfoLine -Label 'Secure-Boot-Quelle' -Value $platformStatus.DetectionSource
Write-StatusLine -Label 'Secure Boot aktiviert' -Status $platformStatus.IsEnabled

if (-not $platformStatus.IsSupported) {
    Write-ActionMessage -Message $platformStatus.Message -Type Error
    Write-ActionMessage -Message 'Bitte das System im UEFI-Modus starten. Auf BIOS-/Legacy-Installationen ist dieses Paket nicht einsetzbar.' -Type Warning
    exit 1
}

if (-not $platformStatus.IsEnabled) {
    Write-ActionMessage -Message $platformStatus.Message -Type Error
    Write-ActionMessage -Message 'Bitte Secure Boot im UEFI/BIOS aktivieren und das Skript danach erneut starten.' -Type Warning
    exit 1
}
#endregion

#region Zertifikate prüfen
Write-SectionHeader -Title 'Zertifikate in UEFI-Datenbanken'

$certStatus = Get-SecureBootCertificateStatus
$summaryResults = @()

foreach ($cert in $certStatus) {
    $label = "{0} ({1})" -f $cert.Name, $cert.Store
    Write-StatusLine -Label $label -Status $cert.Found
    $summaryResults += @{ Name = $cert.Name; Status = $cert.Found }
}

$missing2023 = $certStatus | Where-Object { $_.Is2023 -and -not $_.Found }
$has2023Issues = ($missing2023 | Measure-Object).Count -gt 0
#endregion

#region Zertifikatsherkunft: BIOS/OEM vs. Windows/OS
Write-SectionHeader -Title 'Zertifikatsherkunft: BIOS/OEM vs. Windows/OS'

$dbSources    = Get-SecureBootDatabaseSources
$biosCerts    = @($dbSources | Where-Object { $_.Herkunft -eq 'BIOS/OEM' })
$osCerts      = @($dbSources | Where-Object { $_.Herkunft -eq 'Windows/OS' })
$unknownCerts = @($dbSources | Where-Object { $_.Herkunft -eq 'Unbekannt' })

if ($dbSources.Count -eq 0) {
    Write-ActionMessage -Message 'Keine Zertifikatsdaten verfuegbar (kein Secure Boot oder kein Admin-Zugriff).' -Type Warning
}
else {
    # --- BIOS/OEM ---
    Write-Host ''
    Write-Host "  Im BIOS/UEFI ab Werk hinterlegt  ($($biosCerts.Count) Eintraege):" -ForegroundColor Cyan

    if ($biosCerts.Count -gt 0) {
        foreach ($cert in $biosCerts) {
            $display = '[{0}]  {1}' -f $cert.Datenbank, $cert.Name
            Write-Host ('  {0,-52} gueltig bis {1}' -f $display, $cert.GueltigBis) -ForegroundColor Cyan
        }
    }
    else {
        Write-Host '    (keine oder dbDefault nicht verfuegbar)' -ForegroundColor DarkGray
    }

    # --- Windows / OS ---
    Write-Host ''
    Write-Host "  Durch Windows / Betriebssystem hinzugefuegt  ($($osCerts.Count) Eintraege):" -ForegroundColor Yellow

    if ($osCerts.Count -gt 0) {
        foreach ($cert in $osCerts) {
            $display = '[{0}]  {1}' -f $cert.Datenbank, $cert.Name
            Write-Host ('  {0,-52} gueltig bis {1}' -f $display, $cert.GueltigBis) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '    (keine)' -ForegroundColor DarkGray
    }

    # --- Herkunft unbekannt (kein dbDefault vorhanden) ---
    if ($unknownCerts.Count -gt 0) {
        Write-Host ''
        Write-Host "  Herkunft unbekannt (dbDefault nicht lesbar)  ($($unknownCerts.Count) Eintraege):" -ForegroundColor Gray

        foreach ($cert in $unknownCerts) {
            $display = '[{0}]  {1}' -f $cert.Datenbank, $cert.Name
            Write-Host ('  {0,-52} gueltig bis {1}' -f $display, $cert.GueltigBis) -ForegroundColor Gray
        }
    }

    Write-Host ''
    Write-ActionMessage -Message (
        'Gesamt: {0} Eintraege ({1} BIOS/OEM  |  {2} Windows/OS  |  {3} Unbekannt)' -f
        $dbSources.Count, $biosCerts.Count, $osCerts.Count, $unknownCerts.Count
    ) -Type Info
}
#endregion

#region BitLocker Status
Write-SectionHeader -Title 'BitLocker Status'

$bitlockerVolumes = Get-BitLockerProtectionStatus
$systemDriveBL = $bitlockerVolumes | Where-Object { $_.IsSystemDrive }
$bitlockerActive = $false

if ($systemDriveBL) {
    Write-StatusLine -Label "BitLocker Schutz ($($systemDriveBL.MountPoint))" -Status $true -DisplayValue $systemDriveBL.ProtectionStatus
    Write-InfoLine -Label 'Volume-Status' -Value $systemDriveBL.VolumeStatus
    $bitlockerActive = $systemDriveBL.IsProtected
}
else {
    Write-ActionMessage -Message 'BitLocker ist auf dem Systemlaufwerk nicht konfiguriert.' -Type Info
}

foreach ($vol in ($bitlockerVolumes | Where-Object { -not $_.IsSystemDrive })) {
    Write-InfoLine -Label "BitLocker ($($vol.MountPoint))" -Value $vol.ProtectionStatus
}
#endregion

#region Zusammenfassung
Write-SummaryTable -Results $summaryResults
#endregion

#region Aktion: Update durchführen
if ($Info) {
    Write-ActionMessage -Message 'Analyse-Modus (-Info). Fuer das Update mit -ApplyUpdate ausfuehren.' -Type Info
    exit 0
}

if (-not $has2023Issues) {
    Write-ActionMessage -Message 'Alle 2023-Zertifikate sind vorhanden. Kein Update erforderlich.' -Type Success
    exit 0
}

Write-SectionHeader -Title 'Massnahmen zum Zertifikatsupdate'

if ($has2023Issues) {
    Write-ActionMessage -Message 'Fehlende 2023-Zertifikate erkannt. Update wird vorbereitet...' -Type Warning

    foreach ($cert in $missing2023) {
        Write-ActionMessage -Message "Fehlt: $($cert.Name) ($($cert.Store))" -Type Warning
    }
}

#region Lokale Konfiguration fuer Secure Boot
Write-SectionHeader -Title 'Lokale Konfiguration fuer Secure Boot'

$sbRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'

# 1. Registrierungswert fuer die Zertifikatbereitstellung setzen
#    Registrierungswert: AvailableUpdatesPolicy = 22852 (0x5944)
try {
    $cur1 = (Get-ItemProperty -Path $sbRegPath -Name 'AvailableUpdatesPolicy' -ErrorAction SilentlyContinue).AvailableUpdatesPolicy
    if ($cur1 -ne 22852) {
        Set-ItemProperty -Path $sbRegPath -Name 'AvailableUpdatesPolicy' -Value 22852 -Type DWord -Force -ErrorAction Stop
        Write-ActionMessage -Message 'Registrierungswert ''AvailableUpdatesPolicy'': Auf 22852 gesetzt.' -Type Success
    }
    else {
        Write-ActionMessage -Message 'Registrierungswert ''AvailableUpdatesPolicy'': Bereits gesetzt.' -Type Info
    }
}
catch {
    Write-ActionMessage -Message "Registrierungswert 'AvailableUpdatesPolicy': Fehler beim Setzen – $_" -Type Error
}

# 2. Registrierungswert fuer die Update-Bereitstellung setzen
#    Registrierungswert: HighConfidenceOptOut = 1
try {
    $cur2 = (Get-ItemProperty -Path $sbRegPath -Name 'HighConfidenceOptOut' -ErrorAction SilentlyContinue).HighConfidenceOptOut
    if ($cur2 -ne 1) {
        Set-ItemProperty -Path $sbRegPath -Name 'HighConfidenceOptOut' -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-ActionMessage -Message 'Registrierungswert ''HighConfidenceOptOut'': Auf 1 gesetzt.' -Type Success
    }
    else {
        Write-ActionMessage -Message 'Registrierungswert ''HighConfidenceOptOut'': Bereits gesetzt.' -Type Info
    }
}
catch {
    Write-ActionMessage -Message "Registrierungswert 'HighConfidenceOptOut': Fehler beim Setzen – $_" -Type Error
}
#endregion

# BitLocker pausieren falls aktiv
if ($bitlockerActive) {
    Write-ActionMessage -Message 'BitLocker ist aktiv. Schutz wird fuer 2 Neustarts pausiert...' -Type Warning

    $suspendResult = Suspend-BitLockerForUpdate -MountPoint $systemDriveBL.MountPoint -RebootCount 2
    if ($suspendResult.Suspended) {
        Write-ActionMessage -Message 'BitLocker-Schutz erfolgreich pausiert.' -Type Success
    }
    else {
        Write-ActionMessage -Message "BitLocker konnte nicht pausiert werden: $($suspendResult.Reason)" -Type Error
        Write-ActionMessage -Message 'Update wird abgebrochen um BitLocker-Recovery zu vermeiden.' -Type Error
        exit 1
    }
}

# Secure Boot Update triggern
Write-ActionMessage -Message 'Setze Registrierungswert AvailableUpdates = 0x5944...' -Type Info
$updateResult = Start-SecureBootCertificateUpdate

if ($updateResult.UpdateTriggered) {
    Write-ActionMessage -Message 'Secure Boot Update-Task erfolgreich gestartet.' -Type Success
    Write-ActionMessage -Message 'Ein Neustart ist erforderlich um die Zertifikate zu installieren.' -Type Warning
    Write-ActionMessage -Message 'Nach dem Neustart das Skript erneut ausfuehren um den Status zu pruefen.' -Type Info

    Write-Host ''
    Write-ActionMessage -Message 'Neustart wurde verschoben. Bitte manuell neustarten.' -Type Warning






    # ==================== DATEN SAMMELN ====================
    $daten = @{
        section     = "Secure Boot Zertifikats-Pruefung"
        computer    = $env:COMPUTERNAME
        benutzer    = "$env:USERDOMAIN\$env:USERNAME"
        datum       = Get-Date -Format 'dd.MM.yyyy HH:mm:ss'
        windowsVersion = [System.Environment]::OSVersion.VersionString
        mainboardHersteller = $boardInfo.Hersteller
        mainboardModell     = $boardInfo.Modell
        biosVersion         = $boardInfo.BiosVersion
        biosDatum           = $boardInfo.BiosDatum
        logDatei            = $logPath
        status              = "erfolgreich"
    }

    $headers = @{
        "Authorization" = "Bearer757 $TOKEN"
        "Content-Type"  = "application/json"
    }
    # ======================================================

    try {
        $jsonBody = $daten | ConvertTo-Json -Depth 10

        $response = Invoke-RestMethod -Uri $URL `
                                    -Method Post `
                                    -Body $jsonBody `
                                    -Headers $headers `
                                    -TimeoutSec 5

        Write-Host "✅ Daten erfolgreich an API gesendet" -ForegroundColor Green
        $response | ConvertTo-Json -Depth 3
    }
    catch {
        Write-Host "❌ Fehler beim Senden an API" -ForegroundColor Red
        Write-Host "StatusCode: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Red
        Write-Host "Message: $($_.Exception.Message)" -ForegroundColor Red
        
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $reader.BaseStream.Position = 0
                $errorResponse = $reader.ReadToEnd()
                Write-Host "API-Antwort: $errorResponse" -ForegroundColor Yellow
            } catch {}
        }
    }









    
}
else {
    Write-ActionMessage -Message "Update konnte nicht gestartet werden: $($updateResult.Reason)" -Type Error
    # ==================== DATEN SAMMELN ====================
    $daten = @{
        section     = "Secure Boot Zertifikats-Pruefung"
        computer    = $env:COMPUTERNAME
        benutzer    = "$env:USERDOMAIN\$env:USERNAME"
        datum       = Get-Date -Format 'dd.MM.yyyy HH:mm:ss'
        windowsVersion = [System.Environment]::OSVersion.VersionString
        mainboardHersteller = $boardInfo.Hersteller
        mainboardModell     = $boardInfo.Modell
        biosVersion         = $boardInfo.BiosVersion
        biosDatum           = $boardInfo.BiosDatum
        logDatei            = $logPath

        status              = "Fehlerhaft"
    }

    $headers = @{
        "Authorization" = "Bearer757 $TOKEN"
        "Content-Type"  = "application/json"
    }
    # ======================================================

    try {
        $jsonBody = $daten | ConvertTo-Json -Depth 10

        $response = Invoke-RestMethod -Uri $URL `
                                    -Method Post `
                                    -Body $jsonBody `
                                    -Headers $headers `
                                    -TimeoutSec 5

        Write-Host "✅ Daten erfolgreich an API gesendet" -ForegroundColor Green
        $response | ConvertTo-Json -Depth 3
    }
    catch {
        Write-Host "❌ Fehler beim Senden an API" -ForegroundColor Red
        Write-Host "StatusCode: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Red
        Write-Host "Message: $($_.Exception.Message)" -ForegroundColor Red
        
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $reader.BaseStream.Position = 0
                $errorResponse = $reader.ReadToEnd()
                Write-Host "API-Antwort: $errorResponse" -ForegroundColor Yellow
            } catch {}
        }
    }
    exit 1
}
#endregion

} # end try
finally {
    Stop-Transcript | Out-Null

    # Transcript-Meta-Bloecke (Header + Footer) aus der Log-Datei entfernen.
    # Beide Bloecke sind durch Zeilen aus '*'-Zeichen begrenzt.
    if (Test-Path -Path $logPath) {
        $lines   = Get-Content -Path $logPath -Encoding UTF8
        $cleaned = [System.Collections.Generic.List[string]]::new()
        $inBlock = $false

        foreach ($line in $lines) {
            if ($line -match '^\*{4,}') {
                $inBlock = -not $inBlock
                continue
            }
            if (-not $inBlock) {
                $cleaned.Add($line)
            }
        }

        # Fuehrende Leerzeilen entfernen
        $start = 0
        while ($start -lt $cleaned.Count -and [string]::IsNullOrWhiteSpace($cleaned[$start])) { $start++ }

        Set-Content -Path $logPath -Value $cleaned[$start..($cleaned.Count - 1)] -Encoding UTF8
    }
}
