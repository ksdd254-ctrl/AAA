# Extracts the tweak scripts of many Windows builds into E:\win 10 JDO\iso-tweaks\<name>\ (scripts and small configs only).
# Nothing from those systems is run. Usage: powershell -File extract-all.ps1
$ErrorActionPreference = 'Continue'
$out = 'E:\win 10 JDO\iso-tweaks'
$7z = "$env:ProgramFiles\7-Zip\7z.exe"
$d = Get-ChildItem 'E:\' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'New folder (3)' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1   # (the folder name is Arabic: found, not typed)
$dl = 'E:\Users\1\Downloads'
$isos = @("$d\SkiiOS Finale.iso", "$d\Win11Pro SHBA7x Gaming.iso", "$d\XdzlOS 11 23H2 V9.iso", "$d\KernelOS11 25H2 AiOv1.6.2 (IoT Edition).iso",
  "$d\KirbyOS10-22H2_19045.7663_9CD353AD45D395819FF7FBAA595957F7B6905953833A6AEBF759E606B15CF882.ISO", "$d\LuminV2 Full (v2.52).iso",
  "$d\KernelOS10 22H2 AiOv1.5.1 (IoT Edition).iso", "$dl\blitzosv1.3.0-W10-21H2.iso")
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# X-Lite: a .7z that holds an ISO
$xl = "$dl\[Windows X-Lite] Micro 10 (FBConan).7z"
if (Test-Path -LiteralPath $xl) {
  $tmp = "$out\_xlite"; New-Item -ItemType Directory -Force $tmp | Out-Null
  & $7z e -LiteralPath $xl '*.iso' "-o$tmp" -y -bso0 -bsp0 2>$null
  if (-not (Get-ChildItem $tmp -Filter *.iso)) { & $7z e $xl '*.iso' -r "-o$tmp" -y -bso0 -bsp0 }
  $isos += (Get-ChildItem $tmp -Filter *.iso | Select-Object -First 1).FullName
}
foreach ($i in $isos) {
  if (-not $i -or -not (Test-Path -LiteralPath $i)) { Write-Host "missing $i"; continue }
  Write-Host "=== $i"
  & $here\extract.ps1 -Iso $i -Out $out
}
# FSOS playbook (AME Wizard, standard public archive password)
$ap = "$d\FSOS-XR10-hotfix.apbx"
if (Test-Path -LiteralPath $ap) {
  New-Item -ItemType Directory -Force "$out\FSOS-XR10-hotfix\apbx" | Out-Null
  & $7z x $ap "-o$out\FSOS-XR10-hotfix\apbx" -pmalte -y -bso0 -bsp0 -x'!Executables'
}
'done' | Set-Content "$out\extract-all.done"
