function Get-BitLockerProtectionStatus {
    <#
    .SYNOPSIS
        Prüft den BitLocker-Schutzstatus aller Laufwerke.
    .DESCRIPTION
        Gibt für jedes Laufwerk den Verschlüsselungs- und Schutzstatus zurück.
        Fokus liegt auf dem Systemlaufwerk (typisch C:).
    .OUTPUTS
        [PSCustomObject[]] Array mit MountPoint, ProtectionStatus, VolumeStatus.
    .EXAMPLE
        Get-BitLockerProtectionStatus
    #>
    [CmdletBinding()]
    param()

    try {
        $volumes = Get-BitLockerVolume -ErrorAction Stop

        $results = foreach ($vol in $volumes) {
            [PSCustomObject]@{
                MountPoint       = $vol.MountPoint
                ProtectionStatus = $vol.ProtectionStatus.ToString()
                VolumeStatus     = $vol.VolumeStatus.ToString()
                IsProtected      = ($vol.ProtectionStatus -eq 'On')
                IsSystemDrive    = ($vol.MountPoint -eq "$env:SystemDrive\")
            }
        }

        return $results
    }
    catch {
        Write-Warning "BitLocker-Status konnte nicht ermittelt werden: $_"
        return @()
    }
}

function Suspend-BitLockerForUpdate {
    <#
    .SYNOPSIS
        Pausiert den BitLocker-Schutz auf dem Systemlaufwerk für Secure Boot Updates.
    .DESCRIPTION
        Setzt den BitLocker-Schutz für eine definierte Anzahl Neustarts aus.
        Standard: 2 Neustarts (empfohlen für Secure Boot Zertifikats-Updates).
        Bei RebootCount 0 wird der Schutz bis zum manuellen Fortsetzen pausiert.
    .PARAMETER MountPoint
        Laufwerksbuchstabe (Standard: Systemlaufwerk).
    .PARAMETER RebootCount
        Anzahl erlaubter Neustarts ohne BitLocker-Schutz (Standard: 2).
    .OUTPUTS
        [PSCustomObject] mit Erfolgsstatus.
    .EXAMPLE
        Suspend-BitLockerForUpdate
    .EXAMPLE
        Suspend-BitLockerForUpdate -MountPoint 'D:' -RebootCount 3
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter()]
        [string]$MountPoint = "$env:SystemDrive",

        [Parameter()]
        [ValidateRange(0, 15)]
        [int]$RebootCount = 2
    )

    if (-not $PSCmdlet.ShouldProcess($MountPoint, "BitLocker-Schutz fuer $RebootCount Neustart(s) pausieren")) {
        return [PSCustomObject]@{ Suspended = $false; MountPoint = $MountPoint; Reason = 'Abgebrochen' }
    }

    try {
        Suspend-BitLocker -MountPoint $MountPoint -RebootCount $RebootCount -ErrorAction Stop

        return [PSCustomObject]@{
            Suspended   = $true
            MountPoint  = $MountPoint
            RebootCount = $RebootCount
            Reason      = 'Erfolgreich pausiert'
        }
    }
    catch {
        Write-Warning "BitLocker konnte nicht pausiert werden: $_"
        return [PSCustomObject]@{ Suspended = $false; MountPoint = $MountPoint; Reason = $_.Exception.Message }
    }
}

function Resume-BitLockerAfterUpdate {
    <#
    .SYNOPSIS
        Setzt den BitLocker-Schutz auf dem angegebenen Laufwerk fort.
    .PARAMETER MountPoint
        Laufwerksbuchstabe (Standard: Systemlaufwerk).
    .OUTPUTS
        [PSCustomObject] mit Erfolgsstatus.
    .EXAMPLE
        Resume-BitLockerAfterUpdate
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter()]
        [string]$MountPoint = "$env:SystemDrive"
    )

    if (-not $PSCmdlet.ShouldProcess($MountPoint, 'BitLocker-Schutz fortsetzen')) {
        return [PSCustomObject]@{ Resumed = $false; MountPoint = $MountPoint }
    }

    try {
        Resume-BitLocker -MountPoint $MountPoint -ErrorAction Stop
        return [PSCustomObject]@{ Resumed = $true; MountPoint = $MountPoint }
    }
    catch {
        Write-Warning "BitLocker konnte nicht fortgesetzt werden: $_"
        return [PSCustomObject]@{ Resumed = $false; MountPoint = $MountPoint }
    }
}

Export-ModuleMember -Function Get-BitLockerProtectionStatus, Suspend-BitLockerForUpdate, Resume-BitLockerAfterUpdate
