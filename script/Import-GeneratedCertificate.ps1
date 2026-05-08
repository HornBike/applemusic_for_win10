param(
    [string]$RootPath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$CertificateDirectory = '',
    [string]$CertName = 'AppleMusicWinLocalTest',
    [string]$Password = '12345',
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$Scope = 'CurrentUser'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CertificateDirectory {
    param(
        [string]$BasePath,
        [string]$ConfiguredPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        return (Join-Path $BasePath 'certificates')
    }

    return $ConfiguredPath
}

function Ensure-AdministratorIfNeeded {
    param([string]$StoreScope)

    if ($StoreScope -ne 'LocalMachine') {
        return
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator rights are required when importing into LocalMachine stores.'
    }
}

$resolvedDirectory = Resolve-CertificateDirectory -BasePath $RootPath -ConfiguredPath $CertificateDirectory
$safeName = ($CertName -replace '[^A-Za-z0-9._-]', '_')
$cerPath = Join-Path $resolvedDirectory ($safeName + '.cer')
$pfxPath = Join-Path $resolvedDirectory ($safeName + '.pfx')

if (-not (Test-Path $cerPath)) {
    throw "Certificate file not found: $cerPath"
}

if (-not (Test-Path $pfxPath)) {
    throw "PFX file not found: $pfxPath"
}

Ensure-AdministratorIfNeeded -StoreScope $Scope

$securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
$pfxResult = Import-PfxCertificate -FilePath $pfxPath -Password $securePassword -CertStoreLocation ("Cert:\{0}\My" -f $Scope)
$rootResult = Import-Certificate -FilePath $cerPath -CertStoreLocation ("Cert:\{0}\Root" -f $Scope)
$trustedPeopleResult = Import-Certificate -FilePath $cerPath -CertStoreLocation ("Cert:\{0}\TrustedPeople" -f $Scope)

Write-Host "Imported PFX into Cert:\$Scope\My"
Write-Host "Imported CER into Cert:\$Scope\Root"
Write-Host "Imported CER into Cert:\$Scope\TrustedPeople"
Write-Host "PFX thumbprint: $($pfxResult.Thumbprint)"
Write-Host "Root thumbprint: $($rootResult.Thumbprint)"
Write-Host "TrustedPeople thumbprint: $($trustedPeopleResult.Thumbprint)"