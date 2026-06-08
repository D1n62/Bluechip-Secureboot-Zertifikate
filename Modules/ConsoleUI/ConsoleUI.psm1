function Write-SectionHeader {
    <#
    .SYNOPSIS
        Gibt eine formatierte Abschnittsüberschrift auf der Konsole aus.
    .DESCRIPTION
        Erzeugt eine visuell abgesetzte Überschrift mit Rahmen für strukturierte Konsolenausgaben.
    .PARAMETER Title
        Der anzuzeigende Titel.
    .EXAMPLE
        Write-SectionHeader -Title 'Secure Boot Status'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    $line = '=' * 60
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Write-StatusLine {
    <#
    .SYNOPSIS
        Gibt eine farbige Statuszeile (OK/FEHLER) auf der Konsole aus.
    .DESCRIPTION
        Zeigt einen Prüfpunkt mit farbigem Status an. Grün bei Erfolg, Rot bei Fehler.
    .PARAMETER Label
        Beschreibung des Prüfpunkts.
    .PARAMETER Status
        Boolean-Wert: $true = OK, $false = FEHLER.
    .PARAMETER DisplayValue
        Optionaler Anzeigewert statt OK/FEHLER.
    .EXAMPLE
        Write-StatusLine -Label 'Windows UEFI CA 2023' -Status $true
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [bool]$Status,

        [Parameter()]
        [string]$DisplayValue
    )

    $color = if ($Status) { 'Green' } else { 'Red' }
    $icon = if ($Status) { '[OK]' } else { '[FEHLER]' }
    $value = if ($DisplayValue) { $DisplayValue } else { $icon }

    Write-Host ("  {0,-45} : {1}" -f $Label, $value) -ForegroundColor $color
}

function Write-InfoLine {
    <#
    .SYNOPSIS
        Gibt eine neutrale Informationszeile auf der Konsole aus.
    .PARAMETER Label
        Beschreibung.
    .PARAMETER Value
        Anzeigewert.
    .EXAMPLE
        Write-InfoLine -Label 'Hostname' -Value $env:COMPUTERNAME
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$Value
    )

    Write-Host ("  {0,-45} : {1}" -f $Label, $Value) -ForegroundColor White
}

function Write-ActionMessage {
    <#
    .SYNOPSIS
        Gibt eine Aktionsmeldung auf der Konsole aus.
    .PARAMETER Message
        Die Meldung.
    .PARAMETER Type
        Typ: Info, Warning, Success, Error.
    .EXAMPLE
        Write-ActionMessage -Message 'BitLocker wird pausiert...' -Type Warning
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Success', 'Error')]
        [string]$Type = 'Info'
    )

    $colorMap = @{
        Info    = 'White'
        Warning = 'Yellow'
        Success = 'Green'
        Error   = 'Red'
    }
    $iconMap = @{
        Info    = '[i]'
        Warning = '[!]'
        Success = '[+]'
        Error   = '[X]'
    }

    Write-Host "  $($iconMap[$Type]) $Message" -ForegroundColor $colorMap[$Type]
}

function Write-SummaryTable {
    <#
    .SYNOPSIS
        Gibt eine Zusammenfassung aller Prüfpunkte als Tabelle aus.
    .PARAMETER Results
        Array von Hashtables mit Name und Status.
    .EXAMPLE
        Write-SummaryTable -Results @(@{Name='Test';Status=$true})
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable[]]$Results
    )

    Write-SectionHeader -Title 'Zusammenfassung'

    $passed = ($Results | Where-Object { $_.Status -eq $true }).Count
    $failed = ($Results | Where-Object { $_.Status -eq $false }).Count

    foreach ($result in $Results) {
        Write-StatusLine -Label $result.Name -Status $result.Status
    }

    Write-Host ''
    Write-Host ("  Bestanden: {0}  |  Fehlgeschlagen: {1}  |  Gesamt: {2}" -f $passed, $failed, $Results.Count) -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host ''
}

Export-ModuleMember -Function Write-SectionHeader, Write-StatusLine, Write-InfoLine, Write-ActionMessage, Write-SummaryTable
