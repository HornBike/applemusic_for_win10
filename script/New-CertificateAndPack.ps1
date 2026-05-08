param(
    [int]$BundleIndex = 0,
    [string]$Password = '12345',
    [string]$CertName = 'AppleMusicWinLocalTest',
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string]$RootPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$CertificateDirectory = '',
    [switch]$SkipTimestamp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NaturalSortName {
    param([string]$Name)

    return [regex]::Replace($Name, '\d+', {
        param($Match)
        $Match.Value.PadLeft(20, '0')
    })
}

function Get-SdkTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $command = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $kitsRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
    if (-not (Test-Path $kitsRoot)) {
        throw "Could not find $DisplayName. Install the Windows SDK first."
    }

    $preferredArchitectures = @('x64', 'x86', 'arm64', 'arm')
    $candidates = @()

    Get-ChildItem -Path $kitsRoot -Directory | ForEach-Object {
        $versionPath = $_.FullName
        foreach ($architecture in $preferredArchitectures) {
            $candidate = Join-Path (Join-Path $versionPath $architecture) $ToolName
            if (Test-Path $candidate) {
                $candidates += [PSCustomObject]@{
                    Path = $candidate
                    Version = $_.Name
                    Architecture = $architecture
                }
            }
        }
    }

    if ($candidates.Count -eq 0) {
        throw "Could not find $DisplayName. Install the Windows SDK first."
    }

    $selected = $candidates |
        Sort-Object @{ Expression = { Get-NaturalSortName $_.Version }; Descending = $true },
                    @{ Expression = { [array]::IndexOf($preferredArchitectures, $_.Architecture) } } |
        Select-Object -First 1

    return $selected.Path
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $program = $Arguments[0]
    $programArguments = @()
    if ($Arguments.Length -gt 1) {
        $programArguments = $Arguments[1..($Arguments.Length - 1)]
    }

    $output = & $program $programArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            throw $FailureMessage
        }
        throw "$FailureMessage`n$details"
    }
}

function Get-BundleFiles {
    param([string]$BasePath)

    $bundles = @(Get-ChildItem -Path $BasePath -Filter '*.msixbundle' -File |
        Sort-Object { Get-NaturalSortName $_.Name })

    if ($bundles.Count -eq 0) {
        throw 'No msixbundle files were found in the workspace root.'
    }

    return $bundles
}

function Select-BundleFile {
    param(
        [System.IO.FileInfo[]]$Bundles,
        [int]$SelectedIndex
    )

    if ($SelectedIndex -gt 0) {
        if ($SelectedIndex -gt $Bundles.Count) {
            throw "BundleIndex is out of range. Found $($Bundles.Count) bundle(s)."
        }
        return $Bundles[$SelectedIndex - 1]
    }

    Write-Host 'Available msixbundle files:'
    for ($index = 0; $index -lt $Bundles.Count; $index++) {
        Write-Host (("{0}. {1}" -f ($index + 1), $Bundles[$index].Name))
    }

    while ($true) {
        $inputValue = Read-Host 'Enter the bundle index to process'
        if ($inputValue -match '^\d+$') {
            $parsedIndex = [int]$inputValue
            if ($parsedIndex -ge 1 -and $parsedIndex -le $Bundles.Count) {
                return $Bundles[$parsedIndex - 1]
            }
        }
        Write-Host 'Invalid selection. Try again.'
    }
}

function Update-MinVersionInManifest {
    param([string]$ManifestPath)

    $content = Get-Content -Path $ManifestPath -Raw -Encoding UTF8
    $pattern = '(<(?:\w+:)?TargetDeviceFamily\b[^>]*\bName="Windows\.Desktop"[^>]*\bMinVersion=")([^"]+)(")'
    $regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $matchCount = $regex.Matches($content).Count
    if ($matchCount -eq 0) {
        throw "Could not find the Windows.Desktop TargetDeviceFamily in $ManifestPath"
    }

    $updated = $regex.Replace($content, '${1}10.0.0.0${3}')
    Set-Content -Path $ManifestPath -Value $updated -Encoding UTF8
}

function Convert-BundleNameToLegacyExtension {
    param([string]$BundleName)

    if ($BundleName -like '*.msixbundle') {
        return ($BundleName -replace '\.msixbundle$', '.appxbundle')
    }

    return $BundleName
}

function Remove-PackageGeneratedMetadata {
    param([string]$PackageDirectory)

    foreach ($name in @('AppxSignature.p7x', 'AppxBlockMap.xml', '[Content_Types].xml')) {
        $path = Join-Path $PackageDirectory $name
        if (Test-Path $path) {
            Remove-Item -Path $path -Force
        }
    }

    $metadataDirectory = Join-Path $PackageDirectory 'AppxMetadata'
    if (Test-Path $metadataDirectory) {
        Remove-Item -Path $metadataDirectory -Recurse -Force
    }
}

function Get-PublisherFromManifest {
    param([string]$ManifestPath)

    $content = Get-Content -Path $ManifestPath -Raw -Encoding UTF8
    $match = [regex]::Match($content, '<Identity\b[^>]*\bPublisher="([^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        throw "Could not find the Identity Publisher in $ManifestPath"
    }

    return $match.Groups[1].Value
}

function New-CodeSigningCertificateFiles {
    param(
        [string]$SubjectName,
        [string]$FriendlyName,
        [string]$PfxPassword,
        [string]$ExportDirectory
    )

    if (-not (Test-Path $ExportDirectory)) {
        New-Item -ItemType Directory -Path $ExportDirectory | Out-Null
    }

    $certificateParams = @{
        Subject = $SubjectName
        FriendlyName = $FriendlyName
        Type = 'Custom'
        CertStoreLocation = 'Cert:\CurrentUser\My'
        KeyAlgorithm = 'RSA'
        KeyLength = 2048
        KeyExportPolicy = 'Exportable'
        HashAlgorithm = 'SHA256'
        KeyUsage = 'DigitalSignature'
        TextExtension = @('2.5.29.37={text}1.3.6.1.5.5.7.3.3')
        NotAfter = (Get-Date).AddYears(5)
    }

    $cert = New-SelfSignedCertificate @certificateParams
    $safeName = ($FriendlyName -replace '[^A-Za-z0-9._-]', '_')
    $pfxPath = Join-Path $ExportDirectory ($safeName + '.pfx')
    $cerPath = Join-Path $ExportDirectory ($safeName + '.cer')
    $securePassword = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force

    if (Test-Path $pfxPath) {
        Remove-Item -Path $pfxPath -Force
    }
    if (Test-Path $cerPath) {
        Remove-Item -Path $cerPath -Force
    }

    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $securePassword | Out-Null
    Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

    return [PSCustomObject]@{
        Certificate = $cert
        PfxPath = $pfxPath
        CerPath = $cerPath
    }
}

function Import-CertificateForBundling {
    param(
        [string]$CerPath,
        [string]$PfxPath,
        [string]$PfxPassword
    )

    $securePassword = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
    Import-PfxCertificate -FilePath $PfxPath -Password $securePassword -CertStoreLocation 'Cert:\CurrentUser\My' | Out-Null
    Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
    Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\CurrentUser\TrustedPeople' | Out-Null
}

function Sign-PackageFile {
    param(
        [string]$SignToolPath,
        [string]$FilePath,
        [string]$PfxPath,
        [string]$PfxPassword,
        [string]$TimeStamp,
        [bool]$UseTimestamp
    )

    $arguments = @(
        $SignToolPath,
        'sign',
        '/fd',
        'SHA256',
        '/f',
        $PfxPath,
        '/p',
        $PfxPassword
    )

    if ($UseTimestamp) {
        $arguments += @('/tr', $TimeStamp, '/td', 'SHA256')
    }

    $arguments += $FilePath
    Invoke-ExternalCommand -Arguments $arguments -FailureMessage "Signing failed: $FilePath"
}

function Validate-OutputBundle {
    param([string]$BundlePath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $bundleArchive = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)

    try {
        $bundleManifestEntry = $bundleArchive.GetEntry('AppxMetadata/AppxBundleManifest.xml')
        if ($null -eq $bundleManifestEntry) {
            throw 'The output bundle is missing AppxMetadata/AppxBundleManifest.xml'
        }

        if ($null -eq $bundleArchive.GetEntry('AppxSignature.p7x')) {
            throw 'The output bundle is missing AppxSignature.p7x'
        }

        $bundleReader = New-Object System.IO.StreamReader($bundleManifestEntry.Open())
        try {
            $bundleManifest = $bundleReader.ReadToEnd()
        }
        finally {
            $bundleReader.Dispose()
        }

        if ($bundleManifest -notmatch 'MinVersion="10\.0\.0\.0"') {
            throw 'The output bundle manifest does not contain MinVersion 10.0.0.0'
        }

        $payloadEntries = @($bundleArchive.Entries |
            Where-Object { ($_.FullName -like '*.msix' -or $_.FullName -like '*.appx') -and $_.FullName -notlike '*/*' } |
            Sort-Object FullName)

        if ($payloadEntries.Count -ne 2) {
            throw "The output bundle should contain 2 payload packages, found $($payloadEntries.Count)."
        }

        foreach ($entry in $payloadEntries) {
            $memoryStream = New-Object System.IO.MemoryStream
            $entryStream = $entry.Open()
            try {
                $entryStream.CopyTo($memoryStream)
            }
            finally {
                $entryStream.Dispose()
            }

            $memoryStream.Position = 0
            $payloadArchive = New-Object System.IO.Compression.ZipArchive($memoryStream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
            try {
                $payloadManifestEntry = $payloadArchive.GetEntry('AppxManifest.xml')
                if ($null -eq $payloadManifestEntry) {
                    throw "$($entry.FullName) is missing AppxManifest.xml"
                }
                if ($null -eq $payloadArchive.GetEntry('AppxSignature.p7x')) {
                    throw "$($entry.FullName) is missing AppxSignature.p7x"
                }

                $payloadReader = New-Object System.IO.StreamReader($payloadManifestEntry.Open())
                try {
                    $payloadManifest = $payloadReader.ReadToEnd()
                }
                finally {
                    $payloadReader.Dispose()
                }

                if ($payloadManifest -notmatch 'MinVersion="10\.0\.0\.0"') {
                    throw "$($entry.FullName) does not contain MinVersion 10.0.0.0"
                }
            }
            finally {
                $payloadArchive.Dispose()
                $memoryStream.Dispose()
            }
        }
    }
    finally {
        $bundleArchive.Dispose()
    }
}

$bundleFiles = Get-BundleFiles -BasePath $RootPath
$selectedBundle = Select-BundleFile -Bundles $bundleFiles -SelectedIndex $BundleIndex
$makeAppxPath = Get-SdkTool -ToolName 'makeappx.exe' -DisplayName 'MakeAppx'
$signToolPath = Get-SdkTool -ToolName 'signtool.exe' -DisplayName 'SignTool'

if ([string]::IsNullOrWhiteSpace($CertificateDirectory)) {
    $CertificateDirectory = Join-Path $RootPath 'certificates'
}

$workDirectory = Join-Path $RootPath 'work'
$outputDirectory = Join-Path $RootPath 'output'
$bundleExtractDirectory = Join-Path $workDirectory 'bundle'
$payloadExtractRoot = Join-Path $workDirectory 'payloads'
$rebuiltPayloadRoot = Join-Path $workDirectory 'rebuilt_payloads'

if (Test-Path $workDirectory) {
    Remove-Item -Path $workDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $workDirectory | Out-Null
New-Item -ItemType Directory -Path $bundleExtractDirectory | Out-Null
New-Item -ItemType Directory -Path $payloadExtractRoot | Out-Null
New-Item -ItemType Directory -Path $rebuiltPayloadRoot | Out-Null
if (-not (Test-Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

try {
    Invoke-ExternalCommand -Arguments @($makeAppxPath, 'unbundle', '/p', $selectedBundle.FullName, '/d', $bundleExtractDirectory, '/o') -FailureMessage 'Failed to unbundle the selected msixbundle.'

    $bundleManifestPath = Join-Path $bundleExtractDirectory 'AppxMetadata\AppxBundleManifest.xml'
    $publisherSubject = Get-PublisherFromManifest -ManifestPath $bundleManifestPath
    $certificateInfo = New-CodeSigningCertificateFiles -SubjectName $publisherSubject -FriendlyName $CertName -PfxPassword $Password -ExportDirectory $CertificateDirectory
    Import-CertificateForBundling -CerPath $certificateInfo.CerPath -PfxPath $certificateInfo.PfxPath -PfxPassword $Password

    $payloadFiles = @(Get-ChildItem -Path $bundleExtractDirectory -Filter '*.msix' -File |
        Sort-Object { Get-NaturalSortName $_.Name })

    if ($payloadFiles.Count -ne 2) {
        throw "The outer bundle should contain 2 payload msix files, found $($payloadFiles.Count)."
    }

    foreach ($payloadFile in $payloadFiles) {
        $extractDirectory = Join-Path $payloadExtractRoot $payloadFile.BaseName
        New-Item -ItemType Directory -Path $extractDirectory | Out-Null

        Invoke-ExternalCommand -Arguments @($makeAppxPath, 'unpack', '/p', $payloadFile.FullName, '/d', $extractDirectory, '/o') -FailureMessage "Failed to unpack payload $($payloadFile.Name)."
        Update-MinVersionInManifest -ManifestPath (Join-Path $extractDirectory 'AppxManifest.xml')
        Remove-PackageGeneratedMetadata -PackageDirectory $extractDirectory

        $legacyPayloadName = [System.IO.Path]::GetFileNameWithoutExtension($payloadFile.Name) + '.appx'
        $rebuiltPayloadPath = Join-Path $rebuiltPayloadRoot $legacyPayloadName
        if (Test-Path $rebuiltPayloadPath) {
            Remove-Item -Path $rebuiltPayloadPath -Force
        }

        Invoke-ExternalCommand -Arguments @($makeAppxPath, 'pack', '/d', $extractDirectory, '/p', $rebuiltPayloadPath, '/o') -FailureMessage "Failed to rebuild payload $legacyPayloadName."
        Sign-PackageFile -SignToolPath $signToolPath -FilePath $rebuiltPayloadPath -PfxPath $certificateInfo.PfxPath -PfxPassword $Password -TimeStamp $TimestampUrl -UseTimestamp (-not $SkipTimestamp)
    }

    $outputBundleName = Convert-BundleNameToLegacyExtension -BundleName $selectedBundle.Name
    $outputBundlePath = Join-Path $outputDirectory $outputBundleName
    if (Test-Path $outputBundlePath) {
        Remove-Item -Path $outputBundlePath -Force
    }

    Invoke-ExternalCommand -Arguments @($makeAppxPath, 'bundle', '/d', $rebuiltPayloadRoot, '/p', $outputBundlePath, '/o') -FailureMessage 'Failed to rebuild the final msixbundle.'
    Sign-PackageFile -SignToolPath $signToolPath -FilePath $outputBundlePath -PfxPath $certificateInfo.PfxPath -PfxPassword $Password -TimeStamp $TimestampUrl -UseTimestamp (-not $SkipTimestamp)

    Validate-OutputBundle -BundlePath $outputBundlePath
    Remove-Item -Path $workDirectory -Recurse -Force

    Write-Host "Done. Output bundle: $outputBundlePath"
    Write-Host "PFX certificate: $($certificateInfo.PfxPath)"
    Write-Host "CER certificate: $($certificateInfo.CerPath)"
    Write-Host 'Validation passed and the work directory was removed.'
}
catch {
    Write-Error $_
    if (Test-Path $workDirectory) {
        Write-Host "The work directory was kept for troubleshooting: $workDirectory"
    }
    exit 1
}