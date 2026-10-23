# JDO x QHT - image tests (no VM needed)
# Applies the built install.esd and the stock edition from the official ISO to folders, then checks:
#   network untouched (every network service / driver / policy key equal to stock), drivers, apps, files, tweaks,
#   side-by-side assemblies, auto-start services -> process estimate, and the ISO layout.
# Usage (as admin, outside the Claude app sandbox): powershell -ExecutionPolicy Bypass -File test.ps1 -Iso C:\Users\1\Desktop\Windows.iso
param(
  [Parameter(Mandatory=$true)][string]$Iso,
  [string]$Work = 'E:\win 10 JDO',
  [string]$Edition = 'Windows 10 Pro',
  [string]$LiteIsoFile,     # the ISO to check (default: JDO_x_QHT_W10_22H2.iso / _W11_23H2.iso)
  [switch]$NoApply,          # reuse the folders a previous run applied
  [switch]$Win11             # Windows 11 23H2 build (work folder E:\win 11 JDO, edition Windows 11 Pro)
)
#Requires -RunAsAdministrator
if ($Win11) {
  if (-not $PSBoundParameters.ContainsKey('Work')) { $Work = 'E:\win 11 JDO' }
  if (-not $PSBoundParameters.ContainsKey('Edition')) { $Edition = 'Windows 11 Pro' }
}
$tag = if ($Win11) { 'W11_23H2' } else { 'W10_22H2' }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$lite  = Join-Path $Work 'test\lite'
$stock = Join-Path $Work 'test\stock'
$out   = Join-Path $Work 'test\report.txt'
$liteIso = if ($LiteIsoFile) { $LiteIsoFile } else { Join-Path $Work "JDO_x_QHT_$tag.iso" }
$fail = 0; $pass = 0; $lines = New-Object System.Collections.Generic.List[string]
function Say([string]$t) { Write-Host $t; $lines.Add($t) }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Say "  PASS  $name" } else { $script:fail++; Say "  FAIL  $name  $detail" }
}

# ---------------- apply ----------------
# hives a previous run left loaded keep the folders' files open (DISM apply then fails with error 32)
foreach ($h in 'T_LSYS', 'T_LSW', 'T_LUSR', 'T_SSYS', 'T_SSW') {
  if (Test-Path "Registry::HKEY_LOCAL_MACHINE\$h") { [gc]::Collect(); & reg.exe unload "HKLM\$h" | Out-Null }
}
if (-not $NoApply) {
foreach ($d in $lite, $stock) {
  # Windows 11 app folders go past 260 characters (Widgets node_modules): the \\?\ form and an empty robocopy mirror reach them
  if (Test-Path -LiteralPath $d) { & cmd.exe /c rd /s /q "`"\\?\$d`"" 2>$null }
  if (Test-Path -LiteralPath $d) { $e = Join-Path $Work 'test\empty'; New-Item -ItemType Directory -Force $e | Out-Null; & robocopy.exe $e $d /MIR /NFL /NDL /NJH /NJS /R:0 /W:0 | Out-Null; & cmd.exe /c rd /s /q "`"\\?\$d`"" 2>$null; & cmd.exe /c rd /s /q "`"$e`"" }
  if (Test-Path $d) { throw "could not clear $d (a file in it is still open)" }
  New-Item -ItemType Directory -Force $d | Out-Null
}
Say '== applying the lite image'
& dism.exe /Apply-Image "/ImageFile:$Work\iso\sources\install.esd" /Index:1 "/ApplyDir:$lite" /Quiet
if ($LASTEXITCODE -ne 0) { throw "apply lite failed $LASTEXITCODE" }
Say '== applying the stock edition from the source ISO'
$tmp = Join-Path $Work 'test\stockiso'
& "$env:ProgramFiles\7-Zip\7z.exe" e $Iso 'sources\install.esd' 'sources\install.wim' "-o$tmp" -y -bso0 -bsp0
$img = Get-ChildItem $tmp -Filter 'install.*' | Select-Object -First 1
$idx = (Get-WindowsImage -ImagePath $img.FullName | Where-Object ImageName -eq $Edition).ImageIndex
& dism.exe /Apply-Image "/ImageFile:$($img.FullName)" "/Index:$idx" "/ApplyDir:$stock" /Quiet
if ($LASTEXITCODE -ne 0) { throw "apply stock failed $LASTEXITCODE" }
Remove-Item -LiteralPath $tmp -Recurse -Force
}

foreach ($h in 'T_LSYS', 'T_LSW', 'T_LUSR', 'T_SSYS', 'T_SSW') { if (Test-Path "Registry::HKEY_LOCAL_MACHINE\$h") { [gc]::Collect(); & reg.exe unload "HKLM\$h" | Out-Null } }
foreach ($l in @(@('T_LSYS', "$lite\Windows\System32\config\SYSTEM"), @('T_LSW', "$lite\Windows\System32\config\SOFTWARE"),
                 @('T_LUSR', "$lite\Users\Default\NTUSER.DAT"), @('T_SSYS', "$stock\Windows\System32\config\SYSTEM"),
                 @('T_SSW', "$stock\Windows\System32\config\SOFTWARE"))) {
  & reg.exe load "HKLM\$($l[0])" $l[1] | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path "Registry::HKEY_LOCAL_MACHINE\$($l[0])\*")) { throw "could not load $($l[1]) as $($l[0])" }
}
try {
  # every value under a key; sub-keys the ACL hides (NetworkSetup2...) are skipped on both sides alike
  function Flat([string]$root) {
    $h = @{}
    if (-not (Test-Path $root)) { return $h }
    try { $start = Get-Item $root -ErrorAction Stop } catch { return @{ '(unreadable)' = 'acl' } }
    $base = $start.Name.Length
    $stack = New-Object System.Collections.Stack; $stack.Push($start)
    while ($stack.Count) {
      $k = $stack.Pop()
      foreach ($v in $k.GetValueNames()) {
        $val = $k.GetValue($v, $null, 'DoNotExpandEnvironmentNames'); if ($val -is [array]) { $val = $val -join ',' }
        $h[$k.Name.Substring($base) + '\' + $v] = "$val"
      }
      foreach ($n in $k.GetSubKeyNames()) { try { $c = $k.OpenSubKey($n); if ($c) { $stack.Push($c) } } catch { } }
    }
    $h
  }
  function Same([string]$a, [string]$b) {
    $x = Flat $a; $y = Flat $b
    @($x.Keys + $y.Keys | Sort-Object -Unique | Where-Object { $x[$_] -ne $y[$_] } | ForEach-Object { "$_ stock=[$($y[$_])] lite=[$($x[$_])]" })
  }
  $LiteCS = 'HKLM:\T_LSYS\ControlSet001'; $StockCS = 'HKLM:\T_SSYS\ControlSet001'

  # ---------------- 1. network: identical to stock ----------------
  Say '== 1. network is exactly stock'
  $netSvc = 'Tcpip','Tcpip6','TCPIP6TUNNEL','tcpipreg','AFD','afunix','NetBT','NDIS','NdisCap','NdisVirtualBus','NdisWan','Ndisuio','nsiproxy',
            'Dhcp','Dnscache','NlaSvc','nsi','netprofm','NcbService','NcaSvc','NcdAutoSetup','Netman','Netlogon','WinHttpAutoProxySvc',
            'wcncsvc','WwanSvc','icssvc','mpssvc','BFE','mpsdrv','SharedAccess','iphlpsvc','IpxlatCfgSvc',
            'upnphost','FDResPub','fdPHost','RemoteAccess',
            'WinRM','Dot3Svc','QWAVE','Psched','lltdsvc','rspndr','mrxsmb','mrxsmb20','srv2','srvnet',
            'bowser','rdbss','AJRouter','ALG','WinNat','vwififlt','WFPLWFS'
  foreach ($s in $netSvc) {
    $d = Same "$LiteCS\Services\$s" "$StockCS\Services\$s"
    # XdzlOS (the Windows 11 base) added EnableICMPRedirect=0; the build takes it out again (Windows ships without it)
    if ($Win11) { $d = @($d | Where-Object { $_ -notmatch '^\\Parameters\\EnableICMPRedirect stock=\[0\] lite=\[\]$' }) }
    Check "service $s" ($d.Count -eq 0) ($d -join '; ')
  }
  foreach ($k in 'Control\Network', 'Control\NetworkSetup2', 'Control\Nsi') {
    $d = @(Same "$LiteCS\$k" "$StockCS\$k" | Where-Object { $_ -notmatch '^\\NewNetworkWindowOff\\' }); Check $k ($d.Count -eq 0) ($d -join '; ')   # NewNetworkWindowOff: hides the 'discoverable?' question only
  }
  foreach ($k in 'Policies\Microsoft\Windows\DeliveryOptimization', 'Policies\Microsoft\WindowsFirewall', 'Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator',
                 'Policies\Microsoft\Windows\WcmSvc', 'Policies\Microsoft\Windows NT\DNSClient', 'Microsoft\Windows\CurrentVersion\Internet Settings',
                 'Microsoft\Windows NT\CurrentVersion\NetworkList', 'Microsoft\WcmSvc') {
    $d = Same "HKLM:\T_LSW\$k" "HKLM:\T_SSW\$k"; Check "SOFTWARE\$k" ($d.Count -eq 0) ($d -join '; ')
  }
  $mm = 'Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
  Check 'NetworkThrottlingIndex untouched' ((Get-ItemProperty "HKLM:\T_LSW\$mm").NetworkThrottlingIndex -eq (Get-ItemProperty "HKLM:\T_SSW\$mm").NetworkThrottlingIndex)
  $stockNet = Get-ChildItem "$stock\Windows\System32\DriverStore\FileRepository" -Directory | Where-Object Name -match '^net' | ForEach-Object Name
  $liteNet  = Get-ChildItem "$lite\Windows\System32\DriverStore\FileRepository" -Directory | Where-Object Name -match '^net' | ForEach-Object Name
  $missing = $stockNet | Where-Object { $liteNet -notcontains $_ }
  Check "all $($stockNet.Count) inbox network drivers kept (wired + Wi-Fi)" (-not $missing) ($missing -join ', ')

  # ---------------- 2. hardware identity ----------------
  Say '== 2. no serial / identity changes'
  foreach ($k in 'Control\IDConfigDB', 'Control\ComputerName', 'Control\SystemInformation', 'Enum') {
    $d = Same "$LiteCS\$k" "$StockCS\$k"; Check $k ($d.Count -eq 0) ("$($d.Count) differences")
  }
  foreach ($v in 'MachineGuid') { Check "Cryptography\$v" ((Get-ItemProperty 'HKLM:\T_LSW\Microsoft\Cryptography').$v -eq (Get-ItemProperty 'HKLM:\T_SSW\Microsoft\Cryptography').$v) }

  # ---------------- 3. drivers ----------------
  Say '== 3. drivers'
  Check 'Realtek 2.5GbE driver (rt640x64) in the driver store' ([bool](Get-ChildItem "$lite\Windows\System32\DriverStore\FileRepository" -Directory -Filter 'rt640x64.inf_*'))
  Check 'Xbox controller driver (xusb22)' ([bool](Get-ChildItem "$lite\Windows\System32\DriverStore\FileRepository" -Directory -Filter 'xusb22.inf_*'))
  Check 'HID game controllers (input.inf / hidserv)' ([bool](Get-ChildItem "$lite\Windows\System32\DriverStore\FileRepository" -Directory -Filter 'input.inf_*'))
  Check 'NVMe storage driver' (Test-Path "$lite\Windows\System32\drivers\stornvme.sys")
  Check 'USB audio (headset)' (Test-Path "$lite\Windows\System32\drivers\usbaudio.sys")
  Check 'webcam driver (usbvideo) in the driver store' ([bool](Get-ChildItem "$lite\Windows\System32\DriverStore\FileRepository" -Directory -Filter 'usbvideo.inf_*'))
  Check 'C:\JDO\Drivers has the network driver' ([bool](Get-ChildItem "$lite\JDO\Drivers" -Recurse -Filter rt640x64.inf -ErrorAction SilentlyContinue))

  # ---------------- 4. apps / shell / store ----------------
  Say '== 4. Store included; shell, keyboard, fonts'
  foreach ($a in 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller') {
    Check "in the image: app $a" ([bool](Get-ChildItem "$lite\Program Files\WindowsApps" -Directory -Filter "$a*" -ErrorAction SilentlyContinue))
  }
  # the Store needs these: they stay as Windows ships them (only the update medic is off)
  foreach ($s in 'InstallService', 'wlidsvc', 'wuauserv') {
    Check "$s stock in the image" ($null -eq (Compare-Object (Get-ItemProperty "$LiteCS\Services\$s").Start (Get-ItemProperty "$StockCS\Services\$s").Start))
  }
  Check 'WaaSMedicSvc off' ((Get-ItemProperty "$LiteCS\Services\WaaSMedicSvc").Start -eq 4)
  Check 'Update orchestrator off (no MoUSO worker)' ((Get-ItemProperty "$LiteCS\Services\UsoSvc").Start -eq 4)
  Check 'Delivery Optimization off (owner asked)' ((Get-ItemProperty "$LiteCS\Services\DoSvc").Start -eq 4)
  Check 'svchost groups stock (merging CoreMessagingRegistrar = black screen, proven in the VM)' ((((Get-ItemProperty "$LiteCS\Services\AudioEndpointBuilder").ImagePath -match '-k LocalSystemNetworkRestricted') -and ((Get-ItemProperty "$LiteCS\Services\CoreMessagingRegistrar").ImagePath -match '-k LocalServiceNoNetwork')))
  Check 'activation on demand (sppsvc), Hyper-V guest / sensors / PIN off' (((Get-ItemProperty "$LiteCS\Services\sppsvc").Start -eq 3) -and ((Get-ItemProperty "$LiteCS\Services\vmicheartbeat").Start -eq 4) -and ((Get-ItemProperty "$LiteCS\Services\SensorService").Start -eq 4) -and ((Get-ItemProperty "$LiteCS\Services\NgcSvc").Start -eq 4))
  # boot safety: nothing that starts automatically may depend on a service that is disabled or missing, and every
  # svchost group a service names must exist in the group list - either one stops Windows from reaching the desktop
  $badDep = @(); $grp = (Get-ItemProperty 'HKLM:\T_LSW\Microsoft\Windows NT\CurrentVersion\Svchost').PSObject.Properties.Name
  foreach ($sv in Get-ChildItem "$LiteCS\Services") {
    $p = Get-ItemProperty $sv.PSPath
    if ($p.Start -ne 2 -or -not ($p.Type -band 0x30)) { continue }
    foreach ($d in @($p.DependOnService) | Where-Object { $_ }) {
      $dp = Get-ItemProperty "$LiteCS\Services\$d" -ErrorAction SilentlyContinue
      if (-not $dp -or $dp.Start -eq 4) { $badDep += "$($sv.PSChildName) needs $d" }
    }
    if ($p.ImagePath -match 'svchost\.exe\s+-k\s+(\S+)' -and $grp -notcontains $Matches[1]) { $badDep += "$($sv.PSChildName): group $($Matches[1]) not defined" }
  }
  Check 'auto-start services: no disabled / missing dependency, every svchost group defined' ($badDep.Count -eq 0) ($badDep -join '; ')
  $ownerOff = 'DispBrokerDesktopSvc','DsSvc','FontCache3.0.0.0','hidserv','IKEEXT','LanmanServer','LanmanWorkstation','lmhosts','NetTcpPortSharing','PolicyAgent','RasAuto','RasMan','RmSvc','SessionEnv','SstpSvc','TermService','tzautoupdate','UmRdpService','Wcmsvc','Wecsvc','WlanSvc','workfolderssvc','XboxGipSvc'.Split(',')
  Check 'services the owner has disabled on his own PC are off here' (@($ownerOff | Where-Object { $p = Get-ItemProperty "$LiteCS\Services\$_" -ErrorAction SilentlyContinue; $p -and $p.Start -ne 4 }).Count -eq 0) (($ownerOff | Where-Object { $p = Get-ItemProperty "$LiteCS\Services\$_" -ErrorAction SilentlyContinue; $p -and $p.Start -ne 4 }) -join ', ')
  Check 'Snipping Tool removed' (-not (Test-Path "$lite\Windows\System32\SnippingTool.exe"))
  Check 'JDO icons + post-setup in the image' ((Test-Path "$lite\JDO\Icons\tools.ico") -and (Test-Path "$lite\JDO\Icons\folder.ico") -and (Test-Path "$lite\JDO\JDO-PostSetup.ps1"))
  Check 'no background-app block (Start search works)' (-not (Get-ItemProperty 'HKLM:\T_LSW\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction SilentlyContinue).LetAppsRunInBackground)
  Check 'Run / Cancel warning off' ((Get-ItemProperty 'HKLM:\T_LUSR\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments').SaveZoneInformation -eq 1)
  Check 'JDO x QHT runs after the desktop' ((Test-Path "$lite\JDO\JDO-x-QHT.ps1") -and (Test-Path "$lite\JDO\JDO-x-QHT.cmd") -and ((Get-ItemProperty 'HKLM:\T_LSW\Microsoft\Windows\CurrentVersion\Run').'JDO x QHT' -like '*JDO-x-QHT.cmd*'))
  Check 'Open-Shell installer is in the image (C:\JDO\Apps)' ((Get-Item "$lite\JDO\Apps\OpenShellSetup.exe" -ErrorAction SilentlyContinue).Length -gt 5MB)
  Check 'JDO Tools shortcut starts the menu + Start menu entry' ((Test-Path "$lite\ProgramData\Microsoft\Windows\Start Menu\Programs\JDO Tools.lnk") -and (Test-Path "$lite\Users\Public\Desktop\JDO Tools.lnk"))
  Check 'Windows Update policy in the image' ((Get-ItemProperty 'HKLM:\T_LSW\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue).NoAutoUpdate -eq 1)
  Check 'first boot no longer touches services' (-not (Select-String -LiteralPath "$lite\Windows\Setup\Scripts\firstboot.ps1" -SimpleMatch "Run-Step '-Services'" -Quiet))
  foreach ($a in 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.XboxIdentityProvider', 'Microsoft.NET.Native.Framework.2.2', 'Microsoft.VCLibs.140.00') {
    Check "saved copy for JDO-Tools 18: $a" ([bool](Get-ChildItem "$lite\JDO\Store" -Directory -Filter "${a}_*" -ErrorAction SilentlyContinue | Where-Object { Test-Path "$($_.FullName)\AppxManifest.xml" }))
  }
  if ($Win11) {
    $adv = Get-ItemProperty 'HKLM:\T_LUSR\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Check 'Windows 11: no Widgets / Chat / Copilot buttons' ((Get-ItemProperty 'HKLM:\T_LSW\Policies\Microsoft\Dsh').AllowNewsAndInterests -eq 0 -and $adv.TaskbarMn -eq 0 -and $adv.ShowCopilotButton -eq 0)
    Check 'Windows 11: Widgets app not in the image' (-not (Get-ChildItem "$lite\Program Files\WindowsApps" -Directory -Filter 'MicrosoftWindows.Client.WebExperience*' -ErrorAction SilentlyContinue))
    Check 'Windows 11: full right-click menu' (Test-Path 'HKLM:\T_LUSR\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32')
    Check 'Windows 11: Smart App Control off' ((Get-ItemProperty "$LiteCS\Control\CI\Policy" -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState -eq 0)
    Check 'Windows 11: typing service can start' ((Get-ItemProperty "$LiteCS\Services\TextInputManagementService").Start -in 2, 3)
    Check 'Windows 11: Start pins file' (Test-Path "$lite\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.json")
    Check 'Windows 11: UBPM trace back on (Task Scheduler triggers)' ((Get-ItemProperty "$LiteCS\Control\WMI\Autologger\UBPM").Start -eq 1)
  }
  Check 'Store pinned on the taskbar' ([bool](Select-String -LiteralPath "$lite\Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml" -SimpleMatch 'WindowsStore' -Quiet))
  # what packaged system apps (Start menu search, Settings, NVIDIA Control Panel) need still starts
  foreach ($s in 'AppXSvc', 'StateRepository', 'ClipSVC', 'LicenseManager') {
    $st = (Get-ItemProperty "$LiteCS\Services\$s" -ErrorAction SilentlyContinue).Start
    Check "packaged apps need $s (Start=$st)" ($st -in 2, 3)
  }
  foreach ($f in 'Windows\explorer.exe', 'Windows\System32\ctfmon.exe', 'Windows\System32\kbda1.dll', 'Windows\System32\kbdus.dll',
                 $(if ($Win11) { 'Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\SearchHost.exe' } else { 'Windows\SystemApps\Microsoft.Windows.Search_cw5n1h2txyewy' }),
                 'Windows\SystemApps\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy',
                 'Windows\SystemApps\ShellExperienceHost_cw5n1h2txyewy', 'Windows\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy',
                 'Windows\SystemApps\Microsoft.Windows.CloudExperienceHost_cw5n1h2txyewy', 'Windows\SystemApps\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy',
                 'Windows\Fonts\segoeui.ttf', 'Windows\Fonts\tahoma.ttf', 'Windows\Fonts\arial.ttf', 'Windows\Fonts\times.ttf', 'Windows\Fonts\micross.ttf',
                 'Windows\Fonts\seguiemj.ttf', 'Windows\Fonts\segmdl2.ttf', 'Windows\System32\d3d12.dll', 'Windows\System32\dxgi.dll',
                 'Windows\System32\XInput1_4.dll', 'Windows\System32\mfplat.dll', 'Windows\System32\Windows.Media.dll') {
    Check $f (Test-Path "$lite\$f")
  }
  foreach ($f in 'Windows\Fonts\msyh.ttc', 'Windows\Fonts\Nirmala.ttf', 'Windows\System32\Recovery\Winre.wim', 'Program Files (x86)\Microsoft\Edge',
                 'Windows\SysWOW64\OneDriveSetup.exe', 'Windows\Web', 'Program Files\Windows Defender') {
    Check "removed: $f" (-not (Test-Path "$lite\$f"))
  }

  # ---------------- 5. side-by-side run-time assemblies ----------------
  Say '== 5. WinSxS run-time assemblies (programs need these)'
  $sxs = "$lite\Windows\WinSxS"
  foreach ($p in 'amd64_microsoft.windows.common-controls_6595b64144ccf1df_6.*', 'x86_microsoft.windows.common-controls_6595b64144ccf1df_6.*',
                 'amd64_microsoft.windows.gdiplus_*', 'x86_microsoft.windows.gdiplus_*') {
    Check "WinSxS $p" ([bool](Get-ChildItem $sxs -Directory -Filter $p -ErrorAction SilentlyContinue))
    Check "manifest $p" ([bool](Get-ChildItem "$sxs\Manifests" -Filter "$p.manifest" -ErrorAction SilentlyContinue))
  }
  Say ('  WinSxS folders left: {0}' -f (Get-ChildItem $sxs -Directory).Count)
  # Windows Setup's offlineServicing pass needs the servicing stack and the manifests (VM install test found this)
  foreach ($p in 'amd64_microsoft-windows-servicingstack_*', 'amd64_microsoft-windows-servicingstack-onecore_*', 'x86_microsoft-windows-servicingstack_*') {
    Check "servicing stack: $p" ([bool](Get-ChildItem $sxs -Directory -Filter $p -ErrorAction SilentlyContinue))
  }
  $stockMan = (Get-ChildItem "$stock\Windows\WinSxS\Manifests" -File -ErrorAction SilentlyContinue).Count
  $liteMan = (Get-ChildItem "$sxs\Manifests" -File -ErrorAction SilentlyContinue).Count
  Check "all component manifests kept ($liteMan of $stockMan)" ($liteMan -ge $stockMan * 0.95)
  # nothing may be waiting for the (removed) servicing stack at first boot, or setup hangs on "Configuring updates"
  $cbs = 'HKLM:\T_LSW\Microsoft\Windows\CurrentVersion\Component Based Servicing'
  Check 'no pending servicing work (pending.xml)' (-not (Test-Path "$sxs\pending.xml"))
  foreach ($k in 'RebootPending', 'PackagesPending', 'RebootInProgress', 'SessionsPending\Exclusive') {
    Check "no CBS $k" (-not (Test-Path "$cbs\$k"))
  }
  Check 'no pending file renames' (-not (Get-ItemProperty "$LiteCS\Control\Session Manager" -ErrorAction SilentlyContinue).PendingFileRenameOperations)
  Check 'TrustedInstaller binary still there (Windows\servicing)' (Test-Path "$lite\Windows\servicing\TrustedInstaller.exe")

  # ---------------- 6. tweaks ----------------
  Say '== 6. tweaks'
  Check 'svchost grouping' ((Get-ItemProperty "$LiteCS\Control").SvcHostSplitThresholdInKB -eq 4294967295)
  Check 'black desktop' ((Get-ItemProperty 'HKLM:\T_LUSR\Control Panel\Colors').Background -eq '0 0 0' -and (Get-ItemProperty 'HKLM:\T_LUSR\Control Panel\Desktop').Wallpaper -eq '')
  Check 'dark mode' ((Get-ItemProperty 'HKLM:\T_LUSR\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').AppsUseLightTheme -eq 0)
  Check 'no lock screen' ((Get-ItemProperty 'HKLM:\T_LSW\Policies\Microsoft\Windows\Personalization').NoLockScreen -eq 1)
  Check 'black sign-in image' (Test-Path "$lite\JDO\black.jpg")
  Check 'Fortnite-ready: Game Mode on, Game DVR off' ((Get-ItemProperty 'HKLM:\T_LUSR\Software\Microsoft\GameBar').AutoGameModeEnabled -eq 1 -and (Get-ItemProperty 'HKLM:\T_LUSR\System\GameConfigStore').GameDVR_Enabled -eq 0)
  Check 'raw mouse' ((Get-ItemProperty 'HKLM:\T_LUSR\Control Panel\Mouse').MouseSpeed -eq '0')
  Check 'UAC on (Store needs it), no prompts' ((Get-ItemProperty 'HKLM:\T_LSW\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA -eq 1 -and (Get-ItemProperty 'HKLM:\T_LSW\Microsoft\Windows\CurrentVersion\Policies\System').ConsentPromptBehaviorAdmin -eq 0)
  Check 'Task Scheduler stock (auto, no trigger)' ((Get-ItemProperty "$LiteCS\Services\Schedule").Start -eq 2 -and -not (Test-Path "$LiteCS\Services\Schedule\TriggerInfo"))
  Check 'Time Broker on demand' ((Get-ItemProperty "$LiteCS\Services\TimeBrokerSvc").Start -eq 3)
  Check 'Appinfo on demand (Run as administrator)' ((Get-ItemProperty "$LiteCS\Services\Appinfo").Start -eq 3)
  foreach ($s in 'WinDefend', 'DiagTrack', 'SysMain', 'WSearch', 'WpnService', 'bthserv', 'Spooler') {
    $p = Get-ItemProperty "$LiteCS\Services\$s" -ErrorAction SilentlyContinue; Check "$s disabled or removed" ($null -eq $p -or $p.Start -eq 4)
  }
  foreach ($s in 'AppXSvc', 'ClipSVC', 'StateRepository', 'TokenBroker', 'LicenseManager', 'BITS', 'CryptSvc', 'Winmgmt',
                 'EventLog', 'Audiosrv', 'AudioEndpointBuilder', $(if ($Win11) { 'TextInputManagementService' } else { 'TabletInputService' }), 'FrameServer') {
    $st = (Get-ItemProperty "$LiteCS\Services\$s" -ErrorAction SilentlyContinue).Start
    Check "$s can start (Start=$st)" ($st -in 2, 3)
  }
  Check 'first boot scripts' ((Test-Path "$lite\Windows\Setup\Scripts\firstboot.ps1") -and (Test-Path "$lite\JDO\JDO-Tools.ps1"))
  $scf = "$lite\Windows\Setup\Scripts\SetupComplete.cmd"
  Check 'SetupComplete.cmd only clears the password-change flag + TrustedInstaller off (no devices / services in the middle of setup)' ((Test-Path $scf) -and ((Get-Content $scf) -match 'net user|wmic useraccount|sc config TrustedInstaller|echo off|exit').Count -eq @(Get-Content $scf).Count)
  Check 'desktop shortcut' (Test-Path "$lite\Users\Public\Desktop\JDO Tools.lnk")
  Check 'first boot applies the JDO Ultimate power plan' ([bool](Select-String -LiteralPath "$lite\Windows\Setup\Scripts\firstboot.ps1" -SimpleMatch "Run-Step '-Power'" -Quiet) -and [bool](Select-String -LiteralPath "$lite\JDO\JDO-Tools.ps1" -SimpleMatch "'JDO Ultimate'" -Quiet))
  Check 'first boot disables unneeded devices' ([bool](Select-String -LiteralPath "$lite\Windows\Setup\Scripts\firstboot.ps1" -SimpleMatch "Run-Step '-Devices'" -Quiet))
  foreach ($f in "$lite\JDO\JDO-Tools.ps1", "$lite\Windows\Setup\Scripts\firstboot.ps1") {
    $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check "script parses: $(Split-Path $f -Leaf)" ($e.Count -eq 0)
  }

  # ---------------- 7. process estimate ----------------
  Say '== 7. process estimate (auto-start services after grouping)'
  $groups = @{}; $own = 0
  foreach ($k in Get-ChildItem "$LiteCS\Services") {
    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    if ($p.Start -ne 2 -or -not $p.ImagePath -or ($p.Type -band 0x30) -eq 0) { continue }   # auto-start Win32 services only
    if ($p.ImagePath -match 'svchost\.exe\s+-k\s+(\S+)') { $groups[$Matches[1]] = 1 } else { $own++ }
  }
  $kernel = 12   # System, Registry, smss, 2x csrss, wininit, winlogon, services, lsass, 2x fontdrvhost, dwm
  $shell = 8     # explorer, sihost, taskhostw, ctfmon, RuntimeBroker, StartMenuExperienceHost, ShellExperienceHost, SearchApp (asleep)
  Say ("  svchost hosts: {0}  own-process services: {1}  -> estimated idle processes about {2}" -f $groups.Count, $own, ($kernel + $shell + $groups.Count + $own))
  Say ('  svchost groups: ' + (($groups.Keys | Sort-Object) -join ', '))
}
finally {
  [gc]::Collect(); [gc]::WaitForPendingFinalizers()
  foreach ($h in 'T_LSYS', 'T_LSW', 'T_LUSR', 'T_SSYS', 'T_SSW') { & cmd.exe /c "reg.exe unload HKLM\$h >nul 2>&1" }
}

# ---------------- 8. ISO ----------------
Say '== 8. ISO'
if (Test-Path $liteIso) {
  $list = & "$env:ProgramFiles\7-Zip\7z.exe" l $liteIso
  Check 'BIOS boot file' ([bool]($list | Select-String 'boot\\etfsboot.com'))
  Check 'UEFI boot file' ([bool]($list | Select-String 'efi\\microsoft\\boot\\efisys.bin'))
  Check 'autounattend.xml' ([bool]($list | Select-String 'autounattend.xml'))
  $ua = [xml](Get-Content "$Work\iso\autounattend.xml" -Raw)
  $acc = $ua.unattend.settings.component.UserAccounts.LocalAccounts.LocalAccount | Where-Object { $_ }
  Check 'account "JDO x QHT" without a password, no account questions' ($acc.Name -eq 'JDO x QHT' -and -not $acc.Password.Value -and ($ua.OuterXml -match '<HideLocalAccountScreen>true'))
  Check 'setup downloads no updates (Dynamic Update off)' ($ua.OuterXml -match '<DynamicUpdate>\s*<Enable>false</Enable>')
  Check 'setup screens skipped (no OOBE update check)' ($ua.OuterXml -match '<SkipMachineOOBE>true' -and $ua.OuterXml -match '<SkipUserOOBE>true')
  Check 'first boot runs at first sign-in' ($ua.OuterXml -match 'firstboot\.ps1')
  Check 'no disk is wiped by the real answer file' ($ua.OuterXml -notmatch 'WillWipeDisk')
  Check 'install.esd + boot.wim + setup' ([bool]($list | Select-String 'sources\\install.esd') -and [bool]($list | Select-String 'sources\\boot.wim') -and [bool]($list | Select-String 'sources\\setup.exe'))
  Say ('  ISO size: {0:N2} GB ({1:N0} MB)' -f ((Get-Item $liteIso).Length / 1GB), ((Get-Item $liteIso).Length / 1MB))
} else { Check 'ISO exists' $false }
$sz = (Get-ChildItem $lite -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Say ('  installed files (hard links counted again): {0:N2} GB' -f ($sz / 1GB))

Say ''
Say "RESULT: $pass passed, $fail failed"
$lines | Set-Content -LiteralPath $out -Encoding UTF8
if ($fail) { exit 1 }

