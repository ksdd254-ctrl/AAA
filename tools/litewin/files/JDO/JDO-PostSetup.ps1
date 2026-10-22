# JDO x QHT - after the first restart: Brave and AnyDesk (desktop + Brave on the taskbar), Microsoft Store apps updated.
# Started from the sign-in list until everything is done (no internet = it simply tries again at the next sign-in).
# Official download addresses only; every installer's signature is checked before it runs.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
  return
}
try { $Host.UI.RawUI.WindowTitle = 'JDO x QHT - apps'; $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
New-Item -ItemType Directory -Force (Join-Path $root 'logs') | Out-Null
Start-Transcript (Join-Path $root ('logs\postsetup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')) | Out-Null
$tmp = Join-Path $env:TEMP 'jdo-apps'; New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Ok([string]$t) { Say "  [OK]   $t" 'Green' }
function Bad([string]$t, [string]$fix) { $script:fail++; Say "  [FAIL] $t" 'Red'; if ($fix) { Say "         fix: $fix" 'Yellow' } }

# download with curl (built into Windows, shows progress, follows redirects, retries); PowerShell as a fallback
function Get-Download([string]$Url, [string]$File) {
  Remove-Item $File -Force -ErrorAction SilentlyContinue
  & curl.exe -L --fail --retry 3 --retry-delay 3 --connect-timeout 20 -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -o $File $Url
  if (-not (Test-Path $File) -or (Get-Item $File).Length -lt 100KB) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest $Url -OutFile $File -UseBasicParsing -ErrorAction Stop } catch { }
  }
  (Test-Path $File) -and (Get-Item $File).Length -gt 100KB
}
function Test-Signed([string]$File, [string]$Signer) {
  $s = Get-AuthenticodeSignature $File
  $s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match $Signer
}
function Pin-Taskbar([string]$Lnk) {
  # Windows 10 hides "Pin to taskbar" from scripts; the same Explorer command, called through a temporary verb
  $h = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CommandStore\shell\Windows.taskbarpin' -ErrorAction SilentlyContinue).ExplorerCommandHandler
  if (-not $h -or -not (Test-Path $Lnk)) { return $false }
  $k = 'HKCU:\Software\Classes\*\shell\jdopin'
  New-Item $k -Force | Out-Null; Set-ItemProperty $k -Name ExplorerCommandHandler -Value $h
  try { (New-Object -ComObject Shell.Application).Namespace((Split-Path $Lnk)).ParseName((Split-Path $Lnk -Leaf)).InvokeVerb('jdopin') } catch { }
  Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue
  $true
}

Say 'JDO x QHT - installing Brave and AnyDesk, updating the Microsoft Store' 'Magenta'
Say '  (this window closes by itself when it is done)' 'DarkGray'
Say ''
Say '== Internet' 'Magenta'
$online = $false
for ($i = 0; $i -lt 24 -and -not $online; $i++) {
  try { $r = Invoke-WebRequest 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5; $online = $r.Content -match 'Microsoft' } catch { Start-Sleep -Seconds 5 }
}
if (-not $online) {
  Bad 'no internet' 'plug in the network cable - this runs again by itself at the next sign-in'
  Stop-Transcript | Out-Null; Start-Sleep -Seconds 15; return
}
Ok 'connected'

# ---- Brave ----
Say ''; Say '== Brave' 'Magenta'
$braveExe = "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe"
if (-not (Test-Path $braveExe)) {
  $f = Join-Path $tmp 'BraveSetup.exe'
  if (-not (Get-Download 'https://laptop-updates.brave.com/latest/winx64' $f)) { Bad 'Brave download' 'brave.com/download' }
  elseif (-not (Test-Signed $f 'Brave Software')) { Bad 'Brave installer signature is not valid - not run' 'download it from brave.com'; Remove-Item $f -Force }
  else {
    Say '  installing (up to 5 minutes)...'
    $p = Start-Process $f -ArgumentList '/silent', '/install' -PassThru
    for ($i = 0; $i -lt 300 -and -not (Test-Path $braveExe); $i++) { Start-Sleep -Seconds 1 }
    if (Test-Path $braveExe) { Ok 'Brave installed' } else { Bad 'Brave did not finish installing' 'run C:\JDO\JDO-Apps.cmd > 2' }
  }
} else { Ok 'Brave already installed' }
if (Test-Path $braveExe) {
  $lnk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Brave.lnk'
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath = $braveExe; $s.WorkingDirectory = Split-Path $braveExe; $s.Save()
  Ok 'Brave on the desktop'
  Say '  making Brave light (no Safe Browsing / bloat, memory saver, English only, hardware acceleration off)...' 'Cyan'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'JDO-Tools.ps1') -Slim Brave | Out-Null
  Ok 'Brave is light'
  $startLnk = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Brave.lnk'
  if (-not (Test-Path $startLnk)) { Copy-Item $lnk $startLnk -Force }
  if (Pin-Taskbar $startLnk) { Ok 'Brave on the taskbar' } else { Bad 'Brave not pinned' 'right-click Brave on the desktop > Pin to taskbar' }
}

# ---- AnyDesk ----
Say ''; Say '== AnyDesk' 'Magenta'
$adExe = "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe"
if (-not (Test-Path $adExe)) {
  $f = Join-Path $tmp 'AnyDesk.exe'
  if (-not (Get-Download 'https://download.anydesk.com/AnyDesk.exe' $f)) { Bad 'AnyDesk download' 'anydesk.com/download' }
  elseif (-not (Test-Signed $f 'AnyDesk|philandro')) { Bad 'AnyDesk signature is not valid - not run' 'download it from anydesk.com'; Remove-Item $f -Force }
  else {
    $p = Start-Process $f -ArgumentList '--install', "`"${env:ProgramFiles(x86)}\AnyDesk`"", '--silent', '--create-shortcuts', '--create-desktop-icon' -PassThru
    [void]$p.WaitForExit(180000)
    if (Test-Path $adExe) { Ok 'AnyDesk installed (desktop icon)' } else { Bad 'AnyDesk did not install' 'run C:\JDO\JDO-Apps.cmd > AnyDesk' }
  }
} else { Ok 'AnyDesk already installed' }
if (Test-Path $adExe) {
  $lnk = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'AnyDesk.lnk'
  if (-not (Test-Path $lnk) -and -not (Test-Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'AnyDesk.lnk'))) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath = $adExe; $s.Save()
  }
  # its background service only runs while AnyDesk is open: no extra process at idle
  if (Get-Service AnyDesk -ErrorAction SilentlyContinue) { Set-Service AnyDesk -StartupType Manual -ErrorAction SilentlyContinue; Ok 'AnyDesk service: only when AnyDesk is open (no idle process)' }
}

# ---- Microsoft Store: update the Store and its apps ----
Say ''; Say '== Microsoft Store update' 'Magenta'
try {
  $r = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
       Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop
  Ok 'Store and Store apps: update started (they update in the background, a few minutes)'
} catch { Bad "Store update scan ($($_.Exception.Message))" 'open the Store > Library > Get updates' }

Say ''
if ($fail -eq 0) {
  Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'JDO x QHT apps' -ErrorAction SilentlyContinue
  New-Item -ItemType File (Join-Path $root 'postsetup.done') -Force | Out-Null
  Say '== All done. This window closes in 20 seconds.' 'Green'
} else {
  Say "== $fail step(s) failed - see the fixes above. This runs again at the next sign-in." 'Yellow'
}
Say '   NVIDIA: after installing the driver, run desktop folder JDO x QHT > 2 - Tweaks once (full GPU clock).' 'DarkGray'
Stop-Transcript | Out-Null
Start-Sleep -Seconds 20
