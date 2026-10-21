# JDO x QHT - app installer menu. Press a number: the official installer downloads (progress shown) and installs by itself.
# Official download addresses only; every installer's signature is checked before it runs. Each install has a time limit
# and is checked afterwards (the program file must exist), so one installer can never hang the menu.
# Voicemeeter and the NVIDIA apps change their download links with every version, so for those the official page opens.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
  return
}
try { $Host.UI.RawUI.WindowTitle = 'JDO x QHT - apps'; $Host.UI.RawUI.BackgroundColor = 'Black' } catch { }
New-Item -ItemType Directory -Force (Join-Path $root 'logs') | Out-Null
Start-Transcript (Join-Path $root ('logs\apps-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')) | Out-Null
$tmp = Join-Path $env:TEMP 'jdo-apps'; New-Item -ItemType Directory -Force $tmp | Out-Null
$pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}

$apps = [ordered]@{
  '1' = @{ n = 'Google Chrome'; u = 'https://dl.google.com/chrome/install/ChromeStandaloneSetup64.exe'; f = 'chrome.exe'; a = '/silent /install'; s = 'Google'
           done = @("$pf\Google\Chrome\Application\chrome.exe", "$pf86\Google\Chrome\Application\chrome.exe") }
  '2' = @{ n = 'Brave'; u = 'https://laptop-updates.brave.com/latest/winx64'; f = 'brave.exe'; a = '/silent /install'; s = 'Brave Software'
           done = @("$pf\BraveSoftware\Brave-Browser\Application\brave.exe") }
  '3' = @{ n = 'Epic Games Launcher'; u = 'https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi'; f = 'epic.msi'; a = '/qb /norestart'; s = 'Epic Games'
           done = @("$pf86\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe", "$pf\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe") }
  '4' = @{ n = 'Discord'; u = 'https://discord.com/api/downloads/distributions/app/installers/latest?channel=stable&platform=win&arch=x64'; f = 'discord.exe'; a = '-s'; s = 'Discord'
           done = @("$env:LOCALAPPDATA\Discord\Update.exe") }
  '5' = @{ n = 'AnyDesk'; u = 'https://download.anydesk.com/AnyDesk.exe'; f = 'anydesk.exe'; a = "--install `"$pf86\AnyDesk`" --silent --create-shortcuts --create-desktop-icon"; s = 'AnyDesk|philandro'
           done = @("$pf86\AnyDesk\AnyDesk.exe") }
  '6' = @{ n = 'NVIDIA App (driver + NVIDIA Broadcast inside it)'; page = 'https://www.nvidia.com/en-us/software/nvidia-app/'; done = @("$pf\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe") }
  '7' = @{ n = 'NVIDIA Broadcast'; page = 'https://www.nvidia.com/en-us/geforce/broadcasting/broadcast-app/'; done = @("$pf\NVIDIA Corporation\NVIDIA Broadcast\NVIDIA Broadcast UI.exe") }
  '8' = @{ n = 'Voicemeeter Potato (VB-Audio)'; page = 'https://vb-audio.com/Voicemeeter/potato.htm'; done = @("$pf86\VB\Voicemeeter\voicemeeter8x64.exe", "$pf86\VB\Voicemeeter\voicemeeter8.exe") }
  '9' = @{ n = 'Voicemeeter Banana (VB-Audio)'; page = 'https://vb-audio.com/Voicemeeter/banana.htm'; done = @("$pf86\VB\Voicemeeter\voicemeeterpro_x64.exe", "$pf86\VB\Voicemeeter\voicemeeterpro.exe") }
}

function Get-Download([string]$Url, [string]$File) {
  Remove-Item $File -Force -ErrorAction SilentlyContinue
  & curl.exe -L --fail --retry 3 --retry-delay 3 --connect-timeout 20 -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -o $File $Url
  if (-not (Test-Path $File) -or (Get-Item $File).Length -lt 100KB) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest $Url -OutFile $File -UseBasicParsing -ErrorAction Stop } catch { }
  }
  (Test-Path $File) -and (Get-Item $File).Length -gt 100KB
}
# every app from this menu gets a desktop shortcut once it is installed - also the ones installed from their web page
# (NVIDIA App, Broadcast, Voicemeeter): the menu checks again each time it is shown
function Add-DesktopShortcuts {
  $pub = [Environment]::GetFolderPath('CommonDesktopDirectory'); $usr = [Environment]::GetFolderPath('Desktop')
  $sh = New-Object -ComObject WScript.Shell
  $have = @(Get-ChildItem $pub, $usr -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object { try { $sh.CreateShortcut($_.FullName).TargetPath } catch { } })
  foreach ($a in $apps.Values) {
    $exe = $a.done | Where-Object { $_ -like '*.exe' -and $_ -notlike '*Update.exe' -and (Test-Path $_) } | Select-Object -First 1
    if ($a.n -eq 'Discord' -and (Test-Path "$env:LOCALAPPDATA\Discord\Update.exe")) { $exe = "$env:LOCALAPPDATA\Discord\Update.exe" }
    if (-not $exe -or ($have -contains $exe)) { continue }
    $name = ($a.n -replace '\s*\(.*\)', '').Trim()
    $l = $sh.CreateShortcut((Join-Path $pub "$name.lnk"))
    $l.TargetPath = $exe; $l.WorkingDirectory = Split-Path $exe
    if ($a.n -eq 'Discord') { $l.Arguments = '--processStart Discord.exe'; $l.IconLocation = "$env:LOCALAPPDATA\Discord\app.ico,0" }
    $l.Save(); Write-Host "  desktop shortcut added: $name" -ForegroundColor Green
  }
}
function Open-Page([string]$Url) {
  $b = @("$pf\BraveSoftware\Brave-Browser\Application\brave.exe", "$pf\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($b) { Start-Process $b $Url } else { Write-Host "  No browser yet - install Brave (2) or Chrome (1) first. Page: $Url" -ForegroundColor Yellow }
}
function Install-App($a) {
  if ($a.page) { Write-Host "  Opening the official page: $($a.page)"; Write-Host '  After it installs, come back here and press Enter: the desktop shortcut is added by itself.' -ForegroundColor DarkGray; Open-Page $a.page; return }
  if ($a.done | Where-Object { Test-Path $_ }) { Write-Host "  [OK]   $($a.n) is already installed" -ForegroundColor Green; return }
  $file = Join-Path $tmp $a.f
  Write-Host "  Downloading $($a.n) ..." -ForegroundColor Cyan
  if (-not (Get-Download $a.u $file)) { Write-Host "  [FAIL] download - check the internet connection, then try again" -ForegroundColor Red; return }
  $sig = Get-AuthenticodeSignature $file
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $a.s) { Write-Host "  [FAIL] signature not valid ($($sig.Status)) - deleted, not run" -ForegroundColor Red; Remove-Item $file -Force; return }
  Write-Host "  signed by: $($sig.SignerCertificate.Subject.Split(',')[0])" -ForegroundColor DarkGray
  Write-Host '  Installing (up to 5 minutes) ...'
  $p = if ($file -like '*.msi') { Start-Process msiexec.exe -ArgumentList "/i `"$file`" $($a.a)" -PassThru } else { Start-Process $file -ArgumentList $a.a -PassThru }
  # some installers leave an updater running: wait for the program file, not for every child process
  for ($i = 0; $i -lt 300; $i++) { if ($a.done | Where-Object { Test-Path $_ }) { break }; if ($p.HasExited -and $i -gt 20) { break }; Start-Sleep -Seconds 1 }
  if ($a.done | Where-Object { Test-Path $_ }) { Write-Host "  [OK]   $($a.n) installed" -ForegroundColor Green; Add-DesktopShortcuts }
  else { Write-Host "  [FAIL] $($a.n) did not finish (exit code $(if ($p.HasExited) { $p.ExitCode } else { 'still running' })) - restart and try again" -ForegroundColor Red }
}

while ($true) {
  Clear-Host
  Add-DesktopShortcuts
  Write-Host '  JDO x QHT - Apps' -ForegroundColor Magenta
  Write-Host '  ----------------' -ForegroundColor DarkGray
  foreach ($k in $apps.Keys) {
    $a = $apps[$k]; $st = if ($a.done -and ($a.done | Where-Object { Test-Path $_ })) { '  (installed)' } elseif ($a.page) { '  (opens the official page)' } else { '' }
    Write-Host ('  {0}  {1}{2}' -f $k, $a.n, $st)
  }
  Write-Host '  A  Install 1 to 5 (Chrome, Brave, Epic, Discord, AnyDesk)'
  Write-Host '  0  Exit'
  $c = Read-Host '  Choose'
  Write-Host ''
  if ($c -eq '0') { Stop-Transcript | Out-Null; return }
  if ($c -eq 'A' -or $c -eq 'a') { foreach ($k in '1', '2', '3', '4', '5') { Install-App $apps[$k] } }
  elseif ($apps.Contains($c)) { Install-App $apps[$c] }
  Write-Host ''
  Write-Host '  After installing apps: JDO Tools > 16 (priorities) once. After the NVIDIA driver: 2 - Tweaks once.' -ForegroundColor DarkGray
  Read-Host '  Press Enter'
}
