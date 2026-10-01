<#
.SYNOPSIS
    Mini FTP deployment app (WinSCP based) - upload / rename / remove files and folders.

.DESCRIPTION
    Reads config.json and applies FTP operations using WinSCP .NET assembly:
      - renames : rename / move remote files AND folders (via Session.MoveFile)
      - removes : delete remote files AND folders (recursive)
      - uploads : upload local files + folders to a remote folder (overwrite, recursive)

    Runs on Windows PowerShell 5.1 (Windows Server 2022+) and PowerShell 7+.
    Missing / null / empty sections are skipped automatically.
    Each item is processed independently - one failure does not stop the rest.

    Requires next to this script:
      WinSCPnet.dll + winscp.exe (same folder, same version)
    Download "Automation" ZIP from https://winscp.net/eng/download.php
    (*.NET assembly / COM library* link) and extract both files here.
    Or run with -AutoDownloadWinScp to fetch them automatically from NuGet.

.PARAMETER ConfigPath
    Full path to config.json. Defaults to .\config.json next to the script.

.PARAMETER FtpHost
    Overrides ftp.host from config.json (or env FTP_HOST).

.PARAMETER FtpPort
    Overrides ftp.port (default 21, 22 for SFTP).

.PARAMETER Username
    Overrides ftp.username (or env FTP_USER).

.PARAMETER Password
    Overrides ftp.password (or env FTP_PASS).

.PARAMETER Protocol
    Overrides ftp.protocol. Accepted: Ftp, FtpExplicit, FtpImplicit, Sftp.
    Default: Ftp. For FTPS use FtpExplicit/FtpImplicit.

.PARAMETER RemoteRoot
    Overrides ftp.remoteRoot. Base path that relative remote paths resolve against.
    Default: "/"

.PARAMETER WinScpDllPath
    Full path to WinSCPnet.dll. Defaults to .\WinSCPnet.dll (or .\netstandard2.0\WinSCPnet.dll on PS7).

.PARAMETER AutoDownloadWinScp
    If WinSCPnet.dll is missing, download latest stable WinSCP via NuGet automatically.

.PARAMETER DryRun
    Log what would be done without touching the server (no connection, no changes).

.PARAMETER LogPath
    Optional log file path (appended). Console logging is always on.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\FtpManager.ps1
    powershell -ExecutionPolicy Bypass -File .\FtpManager.ps1 -ConfigPath .\config.json
    powershell -ExecutionPolicy Bypass -File .\FtpManager.ps1 -FtpHost ftp.example.com -Username u -Password p -DryRun

CONFIG.JSON SHAPE
    {
      "ftp": {
        "host": "ftp.example.com",   // optional if passed via -FtpHost / env
        "port": 21,                  // optional
        "username": "user",          // optional if passed via param / env
        "password": "pass",          // optional if passed via param / env
        "protocol": "Ftp",           // Ftp | FtpExplicit | FtpImplicit | Sftp
        "remoteRoot": "/",           // base for all relative remote paths
        "passive": true,             // true (default) / false
        "timeoutSeconds": 60,        // optional
        "sshHostKeyFingerprint": "...", // required for SFTP unless -AcceptAnySshHostKey
        "tlsFingerprint": "...",         // optional for FTPS, else use -AcceptAnyCertificate
        "acceptAnyCertificate": false    // true = insecure, accept any TLS/SSH key (test only)
      },
      "renames": [
        { "remote_file_address": "htdocs/old.txt", "remote_new_file_name": "new.txt" },
        { "remote_file_address": "htdocs/old_folder", "remote_new_file_name": "new_folder" }
      ],
      "removes": [
        { "remote_file_address": "htdocs/obsolete.txt" },
        { "remote_file_address": "htdocs/old_folder" }
      ],
      "uploads": [
        {
          "local_file_address": ["C:\\deploy\\web.config", "C:\\deploy\\app.txt"],
          "local_folder_address": ["C:\\deploy\\assets"],
          "remote_folder": "htdocs"
        }
      ]
    }

    NOTES:
    - All "remote_*" values are RELATIVE to ftp.remoteRoot (default "/").
      A value starting with "/" is treated as absolute and used as-is.
    - "remote_new_file_name" is normally just the new name ("new.txt").
      If it contains a "/" it is treated as a relative target path.
    - Uploads OVERWRITE remote files and copy folders recursively,
      like Windows copy/paste: local folder "assets" -> remote "htdocs/assets/".
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string]$FtpHost = "",
    [int]$FtpPort = 0,
    [string]$Username = "",
    [string]$Password = "",
    [string]$Protocol = "",
    [string]$RemoteRoot = "",
    [string]$WinScpDllPath = "",
    [string]$WinScpExePath = "",
    [switch]$AutoDownloadWinScp,
    [switch]$DryRun,
    [string]$LogPath = "",
    [switch]$AcceptAnyCertificate,
    [switch]$AcceptAnySshHostKey,
    [string]$SshHostKeyFingerprint = "",
    [string]$TlsFingerprint = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:LogFile = ""
$script:Stats = @{
    RenamesTotal   = 0; RenamesOk = 0; RenamesFail = 0; RenamesSkip = 0
    RemovesTotal   = 0; RemovesOk = 0; RemovesFail = 0; RemovesSkip = 0
    UploadsTotal   = 0; UploadsOk = 0; UploadsFail = 0; UploadsSkip = 0
}

# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    if ($Level -eq "ERROR") {
        Write-Host $line -ForegroundColor Red
    }
    elseif ($Level -eq "WARN") {
        Write-Host $line -ForegroundColor Yellow
    }
    elseif ($Level -eq "SUCCESS") {
        Write-Host $line -ForegroundColor Green
    }
    else {
        Write-Host $line
    }
    if ($script:LogFile -ne "" -and $script:LogFile -ne $null) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Get-PropValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-ConfigList {
    param($Config, [string]$Name)
    $val = Get-PropValue $Config $Name
    if ($null -eq $val) { return @() }
    if ($val -is [System.Array]) { return $val }
    return @($val)
}

function ConvertTo-StringList {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value.Trim())
    }
    if ($Value -is [System.Array]) {
        $out = @()
        foreach ($v in $Value) {
            if ($null -eq $v) { continue }
            $s = "$v"
            if ($s -ne $null) { $s = $s.Trim() }
            if (-not [string]::IsNullOrWhiteSpace($s)) { $out += $s }
        }
        return $out
    }
    $s = "$Value"
    if ($s -ne $null) { $s = $s.Trim() }
    if ([string]::IsNullOrWhiteSpace($s)) { return @() }
    return @($s)
}

function Normalize-RemotePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "/" }
    $p = $Path.Replace("\", "/").Trim()
    if (-not $p.StartsWith("/")) { $p = "/" + $p }
    while ($p.Contains("//")) { $p = $p.Replace("//", "/") }
    if ($p.Length -gt 1) { $p = $p.TrimEnd("/") }
    if ($p -eq "") { $p = "/" }
    return $p
}

function Join-RemotePath {
    param([string]$Base, [string]$Child)
    if ([string]::IsNullOrWhiteSpace($Child)) { return (Normalize-RemotePath $Base) }
    $c = $Child.Replace("\", "/").Trim()
    while ($c.Contains("//")) { $c = $c.Replace("//", "/") }
    if ($c.StartsWith("/")) { return (Normalize-RemotePath $c) }
    $b = Normalize-RemotePath $Base
    if ($b -eq "/") { return (Normalize-RemotePath ("/" + $c)) }
    return (Normalize-RemotePath ($b + "/" + $c))
}

function Get-RemoteParent {
    param([string]$FullPath)
    $p = Normalize-RemotePath $FullPath
    if ($p -eq "/") { return "/" }
    $idx = $p.LastIndexOf("/")
    if ($idx -le 0) { return "/" }
    return $p.Substring(0, $idx)
}

function Escape-RemoteMask {
    param([string]$RemotePath)
    try {
        $t = [WinSCP.RemotePath].GetMethod("EscapeFileMask")
        if ($null -ne $t) {
            return [WinSCP.RemotePath]::EscapeFileMask($RemotePath)
        }
    }
    catch { }
    return $RemotePath
}

function Ensure-WinScpAssembly {
    param(
        [string]$DllPath,
        [string]$ExePath,
        [bool]$AllowDownload
    )

    if ([string]::IsNullOrWhiteSpace($DllPath)) {
        $isCore = $false
        try { if ($PSVersionTable.PSEdition -eq "Core") { $isCore = $true } } catch { $isCore = $false }
        if ($isCore) {
            $coreCandidate = Join-Path $PSScriptRoot "netstandard2.0\WinSCPnet.dll"
            if (Test-Path -LiteralPath $coreCandidate) {
                $DllPath = $coreCandidate
            }
            else {
                $DllPath = Join-Path $PSScriptRoot "WinSCPnet.dll"
            }
        }
        else {
            $DllPath = Join-Path $PSScriptRoot "WinSCPnet.dll"
        }
    }

    if (Test-Path -LiteralPath $DllPath) {
        $dllDir = Split-Path -Parent $DllPath
        if ([string]::IsNullOrWhiteSpace($dllDir)) { $dllDir = $PSScriptRoot }
        $exeNextToDll = Join-Path $dllDir "winscp.exe"
        if (-not (Test-Path -LiteralPath $exeNextToDll)) {
            if (-not [string]::IsNullOrWhiteSpace($ExePath) -and (Test-Path -LiteralPath $ExePath)) {
                Write-Log "winscp.exe will be taken from '$ExePath' (not next to DLL)." "WARN"
            }
            else {
                Write-Log "winscp.exe NOT found next to WinSCPnet.dll ($exeNextToDll). WinSCP needs both files with matching versions in the same folder." "WARN"
            }
        }
        try {
            Add-Type -Path $DllPath
        }
        catch {
            throw "Failed to load WinSCP assembly from '$DllPath': $($_.Exception.Message)"
        }
        Write-Log "Loaded WinSCP assembly: $DllPath"
        return $DllPath
    }

    if (-not $AllowDownload) {
        throw ("WinSCPnet.dll not found at '{0}'.`n" -f $DllPath) + `
            "Download the 'Automation' ZIP from https://winscp.net/eng/download.php " + `
            "(link '*.NET assembly / COM library*') and extract WinSCPnet.dll + winscp.exe next to this script. " + `
            "On PowerShell 7+ also extract netstandard2.0\WinSCPnet.dll. " + `
            "Alternatively re-run with -AutoDownloadWinScp to download automatically."
    }

    Write-Log "WinSCPnet.dll not found. Downloading latest stable WinSCP via NuGet..." "WARN"
    $loaded = Install-WinScpFromNuGet -DllPath $DllPath
    try {
        Add-Type -Path $loaded
    }
    catch {
        throw "Downloaded WinSCP but failed to load '$loaded': $($_.Exception.Message)"
    }
    Write-Log "Loaded WinSCP assembly: $loaded" "SUCCESS"
    return $loaded
}

function Install-WinScpFromNuGet {
    param([string]$DllPath)

    $targetDir = Split-Path -Parent $DllPath
    if ([string]::IsNullOrWhiteSpace($targetDir)) { $targetDir = $PSScriptRoot }
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $tempPath = [System.IO.Path]::GetTempPath()
    $nupkg = Join-Path $tempPath ("WinSCP." + [System.Guid]::NewGuid().ToString("N") + ".nupkg")
    $nupkgZip = "$nupkg.zip"
    $extractDir = Join-Path $tempPath ("winscp_nuget_" + [System.Guid]::NewGuid().ToString("N"))
    $nugetUrl = "https://www.nuget.org/api/v2/package/WinSCP"

    try {
        Write-Log "Downloading $nugetUrl ..."
        $downloaded = $false
        # Prefer curl.exe (fast, reliable) if available - Invoke-WebRequest on PS5.1 can hang
        try {
            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($null -ne $curl) {
                & curl.exe -L --fail --show-error --connect-timeout 20 --max-time 300 -o $nupkg $nugetUrl
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $nupkg)) { $downloaded = $true }
            }
        }
        catch { }
        if (-not $downloaded) {
            try {
                Invoke-WebRequest -Uri $nugetUrl -OutFile $nupkg -UseBasicParsing
                $downloaded = $true
            }
            catch {
                # PS7 does not know -UseBasicParsing; retry without it
                if ($_.Exception.Message -match "UseBasicParsing") {
                    Invoke-WebRequest -Uri $nugetUrl -OutFile $nupkg
                    $downloaded = $true
                }
                else { throw }
            }
        }

        Write-Log "Extracting package..."
        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force
        }
        # PS 5.1 Expand-Archive only accepts .zip - .nupkg is just a zip, so copy it
        Copy-Item -LiteralPath $nupkg -Destination $nupkgZip -Force
        Expand-Archive -LiteralPath $nupkgZip -DestinationPath $extractDir -Force

        $dllCandidates = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Filter "WinSCPnet.dll" -File -ErrorAction SilentlyContinue)
        if ($dllCandidates.Count -eq 0) { throw "WinSCPnet.dll not found inside NuGet package." }
        $exeCandidates = @(Get-ChildItem -LiteralPath $extractDir -Recurse -Filter "winscp.exe" -File -ErrorAction SilentlyContinue)
        if ($exeCandidates.Count -eq 0) { throw "winscp.exe not found inside NuGet package." }

        $isCore = $false
        try { if ($PSVersionTable.PSEdition -eq "Core") { $isCore = $true } } catch { }

        # Pick best DLL: prefer net40/lib for Desktop, netstandard2.0 for Core
        $pickedDll = $null
        if ($isCore) {
            $pickedDll = $dllCandidates | Where-Object { $_.FullName -match "netstandard2\.0" } | Select-Object -First 1
        }
        if ($null -eq $pickedDll) {
            $pickedDll = $dllCandidates | Where-Object { $_.FullName -match "net40|net462|lib" } | Select-Object -First 1
        }
        if ($null -eq $pickedDll) { $pickedDll = $dllCandidates[0] }

        $pickedExe = $exeCandidates[0]

        Copy-Item -LiteralPath $pickedDll.FullName -Destination $DllPath -Force
        Write-Log "Copied WinSCPnet.dll -> $DllPath"

        # Keep a netstandard2.0 copy for PS7 if the package contains one
        $stdDll = $dllCandidates | Where-Object { $_.FullName -match "netstandard2\.0" } | Select-Object -First 1
        if ($null -ne $stdDll) {
            $stdDir = Join-Path $PSScriptRoot "netstandard2.0"
            if (-not (Test-Path -LiteralPath $stdDir)) {
                New-Item -ItemType Directory -Path $stdDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $stdDll.FullName -Destination (Join-Path $stdDir "WinSCPnet.dll") -Force
            Write-Log "Copied netstandard2.0 build for PowerShell 7+."
        }

        $exeDest = Join-Path $targetDir "winscp.exe"
        Copy-Item -LiteralPath $pickedExe.FullName -Destination $exeDest -Force
        Write-Log "Copied winscp.exe -> $exeDest" "SUCCESS"

        return $DllPath
    }
    finally {
        try { if (Test-Path -LiteralPath $nupkg) { Remove-Item -LiteralPath $nupkg -Force } } catch { }
        try { if (Test-Path -LiteralPath $nupkgZip) { Remove-Item -LiteralPath $nupkgZip -Force } } catch { }
        try { if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force } } catch { }
    }
}

function New-FtpSessionOptions {
    param($FtpConfig, $RootConfig)

    $sessionOptions = New-Object WinSCP.SessionOptions

    # ---- host / port / credentials (CLI > ftp.* > top-level flat keys > env) ----
    $cfgHost = [string](Get-PropValue $FtpConfig "host")
    if ([string]::IsNullOrWhiteSpace($cfgHost)) { $cfgHost = [string](Get-PropValue $FtpConfig "hostname") }
    if ([string]::IsNullOrWhiteSpace($cfgHost) -and $null -ne $RootConfig) {
        $cfgHost = [string](Get-PropValue $RootConfig "ftp_host")
        if ([string]::IsNullOrWhiteSpace($cfgHost)) { $cfgHost = [string](Get-PropValue $RootConfig "ftpHost") }
        if ([string]::IsNullOrWhiteSpace($cfgHost)) { $cfgHost = [string](Get-PropValue $RootConfig "host") }
        if ([string]::IsNullOrWhiteSpace($cfgHost)) { $cfgHost = [string](Get-PropValue $RootConfig "hostname") }
    }
    $cfgUser = [string](Get-PropValue $FtpConfig "username")
    if ([string]::IsNullOrWhiteSpace($cfgUser)) { $cfgUser = [string](Get-PropValue $FtpConfig "user") }
    if ([string]::IsNullOrWhiteSpace($cfgUser) -and $null -ne $RootConfig) {
        $cfgUser = [string](Get-PropValue $RootConfig "ftp_username")
        if ([string]::IsNullOrWhiteSpace($cfgUser)) { $cfgUser = [string](Get-PropValue $RootConfig "ftpUsername") }
        if ([string]::IsNullOrWhiteSpace($cfgUser)) { $cfgUser = [string](Get-PropValue $RootConfig "username") }
        if ([string]::IsNullOrWhiteSpace($cfgUser)) { $cfgUser = [string](Get-PropValue $RootConfig "user") }
    }
    $cfgPass = [string](Get-PropValue $FtpConfig "password")
    if ([string]::IsNullOrWhiteSpace($cfgPass)) { $cfgPass = [string](Get-PropValue $FtpConfig "pass") }
    if ([string]::IsNullOrWhiteSpace($cfgPass) -and $null -ne $RootConfig) {
        $cfgPass = [string](Get-PropValue $RootConfig "ftp_password")
        if ([string]::IsNullOrWhiteSpace($cfgPass)) { $cfgPass = [string](Get-PropValue $RootConfig "ftpPassword") }
        if ([string]::IsNullOrWhiteSpace($cfgPass)) { $cfgPass = [string](Get-PropValue $RootConfig "password") }
        if ([string]::IsNullOrWhiteSpace($cfgPass)) { $cfgPass = [string](Get-PropValue $RootConfig "pass") }
    }
    $cfgPort = Get-PropValue $FtpConfig "port"
    if ($null -eq $cfgPort -and $null -ne $RootConfig) {
        $cfgPort = Get-PropValue $RootConfig "ftp_port"
        if ($null -eq $cfgPort) { $cfgPort = Get-PropValue $RootConfig "ftpPort" }
        if ($null -eq $cfgPort) { $cfgPort = Get-PropValue $RootConfig "port" }
    }
    $cfgProtocol = [string](Get-PropValue $FtpConfig "protocol")
    if ([string]::IsNullOrWhiteSpace($cfgProtocol)) { $cfgProtocol = [string](Get-PropValue $FtpConfig "secure") }

    $effHost = $FtpHost
    if ([string]::IsNullOrWhiteSpace($effHost)) { $effHost = $cfgHost }
    if ([string]::IsNullOrWhiteSpace($effHost)) { $effHost = $env:FTP_HOST }

    $effUser = $Username
    if ([string]::IsNullOrWhiteSpace($effUser)) { $effUser = $cfgUser }
    if ([string]::IsNullOrWhiteSpace($effUser)) { $effUser = $env:FTP_USER }

    $effPass = $Password
    if ([string]::IsNullOrWhiteSpace($effPass)) { $effPass = $cfgPass }
    if ([string]::IsNullOrWhiteSpace($effPass)) { $effPass = $env:FTP_PASS }

    $effProtocol = $Protocol
    if ([string]::IsNullOrWhiteSpace($effProtocol)) { $effProtocol = $cfgProtocol }
    if ([string]::IsNullOrWhiteSpace($effProtocol)) { $effProtocol = "Ftp" }

    if ([string]::IsNullOrWhiteSpace($effHost)) { throw "FTP host is missing. Set ftp.host in config.json, -FtpHost, or env FTP_HOST." }
    if ([string]::IsNullOrWhiteSpace($effUser)) { throw "FTP username is missing. Set ftp.username in config.json, -Username, or env FTP_USER." }
    # password may legitimately be empty (anonymous) - only warn
    if ([string]::IsNullOrWhiteSpace($effPass)) { Write-Log "FTP password is empty (continuing - anonymous login?)." "WARN" }

    $effPort = $FtpPort
    if ($effPort -eq 0 -and $null -ne $cfgPort) {
        try { $effPort = [int]$cfgPort } catch { $effPort = 0 }
    }

    $sessionOptions.HostName = $effHost.Trim()
    $sessionOptions.UserName = $effUser
    $sessionOptions.Password = $effPass

    # ---- protocol ----
    $p = $effProtocol.Trim().ToLowerInvariant()
    if ($p -eq "sftp") {
        $sessionOptions.Protocol = [WinSCP.Protocol]::Sftp
        if ($effPort -eq 0) { $effPort = 22 }
    }
    else {
        $sessionOptions.Protocol = [WinSCP.Protocol]::Ftp
        if ($effPort -eq 0) { $effPort = 21 }
        $ftpSecure = $null
        try { $ftpSecure = [WinSCP.FtpSecure]::None } catch { }
        if ($p -eq "ftpexplicit" -or $p -eq "ftps" -or $p -eq "ftpsexplicit" -or $p -eq "explicit" -or $p -eq "ftps-explicit") {
            try { $sessionOptions.FtpSecure = [WinSCP.FtpSecure]::Explicit } catch { }
        }
        elseif ($p -eq "ftpimplicit" -or $p -eq "ftpsimplicit" -or $p -eq "implicit" -or $p -eq "ftps-implicit") {
            try { $sessionOptions.FtpSecure = [WinSCP.FtpSecure]::Implicit } catch { }
        }
        else {
            try { $sessionOptions.FtpSecure = [WinSCP.FtpSecure]::None } catch { }
        }
    }
    $sessionOptions.PortNumber = $effPort

    # ---- passive / active ----
    $passiveVal = Get-PropValue $FtpConfig "passive"
    if ($null -eq $passiveVal) { $passiveVal = Get-PropValue $FtpConfig "ftpMode" }
    $usePassive = $true
    if ($null -ne $passiveVal) {
        if ($passiveVal -is [bool]) { $usePassive = $passiveVal }
        elseif ("$passiveVal".ToLowerInvariant() -eq "active") { $usePassive = $false }
        elseif ("$passiveVal".ToLowerInvariant() -eq "passive") { $usePassive = $true }
        else {
            try { $usePassive = [bool]::Parse("$passiveVal") } catch { $usePassive = $true }
        }
    }
    try {
        if ($usePassive) { $sessionOptions.FtpMode = [WinSCP.FtpMode]::Passive }
        else { $sessionOptions.FtpMode = [WinSCP.FtpMode]::Active }
    }
    catch { }

    # ---- timeout ----
    $timeoutSec = Get-PropValue $FtpConfig "timeoutSeconds"
    if ($null -eq $timeoutSec) { $timeoutSec = Get-PropValue $FtpConfig "timeout" }
    if ($null -ne $timeoutSec) {
        try { $sessionOptions.Timeout = New-TimeSpan -Seconds ([int]$timeoutSec) } catch { }
    }

    # ---- host key / certificate ----
    $sshFp = $SshHostKeyFingerprint
    if ([string]::IsNullOrWhiteSpace($sshFp)) { $sshFp = [string](Get-PropValue $FtpConfig "sshHostKeyFingerprint") }
    if ([string]::IsNullOrWhiteSpace($sshFp)) { $sshFp = [string](Get-PropValue $FtpConfig "sshFingerprint") }
    if ([string]::IsNullOrWhiteSpace($sshFp)) { $sshFp = $env:FTP_SSH_FINGERPRINT }

    $tlsFp = $TlsFingerprint
    if ([string]::IsNullOrWhiteSpace($tlsFp)) { $tlsFp = [string](Get-PropValue $FtpConfig "tlsFingerprint") }
    if ([string]::IsNullOrWhiteSpace($tlsFp)) { $tlsFp = [string](Get-PropValue $FtpConfig "tlsHostCertificateFingerprint") }
    if ([string]::IsNullOrWhiteSpace($tlsFp)) { $tlsFp = [string](Get-PropValue $FtpConfig "certificateFingerprint") }
    if ([string]::IsNullOrWhiteSpace($tlsFp)) { $tlsFp = $env:FTP_TLS_FINGERPRINT }

    $acceptAnyCfg = Get-PropValue $FtpConfig "acceptAnyCertificate"
    if ($null -eq $acceptAnyCfg) { $acceptAnyCfg = Get-PropValue $FtpConfig "giveUpSecurityAndAcceptAny" }
    $acceptAny = $false
    if ($AcceptAnyCertificate -or $AcceptAnySshHostKey) { $acceptAny = $true }
    if ($acceptAnyCfg -eq $true -or "$acceptAnyCfg".ToLowerInvariant() -eq "true") { $acceptAny = $true }

    if ($sessionOptions.Protocol -eq [WinSCP.Protocol]::Sftp) {
        if (-not [string]::IsNullOrWhiteSpace($sshFp)) {
            $sessionOptions.SshHostKeyFingerprint = $sshFp.Trim()
        }
        elseif ($acceptAny) {
            try { $sessionOptions.GiveUpSecurityAndAcceptAnySshHostKey = $true } catch { }
            Write-Log "INSECURE: accepting any SSH host key. Use sshHostKeyFingerprint in production." "WARN"
        }
        else {
            Write-Log "No sshHostKeyFingerprint configured for SFTP. Connection may fail, or use -AcceptAnySshHostKey for testing (insecure)." "WARN"
        }
    }
    else {
        # FTP / FTPS
        $isSecure = $false
        try { $isSecure = ($sessionOptions.FtpSecure -ne [WinSCP.FtpSecure]::None) } catch { }
        if ($isSecure) {
            if (-not [string]::IsNullOrWhiteSpace($tlsFp)) {
                $sessionOptions.TlsHostCertificateFingerprint = $tlsFp.Trim()
            }
            elseif ($acceptAny) {
                try { $sessionOptions.GiveUpSecurityAndAcceptAnyTlsHostCertificate = $true } catch { }
                Write-Log "INSECURE: accepting any TLS certificate. Use tlsFingerprint in production." "WARN"
            }
            else {
                Write-Log "No tlsFingerprint configured for FTPS. Connection may fail, or use -AcceptAnyCertificate for testing (insecure)." "WARN"
            }
        }
    }

    return $sessionOptions
}

function Get-RemoteRoot {
    param($FtpConfig)
    $root = $RemoteRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-PropValue $FtpConfig "remoteRoot") }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-PropValue $FtpConfig "remote_root") }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-PropValue $FtpConfig "root") }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [string](Get-PropValue $FtpConfig "basePath") }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = "/" }
    return (Normalize-RemotePath $root)
}

function Ensure-RemoteDirectory {
    param($Session, [string]$RemoteDir)
    $dir = Normalize-RemotePath $RemoteDir
    if ($dir -eq "/") { return }
    if ($script:DryRunFlag) { return }
    $exists = $false
    try {
        $info = $Session.GetFileInfo($dir)
        if ($null -ne $info -and $info.IsDirectory) { $exists = $true }
        elseif ($null -ne $info) { throw "Remote path '$dir' exists but is a file, cannot create directory." }
    }
    catch {
        if ($_.Exception.Message -match "exists but is a file") { throw }
        # not found -> create below
    }
    if ($exists) { return }
    try {
        $Session.CreateDirectory($dir)
        Write-Log "Created remote folder: $dir"
    }
    catch {
        if ($_.Exception.Message -match "already exists|exists") { return }
        throw
    }
}

function Invoke-RenameOperations {
    param($Session, $Renames, [string]$RemoteRoot)
    if ($null -eq $Renames -or @($Renames).Count -eq 0) {
        Write-Log "renames: empty or missing -> skipped."
        return
    }
    $index = 0
    foreach ($item in @($Renames)) {
        $index++
        if ($null -eq $item) {
            $script:Stats.RenamesSkip++
            Write-Log "renames[$index]: null entry -> skipped." "WARN"
            continue
        }
        $srcRel = [string](Get-PropValue $item "remote_file_address")
        if ([string]::IsNullOrWhiteSpace($srcRel)) { $srcRel = [string](Get-PropValue $item "remoteFileAddress") }
        if ([string]::IsNullOrWhiteSpace($srcRel)) { $srcRel = [string](Get-PropValue $item "source") }
        if ([string]::IsNullOrWhiteSpace($srcRel)) { $srcRel = [string](Get-PropValue $item "path") }
        $newName = [string](Get-PropValue $item "remote_new_file_name")
        if ([string]::IsNullOrWhiteSpace($newName)) { $newName = [string](Get-PropValue $item "remoteNewFileName") }
        if ([string]::IsNullOrWhiteSpace($newName)) { $newName = [string](Get-PropValue $item "newName") }
        if ([string]::IsNullOrWhiteSpace($newName)) { $newName = [string](Get-PropValue $item "target") }

        if ([string]::IsNullOrWhiteSpace($srcRel) -or [string]::IsNullOrWhiteSpace($newName)) {
            $script:Stats.RenamesSkip++
            Write-Log "renames[$index]: missing remote_file_address or remote_new_file_name -> skipped." "WARN"
            continue
        }
        $srcRel = $srcRel.Trim()
        $newName = $newName.Trim()

        $srcFull = Join-RemotePath $RemoteRoot $srcRel
        if ($newName.Contains("/") -or $newName.Contains("\")) {
            $tgtFull = Join-RemotePath $RemoteRoot $newName
        }
        else {
            $parent = Get-RemoteParent $srcFull
            if ($parent -eq "/") { $tgtFull = Normalize-RemotePath ("/" + $newName) }
            else { $tgtFull = Normalize-RemotePath ($parent + "/" + $newName) }
        }

        if ($srcFull -eq $tgtFull) {
            $script:Stats.RenamesSkip++
            Write-Log "renames[$index]: source and target identical ($srcFull) -> skipped." "WARN"
            continue
        }

        $script:Stats.RenamesTotal++
        if ($script:DryRunFlag) {
            Write-Log "[DRYRUN] Would rename: $srcFull -> $tgtFull"
            $script:Stats.RenamesOk++
            continue
        }
        try {
            # verify source exists for a clearer message
            try { $null = $Session.GetFileInfo($srcFull) }
            catch {
                throw "source not found: $srcFull ($($_.Exception.Message))"
            }
            $Session.MoveFile($srcFull, $tgtFull)
            $script:Stats.RenamesOk++
            Write-Log "Renamed: $srcFull -> $tgtFull" "SUCCESS"
        }
        catch {
            $script:Stats.RenamesFail++
            Write-Log "renames[$index] FAILED: $srcFull -> $tgtFull : $($_.Exception.Message)" "ERROR"
        }
    }
}

function Invoke-RemoveOperations {
    param($Session, $Removes, [string]$RemoteRoot)
    if ($null -eq $Removes -or @($Removes).Count -eq 0) {
        Write-Log "removes: empty or missing -> skipped."
        return
    }
    $index = 0
    foreach ($item in @($Removes)) {
        $index++
        if ($null -eq $item) {
            $script:Stats.RemovesSkip++
            Write-Log "removes[$index]: null entry -> skipped." "WARN"
            continue
        }
        $rel = ""
        if ($item -is [string]) { $rel = $item }
        else {
            $rel = [string](Get-PropValue $item "remote_file_address")
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = [string](Get-PropValue $item "remoteFileAddress") }
            if ([string]::IsNullOrWhiteSpace($rel)) { $rel = [string](Get-PropValue $item "path") }
        }
        if ([string]::IsNullOrWhiteSpace($rel)) {
            $script:Stats.RemovesSkip++
            Write-Log "removes[$index]: missing remote_file_address -> skipped." "WARN"
            continue
        }
        $rel = $rel.Trim()
        $full = Join-RemotePath $RemoteRoot $rel

        $script:Stats.RemovesTotal++
        if ($script:DryRunFlag) {
            Write-Log "[DRYRUN] Would remove: $full (file or folder, recursive)"
            $script:Stats.RemovesOk++
            continue
        }
        try {
            $info = $null
            try { $info = $Session.GetFileInfo($full) }
            catch {
                throw "remote path not found: $full"
            }
            if ($null -ne $info -and $info.IsDirectory) {
                $escaped = Escape-RemoteMask $full
                # 1) delete contents
                try {
                    $r1 = $Session.RemoveFiles($escaped + "/*")
                    try { $r1.Check() } catch {
                        if ($_.Exception.Message -match "No file|not found|No such|Could not|not exist") {
                            Write-Log "Folder $full is empty (or contents already gone)."
                        }
                        else { throw }
                    }
                }
                catch {
                    if ($_.Exception.Message -match "No file|not found|No such|not exist") {
                        Write-Log "Folder $full has no deletable contents (continuing)."
                    }
                    else { throw }
                }
                # 2) delete folder itself
                $r2 = $Session.RemoveFiles($escaped)
                $r2.Check()
                Write-Log "Removed folder (recursive): $full" "SUCCESS"
            }
            else {
                $escaped = Escape-RemoteMask $full
                $r = $Session.RemoveFiles($escaped)
                $r.Check()
                Write-Log "Removed file: $full" "SUCCESS"
            }
            $script:Stats.RemovesOk++
        }
        catch {
            $script:Stats.RemovesFail++
            Write-Log "removes[$index] FAILED: $full : $($_.Exception.Message)" "ERROR"
        }
    }
}

function Invoke-UploadOperations {
    param($Session, $Uploads, [string]$RemoteRoot)
    if ($null -eq $Uploads -or @($Uploads).Count -eq 0) {
        Write-Log "uploads: empty or missing -> skipped."
        return
    }
    $entryIndex = 0
    foreach ($entry in @($Uploads)) {
        $entryIndex++
        if ($null -eq $entry) {
            Write-Log "uploads[$entryIndex]: null entry -> skipped." "WARN"
            continue
        }
        $remoteFolderRel = [string](Get-PropValue $entry "remote_folder")
        if ([string]::IsNullOrWhiteSpace($remoteFolderRel)) { $remoteFolderRel = [string](Get-PropValue $entry "remoteFolder") }
        if ([string]::IsNullOrWhiteSpace($remoteFolderRel)) { $remoteFolderRel = [string](Get-PropValue $entry "remoteDir") }
        if ([string]::IsNullOrWhiteSpace($remoteFolderRel)) { $remoteFolderRel = [string](Get-PropValue $entry "target") }

        $fileVal = Get-PropValue $entry "local_file_address"
        if ($null -eq $fileVal) { $fileVal = Get-PropValue $entry "localFileAddress" }
        if ($null -eq $fileVal) { $fileVal = Get-PropValue $entry "local_files" }
        if ($null -eq $fileVal) { $fileVal = Get-PropValue $entry "files" }

        $folderVal = Get-PropValue $entry "local_folder_address"
        if ($null -eq $folderVal) { $folderVal = Get-PropValue $entry "localFolderAddress" }
        if ($null -eq $folderVal) { $folderVal = Get-PropValue $entry "local_folders" }
        if ($null -eq $folderVal) { $folderVal = Get-PropValue $entry "folders" }

        $files = @(ConvertTo-StringList $fileVal)
        $folders = @(ConvertTo-StringList $folderVal)

        if ($files.Count -eq 0 -and $folders.Count -eq 0) {
            Write-Log "uploads[$entryIndex]: no local files/folders -> skipped." "WARN"
            continue
        }

        $remoteFolderFull = Join-RemotePath $RemoteRoot $remoteFolderRel
        Write-Log "uploads[$entryIndex]: target remote folder = $remoteFolderFull"

        if (-not $script:DryRunFlag) {
            try { Ensure-RemoteDirectory $Session $remoteFolderFull }
            catch {
                Write-Log "uploads[$entryIndex]: cannot create remote folder $remoteFolderFull : $($_.Exception.Message)" "ERROR"
                $script:Stats.UploadsFail += ($files.Count + $folders.Count)
                $script:Stats.UploadsTotal += ($files.Count + $folders.Count)
                continue
            }
        }
        else {
            Write-Log "[DRYRUN] Would ensure remote folder exists: $remoteFolderFull"
        }

        $transferOptions = $null
        if (-not $script:DryRunFlag) {
            $transferOptions = New-Object WinSCP.TransferOptions
            try { $transferOptions.OverwriteMode = [WinSCP.OverwriteMode]::Overwrite } catch { }
            try { $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary } catch { }
        }

        # ---- single files ----
        foreach ($localFile in $files) {
            $script:Stats.UploadsTotal++
            if (-not (Test-Path -LiteralPath $localFile)) {
                $script:Stats.UploadsSkip++
                Write-Log "uploads[$entryIndex]: local file not found -> skipped: $localFile" "WARN"
                continue
            }
            $item = Get-Item -LiteralPath $localFile
            if ($item.PSIsContainer) {
                $script:Stats.UploadsSkip++
                Write-Log "uploads[$entryIndex]: '$localFile' is a folder but listed under local_file_address -> skipped (put it under local_folder_address)." "WARN"
                continue
            }
            $remoteTarget = Join-RemotePath $remoteFolderFull $item.Name
            # WinSCP PutFiles needs native Windows backslash absolute path.
            # Forward slashes (C:/...) make it resolve to C:\<name> only.
            $localFileFull = $item.FullName
            if ($script:DryRunFlag) {
                Write-Log "[DRYRUN] Would upload file: $localFileFull -> $remoteTarget (overwrite)"
                $script:Stats.UploadsOk++
                continue
            }
            try {
                $res = $Session.PutFiles($localFileFull, $remoteTarget, $false, $transferOptions)
                $res.Check()
                $script:Stats.UploadsOk++
                Write-Log "Uploaded file: $localFileFull -> $remoteTarget" "SUCCESS"
            }
            catch {
                $script:Stats.UploadsFail++
                Write-Log "Upload file FAILED: $localFileFull -> $remoteTarget : $($_.Exception.Message)" "ERROR"
            }
        }

        # ---- folders (recursive, Windows copy/paste semantics) ----
        foreach ($localFolder in $folders) {
            $script:Stats.UploadsTotal++
            if (-not (Test-Path -LiteralPath $localFolder)) {
                $script:Stats.UploadsSkip++
                Write-Log "uploads[$entryIndex]: local folder not found -> skipped: $localFolder" "WARN"
                continue
            }
            $item = Get-Item -LiteralPath $localFolder
            if (-not $item.PSIsContainer) {
                $script:Stats.UploadsSkip++
                Write-Log "uploads[$entryIndex]: '$localFolder' is a file but listed under local_folder_address -> skipped (put it under local_file_address)." "WARN"
                continue
            }
            $folderName = $item.Name
            $remoteTargetDir = (Normalize-RemotePath (Join-RemotePath $remoteFolderFull $folderName)) + "/"
            $localFolderFull = $item.FullName
            $localMask = $localFolderFull.TrimEnd("\", "/") + "\*"

            if ($script:DryRunFlag) {
                Write-Log "[DRYRUN] Would upload folder (recursive): $localFolderFull -> $remoteTargetDir (overwrite)"
                $script:Stats.UploadsOk++
                continue
            }
            try {
                Ensure-RemoteDirectory $Session (Normalize-RemotePath (Join-RemotePath $remoteFolderFull $folderName))
                $res = $Session.PutFiles($localMask, $remoteTargetDir, $false, $transferOptions)
                $res.Check()
                $script:Stats.UploadsOk++
                Write-Log "Uploaded folder: $localFolderFull -> $remoteTargetDir" "SUCCESS"
            }
            catch {
                $script:Stats.UploadsFail++
                Write-Log "Upload folder FAILED: $localFolderFull -> $remoteTargetDir : $($_.Exception.Message)" "ERROR"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
$script:DryRunFlag = [bool]$DryRun
if ($LogPath -ne "" -and $LogPath -ne $null) { $script:LogFile = $LogPath }

try {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $PSScriptRoot "config.json"
    }
    Write-Log "=== FTP Manager started ==="
    Write-Log "Config: $ConfigPath"
    if ($script:DryRunFlag) { Write-Log "DRY-RUN mode: no changes will be made." "WARN" }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "config.json not found at '$ConfigPath'. Copy config.example.json and edit it."
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    try {
        $config = $raw | ConvertFrom-Json
    }
    catch {
        throw "config.json is not valid JSON: $($_.Exception.Message)"
    }

    $ftpConfig = Get-PropValue $config "ftp"
    if ($null -eq $ftpConfig) { $ftpConfig = New-Object PSObject }

    $renames = Get-ConfigList $config "renames"
    $removes = Get-ConfigList $config "removes"
    $uploads = Get-ConfigList $config "uploads"

    if (@($renames).Count -eq 0) { Write-Log "renames: attribute missing/null/empty -> will skip." }
    if (@($removes).Count -eq 0) { Write-Log "removes: attribute missing/null/empty -> will skip." }
    if (@($uploads).Count -eq 0) { Write-Log "uploads: attribute missing/null/empty -> will skip." }

    $remoteRoot = Get-RemoteRoot $ftpConfig
    Write-Log "Remote root (base for relative paths): $remoteRoot"

    $session = $null
    $sessionOptions = $null

    if (-not $script:DryRunFlag) {
        $dllUsed = Ensure-WinScpAssembly -DllPath $WinScpDllPath -ExePath $WinScpExePath -AllowDownload ([bool]$AutoDownloadWinScp)
        if (-not [string]::IsNullOrWhiteSpace($WinScpExePath) -and (Test-Path -LiteralPath $WinScpExePath)) {
            Write-Log "Using explicit winscp.exe path: $WinScpExePath"
        }
        $sessionOptions = New-FtpSessionOptions $ftpConfig $config

        $session = New-Object WinSCP.Session
        if (-not [string]::IsNullOrWhiteSpace($WinScpExePath) -and (Test-Path -LiteralPath $WinScpExePath)) {
            try { $session.ExecutablePath = $WinScpExePath } catch { }
        }
        try {
            $logDir = $PSScriptRoot
            $session.SessionLogPath = (Join-Path $logDir ("ftp-session-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log"))
        }
        catch { }

        Write-Log "Connecting to $($sessionOptions.HostName):$($sessionOptions.PortNumber) as $($sessionOptions.UserName) [protocol=$($sessionOptions.Protocol)] ..."
        try {
            $session.Open($sessionOptions)
        }
        catch {
            throw "FTP connect failed: $($_.Exception.Message)"
        }
        Write-Log "Connected." "SUCCESS"
    }
    else {
        # DryRun: still validate connection settings syntactically (needs assembly? no).
        Write-Log "[DRYRUN] Skipping connection."
    }

    # Order follows config.json: renames -> removes -> uploads
    Write-Log "--- Step 1/3: renames ---"
    Invoke-RenameOperations -Session $session -Renames $renames -RemoteRoot $remoteRoot

    Write-Log "--- Step 2/3: removes ---"
    Invoke-RemoveOperations -Session $session -Removes $removes -RemoteRoot $remoteRoot

    Write-Log "--- Step 3/3: uploads (overwrite) ---"
    Invoke-UploadOperations -Session $session -Uploads $uploads -RemoteRoot $remoteRoot

    $totalFail = $script:Stats.RenamesFail + $script:Stats.RemovesFail + $script:Stats.UploadsFail
    Write-Log ("=== SUMMARY === renames ok={0} fail={1} skip={2} | removes ok={3} fail={4} skip={5} | uploads ok={6} fail={7} skip={8}" -f `
        $script:Stats.RenamesOk, $script:Stats.RenamesFail, $script:Stats.RenamesSkip, `
        $script:Stats.RemovesOk, $script:Stats.RemovesFail, $script:Stats.RemovesSkip, `
        $script:Stats.UploadsOk, $script:Stats.UploadsFail, $script:Stats.UploadsSkip)

    if ($totalFail -gt 0) {
        Write-Log "Finished WITH $totalFail failure(s)." "ERROR"
        exit 1
    }
    Write-Log "Finished successfully." "SUCCESS"
    exit 0
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" "ERROR"
    try { Write-Log ($_.ScriptStackTrace) "ERROR" } catch { }
    exit 2
}
finally {
    try {
        if ($null -ne $session) { $session.Dispose() }
    }
    catch { }
}
