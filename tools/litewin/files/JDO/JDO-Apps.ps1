# JDO x QHT - app installer menu. Press a number: the official installer downloads and installs by itself.
# Only official download addresses. Every installer's Microsoft-style signature is checked before it runs.
# Voicemeeter and the NVIDIA apps change their download links all the time, so for those the official page opens.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force (Join-Path $root 'logs') | Out-Null
Start-Transcript (Join-Path $root ('logs\apps-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')) | Out-Null
$tmp = Join-Path $env:TEMP 'jdo-apps'; New-Item -ItemType Directory -Force $tmp | Out-Null

$apps = [ordered]@{
  '1' = @{ n = 'Google Chrome';      u = 'https://dl.google.com/chrome/install/ChromeStandaloneSetup64.exe'; f = 'chrome.exe'; a = '/silent /install' }
  '2' = @{ n = 'Brave';              u = 'https://laptop-updates.brave.com/latest/winx64'; f = 'brave.exe'; a = '/silent /install' }
  '3' = @{ n = 'Epic Games Launcher'; u = 'https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi'; f = 'epic.msi'; a = '/qb /norestart' }
  '4' = @{ n = 'Discord';            u = 'https://discord.com/api/downloads/distributions/app/installers/latest?channel=stable&platform=win&arch=x64&format=exe'; f = 'discord.exe'; a = '' }
  '5' = @{ n = 'NVIDIA App (also installs NVIDIA Broadcast from inside it)'; page = 'https://www.nvidia.com/en-us/software/nvidia-app/' }
  '6' = @{ n = 'NVIDIA Broadcast';   page = 'https://www.nvidia.com/en-us/geforce/broadcasting/broadcast-app/' }
  '7' = @{ n = 'Voicemeeter Potato (VB-Audio)'; page = 'https://vb-audio.com/Voicemeeter/potato.htm' }
  '8' = @{ n = 'Voicemeeter Banana (VB-Audio)'; page = 'https://vb-audio.com/Voicemeeter/banana.htm' }
}

function Install-App($a) {
  if ($a.page) { Write-Host "  Opening the official page: $($a.page)"; Start-Process $a.page; return }
  $file = Join-Path $tmp $a.f
  Write-Host "  Downloading $($a.n) ..."
  try { Invoke-WebRequest -Uri $a.u -OutFile $file -UseBasicParsing -ErrorAction Stop }
  catch { Write-Host "  Download failed ($($_.Exception.Message)). Opening the browser instead." -ForegroundColor Yellow; Start-Process $a.u; return }
  $sig = Get-AuthenticodeSignature $file
  if ($sig.Status -ne 'Valid') { Write-Host "  The file's signature is not valid ($($sig.Status)) - NOT installed. Deleted." -ForegroundColor Red; Remove-Item $file -Force; return }
  Write-Host "  Signed by: $($sig.SignerCertificate.Subject.Split(',')[0])"
  Write-Host '  Installing ...'
  if ($file -like '*.msi') { Start-Process msiexec.exe -ArgumentList "/i `"$file`" $($a.a)" -Wait }
  elseif ($a.a) { Start-Process $file -ArgumentList $a.a -Wait } else { Start-Process $file -Wait }
  Write-Host "  $($a.n): done" -ForegroundColor Green
}

while ($true) {
  Clear-Host
  Write-Host '  JDO x QHT - Apps' -ForegroundColor Cyan
  Write-Host '  ----------------'
  foreach ($k in $apps.Keys) { Write-Host ('  {0}  {1}' -f $k, $apps[$k].n) }
  Write-Host '  9  Install 1 to 4 (Chrome, Brave, Epic, Discord)'
  Write-Host '  0  Exit'
  $c = Read-Host '  Choose'
  Write-Host ''
  if ($c -eq '0') { Stop-Transcript | Out-Null; return }
  if ($c -eq '9') { foreach ($k in '1', '2', '3', '4') { Install-App $apps[$k] } }
  elseif ($apps.Contains($c)) { Install-App $apps[$c] }
  Write-Host '  After installing apps, run JDO Tools option 16 (priorities) once.' -ForegroundColor DarkGray
  Read-Host '  Press Enter'
}
