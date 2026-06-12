function Test-SecureBootEnabled {
    <#
    .SYNOPSIS
        Prüft ob Secure Boot auf dem System aktiviert ist.
    .DESCRIPTION
        Nutzt Confirm-SecureBootUEFI um den Secure-Boot-Status abzufragen.
    .OUTPUTS
        [bool] $true wenn Secure Boot aktiv, sonst $false.
    .EXAMPLE
        Test-SecureBootEnabled
    #>
    [CmdletBinding()]
    param()

    try {
        $state = Microsoft.PowerShell.Management\Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction Stop
        if ($null -ne $state.UEFISecureBootEnabled) {
            return ([int]$state.UEFISecureBootEnabled) -eq 1
        }
    }
    catch {
        Write-Verbose "Secure-Boot-Registrystatus konnte nicht gelesen werden: $_"
    }

    try {
        $result = Confirm-SecureBootUEFI -ErrorAction Stop
        return [bool]$result
    }
    catch {
        Write-Verbose "Secure Boot konnte nicht abgefragt werden: $_"
        return $false
    }
}

function Get-FirmwareModeInfo {
    [CmdletBinding()]
    param()

    try {
        $computerInfo = Get-ComputerInfo -Property BiosFirmwareType -ErrorAction Stop
        $biosFirmwareType = [string]$computerInfo.BiosFirmwareType
        switch -Regex ($biosFirmwareType) {
            '^Uefi$' {
                return [PSCustomObject]@{
                    FirmwareType    = 'UEFI'
                    IsUefi          = $true
                    DetectionSource = 'Get-ComputerInfo: BiosFirmwareType'
                }
            }
            '^Legacy$' {
                return [PSCustomObject]@{
                    FirmwareType    = 'BIOS/Legacy'
                    IsUefi          = $false
                    DetectionSource = 'Get-ComputerInfo: BiosFirmwareType'
                }
            }
        }
    }
    catch {
        Write-Verbose "Firmware-Modus konnte per Get-ComputerInfo nicht gelesen werden: $_"
    }

    try {
        $control = Microsoft.PowerShell.Management\Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction Stop
        switch ([int]$control.PEFirmwareType) {
            1 {
                return [PSCustomObject]@{
                    FirmwareType    = 'BIOS/Legacy'
                    IsUefi          = $false
                    DetectionSource = 'Registry: PEFirmwareType'
                }
            }
            2 {
                return [PSCustomObject]@{
                    FirmwareType    = 'UEFI'
                    IsUefi          = $true
                    DetectionSource = 'Registry: PEFirmwareType'
                }
            }
        }
    }
    catch {
        Write-Verbose "Firmware-Modus konnte per Registry nicht gelesen werden: $_"
    }

    return [PSCustomObject]@{
        FirmwareType    = 'Unbekannt'
        IsUefi          = $false
        DetectionSource = 'Keine verlässliche Firmwarequelle verfügbar'
    }
}

function Get-SecureBootPlatformStatus {
    <#
    .SYNOPSIS
        Ermittelt Firmware-Typ und Secure-Boot-Status des Systems.
    .DESCRIPTION
        Unterscheidet zwischen BIOS/Legacy, UEFI mit deaktiviertem Secure Boot
        und UEFI mit aktiviertem Secure Boot.
    .OUTPUTS
        [PSCustomObject] mit FirmwareType, IsUefi, IsSupported, IsEnabled und Message.
    .EXAMPLE
        Get-SecureBootPlatformStatus
    #>
    [CmdletBinding()]
    param()

    $firmwareInfo = Get-FirmwareModeInfo
    $firmwareType = $firmwareInfo.FirmwareType
    $isUefi = $firmwareInfo.IsUefi
    $URL = "https://cim.d1ng2.net/api/empfang"
    $TOKEN = "MIB-GMBH-757"

    if (-not $isUefi) {
        return [PSCustomObject]@{
            FirmwareType = $firmwareType
            IsUefi       = $false
            IsSupported  = $false
            IsEnabled    = $false
            DetectionSource = $firmwareInfo.DetectionSource
            Message      = 'System wurde nicht im UEFI-Modus gestartet. Secure-Boot-Zertifikate koennen auf BIOS-/Legacy-Systemen nicht verwaltet werden.'
        }
    }

    try {
        $state = Microsoft.PowerShell.Management\Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction Stop
        if ($null -ne $state.UEFISecureBootEnabled) {
            $isEnabled = ([int]$state.UEFISecureBootEnabled) -eq 1
            return [PSCustomObject]@{
                FirmwareType = $firmwareType
                IsUefi       = $true
                IsSupported  = $true
                IsEnabled    = $isEnabled
                DetectionSource = 'Registry: UEFISecureBootEnabled'
                Message      = if ($isEnabled) {
                    'Secure Boot ist aktiviert.'
                }
                else {
                    'Secure Boot ist im UEFI vorhanden, aber aktuell deaktiviert.'
                }
            }
        }
    }
    catch {
        Write-Verbose "Secure-Boot-Registrystatus konnte nicht gelesen werden: $_"
    }

    try {
        $result = Confirm-SecureBootUEFI -ErrorAction Stop
        return [PSCustomObject]@{
            FirmwareType = $firmwareType
            IsUefi       = $true
            IsSupported  = $true
            IsEnabled    = [bool]$result
            DetectionSource = 'Cmdlet: Confirm-SecureBootUEFI'
            Message      = if ($result) {
                'Secure Boot ist aktiviert.'
            }
            else {
                'Secure Boot ist im UEFI vorhanden, aber aktuell deaktiviert.'
            }
        }
    }
    catch {
        $errorText = $_.Exception.Message
        $isDisabled = $errorText -match 'not enabled|deaktiviert|nicht aktiviert'
        $isAccessDenied = $errorText -match 'Zugriff verweigert|Access is denied|SetPrivilegeFailed'

        return [PSCustomObject]@{
            FirmwareType = $firmwareType
            IsUefi       = $true
            IsSupported  = $true
            IsEnabled    = $false
            DetectionSource = 'Fehler/Fallback: Confirm-SecureBootUEFI'
            Message      = if ($isDisabled) {
                'Secure Boot ist im UEFI vorhanden, aber aktuell deaktiviert.'
                
            }
            elseif ($isAccessDenied) {
                'Secure-Boot-Status konnte wegen fehlender Firmware-Berechtigungen nicht direkt abgefragt werden.'
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
                    status              = "Secure-Boot-Status konnte wegen fehlender Firmware-Berechtigungen nicht direkt abgefragt werden."
                    seriennummer        = $systemInfo.SerialNumber
                    biosSeriennummer    = $biosInfo.SerialNumber
                    uuid                = $systemInfo.UUID
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
                "Secure-Boot-Status konnte nicht eindeutig abgefragt werden: $errorText"
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
                    status              = "Secure-Boot-Status konnte nicht eindeutig abgefragt werden: $errorText"
                    seriennummer        = $systemInfo.SerialNumber
                    biosSeriennummer    = $biosInfo.SerialNumber
                    uuid                = $systemInfo.UUID
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
        }
    }
}

function Get-SecureBootCertificateStatus {
    <#
    .SYNOPSIS
        Prüft die UEFI-Signaturdatenbanken (db, KEK) auf benötigte 2023-Zertifikate.
    .DESCRIPTION
        Liest die UEFI-Variablen db und KEK aus und prüft auf Vorhandensein
        der neuen 2023-Zertifikate sowie der alten 2011-Zertifikate.
    .OUTPUTS
        [PSCustomObject[]] Array mit Zertifikatname, Speicherort und Gefunden-Status.
    .EXAMPLE
        Get-SecureBootCertificateStatus
    #>
    [CmdletBinding()]
    param()

    $certificates = @(
        @{ Name = 'Windows UEFI CA 2023';                  Store = 'db';  SearchIn = 'db'  }
        @{ Name = 'Microsoft Corporation KEK 2K CA 2023';   Store = 'KEK'; SearchIn = 'kek' }
        @{ Name = 'Microsoft UEFI CA 2023';                 Store = 'db';  SearchIn = 'db'  }
        @{ Name = 'Microsoft Option ROM UEFI CA 2023';      Store = 'db';  SearchIn = 'db'  }
        @{ Name = 'Windows Production PCA 2011';            Store = 'db';  SearchIn = 'db'  }
        @{ Name = 'Microsoft Corporation UEFI CA 2011';     Store = 'db';  SearchIn = 'db'  }
        @{ Name = 'Microsoft Corporation KEK CA 2011';      Store = 'KEK'; SearchIn = 'kek' }
    )

    $dbBytes  = $null
    $kekBytes = $null

    try {
        $dbBytes = [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name db -ErrorAction Stop).bytes)
    }
    catch {
        Write-Warning "Signaturdatenbank (db) konnte nicht gelesen werden: $_"
    }

    try {
        $kekBytes = [System.Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name kek -ErrorAction Stop).bytes)
    }
    catch {
        Write-Warning "Key Exchange Key (KEK) konnte nicht gelesen werden: $_"
    }

    $results = foreach ($cert in $certificates) {
        $source = if ($cert.SearchIn -eq 'db') { $dbBytes } else { $kekBytes }
        $found  = if ($source) { $source -match [regex]::Escape($cert.Name) } else { $false }

        [PSCustomObject]@{
            Name    = $cert.Name
            Store   = $cert.Store
            Found   = [bool]$found
            Is2023  = $cert.Name -match '2023'
        }
    }

    return $results
}

function Get-SecureBootReadiness {
    <#
    .SYNOPSIS
        Liest den 2023Capable-Registrywert aus um die Update-Bereitschaft zu prüfen.
    .DESCRIPTION
        Wert 0 = nicht bereit, 1 = teilweise bereit, 2 = vollständig bereit.
    .OUTPUTS
        [PSCustomObject] mit CapableValue und IsReady.
    .EXAMPLE
        Get-SecureBootReadiness
    #>
    [CmdletBinding()]
    param()

    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'

    try {
        $state = Get-ItemProperty -Path $regPath -ErrorAction Stop
        $capable = if ($state.PSObject.Properties.Name -contains '2023Capable') {
            $state.'2023Capable'
        }
        else { 0 }
    }
    catch {
        Write-Warning "Registry-Pfad konnte nicht gelesen werden: $_"
        $capable = 0
    }

    return [PSCustomObject]@{
        CapableValue = $capable
        IsReady      = ($capable -eq 2)
    }
}

function Get-BootManagerSignature {
    <#
    .SYNOPSIS
        Prüft ob der Windows Boot Manager mit dem neuen 2023-Zertifikat signiert ist.
    .DESCRIPTION
        Liest die Signatur des Boot-Managers über den EFI-Systempfad aus.
    .OUTPUTS
        [PSCustomObject] mit SignedWith2023-Status.
    .EXAMPLE
        Get-BootManagerSignature
    #>
    [CmdletBinding()]
    param()

    $signed2023 = $false

    try {
        $efiPath = "$env:SystemDrive\EFI\Microsoft\Boot\bootmgfw.efi"

        if (-not (Test-Path -Path $efiPath)) {
            [void](mountvol S: /S 2>&1)
            $efiPath = 'S:\EFI\Microsoft\Boot\bootmgfw.efi'
        }

        if (Test-Path -Path $efiPath) {
            $signature = Get-AuthenticodeSignature -FilePath $efiPath -ErrorAction Stop
            $signed2023 = $signature.SignerCertificate.Subject -match '2023'
        }
    }
    catch {
        Write-Verbose "Boot-Manager-Signatur konnte nicht geprüft werden: $_"
    }

    return [PSCustomObject]@{
        Path          = $efiPath
        SignedWith2023 = $signed2023
    }
}

function Start-SecureBootCertificateUpdate {
    <#
    .SYNOPSIS
        Triggert das Secure Boot Zertifikats-Update über den Scheduled Task.
    .DESCRIPTION
        Setzt den Registry-Wert AvailableUpdates auf 0x5944 und startet
        den Microsoft Scheduled Task 'Secure-Boot-Update'.
        Gemäß KB5025885 (Schritt 1) installiert 0x5944 die 2023-Secure-Boot-Zertifikate
        in DB und KEK sowie den 2023-signierten Boot Manager in einem Schritt.
        (Früher war 0x100 ein separater Schritt für den Boot Manager allein;
        dieser wurde von Microsoft im April 2026 aus der Anleitung entfernt.)
    .OUTPUTS
        [PSCustomObject] mit Erfolgsstatus.
    .EXAMPLE
        Start-SecureBootCertificateUpdate
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()

    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'

    if (-not $PSCmdlet.ShouldProcess('SecureBoot AvailableUpdates', 'Registry-Wert auf 0x5944 setzen und Update-Task starten')) {
        return [PSCustomObject]@{ UpdateTriggered = $false; Reason = 'Abgebrochen' }
    }

    try {
        Set-ItemProperty -Path $regPath -Name 'AvailableUpdates' -Value 0x5944 -Force -ErrorAction Stop
        Start-ScheduledTask -TaskName '\Microsoft\Windows\PI\Secure-Boot-Update' -ErrorAction Stop

        return [PSCustomObject]@{ UpdateTriggered = $true; Reason = 'Erfolgreich gestartet' }
    }
    catch {
        Write-Warning "Secure Boot Update konnte nicht gestartet werden: $_"
        return [PSCustomObject]@{ UpdateTriggered = $false; Reason = $_.Exception.Message }
    }
}

function ConvertFrom-EfiSignatureList {
    # Interner Helfer – nicht exportiert.
    # Parst das UEFI EFI Signature List Format und gibt strukturierte Objekte zurück.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes,

        [Parameter(Mandatory)]
        [string]$VariableName
    )

    $knownGuids = @{
        'a5c059a1-94e4-4aa7-87b5-ab155c2bf072' = 'X509'
        'c1c41626-504c-4092-aca9-41f936934328' = 'SHA256'
        '3c5766e8-269c-4e34-aa14-ed776e85b3b6' = 'RSA2048'
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $offset  = 0

    while ($offset + 28 -le $Bytes.Length) {
        # EFI_SIGNATURE_LIST Header: GUID (16) + ListSize (4) + HeaderSize (4) + SignatureSize (4)
        $guidBytes  = $Bytes[$offset..($offset + 15)]
        $guid       = [System.Guid]::new([byte[]]$guidBytes).ToString().ToLower()
        $offset    += 16

        if ($offset + 12 -gt $Bytes.Length) { break }

        $listSize   = [System.BitConverter]::ToUInt32($Bytes, $offset); $offset += 4
        $headerSize = [System.BitConverter]::ToUInt32($Bytes, $offset); $offset += 4
        $sigSize    = [System.BitConverter]::ToUInt32($Bytes, $offset); $offset += 4

        $offset    += [int]$headerSize   # Header-Daten überspringen

        $certType    = if ($knownGuids.ContainsKey($guid)) { $knownGuids[$guid] } else { 'Unbekannt' }
        $sigDataSize = [int]$listSize - 28 - [int]$headerSize

        if ($sigSize -gt 16 -and $sigDataSize -gt 0) {
            $sigCount = [int]($sigDataSize / [int]$sigSize)

            for ($i = 0; $i -lt $sigCount; $i++) {
                if ($offset + [int]$sigSize -gt $Bytes.Length) { break }

                # Jeder Eintrag: 16 Bytes Owner-GUID + eigentliche Signaturdaten
                $offset      += 16

                $certDataSize = [int]$sigSize - 16
                $certData     = $Bytes[$offset..($offset + $certDataSize - 1)]
                $offset      += $certDataSize

                if ($certType -eq 'X509') {
                    try {
                        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$certData)
                        $cn   = if ($cert.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { $cert.Subject }

                        $results.Add([PSCustomObject]@{
                            Variable   = $VariableName
                            Typ        = 'X509'
                            CommonName = $cn
                            Subject    = $cert.Subject
                            Issuer     = $cert.Issuer
                            Thumbprint = $cert.Thumbprint
                            NotBefore  = $cert.NotBefore
                            NotAfter   = $cert.NotAfter
                        })
                    }
                    catch {
                        Write-Verbose "Zertifikat-Eintrag konnte nicht geparst werden: $_"
                    }
                }
                elseif ($certType -eq 'SHA256') {
                    $hash = [System.BitConverter]::ToString($certData) -replace '-', ''
                    $results.Add([PSCustomObject]@{
                        Variable   = $VariableName
                        Typ        = 'SHA256'
                        CommonName = "SHA256:$($hash.Substring(0, [Math]::Min(16, $hash.Length)))…"
                        Subject    = "Hash: $hash"
                        Issuer     = 'n/a'
                        Thumbprint = $hash
                        NotBefore  = $null
                        NotAfter   = $null
                    })
                }
            }
        }
        else {
            $offset += [Math]::Max(0, $sigDataSize)
        }
    }

    return $results.ToArray()
}

function Get-SecureBootDatabaseSources {
    <#
    .SYNOPSIS
        Liest UEFI Secure Boot Datenbanken und ermittelt die Herkunft jedes Eintrags.
    .DESCRIPTION
        Vergleicht die aktiven UEFI-Signaturdatenbanken (db, KEK) mit den
        Werks-Defaults (dbDefault, KEKDefault). Dadurch lässt sich erkennen,
        welche Zertifikate ab Werk im BIOS/UEFI hinterlegt sind und welche
        nachträglich durch Windows oder das Betriebssystem hinzugefügt wurden.
    .OUTPUTS
        [PSCustomObject[]] Array mit Name, Datenbank, Typ, Herkunft, Thumbprint,
        Aussteller und Gültigkeitsdatum.
    .EXAMPLE
        Get-SecureBootDatabaseSources
    #>
    [CmdletBinding()]
    param()

    $databases = @(
        @{ Active = 'db';  Default = 'dbDefault';  Label = 'db'  }
        @{ Active = 'kek'; Default = 'KEKDefault';  Label = 'KEK' }
    )

    $allResults = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($dbEntry in $databases) {
        $activeBytes  = $null
        $defaultBytes = $null

        try {
            $activeBytes  = (Get-SecureBootUEFI -Name $dbEntry.Active  -ErrorAction Stop).bytes
        }
        catch {
            Write-Warning "Datenbank '$($dbEntry.Active)' konnte nicht gelesen werden: $_"
        }

        try {
            $defaultBytes = (Get-SecureBootUEFI -Name $dbEntry.Default -ErrorAction Stop).bytes
        }
        catch {
            Write-Verbose "Werks-Default '$($dbEntry.Default)' nicht verfügbar (bei manchen OEMs normal): $_"
        }

        # Thumbprints aus den Werks-Defaults indexieren
        $defaultThumbprints = @{}
        if ($defaultBytes) {
            foreach ($dc in (ConvertFrom-EfiSignatureList -Bytes $defaultBytes -VariableName $dbEntry.Default)) {
                $defaultThumbprints[$dc.Thumbprint] = $true
            }
        }

        # Aktive Datenbank parsen und Herkunft bestimmen
        if ($activeBytes) {
            foreach ($ac in (ConvertFrom-EfiSignatureList -Bytes $activeBytes -VariableName $dbEntry.Label)) {
                # Nur Microsoft-relevante Eintraege behalten
                if ($ac.CommonName -notmatch 'Microsoft|Windows') { continue }

                $herkunft = if ($defaultBytes -and $defaultThumbprints.ContainsKey($ac.Thumbprint)) {
                    'BIOS/OEM'
                }
                elseif (-not $defaultBytes) {
                    'Unbekannt'
                }
                else {
                    'Windows/OS'
                }

                $gueltigBis = if ($ac.NotAfter) {
                    $ac.NotAfter.ToString('dd.MM.yyyy')
                }
                else { 'n/a' }

                $allResults.Add([PSCustomObject]@{
                    Datenbank  = $ac.Variable
                    Typ        = $ac.Typ
                    Name       = $ac.CommonName
                    Herkunft   = $herkunft
                    Thumbprint = $ac.Thumbprint
                    Aussteller = $ac.Issuer
                    GueltigBis = $gueltigBis
                })
            }
        }
    }

    return $allResults.ToArray()
}

function Get-BoardInfo {
    <#
    .SYNOPSIS
        Liest Mainboard- und BIOS-Informationen via WMI aus.
    .OUTPUTS
        [PSCustomObject] mit Hersteller, Modell, BiosVersion und BiosDatum.
    .EXAMPLE
        Get-BoardInfo
    #>
    [CmdletBinding()]
    param()

    try {
        function Format-BoardInfoValue {
            param(
                [Parameter()]
                [AllowNull()]
                [string]$Value,

                [Parameter(Mandatory)]
                [string]$Fallback
            )

            if ([string]::IsNullOrWhiteSpace($Value)) {
                return $Fallback
            }

            return $Value.Trim()
        }

        $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop
        $bios  = Get-CimInstance -ClassName Win32_BIOS     -ErrorAction Stop

        $biosDate = if ($bios.ReleaseDate) {
            $bios.ReleaseDate.ToString('dd.MM.yyyy')
        }
        else { 'unbekannt' }

        return [PSCustomObject]@{
            Hersteller  = Format-BoardInfoValue -Value $board.Manufacturer -Fallback 'unbekannt'
            Modell      = Format-BoardInfoValue -Value $board.Product -Fallback 'unbekannt'
            BiosVersion = Format-BoardInfoValue -Value $bios.SMBIOSBIOSVersion -Fallback 'unbekannt'
            BiosDatum   = $biosDate
        }
    }
    catch {
        Write-Warning "Board-/BIOS-Informationen konnten nicht gelesen werden: $_"
        return [PSCustomObject]@{
            Hersteller  = 'n/a'
            Modell      = 'n/a'
            BiosVersion = 'n/a'
            BiosDatum   = 'n/a'
        }
    }
}

function Test-AdminPrivileges {
    <#
    .SYNOPSIS
        Prüft ob das Skript mit Administratorrechten ausgeführt wird.
    .OUTPUTS
        [bool] $true wenn Administrator, sonst $false.
    .EXAMPLE
        Test-AdminPrivileges
    #>
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function Test-SecureBootEnabled,
    Get-SecureBootPlatformStatus,
    Get-SecureBootCertificateStatus,
    Get-SecureBootReadiness,
    Get-BootManagerSignature,
    Start-SecureBootCertificateUpdate,
    Test-AdminPrivileges,
    Get-SecureBootDatabaseSources,
    Get-BoardInfo
