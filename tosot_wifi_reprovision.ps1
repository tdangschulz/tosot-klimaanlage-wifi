[CmdletBinding()]
param(
    [string]$TargetSsid,
    [string]$TargetPsw,
    [Nullable[int]]$CheckInterval,
    [Nullable[int]]$InitialSendWait,
    [Nullable[int]]$SendRetries,
    [Nullable[int]]$SendInterval,
    [Nullable[int]]$VerifyTimeout,
    [Nullable[int]]$VerifyScanInterval,
    [string]$ApIpCandidates,
    [string]$ReconnectSsid,
    [switch]$NoReconnect,
    [string]$EnvFile,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-Usage {
    @"
Usage:
  .\tosot_wifi_reprovision.ps1 [options]

Description:
  Scans for configured Gree/Tosot AP SSIDs, connects, sends WLAN provisioning,
  and verifies success by checking AP visibility.
  If present, values are auto-loaded from .env (or -EnvFile).

Options:
  -Help                            Show this help and exit
  -TargetSsid SSID                 Target router SSID
  -TargetPsw PASSWORD              Target router password
  -CheckInterval SEC               Main scan loop interval (default: 60)
  -InitialSendWait SEC             Wait before first UDP send (default: 5)
  -SendRetries N                   UDP send attempts per provisioning (default: 12)
  -SendInterval SEC                Pause between UDP sends (default: 2)
  -VerifyTimeout SEC               Max verification time (default: 120)
  -VerifyScanInterval SEC          Verification rescan interval (default: 5)
  -ApIpCandidates "IP1 IP2"         AP IP fallback list (default: "192.168.1.1 192.168.0.1")
  -ReconnectSsid SSID              WiFi SSID to reconnect to when no AP is visible
  -NoReconnect                     Disable reconnect behavior
  -EnvFile PATH                    Path to .env file (default: .\.env)

Examples:
  .\tosot_wifi_reprovision.ps1 -Help
  .\tosot_wifi_reprovision.ps1 -TargetSsid MeinWLAN -TargetPsw secret
  .\tosot_wifi_reprovision.ps1 -CheckInterval 90 -SendRetries 15
"@
}

function Get-Setting {
    param(
        [AllowNull()]$CliValue,
        [Parameter(Mandatory = $true)][bool]$CliProvided,
        [Parameter(Mandatory = $true)][string]$EnvVar,
        [Parameter(Mandatory = $true)]$DefaultValue,
        [switch]$AllowEmpty
    )

    if ($CliProvided -and $null -ne $CliValue -and ($AllowEmpty -or $CliValue -ne '')) {
        return $CliValue
    }

    $envValue = [Environment]::GetEnvironmentVariable($EnvVar)
    if ($null -ne $envValue -and ($AllowEmpty -or $envValue -ne '')) {
        return $envValue
    }

    return $DefaultValue
}

function Load-EnvFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) {
            return
        }

        $idx = $line.IndexOf('=')
        if ($idx -lt 1) {
            return
        }

        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()

        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }

        [Environment]::SetEnvironmentVariable($key, $val)
    }
}

function Parse-Int {
    param(
        [AllowNull()]$Value,
        [int]$Fallback
    )

    if ($null -eq $Value) {
        return $Fallback
    }

    $stringValue = [string]$Value
    if ([string]::IsNullOrWhiteSpace($stringValue)) {
        return $Fallback
    }

    $tmp = 0
    if ([int]::TryParse($stringValue, [ref]$tmp)) {
        return $tmp
    }

    return $Fallback
}

function Is-GreeApSsid {
    param([string]$Ssid)
    return $script:GreeApPsw.ContainsKey($Ssid)
}

function Get-ApDisplayName {
    param([string]$ApSsid)

    if ($script:GreeApLabel.ContainsKey($ApSsid)) {
        return "$ApSsid ($($script:GreeApLabel[$ApSsid]))"
    }

    return $ApSsid
}

function Get-WlanInterface {
    Write-Host 'Searching for WLAN interface...'

    $raw = netsh wlan show interfaces
    $name = $null
    foreach ($line in $raw) {
        if ($line -match '^\s*(Name|Interface name|Schnittstellenname)\s*:\s*(.+)$') {
            $name = $Matches[2].Trim()
            break
        }
        if ($line -match '^\s*Name\s*:\s*(.+)$') {
            $name = $Matches[1].Trim()
            break
        }
    }

    if (-not $name) {
        throw 'No WLAN interface found via netsh.'
    }

    Write-Host "WLAN interface: $name"
    return $name
}

function Get-WlanStatus {
    param([string]$Interface)

    $result = [ordered]@{
        State = 'unknown'
        Ssid  = 'none'
    }

    $raw = netsh wlan show interfaces interface="$Interface"
    if (-not $raw) {
        $raw = netsh wlan show interfaces
    }

    $connectedWords = @('connected', 'verbunden', 'conectado', 'connecte')
    $disconnectedWords = @('disconnected', 'getrennt', 'desconectado', 'deconnecte')

    foreach ($line in $raw) {
        if ($line -match '^\s*(Name|Interface name|Schnittstellenname)\s*:\s*(.+)$') {
            if ($Matches[2].Trim() -ne $Interface) {
                continue
            }
        }

        if ($line -match '^\s*(State|Status|Zustand|Estado|Etat)\s*:\s*(.+)$') {
            $stateRaw = $Matches[2].Trim().ToLowerInvariant()
            if ($connectedWords -contains $stateRaw) {
                $result.State = 'connected'
            }
            elseif ($disconnectedWords -contains $stateRaw) {
                $result.State = 'disconnected'
            }
            else {
                $result.State = $stateRaw
            }
            continue
        }

        if ($line -match '^\s*SSID\s*:\s*(.+)$') {
            $val = $Matches[1].Trim()
            if ($val -and $val -notmatch '^BSSID') {
                $result.Ssid = $val
            }
            continue
        }
    }

    if ($result.State -eq 'unknown' -and $result.Ssid -ne 'none') {
        $result.State = 'connected'
    }

    return $result
}

function New-WlanProfileXml {
    param(
        [string]$Ssid,
        [string]$Password
    )

    $escSsid = [Security.SecurityElement]::Escape($Ssid)
    $escPsw = [Security.SecurityElement]::Escape($Password)

    return @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$escSsid</name>
  <SSIDConfig>
    <SSID>
      <name>$escSsid</name>
    </SSID>
  </SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM>
    <security>
      <authEncryption>
        <authentication>WPA2PSK</authentication>
        <encryption>AES</encryption>
        <useOneX>false</useOneX>
      </authEncryption>
      <sharedKey>
        <keyType>passPhrase</keyType>
        <protected>false</protected>
        <keyMaterial>$escPsw</keyMaterial>
      </sharedKey>
    </security>
  </MSM>
</WLANProfile>
"@
}

function Ensure-WlanProfile {
    param(
        [string]$Ssid,
        [string]$Password
    )

    $null = netsh wlan show profile name="$Ssid"
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host "Creating temporary WLAN profile for '$Ssid'"
    $tmpFile = Join-Path $env:TEMP ("tosot_profile_{0}.xml" -f ([Guid]::NewGuid().ToString('N')))
    try {
        New-WlanProfileXml -Ssid $Ssid -Password $Password | Set-Content -LiteralPath $tmpFile -Encoding UTF8
        $null = netsh wlan add profile filename="$tmpFile" user=current
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add WLAN profile for '$Ssid'."
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmpFile) {
            Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Connect-ToAp {
    param(
        [string]$Ssid,
        [string]$Password,
        [string]$Interface
    )

    Write-Host "Attempting connection to '$Ssid' on $Interface"
    $null = netsh wlan disconnect interface="$Interface"
    Start-Sleep -Seconds 1

    Ensure-WlanProfile -Ssid $Ssid -Password $Password
    $null = netsh wlan connect name="$Ssid" ssid="$Ssid" interface="$Interface"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "netsh connect failed for '$Ssid'."
        return $false
    }

    # Short early check to avoid waiting full timeout on obvious failures.
    Start-Sleep -Seconds 2
    $status = Get-WlanStatus -Interface $Interface
    if ($status.Ssid -eq $Ssid -and $status.State -eq 'connected') {
        return $true
    }

    return $true
}

function Test-ConnectionStatus {
    param(
        [string]$Ssid,
        [string]$Interface
    )

    $timeout = 60
    Write-Host "Checking connection status on $Interface (timeout ${timeout}s)..."

    for ($i = 1; $i -le $timeout; $i++) {
        $status = Get-WlanStatus -Interface $Interface
        $hasIp = $false
        try {
            $ipObj = Get-NetIPAddress -InterfaceAlias $Interface -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -and $_.IPAddress -ne '169.254.0.0' }
            $hasIp = $null -ne $ipObj
        }
        catch {
            $hasIp = $false
        }

        Write-Host "[$i/$timeout] State: $($status.State) | SSID: $($status.Ssid) | IP: $hasIp"

        if ($status.State -eq 'connected' -and $status.Ssid -eq $Ssid -and $hasIp) {
            Write-Host "Connected to $Ssid"
            return $true
        }

        Start-Sleep -Seconds 1
    }

    Write-Host "Not connected after ${timeout}s"
    return $false
}

function Scan-VisibleAps {
    Write-Host 'Scanning WiFi networks...'

    $null = netsh wlan show networks mode=bssid
    Start-Sleep -Seconds 3
    $raw = netsh wlan show networks mode=bssid

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $raw) {
        if ($line -match '^\s*SSID\s+\d+\s*:\s*(.*)$') {
            $ssid = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($ssid)) {
                $null = $set.Add($ssid)
            }
        }
    }

    return $set
}

function Is-ApVisible {
    param([string]$ApSsid)

    $visible = Scan-VisibleAps
    return $visible.Contains($ApSsid)
}

function Detect-ApIp {
    param(
        [string]$Interface,
        [string[]]$Candidates
    )

    try {
        $route = Get-NetRoute -InterfaceAlias $Interface -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric |
            Select-Object -First 1
        if ($route -and $route.NextHop -and $route.NextHop -ne '0.0.0.0') {
            return $route.NextHop
        }
    }
    catch {
    }

    foreach ($candidate in $Candidates) {
        if (Test-Connection -ComputerName $candidate -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }

    return $Candidates[0]
}

function Send-Configuration {
    param(
        [string]$WifiSsid,
        [string]$WifiPsw,
        [string]$ApIp,
        [int]$Port,
        [int]$StartupWait,
        [int]$Retries,
        [int]$Interval
    )

    $payloadObj = [ordered]@{
        psw  = $WifiPsw
        ssid = $WifiSsid
        t    = 'wlan'
    }
    $json = $payloadObj | ConvertTo-Json -Compress

    Write-Host "Provisioning to ${ApIp}:$Port"
    Write-Host "Payload: $json"
    Write-Host "Waiting ${StartupWait}s before first send..."
    Start-Sleep -Seconds $StartupWait

    if (Test-Connection -ComputerName $ApIp -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "AP reachable at $ApIp"
    }
    else {
        Write-Host 'AP not pingable, still sending UDP payload.'
    }

    $udp = [System.Net.Sockets.UdpClient]::new()
    $endpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($ApIp), $Port)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ok = $true

    try {
        for ($i = 1; $i -le $Retries; $i++) {
            Write-Host "UDP send attempt $i/$Retries"
            try {
                $null = $udp.Send($bytes, $bytes.Length, $endpoint)
            }
            catch {
                Write-Host "UDP send failed on attempt ${i}: $($_.Exception.Message)"
                $ok = $false
            }
            Start-Sleep -Seconds $Interval
        }
    }
    finally {
        $udp.Dispose()
    }

    if ($ok) {
        Write-Host 'Provisioning payload sent.'
    }
    else {
        Write-Host 'Provisioning send completed with errors.'
    }

    return $ok
}

function Verify-ProvisioningSuccess {
    param(
        [string]$ApSsid,
        [int]$Timeout,
        [int]$ScanInterval
    )

    Write-Host "Verifying provisioning success for '$ApSsid' (timeout ${Timeout}s)..."

    $elapsed = 0
    $stableMissing = 0

    while ($elapsed -lt $Timeout) {
        if (Is-ApVisible -ApSsid $ApSsid) {
            Write-Host "AP '$ApSsid' still visible (${elapsed}s/${Timeout}s)"
            $stableMissing = 0
        }
        else {
            $stableMissing++
            Write-Host "AP '$ApSsid' not visible (${elapsed}s/${Timeout}s), streak=$stableMissing"
            if ($stableMissing -ge 2) {
                Write-Host 'Provisioning likely successful (AP mode exited).'
                return $true
            }
        }

        Start-Sleep -Seconds $ScanInterval
        $elapsed += $ScanInterval
    }

    Write-Host "Verification timeout: AP '$ApSsid' still appears periodically."
    return $false
}

function Reconnect-ToFallbackWifi {
    param(
        [string]$FallbackSsid,
        [string]$Interface,
        [bool]$ReconnectEnabled
    )

    if (-not $ReconnectEnabled) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($FallbackSsid)) {
        Write-Host 'Reconnect skipped: no fallback SSID configured.'
        return $false
    }

    $status = Get-WlanStatus -Interface $Interface
    if ($status.Ssid -eq $FallbackSsid) {
        Write-Host "Already connected to fallback WiFi: $FallbackSsid"
        return $true
    }

    Write-Host "Reconnecting to fallback WiFi: $FallbackSsid"
    $null = netsh wlan connect name="$FallbackSsid" ssid="$FallbackSsid" interface="$Interface"
    Start-Sleep -Seconds 5
    $status = Get-WlanStatus -Interface $Interface
    if ($status.State -eq 'connected' -and $status.Ssid -eq $FallbackSsid) {
        return $true
    }

    Write-Host "Reconnect to '$FallbackSsid' failed (profile missing or unavailable)."
    return $false
}

if ($Help) {
    Show-Usage
    exit 0
}

$EnvFile = Get-Setting -CliValue $EnvFile -CliProvided:$($PSBoundParameters.ContainsKey('EnvFile')) -EnvVar 'ENV_FILE' -DefaultValue '.env' -AllowEmpty
Load-EnvFile -Path $EnvFile

$script:GreeApPsw = @{
    'c6982a76' = (Get-Setting -CliValue $null -CliProvided:$false -EnvVar 'AP_PSW_C6982A76' -DefaultValue '12345678')
    'c699e6bf' = (Get-Setting -CliValue $null -CliProvided:$false -EnvVar 'AP_PSW_C699E6BF' -DefaultValue '12345678')
    'c699e72b' = (Get-Setting -CliValue $null -CliProvided:$false -EnvVar 'AP_PSW_C699E72B' -DefaultValue '12345678')
}

$script:GreeApLabel = @{
    'c699e72b' = 'Buero'
    'c6982a76' = 'Hobbyzimmer'
    'c699e6bf' = 'Schlafzimmer'
}

$TargetSsid = Get-Setting -CliValue $TargetSsid -CliProvided:$($PSBoundParameters.ContainsKey('TargetSsid')) -EnvVar 'TARGET_SSID' -DefaultValue ''
$TargetPsw = Get-Setting -CliValue $TargetPsw -CliProvided:$($PSBoundParameters.ContainsKey('TargetPsw')) -EnvVar 'TARGET_PSW' -DefaultValue ''
$CheckInterval = Parse-Int -Value (Get-Setting -CliValue $CheckInterval -CliProvided:$($PSBoundParameters.ContainsKey('CheckInterval')) -EnvVar 'CHECK_INTERVAL' -DefaultValue '60') -Fallback 60
$InitialSendWait = Parse-Int -Value (Get-Setting -CliValue $InitialSendWait -CliProvided:$($PSBoundParameters.ContainsKey('InitialSendWait')) -EnvVar 'INITIAL_SEND_WAIT' -DefaultValue '5') -Fallback 5
$SendRetries = Parse-Int -Value (Get-Setting -CliValue $SendRetries -CliProvided:$($PSBoundParameters.ContainsKey('SendRetries')) -EnvVar 'SEND_RETRIES' -DefaultValue '12') -Fallback 12
$SendInterval = Parse-Int -Value (Get-Setting -CliValue $SendInterval -CliProvided:$($PSBoundParameters.ContainsKey('SendInterval')) -EnvVar 'SEND_INTERVAL' -DefaultValue '2') -Fallback 2
$VerifyTimeout = Parse-Int -Value (Get-Setting -CliValue $VerifyTimeout -CliProvided:$($PSBoundParameters.ContainsKey('VerifyTimeout')) -EnvVar 'VERIFY_TIMEOUT' -DefaultValue '120') -Fallback 120
$VerifyScanInterval = Parse-Int -Value (Get-Setting -CliValue $VerifyScanInterval -CliProvided:$($PSBoundParameters.ContainsKey('VerifyScanInterval')) -EnvVar 'VERIFY_SCAN_INTERVAL' -DefaultValue '5') -Fallback 5
$ApIpCandidates = Get-Setting -CliValue $ApIpCandidates -CliProvided:$($PSBoundParameters.ContainsKey('ApIpCandidates')) -EnvVar 'AP_IP_CANDIDATES' -DefaultValue '192.168.1.1 192.168.0.1'
$ReconnectSsid = Get-Setting -CliValue $ReconnectSsid -CliProvided:$($PSBoundParameters.ContainsKey('ReconnectSsid')) -EnvVar 'RECONNECT_SSID' -DefaultValue '' -AllowEmpty
$ReconnectEnabledEnv = Get-Setting -CliValue $null -CliProvided:$false -EnvVar 'RECONNECT_ENABLED' -DefaultValue '1'
$ReconnectEnabled = ($ReconnectEnabledEnv -ne '0')
if ($NoReconnect) {
    $ReconnectEnabled = $false
}

if ([string]::IsNullOrWhiteSpace($TargetPsw)) {
    throw 'TARGET_PSW is empty. Set it via -TargetPsw or env var TARGET_PSW.'
}

if ([string]::IsNullOrWhiteSpace($TargetSsid)) {
    throw 'TARGET_SSID is empty. Set it via -TargetSsid or env var TARGET_SSID.'
}

$apCandidates = $ApIpCandidates.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
if ($apCandidates.Count -eq 0) {
    $apCandidates = @('192.168.1.1', '192.168.0.1')
}

$apPort = 7000

Write-Host 'Gree AP WiFi Configurator v2.2 (Windows PowerShell)'
Write-Host "Target WiFi: $TargetSsid"
Write-Host "Check interval: ${CheckInterval}s"
Write-Host '----------------------------------------'

$wlanIface = Get-WlanInterface

if ([string]::IsNullOrWhiteSpace($ReconnectSsid)) {
    $initialStatus = Get-WlanStatus -Interface $wlanIface
    if ($initialStatus.Ssid -and $initialStatus.Ssid -ne 'none' -and -not (Is-GreeApSsid -Ssid $initialStatus.Ssid)) {
        $ReconnectSsid = $initialStatus.Ssid
    }
    else {
        $ReconnectSsid = $TargetSsid
    }
}

if ($ReconnectEnabled) {
    Write-Host "Fallback WiFi for reconnect: $ReconnectSsid"
}
else {
    Write-Host 'Fallback reconnect disabled'
}

Write-Host '----------------------------------------'

while ($true) {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "${timestamp}: scanning for Gree AC APs..."

    $visibleAps = Scan-VisibleAps
    $status = Get-WlanStatus -Interface $wlanIface

    Write-Host "Current connection: $($status.Ssid)"
    Write-Host 'Visible APs:'
    foreach ($visible in $visibleAps) {
        Write-Host "  $visible"
    }

    $foundAp = $false

    foreach ($apSsid in $script:GreeApPsw.Keys) {
        $apName = Get-ApDisplayName -ApSsid $apSsid

        if ($visibleAps.Contains($apSsid)) {
            Write-Host '----------------------------------------'
            Write-Host "$apName is visible -> processing..."
            $foundAp = $true

            if ($status.Ssid -eq $apSsid -and $status.State -eq 'connected') {
                Write-Host "Already connected to $apName -> provisioning"
                $apIp = Detect-ApIp -Interface $wlanIface -Candidates $apCandidates
                Write-Host "Using AP IP: $apIp"
                if (Send-Configuration -WifiSsid $TargetSsid -WifiPsw $TargetPsw -ApIp $apIp -Port $apPort -StartupWait $InitialSendWait -Retries $SendRetries -Interval $SendInterval) {
                    $null = Verify-ProvisioningSuccess -ApSsid $apSsid -Timeout $VerifyTimeout -ScanInterval $VerifyScanInterval
                }
                continue
            }

            if (Connect-ToAp -Ssid $apSsid -Password $script:GreeApPsw[$apSsid] -Interface $wlanIface) {
                Write-Host 'Connection attempt submitted -> verifying...'
                if (Test-ConnectionStatus -Ssid $apSsid -Interface $wlanIface) {
                    Write-Host "Fully connected to $apName -> provisioning"
                    $apIp = Detect-ApIp -Interface $wlanIface -Candidates $apCandidates
                    Write-Host "Using AP IP: $apIp"
                    if (Send-Configuration -WifiSsid $TargetSsid -WifiPsw $TargetPsw -ApIp $apIp -Port $apPort -StartupWait $InitialSendWait -Retries $SendRetries -Interval $SendInterval) {
                        $null = Verify-ProvisioningSuccess -ApSsid $apSsid -Timeout $VerifyTimeout -ScanInterval $VerifyScanInterval
                    }
                    Start-Sleep -Seconds 3
                }
                else {
                    Write-Host 'Connection verification failed.'
                }
            }
            else {
                Write-Host "Connection to $apName failed."
            }
        }
        else {
            Write-Host "$apName not visible"
        }
    }

    if (-not $foundAp) {
        Write-Host 'No Gree AP visible -> waiting...'
        $null = Reconnect-ToFallbackWifi -FallbackSsid $ReconnectSsid -Interface $wlanIface -ReconnectEnabled $ReconnectEnabled
    }

    Write-Host '----------------------------------------'
    Write-Host "Sleeping ${CheckInterval}s until next scan..."
    Start-Sleep -Seconds $CheckInterval
}
