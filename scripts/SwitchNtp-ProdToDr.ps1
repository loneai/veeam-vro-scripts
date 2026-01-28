# =====================================================================
# VRO SCRIPT: TEST COMMUNICATION PORT FROM SOURCE SERVER (Linux guest)
# - Runs from VRO (PowerShell) and executes bash inside the Linux VM via VMware Tools
# - Tests connectivity from the SOURCE VM to one or more destination hosts on a port
#

#   DestinationHosts = "10.154.136.1,10.154.136.2"
#   DestinationPort  = 123
#   Protocol         = "udp"
# =====================================================================

Param(
    [Parameter(Mandatory=$true)]
    [String]$CurrentPlanState,

    [Parameter(Mandatory=$true)]
    [String]$VcsaHostname,

    [Parameter(Mandatory=$true)]
    [String]$VcsaCredentialsUsername,

    [Parameter(Mandatory=$true)]
    [String]$VcsaCredentialsPassword,

    [Parameter(Mandatory=$true)]
    [String]$VmCredentialsUsername,

    [Parameter(Mandatory=$true)]
    [String]$VmCredentialsPassword,

    # VM to run the test FROM (your "source server")
    [Parameter(Mandatory=$true)]
    [String]$SourceVmName,

    # Comma-separated list, e.g. "10.154.136.1,10.154.136.2"
    [Parameter(Mandatory=$true)]
    [String]$DestinationHosts,

    [Parameter(Mandatory=$true)]
    [Int]$DestinationPort,

    # "tcp" or "udp"
    [Parameter(Mandatory=$false)]
    [ValidateSet("tcp","udp")]
    [String]$Protocol = "tcp",

    [Parameter(Mandatory=$false)]
    [Int]$TimeoutSeconds = 3,

    [Parameter(Mandatory=$true)]
    [String]$ScriptPath
)

$Version = "1.0.0-TEST-PORT-FROM-SOURCE"

# -------------------------------
# Logging
# -------------------------------
$logDir = Join-Path $ScriptPath "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$LogFile = Join-Path $logDir "$($SourceVmName)-TestPort.log"

Function Write-Log {
    param([string]$str)
    Write-Host $str
    $dt = (Get-Date).ToString("yyyy.MM.dd HH:mm:ss")
    Add-Content $LogFile -Value "[$dt] <$CurrentPid> $str"
}

Write-Log ("=" * 78)
Write-Log "{"
Write-Log "`tScript: $($MyInvocation.MyCommand.Name)"
Write-Log "`tVersion: { $Version }"
Write-Log "}"

# -------------------------------
# Validate inputs (basic safety)
# -------------------------------
if ($DestinationPort -lt 1 -or $DestinationPort -gt 65535) {
    throw "DestinationPort must be between 1 and 65535."
}

# allow only common hostname/IP characters to avoid injection into bash
if ($DestinationHosts -match "[^0-9a-zA-Z\._\-,:]") {
    throw "DestinationHosts contains invalid characters. Allowed: letters, digits, dot, underscore, hyphen, comma, colon."
}

$hostsSpaceSeparated = ($DestinationHosts -replace ",", " ").Trim()

Write-Log "[INFO] Running port test from VM: $($SourceVmName)"
Write-Log "[INFO] Destinations: $($DestinationHosts)  Port: $($DestinationPort)  Proto: $($Protocol)  Timeout: $($TimeoutSeconds)s"

function Invoke-LinuxGuestBash {
    param(
        [Parameter(Mandatory=$true)] [string] $VmName,
        [Parameter(Mandatory=$true)] [pscredential] $GuestCredential,
        [Parameter(Mandatory=$true)] [string] $BashScript
    )

    # Base64 encode payload (PS 5.1 safe)
    $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BashScript))
    $scriptText = "printf '%s' '$enc' | base64 -d | bash"

    $vmObj = Get-VM -Name $VmName -ErrorAction Stop
    $res   = Invoke-VMScript -VM $vmObj -ScriptType Bash -ScriptText $scriptText -GuestCredential $GuestCredential -ErrorAction Stop

    Write-Log "[INFO] Guest output on $($VmName):`n$($res.ScriptOutput)"
    return $res
}

# Credentials
$vcsaCredentials = New-Object System.Management.Automation.PSCredential(
    $VcsaCredentialsUsername,
    (ConvertTo-SecureString $VcsaCredentialsPassword -AsPlainText -Force)
)

$vmCredentials = New-Object System.Management.Automation.PSCredential(
    $VmCredentialsUsername,
    (ConvertTo-SecureString $VmCredentialsPassword -AsPlainText -Force)
)

# Connect to vCenter
Try {
    Write-Log "[INFO] Connecting to vCenter: $VcsaHostname"
    Connect-VIServer -Server $VcsaHostname -Credential $vcsaCredentials -Force | Out-Null
    Write-Log "[INFO] Connected to vCenter: $VcsaHostname"
}
Catch {
    Write-Log "[ERR] Failed to connect to vCenter. $($_.Exception.Message)"
    throw
}

# -------------------------------
# Bash payload executed inside the Linux guest
# -------------------------------
# NOTE: Single-quoted here-string so PowerShell does NOT evaluate $(...) etc.
$bash = @'
set -euo pipefail

HOSTS="__HOSTS__"
PORT="__PORT__"
PROTO="__PROTO__"
TIMEOUT="__TIMEOUT__"

fail=0

echo "Testing connectivity..."
echo "Hosts: $HOSTS"
echo "Port:  $PORT"
echo "Proto: $PROTO"
echo "Timeout: ${TIMEOUT}s"

test_tcp() {
  h="$1"; p="$2"; t="$3"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w "$t" "$h" "$p" >/dev/null 2>&1
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$t" bash -c "</dev/tcp/$h/$p" >/dev/null 2>&1
  else
    bash -c "</dev/tcp/$h/$p" >/dev/null 2>&1
  fi
}

test_udp() {
  h="$1"; p="$2"; t="$3"
  if command -v nc >/dev/null 2>&1; then
    nc -u -z -w "$t" "$h" "$p" >/dev/null 2>&1
  elif [ -e /dev/udp/"$h"/"$p" ] 2>/dev/null; then
    # Best-effort UDP send (does not guarantee reply)
    if command -v timeout >/dev/null 2>&1; then
      timeout "$t" bash -c "echo -n test > /dev/udp/$h/$p" >/dev/null 2>&1
    else
      bash -c "echo -n test > /dev/udp/$h/$p" >/dev/null 2>&1
    fi
  else
    # Fallback: try using bash /dev/udp write anyway
    if command -v timeout >/dev/null 2>&1; then
      timeout "$t" bash -c "echo -n test > /dev/udp/$h/$p" >/dev/null 2>&1
    else
      bash -c "echo -n test > /dev/udp/$h/$p" >/dev/null 2>&1
    fi
  fi
}

for h in $HOSTS; do
  if [ "$PROTO" = "tcp" ]; then
    if test_tcp "$h" "$PORT" "$TIMEOUT"; then
      echo "PASS: $h:$PORT/tcp"
    else
      echo "FAIL: $h:$PORT/tcp"
      fail=1
    fi
  else
    if test_udp "$h" "$PORT" "$TIMEOUT"; then
      echo "PASS: $h:$PORT/udp"
    else
      echo "FAIL: $h:$PORT/udp"
      fail=1
    fi
  fi
done

exit "$fail"
'@

# Inject values safely (simple token replacement)
$bash = $bash.Replace("__HOSTS__", $hostsSpaceSeparated)
$bash = $bash.Replace("__PORT__",  [string]$DestinationPort)
$bash = $bash.Replace("__PROTO__", $Protocol)
$bash = $bash.Replace("__TIMEOUT__", [string]$TimeoutSeconds)

# Execute from Source VM
$res = Invoke-LinuxGuestBash -VmName $SourceVmName -GuestCredential $vmCredentials -BashScript $bash

if ($res.ExitCode -ne 0) {
    Write-Log "[ERR] Port test FAILED from $($SourceVmName)."
    Exit 1
}

Write-Log "[INFO] Port test PASSED from $($SourceVmName)."
Exit 0

