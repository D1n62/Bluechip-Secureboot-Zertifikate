<#
.SYNOPSIS
    Checks and updates the Windows UEFI Secure Boot 2023 certificates.
.DESCRIPTION
    Main script for analyzing and updating Secure Boot certificates.
    Checks db, KEK, Boot Manager signature, BitLocker protection and triggers
    the Microsoft certificate update if required.

    Reference: KB5062710 - Windows Secure Boot certificate expiration and CA updates
    https://support.microsoft.com/topic/5062710

    Required certificates (expiring 2026):
    - Windows UEFI CA 2023              (db)  - Boot Loader Signature
    - Microsoft Corporation KEK 2K CA 2023 (KEK) - DB/DBX Updates
    - Microsoft UEFI CA 2023             (db)  - 3rd-Party Boot Loader
    - Microsoft Option ROM UEFI CA 2023  (db)  - Option ROMs
.NOTES
    Requires administrator privileges.
    If BitLocker is active, protection is automatically suspended.
.EXAMPLE
    .\Invoke-SecureBootUpdateEN.ps1 -Info
    Shows a full system analysis (certificates, BitLocker, readiness).
.EXAMPLE
    .\Invoke-SecureBootUpdateEN.ps1 -ApplyUpdate
    Checks and applies missing certificate updates.
.EXAMPLE
    .\Invoke-SecureBootUpdateEN.ps1 -Check
    Quick verification: checks whether the 2023 certificates are present after the update.
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

#region Load modules
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
    throw 'Module files not found. Expected a "Modules" folder next to the script, one level above it, or in the repository root.'
}
Import-Module (Join-Path $modulePath 'ConsoleUI\ConsoleUI.psm1') -Force
Import-Module (Join-Path $modulePath 'UefiSecureBoot\UefiSecureBoot.psm1') -Force
Import-Module (Join-Path $modulePath 'BitLockerHelper\BitLockerHelper.psm1') -Force
#endregion

#region Administrator check
if (-not (Test-AdminPrivileges)) {
    Write-ActionMessage -Message 'This script requires administrator privileges. Please run as administrator.' -Type Error
    exit 1
}
#endregion

#region Parameter validation
if (-not ($Info -or $ApplyUpdate -or $Check)) {
    Write-Host ''
    Write-Host '  Error: No mode specified.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  Usage:' -ForegroundColor Yellow
    Write-Host '    -Info         Show full system analysis' -ForegroundColor Yellow
    Write-Host '    -ApplyUpdate  Apply missing certificate updates' -ForegroundColor Yellow
    Write-Host '    -Check        Quick verification after the update' -ForegroundColor Yellow
    exit 1
}
if (($Info.IsPresent -as [int]) + ($ApplyUpdate.IsPresent -as [int]) + ($Check.IsPresent -as [int]) -gt 1) {
    Write-Host ''
    Write-Host '  Error: Specify only one mode at a time (-Info, -ApplyUpdate or -Check).' -ForegroundColor Red
    exit 1
}
#endregion

#region Logging
$modeName = if ($Info) { 'Info' } elseif ($ApplyUpdate) { 'ApplyUpdate' } else { 'Check' }
$boardInfo = Get-BoardInfo
$logName   = ($boardInfo.Modell + '_' + $boardInfo.BiosVersion) -replace '[\\/:*?"<>|]', '_'
$logPath   = Join-Path $PSScriptRoot ("{0}-{1}.log" -f $logName, $modeName)
Start-Transcript -Path $logPath -Force | Out-Null
#endregion

try {

#region Quick verification (-Check)
if ($Check) {
    Write-SectionHeader -Title 'Quick Verification: 2023 Certificates'
    $certCheck = Get-SecureBootCertificateStatus
    $only2023  = $certCheck | Where-Object { $_.Is2023 }
    foreach ($c in $only2023) {
        $label = '{0} ({1})' -f $c.Name, $c.Store
        Write-StatusLine -Label $label -Status $c.Found
    }
    $stillMissing = $only2023 | Where-Object { -not $_.Found }
    if (($stillMissing | Measure-Object).Count -eq 0) {
        Write-ActionMessage -Message 'All 2023 certificates are present. Update was successful.' -Type Success
    }
    else {
        Write-ActionMessage -Message 'Some 2023 certificates are still missing. A reboot may be required.' -Type Warning
        foreach ($m in $stillMissing) {
            Write-ActionMessage -Message "Missing: $($m.Name) ($($m.Store))" -Type Warning
        }
    }
    exit 0
}
#endregion

#region System info header
Write-SectionHeader -Title 'Secure Boot Certificate Check'
Write-InfoLine -Label 'Computer' -Value $env:COMPUTERNAME
Write-InfoLine -Label 'User' -Value "$env:USERDOMAIN\$env:USERNAME"
Write-InfoLine -Label 'Date' -Value (Get-Date -Format 'MM/dd/yyyy HH:mm:ss')
Write-InfoLine -Label 'Windows Version' -Value ([System.Environment]::OSVersion.VersionString)
Write-InfoLine -Label 'Mainboard Manufacturer' -Value $boardInfo.Hersteller
Write-InfoLine -Label 'Mainboard Model' -Value $boardInfo.Modell
Write-InfoLine -Label 'BIOS Version' -Value $boardInfo.BiosVersion
Write-InfoLine -Label 'BIOS Date' -Value $boardInfo.BiosDatum
Write-InfoLine -Label 'Log File' -Value $logPath
#endregion

#region Secure Boot status
Write-SectionHeader -Title 'Secure Boot Basic Status'

$platformStatus = Get-SecureBootPlatformStatus
Write-InfoLine -Label 'Firmware Mode' -Value $platformStatus.FirmwareType
Write-InfoLine -Label 'Secure Boot source' -Value $platformStatus.DetectionSource
Write-StatusLine -Label 'Secure Boot enabled' -Status $platformStatus.IsEnabled

if (-not $platformStatus.IsSupported) {
    Write-ActionMessage -Message 'System is not running in UEFI mode. Secure Boot certificates cannot be managed on BIOS/Legacy systems.' -Type Error
    Write-ActionMessage -Message 'Please boot the system in UEFI mode. This package is not applicable to BIOS/Legacy installations.' -Type Warning
    exit 1
}

if (-not $platformStatus.IsEnabled) {
    Write-ActionMessage -Message 'Secure Boot is available in UEFI but currently disabled.' -Type Error
    Write-ActionMessage -Message 'Please enable Secure Boot in UEFI/BIOS and run the script again.' -Type Warning
    exit 1
}
#endregion

#region Check certificates
Write-SectionHeader -Title 'Certificates in UEFI Databases'

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

#region Certificate origin: BIOS/OEM vs. Windows/OS
Write-SectionHeader -Title 'Certificate Origin: BIOS/OEM vs. Windows/OS'

$dbSources    = Get-SecureBootDatabaseSources
$biosCerts    = @($dbSources | Where-Object { $_.Herkunft -eq 'BIOS/OEM' })
$osCerts      = @($dbSources | Where-Object { $_.Herkunft -eq 'Windows/OS' })
$unknownCerts = @($dbSources | Where-Object { $_.Herkunft -eq 'Unbekannt' })

if ($dbSources.Count -eq 0) {
    Write-ActionMessage -Message 'No certificate data available (no Secure Boot or no admin access).' -Type Warning
}
else {
    # --- BIOS/OEM ---
    Write-Host ''
    Write-Host "  Provisioned in BIOS/UEFI by manufacturer  ($($biosCerts.Count) entries):" -ForegroundColor Cyan

    if ($biosCerts.Count -gt 0) {
        foreach ($cert in $biosCerts) {
            $display = '[{0}]  {1}' -f $cert.Datenbank, $cert.Name
            Write-Host ('  {0,-52} valid until {1}' -f $display, $cert.GueltigBis) -ForegroundColor Cyan
        }
    }
    else {
        Write-Host '    (none or dbDefault not available)' -ForegroundColor DarkGray
    }

    # --- Windows / OS ---
    Write-Host ''
    Write-Host "  Added by Windows / Operating System  ($($osCerts.Count) entries):" -ForegroundColor Yellow

    if ($osCerts.Count -gt 0) {
        foreach ($cert in $osCerts) {
            $display = '[{0}]  {1}' -f $cert.Datenbank, $cert.Name
            Write-Host ('  {0,-52} valid until {1}' -f $display, $cert.GueltigBis) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '    (none)' -ForegroundColor DarkGray
    }

    # --- Origin unknown (no dbDefault available) ---
    if ($unknownCerts.Count -gt 0) {
        Write-Host ''
        Write-Host "  Origin unknown (dbDefault not readable)  ($($unknownCerts.Count) entries):" -ForegroundColor Gray

        foreach ($cert in $unknownCerts) {
            $display = '[{0}]  {1}' -f $cert.Datenbank, $cert.Name
            Write-Host ('  {0,-52} valid until {1}' -f $display, $cert.GueltigBis) -ForegroundColor Gray
        }
    }

    Write-Host ''
    Write-ActionMessage -Message (
        'Total: {0} entries ({1} BIOS/OEM  |  {2} Windows/OS  |  {3} Unknown)' -f
        $dbSources.Count, $biosCerts.Count, $osCerts.Count, $unknownCerts.Count
    ) -Type Info
}
#endregion

#region BitLocker status
Write-SectionHeader -Title 'BitLocker Status'

$bitlockerVolumes = Get-BitLockerProtectionStatus
$systemDriveBL = $bitlockerVolumes | Where-Object { $_.IsSystemDrive }
$bitlockerActive = $false

if ($systemDriveBL) {
    Write-StatusLine -Label "BitLocker Protection ($($systemDriveBL.MountPoint))" -Status $true -DisplayValue $systemDriveBL.ProtectionStatus
    Write-InfoLine -Label 'Volume Status' -Value $systemDriveBL.VolumeStatus
    $bitlockerActive = $systemDriveBL.IsProtected
}
else {
    Write-ActionMessage -Message 'BitLocker is not configured on the system drive.' -Type Info
}

foreach ($vol in ($bitlockerVolumes | Where-Object { -not $_.IsSystemDrive })) {
    Write-InfoLine -Label "BitLocker ($($vol.MountPoint))" -Value $vol.ProtectionStatus
}
#endregion

#region Summary
Write-SummaryTable -Results $summaryResults
#endregion

#region Action: Apply update
if ($Info) {
    Write-ActionMessage -Message 'Analysis mode (-Info). Run with -ApplyUpdate to apply changes.' -Type Info
    exit 0
}

if (-not $has2023Issues) {
    Write-ActionMessage -Message 'All 2023 certificates are present. No update required.' -Type Success
    exit 0
}

Write-SectionHeader -Title 'Certificate Update Actions'

if ($has2023Issues) {
    Write-ActionMessage -Message 'Missing 2023 certificates detected. Preparing update...' -Type Warning

    foreach ($cert in $missing2023) {
        Write-ActionMessage -Message "Missing: $($cert.Name) ($($cert.Store))" -Type Warning
    }
}

#region Local Secure Boot configuration
Write-SectionHeader -Title 'Local Secure Boot Configuration'

$sbRegPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'

# 1. Set registry value for certificate provisioning
#    Registry value: AvailableUpdatesPolicy = 22852 (0x5944)
try {
    $cur1 = (Get-ItemProperty -Path $sbRegPath -Name 'AvailableUpdatesPolicy' -ErrorAction SilentlyContinue).AvailableUpdatesPolicy
    if ($cur1 -ne 22852) {
        Set-ItemProperty -Path $sbRegPath -Name 'AvailableUpdatesPolicy' -Value 22852 -Type DWord -Force -ErrorAction Stop
        Write-ActionMessage -Message "Registry value 'AvailableUpdatesPolicy': Set to 22852." -Type Success
    }
    else {
        Write-ActionMessage -Message "Registry value 'AvailableUpdatesPolicy': Already set." -Type Info
    }
}
catch {
    Write-ActionMessage -Message "Registry value 'AvailableUpdatesPolicy': Error setting value – $_" -Type Error
}

# 2. Set registry value for provisioning via updates
#    Registry value: HighConfidenceOptOut = 1
try {
    $cur2 = (Get-ItemProperty -Path $sbRegPath -Name 'HighConfidenceOptOut' -ErrorAction SilentlyContinue).HighConfidenceOptOut
    if ($cur2 -ne 1) {
        Set-ItemProperty -Path $sbRegPath -Name 'HighConfidenceOptOut' -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-ActionMessage -Message "Registry value 'HighConfidenceOptOut': Set to 1." -Type Success
    }
    else {
        Write-ActionMessage -Message "Registry value 'HighConfidenceOptOut': Already set." -Type Info
    }
}
catch {
    Write-ActionMessage -Message "Registry value 'HighConfidenceOptOut': Error setting value – $_" -Type Error
}
#endregion

# Suspend BitLocker if active
if ($bitlockerActive) {
    Write-ActionMessage -Message 'BitLocker is active. Suspending protection for 2 reboots...' -Type Warning

    $suspendResult = Suspend-BitLockerForUpdate -MountPoint $systemDriveBL.MountPoint -RebootCount 2
    if ($suspendResult.Suspended) {
        Write-ActionMessage -Message 'BitLocker protection successfully suspended.' -Type Success
    }
    else {
        Write-ActionMessage -Message "BitLocker could not be suspended: $($suspendResult.Reason)" -Type Error
        Write-ActionMessage -Message 'Update aborted to avoid BitLocker recovery.' -Type Error
        exit 1
    }
}

# Trigger Secure Boot update
Write-ActionMessage -Message 'Setting registry value AvailableUpdates = 0x100...' -Type Info
$updateResult = Start-SecureBootCertificateUpdate

if ($updateResult.UpdateTriggered) {
    Write-ActionMessage -Message 'Secure Boot update task successfully started.' -Type Success
    Write-ActionMessage -Message 'A restart is required to install the certificates.' -Type Warning
    Write-ActionMessage -Message 'After reboot, run the script again to verify the status.' -Type Info

    Write-Host ''
    $reboot = Read-Host '  Restart now? (Y/N)'
    if ($reboot -eq 'Y') {
        Restart-Computer -Force
    }
    else {
        Write-ActionMessage -Message 'Restart postponed. Please restart manually.' -Type Warning
    }
}
else {
    Write-ActionMessage -Message "Update could not be started: $($updateResult.Reason)" -Type Error
    exit 1
}
#endregion

} # end try
finally {
    Stop-Transcript | Out-Null

    # Remove transcript meta blocks (header + footer) from the log file.
    # Both blocks are delimited by lines of '*' characters.
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

        # Remove leading blank lines
        $start = 0
        while ($start -lt $cleaned.Count -and [string]::IsNullOrWhiteSpace($cleaned[$start])) { $start++ }

        Set-Content -Path $logPath -Value $cleaned[$start..($cleaned.Count - 1)] -Encoding UTF8
    }
}
