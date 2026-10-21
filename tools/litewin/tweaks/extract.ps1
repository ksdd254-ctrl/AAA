# Pulls the tweak scripts out of other Windows builds (FoxOS, SharawyOS, SapphireOS...) for review / merging.
# Copies only scripts and small config files - never runs anything from them.
# Usage: powershell -ExecutionPolicy Bypass -File extract.ps1 -Iso <iso> [-Out 'E:\win 10 JDO\iso-tweaks']
param([Parameter(Mandatory=$true)][string[]]$Iso, [string]$Out = 'E:\win 10 JDO\iso-tweaks')
$ErrorActionPreference = 'Continue'
$7z = "$env:ProgramFiles\7-Zip\7z.exe"
$want = '\.(cmd|bat|ps1|psm1|reg|vbs|xml|ini|pow|nip|txt|json|au3|ahk)$'
foreach ($i in $Iso) {
  $name = [IO.Path]::GetFileNameWithoutExtension($i)
  $dst = Join-Path $Out $name
  New-Item -ItemType Directory -Force "$dst\iso", "$dst\image" | Out-Null
  "== $name" | Write-Host
  # ISO itself: everything outside boot / efi / setup binaries
  $isoList = & $7z l -ba -slt $i | Select-String '^Path = ' | ForEach-Object { $_.Line.Substring(7) }
  $isoPick = $isoList | Where-Object { $_ -match $want -and $_ -notmatch '^(boot|efi|support)\\|^sources\\(?!\$OEM\$)[^\\]+\\' }
  if ($isoPick) { $isoPick | Set-Content "$dst\iso-list.txt"; & $7z x $i "-o$dst\iso" "@$dst\iso-list.txt" -y -bso0 -bsp0 | Out-Null }
  # install image: pull it out once, then only the scripts / configs outside the stock Windows folders
  $img = $isoList | Where-Object { $_ -match '^sources\\install\.(wim|esd|swm)$' } | Select-Object -First 1
  if (-not $img) { continue }
  $local = Join-Path $dst (Split-Path $img -Leaf)
  if (-not (Test-Path $local)) { & $7z e $i $img "-o$dst" -y -bso0 -bsp0 | Out-Null }
  $all = & $7z l -ba -slt $local | Select-String '^Path = ' | ForEach-Object { $_.Line.Substring(7) }
  $all | Set-Content "$dst\image-all.txt"
  $pick = $all | Where-Object { $_ -match $want -and (
      $_ -match '(^|\\)Windows\\Setup\\' -or $_ -match '(^|\\)Users\\[^\\]+\\(Desktop|AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup)\\' -or
      $_ -match '(^|\\)ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\StartUp\\' -or
      $_ -notmatch '^(\d+\\)?(Windows|Program Files|Program Files \(x86\)|ProgramData|Users|\$Recycle\.Bin|PerfLogs|Recovery|System Volume Information)\\' ) -and
      $_ -notmatch '(^|\\)Windows\\(WinSxS|servicing|System32|SysWOW64)\\' }
  $pick | Set-Content "$dst\image-list.txt"
  if ($pick) { & $7z x $local "-o$dst\image" "@$dst\image-list.txt" -y -bso0 -bsp0 | Out-Null }
  Write-Host "  iso files: $(@($isoPick).Count)  image files: $(@($pick).Count)"
}
'done' | Set-Content (Join-Path $Out 'extract.done')

