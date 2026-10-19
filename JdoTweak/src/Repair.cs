using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Management;
using System.ServiceProcess;
using Microsoft.Win32;

namespace JdoTweak
{
    public class Fix
    {
        public string Id, Group, Ar, En, DescAr, DescEn, Script;
        public bool Slow;
        public string Title { get { return L.Pick(Ar, En); } }
        public string Desc { get { return L.Pick(DescAr, DescEn); } }
    }

    public class FixGroup
    {
        public string Id, Ar, En, Icon;
        public string Title { get { return L.Pick(Ar, En); } }
    }

    public class Issue
    {
        public string Ar, En, FixId;
        public int Level;   // 0 info, 1 warning, 2 problem
        public string Title { get { return L.Pick(Ar, En); } }
    }

    public static class Repair
    {
        public static readonly List<FixGroup> Groups = new List<FixGroup>
        {
            new FixGroup { Id = "system",  Ar = "النظام والملفات",      En = "System & Files",       Icon = "" },
            new FixGroup { Id = "tweak",   Ar = "مشاكل التويكات",       En = "Tweak Problems",       Icon = "" },
            new FixGroup { Id = "network", Ar = "الإنترنت والشبكة",     En = "Internet & Network",   Icon = "" },
            new FixGroup { Id = "store",   Ar = "المتجر والتطبيقات",    En = "Store & Apps",         Icon = "" },
            new FixGroup { Id = "update",  Ar = "تحديثات ويندوز",       En = "Windows Update",       Icon = "" },
            new FixGroup { Id = "audio",   Ar = "الصوت",                En = "Audio",                Icon = "" },
            new FixGroup { Id = "devices", Ar = "الأجهزة والتعريفات",   En = "Devices & Drivers",    Icon = "" },
            new FixGroup { Id = "games",   Ar = "الألعاب والبرامج",     En = "Games & Programs",     Icon = "" },
            new FixGroup { Id = "security",Ar = "الحماية",              En = "Security",             Icon = "" },
        };

        // Windows default start type for services that tweak packs commonly break.
        // 2 = Automatic, 3 = Manual.
        static readonly string ServiceDefaults =
            "AudioSrv=2 AudioEndpointBuilder=2 Dnscache=2 Dhcp=2 NlaSvc=2 netprofm=3 nsi=2 iphlpsvc=2 LanmanWorkstation=2 LanmanServer=2 " +
            "Wcmsvc=2 WlanSvc=2 BFE=2 mpssvc=2 CryptSvc=2 EventLog=2 Schedule=2 Winmgmt=2 Themes=2 FontCache=2 Power=2 ProfSvc=2 " +
            "UserManager=2 gpsvc=2 ShellHWDetection=2 SENS=2 EventSystem=2 SystemEventsBroker=2 TimeBrokerSvc=3 CDPSvc=2 DPS=2 " +
            "WdiServiceHost=3 WdiSystemHost=3 PcaSvc=2 DusmSvc=2 WpnService=2 StorSvc=3 TokenBroker=3 StateRepository=3 AppXSvc=3 " +
            "ClipSVC=3 InstallService=3 LicenseManager=3 wlidsvc=3 BITS=2 wuauserv=3 UsoSvc=2 TrustedInstaller=3 W32Time=3 " +
            "camsvc=3 NcbService=3 KeyIso=3 VaultSvc=3 msiserver=3 seclogon=3 hidserv=3 TabletInputService=3 BthServ=3 bthserv=3 " +
            "XboxGipSvc=3 XblAuthManager=3 XblGameSave=3 XboxNetApiSvc=3 GamingServices=2 GamingServicesNet=2 Spooler=2 " +
            "WSearch=2 SysMain=2 DeviceAssociationService=3 DevicesFlowUserSvc=3 PlugPlay=3 DsmSvc=3 Audiosrv=2 lmhosts=3 " +
            "WinHttpAutoProxySvc=3 SstpSvc=3 RasMan=3 Netman=3 WerSvc=3 diagnosticshub.standardcollector.service=3 DiagTrack=2";

        static string ServiceScript(string list)
        {
            return "$list = '" + list + "'.Split(' ');" +
                   "foreach ($e in $list) { $n,$v = $e.Split('='); $k = \"HKLM:\\SYSTEM\\CurrentControlSet\\Services\\$n\";" +
                   " if (Test-Path $k) { Set-ItemProperty $k -Name Start -Value ([int]$v) -Type DWord; Write-Output \"$n -> $(if($v -eq '2'){'Automatic'}else{'Manual'})\" } }" +
                   "foreach ($n in 'AudioSrv','AudioEndpointBuilder','Dnscache','Dhcp','BFE','mpssvc','CryptSvc','EventLog','Schedule','Winmgmt','Themes','Power') { Start-Service $n -ErrorAction SilentlyContinue }";
        }

        public static readonly List<Fix> Fixes = new List<Fix>
        {
            // ---------------- system ----------------
            new Fix { Id = "sfc", Group = "system", Slow = true, Ar = "إصلاح ملفات النظام (SFC)", En = "Repair System Files (SFC)",
                DescAr = "يفحص كل ملفات ويندوز ويرجع التالف منها. ياخذ 10-20 دقيقة.", DescEn = "Scans every Windows file and restores damaged ones. Takes 10-20 minutes.",
                Script = "sfc /scannow" },
            new Fix { Id = "dism", Group = "system", Slow = true, Ar = "إصلاح صورة الويندوز (DISM)", En = "Repair Windows Image (DISM)",
                DescAr = "ينزل ملفات سليمة من مايكروسوفت ويصلح فيها الويندوز. شغله قبل SFC إذا SFC ما قدر يصلح.", DescEn = "Downloads clean files from Microsoft to repair Windows. Run it before SFC if SFC can't fix things.",
                Script = "DISM /Online /Cleanup-Image /RestoreHealth" },
            new Fix { Id = "chkdsk", Group = "system", Ar = "فحص الهارد عند الإقلاع (CHKDSK)", En = "Check Disk on Next Boot (CHKDSK)",
                DescAr = "يجدول فحص وإصلاح أخطاء الهارد C في الإقلاع الجاي.", DescEn = "Schedules a scan and repair of drive C on the next restart.",
                Script = "cmd /c 'echo Y | chkdsk C: /f /r'; Write-Output 'Scheduled. Restart to run the disk check.'" },
            new Fix { Id = "components", Group = "system", Slow = true, Ar = "تنظيف ملفات التحديثات القديمة", En = "Clean Old Update Files",
                DescAr = "يحذف نسخ التحديثات القديمة من مجلد WinSxS ويفضي جيجات من الهارد.", DescEn = "Removes superseded update copies from WinSxS, freeing gigabytes.",
                Script = "DISM /Online /Cleanup-Image /StartComponentCleanup" },
            new Fix { Id = "temp", Group = "system", Ar = "تنظيف الملفات المؤقتة", En = "Clean Temporary Files",
                DescAr = "يحذف الملفات المؤقتة للمستخدم والنظام وكاش الشيدر القديم.", DescEn = "Deletes user and system temp files and stale shader cache.",
                Script = "$before = (Get-PSDrive C).Free; foreach ($p in \"$env:TEMP\\*\",\"$env:SystemRoot\\Temp\\*\",\"$env:LOCALAPPDATA\\D3DSCache\\*\",\"$env:LOCALAPPDATA\\NVIDIA\\DXCache\\*\",\"$env:LOCALAPPDATA\\AMD\\DxCache\\*\",\"$env:SystemRoot\\SoftwareDistribution\\DeliveryOptimization\\*\") { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }; $freed = ((Get-PSDrive C).Free - $before) / 1MB; Write-Output ('Freed {0:N0} MB' -f [math]::Max(0,$freed))" },
            new Fix { Id = "explorer", Group = "system", Ar = "إعادة تشغيل شريط المهام والمستكشف", En = "Restart Taskbar & Explorer",
                DescAr = "يصلح تعليق شريط المهام وقائمة ابدأ وسطح المكتب.", DescEn = "Fixes a frozen taskbar, Start menu or desktop.",
                Script = "Stop-Process -Name explorer -Force; Start-Sleep 2; if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer }; Write-Output 'Explorer restarted'" },
            new Fix { Id = "startmenu", Group = "system", Ar = "إصلاح قائمة ابدأ والبحث", En = "Fix Start Menu & Search",
                DescAr = "يعيد تسجيل قائمة ابدأ والبحث إذا ما تفتح أو ما تكتب فيها.", DescEn = "Re-registers Start and Search when they won't open or accept typing.",
                Script = "foreach ($n in 'Microsoft.Windows.ShellExperienceHost','Microsoft.Windows.StartMenuExperienceHost','MicrosoftWindows.Client.CBS','Microsoft.Windows.Search') { Get-AppxPackage -AllUsers $n | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register \"$($_.InstallLocation)\\AppXManifest.xml\"; Write-Output \"Re-registered $($_.Name)\" } }; Stop-Process -Name StartMenuExperienceHost,SearchHost,SearchApp -Force -ErrorAction SilentlyContinue" },
            new Fix { Id = "iconcache", Group = "system", Ar = "إصلاح الأيقونات والصور المصغرة", En = "Fix Icons & Thumbnails",
                DescAr = "يعيد بناء كاش الأيقونات إذا طلعت أيقونات بيضاء أو غلط.", DescEn = "Rebuilds the icon cache when icons show blank or wrong.",
                Script = "Stop-Process -Name explorer -Force; Remove-Item \"$env:LOCALAPPDATA\\IconCache.db\" -Force -ErrorAction SilentlyContinue; Remove-Item \"$env:LOCALAPPDATA\\Microsoft\\Windows\\Explorer\\iconcache_*.db\",\"$env:LOCALAPPDATA\\Microsoft\\Windows\\Explorer\\thumbcache_*.db\" -Force -ErrorAction SilentlyContinue; Start-Process explorer; Write-Output 'Icon cache rebuilt'" },
            new Fix { Id = "taskmgr", Group = "system", Ar = "إرجاع مدير المهام والريجستري", En = "Re-enable Task Manager & Regedit",
                DescAr = "يفتح مدير المهام ومحرر الريجستري إذا انقفلوا بسبب تويك أو فيروس.", DescEn = "Unlocks Task Manager and Registry Editor if a tweak or malware disabled them.",
                Script = "foreach ($h in 'HKCU','HKLM') { $k = \"$($h):\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System\"; Remove-ItemProperty $k -Name DisableTaskMgr,DisableRegistryTools,DisableCMD -ErrorAction SilentlyContinue }; Write-Output 'Task Manager, Regedit and CMD unlocked'" },
            new Fix { Id = "wmi", Group = "system", Ar = "إصلاح WMI", En = "Repair WMI",
                DescAr = "يصلح قاعدة بيانات WMI اللي تستخدمها البرامج لقراءة معلومات الجهاز.", DescEn = "Repairs the WMI repository that programs use to read hardware info.",
                Script = "winmgmt /verifyrepository; winmgmt /salvagerepository; Write-Output 'WMI checked'" },
            new Fix { Id = "time", Group = "system", Ar = "ضبط الوقت والتاريخ", En = "Fix Date & Time Sync",
                DescAr = "يرجع مزامنة الساعة مع الإنترنت. الوقت الغلط يخرب تسجيل الدخول بالألعاب والمواقع.", DescEn = "Restores internet time sync. A wrong clock breaks game and website logins.",
                Script = "Set-Service W32Time -StartupType Manual; Start-Service W32Time; w32tm /config /syncfromflags:manual /manualpeerlist:'time.windows.com' /update; w32tm /resync /force" },
            new Fix { Id = "restorepoint", Group = "system", Ar = "إنشاء نقطة استعادة", En = "Create Restore Point",
                DescAr = "يحفظ حالة الجهاز الحين عشان ترجع لها إذا صار أي شي.", DescEn = "Saves the current state so you can roll back if anything goes wrong.",
                Script = "Set-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore' -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord; Enable-ComputerRestore -Drive \"$env:SystemDrive\\\"; Checkpoint-Computer -Description 'JDO Tweak' -RestorePointType MODIFY_SETTINGS; Write-Output 'Restore point created'" },

            // ---------------- tweak problems ----------------
            new Fix { Id = "revertjdo", Group = "tweak", Ar = "إرجاع كل تويكات البرنامج", En = "Revert Every JDO Tweak",
                DescAr = "يرجع كل قيمة غيرها البرنامج للقيمة الأصلية حقت جهازك.", DescEn = "Restores every value this app changed to your PC's original.",
                Script = "@revert" },
            new Fix { Id = "services", Group = "tweak", Ar = "إرجاع خدمات ويندوز الأساسية", En = "Restore Essential Windows Services",
                DescAr = "يرجع أكثر من 80 خدمة للإعداد الافتراضي حق ويندوز. يصلح أغلب مشاكل التويكات القوية (صوت، نت، متجر، بلوتوث، طابعة).", DescEn = "Puts 80+ services back to Windows defaults. Fixes most problems left by aggressive tweaks (audio, internet, Store, Bluetooth, printing).",
                Script = ServiceScript(ServiceDefaults) },
            new Fix { Id = "powerplans", Group = "tweak", Ar = "إرجاع خطط الطاقة الأصلية", En = "Restore Default Power Plans",
                DescAr = "يحذف خطط الطاقة المخصصة ويرجع خطط ويندوز الأصلية.", DescEn = "Removes custom power plans and restores Windows' originals.",
                Script = "powercfg -restoredefaultschemes; powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e; Write-Output 'Balanced plan active'" },
            new Fix { Id = "bcdreset", Group = "tweak", Ar = "إزالة تعديلات الإقلاع (BCD) اللي تسبب تقطيع", En = "Remove Boot (BCD) Tweaks That Cause Stutter",
                DescAr = "يحذف تعديلات useplatformclock و disabledynamictick وغيرها اللي تسويها برامج التويك الثانية وتسبب تقطيع.", DescEn = "Removes useplatformclock, disabledynamictick and similar boot edits other tweak tools make, which cause stutter.",
                Script = "foreach ($v in 'useplatformclock','useplatformtick','disabledynamictick','tscsyncpolicy','x2apicpolicy','nx','linearaddress57','increaseuserva','firstmegabytepolicy','avoidlowmemory','nolowmem','configaccesspolicy','MSI','usephysicaldestination','usefirmwarepcisettings','perfmem','uselegacyapicmode') { bcdedit /deletevalue $v 2>$null | Out-Null }; bcdedit /set hypervisorlaunchtype auto | Out-Null; Write-Output 'Boot tweaks removed. Restart to apply.'" },
            new Fix { Id = "inputreset", Group = "tweak", Ar = "إرجاع إعدادات الماوس والكيبورد الأصلية", En = "Reset Mouse & Keyboard to Defaults",
                DescAr = "إذا الماوس أو الكيبورد صار يعلق أو يقطع بعد تويك، هذا يرجعهم للأصل.", DescEn = "If the mouse or keyboard lags or skips after a tweak, this resets them.",
                Script = "Remove-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\mouclass\\Parameters' -Name MouseDataQueueSize,ThreadPriority -ErrorAction SilentlyContinue; Remove-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\kbdclass\\Parameters' -Name KeyboardDataQueueSize,ThreadPriority -ErrorAction SilentlyContinue; Set-ItemProperty 'HKCU:\\Control Panel\\Mouse' -Name MouseSpeed -Value '1'; Set-ItemProperty 'HKCU:\\Control Panel\\Mouse' -Name MouseThreshold1 -Value '6'; Set-ItemProperty 'HKCU:\\Control Panel\\Mouse' -Name MouseThreshold2 -Value '10'; Set-ItemProperty 'HKCU:\\Control Panel\\Mouse' -Name MouseSensitivity -Value '10'; Set-ItemProperty 'HKCU:\\Control Panel\\Keyboard' -Name KeyboardDelay -Value '1'; Set-ItemProperty 'HKCU:\\Control Panel\\Keyboard' -Name KeyboardSpeed -Value '31'; foreach ($s in 'usbxhci','USBHUB3') { Remove-ItemProperty \"HKLM:\\SYSTEM\\CurrentControlSet\\Services\\$s\\Parameters\" -Name ThreadPriority -ErrorAction SilentlyContinue }; Write-Output 'Mouse and keyboard reset. Restart to apply.'" },
            new Fix { Id = "gpureset", Group = "tweak", Ar = "إرجاع إعدادات كرت الشاشة الأصلية", En = "Reset GPU Tweaks",
                DescAr = "يصلح الشاشة السوداء والتعليق والوميض اللي تسببه تويكات كرت الشاشة.", DescEn = "Fixes black screens, hangs and flicker caused by GPU tweaks.",
                Script = "$g='HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers'; Remove-ItemProperty \"$g\\Scheduler\" -Name EnablePreemption -ErrorAction SilentlyContinue; Remove-ItemProperty $g -Name TdrLevel,TdrDelay,TdrDdiDelay,TdrDebugMode -ErrorAction SilentlyContinue; Remove-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm' -Name OverlayTestMode -ErrorAction SilentlyContinue; foreach ($n in 'DisablePreemption','DisableCudaContextPreemption') { Remove-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\nvlddmkm' -Name $n -ErrorAction SilentlyContinue }; Remove-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\nvlddmkm\\Parameters' -Name ThreadPriority -ErrorAction SilentlyContinue; Write-Output 'GPU tweaks reset. Restart to apply.'" },
            new Fix { Id = "memreset", Group = "tweak", Ar = "إرجاع إعدادات الرام الأصلية", En = "Reset Memory Tweaks",
                DescAr = "يرجع ضغط الرام والتحميل المسبق وملف الترحيل للوضع الطبيعي.", DescEn = "Restores memory compression, prefetch and the page file to normal.",
                Script = "Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue; Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue; $m='HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management'; Set-ItemProperty $m -Name LargeSystemCache -Value 0 -Type DWord; Remove-ItemProperty $m -Name IoPageLockLimit,SecondLevelDataCache -ErrorAction SilentlyContinue; Set-ItemProperty \"$m\\PrefetchParameters\" -Name EnablePrefetcher -Value 3 -Type DWord; Set-ItemProperty \"$m\\PrefetchParameters\" -Name EnableSuperfetch -Value 3 -Type DWord; $cs = Get-CimInstance Win32_ComputerSystem; if (-not $cs.AutomaticManagedPagefile) { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } }; Write-Output 'Memory settings restored. Restart to apply.'" },
            new Fix { Id = "visualreset", Group = "tweak", Ar = "إرجاع شكل ويندوز الأصلي", En = "Restore Windows Visual Effects",
                DescAr = "يرجع الحركات والشفافية والخطوط الناعمة إذا الويندوز صار شكله مكسور.", DescEn = "Brings back animations, transparency and font smoothing if Windows looks broken.",
                Script = "Set-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects' -Name VisualFXSetting -Value 0 -Type DWord; Set-ItemProperty 'HKCU:\\Control Panel\\Desktop' -Name FontSmoothing -Value '2'; Set-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize' -Name EnableTransparency -Value 1 -Type DWord; Set-ItemProperty 'HKCU:\\Control Panel\\Desktop\\WindowMetrics' -Name MinAnimate -Value '1'; Stop-Process -Name explorer -Force; Write-Output 'Visual effects restored'" },

            // ---------------- network ----------------
            new Fix { Id = "netreset", Group = "network", Ar = "إعادة ضبط الشبكة بالكامل", En = "Full Network Reset",
                DescAr = "يصلح أغلب مشاكل النت: يعيد ضبط Winsock و IP ويمسح كاش DNS. يحتاج ريستارت.", DescEn = "Fixes most internet problems: resets Winsock and IP and flushes DNS. Needs a restart.",
                Script = "netsh winsock reset; netsh int ip reset; netsh int ipv6 reset; ipconfig /release | Out-Null; ipconfig /renew | Out-Null; ipconfig /flushdns; ipconfig /registerdns | Out-Null; Write-Output 'Network reset. Restart to finish.'" },
            new Fix { Id = "tcpreset", Group = "network", Ar = "إرجاع إعدادات TCP الأصلية", En = "Reset TCP Settings to Default",
                DescAr = "يلغي كل تويكات TCP و netsh اللي ممكن ترفع البنق أو تقطع النت.", DescEn = "Undoes TCP and netsh tweaks that can raise ping or drop your connection.",
                Script = "netsh int tcp reset; netsh int tcp set global autotuninglevel=normal; netsh int tcp set heuristics enabled; netsh int tcp set global rss=enabled; netsh int tcp set supplemental internet congestionprovider=default; $p='HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters'; Remove-ItemProperty $p -Name DefaultTTL,TcpWindowSize,GlobalMaxTcpWindowSize,Tcp1323Opts,TcpMaxDupAcks,SackOpts,MaxUserPort,TcpTimedWaitDelay,TcpNoDelay,TcpAckFrequency,DisableTaskOffload -ErrorAction SilentlyContinue; Write-Output 'TCP settings restored'" },
            new Fix { Id = "adapters", Group = "network", Ar = "إعادة تشغيل كرت الشبكة", En = "Restart Network Adapters",
                DescAr = "يطفي ويشغل كرت الشبكة. يصلح انقطاع النت المفاجئ.", DescEn = "Turns network adapters off and on. Fixes sudden disconnects.",
                Script = "Get-NetAdapter -Physical | Restart-NetAdapter -Confirm:$false; Write-Output 'Adapters restarted'" },
            new Fix { Id = "adapteradv", Group = "network", Ar = "إرجاع إعدادات كرت الشبكة المتقدمة", En = "Reset Adapter Advanced Settings",
                DescAr = "يرجع إعدادات كرت الشبكة المتقدمة للأصل (Interrupt Moderation وغيرها).", DescEn = "Resets adapter advanced properties (Interrupt Moderation and others) to default.",
                Script = "Get-NetAdapter -Physical | ForEach-Object { Reset-NetAdapterAdvancedProperty -Name $_.Name -DisplayName '*' -NoRestart; Enable-NetAdapterPowerManagement -Name $_.Name -NoRestart -ErrorAction SilentlyContinue }; Get-NetAdapter -Physical | Restart-NetAdapter -Confirm:$false; Write-Output 'Adapter settings reset'" },
            new Fix { Id = "dnsauto", Group = "network", Ar = "إرجاع DNS تلقائي", En = "Reset DNS to Automatic",
                DescAr = "يرجع DNS لإعداد مزود النت.", DescEn = "Puts DNS back to your internet provider's setting.",
                Script = "Get-NetAdapter -Physical | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses }; ipconfig /flushdns; Write-Output 'DNS set to automatic'" },
            new Fix { Id = "dnscf", Group = "network", Ar = "DNS سريع (Cloudflare 1.1.1.1)", En = "Fast DNS (Cloudflare 1.1.1.1)",
                DescAr = "يحول DNS لـ Cloudflare. يسرع فتح المواقع ويحل مشاكل عدم فتح بعض المواقع.", DescEn = "Switches DNS to Cloudflare. Speeds up lookups and fixes sites that won't open.",
                Script = "Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ('1.1.1.1','1.0.0.1') }; ipconfig /flushdns; Write-Output 'DNS set to 1.1.1.1'" },
            new Fix { Id = "dnsgoogle", Group = "network", Ar = "DNS قوقل (8.8.8.8)", En = "Google DNS (8.8.8.8)",
                DescAr = "يحول DNS لقوقل.", DescEn = "Switches DNS to Google.",
                Script = "Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ('8.8.8.8','8.8.4.4') }; ipconfig /flushdns; Write-Output 'DNS set to 8.8.8.8'" },
            new Fix { Id = "hosts", Group = "network", Ar = "إرجاع ملف Hosts الأصلي", En = "Restore Default Hosts File",
                DescAr = "يصلح المواقع أو الألعاب اللي انحظرت بسبب تعديل ملف hosts.", DescEn = "Fixes sites or games blocked by hosts-file edits.",
                Script = "$h=\"$env:SystemRoot\\System32\\drivers\\etc\\hosts\"; Copy-Item $h \"$h.jdo-backup\" -Force; Set-Content $h \"# Copyright (c) 1993-2009 Microsoft Corp.`r`n#`r`n# localhost name resolution is handled within DNS itself.`r`n#`t127.0.0.1       localhost`r`n#`t::1             localhost`r`n\" -Encoding ASCII; ipconfig /flushdns; Write-Output 'Hosts restored (backup saved as hosts.jdo-backup)'" },
            new Fix { Id = "proxy", Group = "network", Ar = "إلغاء البروكسي", En = "Remove Proxy Settings",
                DescAr = "يلغي أي بروكسي يمنع النت أو يبطئه.", DescEn = "Removes any proxy that blocks or slows your internet.",
                Script = "netsh winhttp reset proxy; Set-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' -Name ProxyEnable -Value 0 -Type DWord; Remove-ItemProperty 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' -Name ProxyServer,AutoConfigURL -ErrorAction SilentlyContinue; Write-Output 'Proxy removed'" },
            new Fix { Id = "firewall", Group = "network", Ar = "إرجاع جدار الحماية الأصلي", En = "Reset Windows Firewall",
                DescAr = "يرجع قواعد جدار الحماية للأصل. يصلح الألعاب اللي ما تتصل.", DescEn = "Resets firewall rules to default. Fixes games that can't connect.",
                Script = "netsh advfirewall reset; Write-Output 'Firewall reset'" },

            // ---------------- store ----------------
            new Fix { Id = "storeinstall", Group = "store", Slow = true, Ar = "إرجاع مايكروسوفت ستور (حتى لو محذوف)", En = "Restore Microsoft Store (Even If Removed)",
                DescAr = "إذا المتجر محذوف ينزله كامل من مايكروسوفت، وإذا موجود يعيد تسجيله ويصلحه.", DescEn = "If the Store was removed, downloads it in full from Microsoft; if present, re-registers and repairs it.",
                Script = "foreach ($s in 'ClipSVC','AppXSvc','InstallService','LicenseManager','wlidsvc','TokenBroker','StateRepository') { Set-ItemProperty \"HKLM:\\SYSTEM\\CurrentControlSet\\Services\\$s\" -Name Start -Value 3 -Type DWord -ErrorAction SilentlyContinue }; $s = Get-AppxPackage -AllUsers Microsoft.WindowsStore; if ($s) { $s | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register \"$($_.InstallLocation)\\AppXManifest.xml\" }; Write-Output 'Store found - re-registered' } else { Write-Output 'Store missing - reinstalling from Microsoft...'; Start-Process wsreset.exe -ArgumentList '-i' -Wait; Start-Sleep 20; if (Get-AppxPackage -AllUsers Microsoft.WindowsStore) { Write-Output 'Store installed' } else { Write-Output 'Install queued - it will appear within a few minutes' } }; foreach ($d in 'Microsoft.DesktopAppInstaller','Microsoft.StorePurchaseApp','Microsoft.VCLibs.140.00','Microsoft.UI.Xaml.2.8','Microsoft.NET.Native.Runtime.2.2','Microsoft.NET.Native.Framework.2.2') { Get-AppxPackage -AllUsers $d | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register \"$($_.InstallLocation)\\AppXManifest.xml\" -ErrorAction SilentlyContinue } }" },
            new Fix { Id = "storecache", Group = "store", Ar = "مسح كاش المتجر", En = "Clear Store Cache",
                DescAr = "يصلح التنزيلات المعلقة والأخطاء داخل المتجر.", DescEn = "Fixes stuck downloads and errors inside the Store.",
                Script = "Start-Process wsreset.exe -Wait; Stop-Process -Name WinStore.App -Force -ErrorAction SilentlyContinue; Write-Output 'Store cache cleared'" },
            new Fix { Id = "storedl", Group = "store", Ar = "إصلاح تنزيلات المتجر المعلقة", En = "Fix Stuck Store Downloads",
                DescAr = "يعيد تشغيل خدمات التنزيل والتثبيت ويمسح الكاش.", DescEn = "Restarts the download and install services and clears their cache.",
                Script = "foreach ($s in 'InstallService','BITS','wuauserv','DoSvc') { Set-Service $s -StartupType Manual -ErrorAction SilentlyContinue; Restart-Service $s -Force -ErrorAction SilentlyContinue }; Remove-Item \"$env:SystemRoot\\SoftwareDistribution\\Download\\*\" -Recurse -Force -ErrorAction SilentlyContinue; Write-Output 'Download services restarted'" },
            new Fix { Id = "apps", Group = "store", Slow = true, Ar = "إعادة تسجيل كل تطبيقات ويندوز", En = "Re-register All Windows Apps",
                DescAr = "يصلح التطبيقات اللي ما تفتح (الإعدادات، الآلة الحاسبة، الصور...).", DescEn = "Fixes built-in apps that won't open (Settings, Calculator, Photos...).",
                Script = "Get-AppxPackage -AllUsers | Where-Object { $_.InstallLocation } | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register \"$($_.InstallLocation)\\AppXManifest.xml\" -ErrorAction SilentlyContinue; Write-Output $_.Name }" },
            new Fix { Id = "xbox", Group = "store", Ar = "إصلاح Xbox و Game Pass", En = "Fix Xbox & Game Pass",
                DescAr = "يرجع خدمات Xbox وخدمات الألعاب. يصلح ألعاب Game Pass اللي ما تفتح أو ما تتثبت.", DescEn = "Restores Xbox and Gaming Services. Fixes Game Pass games that won't open or install.",
                Script = ServiceScript("XboxGipSvc=3 XblAuthManager=3 XblGameSave=3 XboxNetApiSvc=3 GamingServices=2 GamingServicesNet=2 InstallService=3 TokenBroker=3 wlidsvc=3") + "; Remove-ItemProperty 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\GameDVR' -Name AllowGameDVR -ErrorAction SilentlyContinue; if (-not (Get-AppxPackage -AllUsers Microsoft.GamingServices)) { Start-Process 'ms-windows-store://pdp/?productid=9MWPM2CQNLHN'; Write-Output 'Gaming Services missing - opened its Store page to install' }" },

            // ---------------- update ----------------
            new Fix { Id = "wureset", Group = "update", Ar = "إصلاح تحديثات ويندوز", En = "Repair Windows Update",
                DescAr = "يمسح كاش التحديثات ويعيد تشغيل خدماتها. يصلح التحديثات العالقة والأخطاء.", DescEn = "Clears the update cache and restarts its services. Fixes stuck updates and error codes.",
                Script = "foreach ($s in 'wuauserv','BITS','CryptSvc','msiserver','UsoSvc') { Stop-Service $s -Force -ErrorAction SilentlyContinue }; Rename-Item \"$env:SystemRoot\\SoftwareDistribution\" \"SoftwareDistribution.old$(Get-Random)\" -ErrorAction SilentlyContinue; Rename-Item \"$env:SystemRoot\\System32\\catroot2\" \"catroot2.old$(Get-Random)\" -ErrorAction SilentlyContinue; foreach ($s in 'wuauserv','BITS','CryptSvc','msiserver','UsoSvc') { Start-Service $s -ErrorAction SilentlyContinue }; Write-Output 'Windows Update components reset'" },
            new Fix { Id = "wuenable", Group = "update", Ar = "تشغيل تحديثات ويندوز من جديد", En = "Turn Windows Update Back On",
                DescAr = "يلغي أي تويك أو سياسة قفلت التحديثات.", DescEn = "Removes any tweak or policy that turned updates off.",
                Script = ServiceScript("wuauserv=3 UsoSvc=2 BITS=2 WaaSMedicSvc=3 DoSvc=2") + "; Remove-Item 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate' -Recurse -Force -ErrorAction SilentlyContinue; Write-Output 'Windows Update enabled'" },

            // ---------------- audio ----------------
            new Fix { Id = "audio", Group = "audio", Ar = "إصلاح الصوت", En = "Fix No Sound",
                DescAr = "يعيد تشغيل خدمات الصوت ويرجعها تلقائية.", DescEn = "Restarts the audio services and sets them back to automatic.",
                Script = ServiceScript("Audiosrv=2 AudioEndpointBuilder=2 MMCSS=2") + "; Restart-Service AudioEndpointBuilder -Force; Restart-Service Audiosrv -Force; Write-Output 'Audio services restarted'" },
            new Fix { Id = "audiodev", Group = "audio", Ar = "إعادة تشغيل كرت الصوت", En = "Restart Audio Devices",
                DescAr = "يطفي ويشغل أجهزة الصوت. يصلح السماعة اللي ما تنعرف.", DescEn = "Restarts audio devices. Fixes headsets that aren't detected.",
                Script = "Get-PnpDevice -Class AudioEndpoint,MEDIA -PresentOnly | ForEach-Object { pnputil /restart-device \"$($_.InstanceId)\" | Out-Null }; Write-Output 'Audio devices restarted'" },

            // ---------------- devices ----------------
            new Fix { Id = "scanhw", Group = "devices", Ar = "إعادة فحص القطع والأجهزة", En = "Rescan Hardware",
                DescAr = "يدور على الأجهزة اللي ما انعرفت ويثبتها.", DescEn = "Finds devices Windows hasn't detected and installs them.",
                Script = "pnputil /scan-devices; Get-PnpDevice -PresentOnly | Where-Object { $_.Status -ne 'OK' } | ForEach-Object { Write-Output \"Problem: $($_.FriendlyName) [$($_.Status)]\" }" },
            new Fix { Id = "usbpower", Group = "devices", Ar = "إصلاح انقطاع USB", En = "Fix USB Disconnects",
                DescAr = "يمنع ويندوز من فصل منافذ USB لتوفير الطاقة.", DescEn = "Stops Windows cutting power to USB ports to save energy.",
                Script = "powercfg -setacvalueindex scheme_current 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0; powercfg -setactive scheme_current; Get-CimInstance -Namespace root\\wmi -ClassName MSPower_DeviceEnable | Where-Object { $_.InstanceName -match 'USB' } | Set-CimInstance -Property @{ Enable = $false }; Write-Output 'USB power saving off'" },
            new Fix { Id = "bluetooth", Group = "devices", Ar = "إصلاح البلوتوث", En = "Fix Bluetooth",
                DescAr = "يرجع خدمات البلوتوث ويعيد تشغيلها.", DescEn = "Restores and restarts the Bluetooth services.",
                Script = ServiceScript("bthserv=3 BthAvctpSvc=3 BTAGService=3 DeviceAssociationService=3") + "; Restart-Service bthserv -Force -ErrorAction SilentlyContinue; Write-Output 'Bluetooth services restored'" },
            new Fix { Id = "printer", Group = "devices", Ar = "إصلاح الطابعة", En = "Fix Printing",
                DescAr = "يرجع خدمة الطباعة ويمسح الطباعات العالقة.", DescEn = "Restores the print service and clears stuck print jobs.",
                Script = "Stop-Service Spooler -Force -ErrorAction SilentlyContinue; Remove-Item \"$env:SystemRoot\\System32\\spool\\PRINTERS\\*\" -Force -ErrorAction SilentlyContinue; Set-Service Spooler -StartupType Automatic; Start-Service Spooler; Write-Output 'Print spooler fixed'" },
            new Fix { Id = "gpurestart", Group = "devices", Ar = "إعادة تشغيل تعريف كرت الشاشة", En = "Restart Graphics Driver",
                DescAr = "يصلح الشاشة اللي علقت أو صارت سوداء بدون ريستارت. الشاشة بتطفي ثانية.", DescEn = "Recovers a frozen or black display without restarting. The screen will blink once.",
                Script = "Get-PnpDevice -Class Display -PresentOnly | ForEach-Object { pnputil /restart-device \"$($_.InstanceId)\" }" },

            // ---------------- games ----------------
            new Fix { Id = "runtimes", Group = "games", Slow = true, Ar = "تثبيت ملفات تشغيل الألعاب (VC++ / DirectX)", En = "Install Game Runtimes (VC++ / DirectX)",
                DescAr = "يثبت Visual C++ و DirectX. يحل أخطاء مثل MSVCP140.dll و d3dx9 و VCRUNTIME140.", DescEn = "Installs Visual C++ and DirectX. Fixes errors like MSVCP140.dll, d3dx9 and VCRUNTIME140.",
                Script = "if (Get-Command winget -ErrorAction SilentlyContinue) { foreach ($id in 'Microsoft.VCRedist.2015+.x64','Microsoft.VCRedist.2015+.x86','Microsoft.VCRedist.2013.x64','Microsoft.VCRedist.2013.x86','Microsoft.VCRedist.2012.x64','Microsoft.VCRedist.2010.x64','Microsoft.DirectX') { Write-Output \"Installing $id...\"; winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Null } ; Write-Output 'Done' } else { Write-Output 'winget not found - opening the Microsoft download page'; Start-Process 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist' }" },
            new Fix { Id = "netfx", Group = "games", Slow = true, Ar = "تفعيل .NET Framework 3.5", En = "Enable .NET Framework 3.5",
                DescAr = "بعض الألعاب والبرامج القديمة تحتاجه.", DescEn = "Some older games and programs need it.",
                Script = "DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart" },
            new Fix { Id = "shadercache", Group = "games", Ar = "مسح كاش الشيدر", En = "Clear Shader Cache",
                DescAr = "يصلح التقطيع والأخطاء الرسومية بعد تحديث التعريف. اللعبة بتبني الكاش من جديد أول مرة.", DescEn = "Fixes stutter and visual glitches after a driver update. Games rebuild it on first launch.",
                Script = "foreach ($p in \"$env:LOCALAPPDATA\\D3DSCache\",\"$env:LOCALAPPDATA\\NVIDIA\\DXCache\",\"$env:LOCALAPPDATA\\NVIDIA\\GLCache\",\"$env:LOCALAPPDATA\\AMD\\DxCache\",\"$env:LOCALAPPDATA\\AMD\\GLCache\",\"$env:LOCALAPPDATA\\AMD\\VkCache\",\"$env:PROGRAMDATA\\NVIDIA Corporation\\NV_Cache\") { Remove-Item \"$p\\*\" -Recurse -Force -ErrorAction SilentlyContinue }; Write-Output 'Shader cache cleared'" },
            new Fix { Id = "anticheat", Group = "games", Ar = "إصلاح مكافح الغش (Vanguard / EAC / BattlEye)", En = "Fix Anti-Cheat (Vanguard / EAC / BattlEye)",
                DescAr = "يرجع الإعدادات اللي يطلبها مكافح الغش: الحماية، التوقيع، DEP. يصلح أخطاء مثل VAN 1067 و VAN 9001.", DescEn = "Restores what anti-cheats need: memory protection, driver signing, DEP. Fixes errors like VAN 1067 and VAN 9001.",
                Script = "bcdedit /set nx OptIn | Out-Null; bcdedit /set testsigning off | Out-Null; bcdedit /set nointegritychecks off | Out-Null; bcdedit /deletevalue hypervisorlaunchtype 2>$null | Out-Null; foreach ($s in 'vgc','vgk','EasyAntiCheat','EasyAntiCheat_EOS','BEService') { if (Get-Service $s -ErrorAction SilentlyContinue) { Set-Service $s -StartupType Manual -ErrorAction SilentlyContinue; Write-Output \"$s ok\" } }; Write-Output 'Anti-cheat requirements restored. Restart to apply.'" },

            // ---------------- security ----------------
            new Fix { Id = "defender", Group = "security", Ar = "تشغيل Windows Defender من جديد", En = "Turn Windows Defender Back On",
                DescAr = "يلغي أي تويك قفل الحماية ويرجع Defender يشتغل.", DescEn = "Removes tweaks that disabled protection and turns Defender back on.",
                Script = "$p='HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows Defender'; Remove-ItemProperty $p -Name DisableAntiSpyware,DisableAntiVirus -ErrorAction SilentlyContinue; Remove-Item \"$p\\Real-Time Protection\" -Recurse -Force -ErrorAction SilentlyContinue; foreach ($s in 'WinDefend','WdNisSvc','SecurityHealthService','wscsvc','Sense') { Set-ItemProperty \"HKLM:\\SYSTEM\\CurrentControlSet\\Services\\$s\" -Name Start -Value $(if ($s -eq 'WdNisSvc' -or $s -eq 'Sense') {3} else {2}) -Type DWord -ErrorAction SilentlyContinue }; Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction SilentlyContinue; Write-Output 'Defender restored. Restart to finish.'" },
            new Fix { Id = "uac", Group = "security", Ar = "تشغيل UAC من جديد", En = "Turn UAC Back On",
                DescAr = "يرجع نافذة السماح للبرامج. لازم لتطبيقات المتجر.", DescEn = "Brings back the app permission prompt. Store apps need it.",
                Script = "$k='HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System'; Set-ItemProperty $k -Name EnableLUA -Value 1 -Type DWord; Set-ItemProperty $k -Name ConsentPromptBehaviorAdmin -Value 5 -Type DWord; Set-ItemProperty $k -Name PromptOnSecureDesktop -Value 1 -Type DWord; Write-Output 'UAC on. Restart to apply.'" },
            new Fix { Id = "smartscreen", Group = "security", Ar = "تشغيل SmartScreen من جديد", En = "Turn SmartScreen Back On",
                DescAr = "يرجع فحص الملفات المنزّلة.", DescEn = "Restores scanning of downloaded files.",
                Script = "Remove-ItemProperty 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System' -Name EnableSmartScreen -ErrorAction SilentlyContinue; Set-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer' -Name SmartScreenEnabled -Value 'Warn'; Write-Output 'SmartScreen on'" },
            new Fix { Id = "policies", Group = "security", Ar = "مسح كل السياسات المفروضة (Group Policy)", En = "Reset All Group Policies",
                DescAr = "يمسح كل السياسات اللي حطتها برامج التويك أو الفيروسات. تنبيه: يلغي تويكات السياسات كلها.", DescEn = "Clears every policy set by tweak tools or malware. Note: removes all policy-based tweaks too.",
                Script = "Remove-Item \"$env:SystemRoot\\System32\\GroupPolicy\" -Recurse -Force -ErrorAction SilentlyContinue; Remove-Item \"$env:SystemRoot\\System32\\GroupPolicyUsers\" -Recurse -Force -ErrorAction SilentlyContinue; gpupdate /force; Write-Output 'Group policies reset'" },
        };

        public static Fix Get(string id) { return Fixes.FirstOrDefault(f => f.Id == id); }

        // ---------- automatic scan ----------
        public static List<Issue> Scan(Catalog cat)
        {
            var list = new List<Issue>();
            Action<int, string, string, string> add = (lvl, ar, en, fix) => list.Add(new Issue { Level = lvl, Ar = ar, En = en, FixId = fix });

            try
            {
                var d = new DriveInfo(Path.GetPathRoot(Environment.SystemDirectory));
                double freeGb = d.AvailableFreeSpace / 1073741824.0;
                if (freeGb < 15 || d.AvailableFreeSpace < d.TotalSize * 0.08)
                    add(2, "مساحة الهارد C قليلة (" + freeGb.ToString("0") + " جيجا فاضية)", "Drive C is low on space (" + freeGb.ToString("0") + " GB free)", "temp");
            }
            catch { }

            try
            {
                long temp = DirSize(Path.GetTempPath()) + DirSize(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp"));
                if (temp > 1073741824L) add(1, "ملفات مؤقتة كثيرة (" + (temp / 1048576) + " ميجا)", "Lots of temporary files (" + (temp / 1048576) + " MB)", "temp");
            }
            catch { }

            // Essential services that should never be disabled
            var essential = new[] { "AudioSrv", "AudioEndpointBuilder", "Dnscache", "Dhcp", "BFE", "CryptSvc", "EventLog", "Schedule", "Winmgmt", "Themes", "Power", "AppXSvc", "ClipSVC", "StateRepository", "TokenBroker", "nsi", "NlaSvc" };
            var broken = new List<string>();
            foreach (var s in essential)
            {
                object v = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\" + s, "Start", null);
                if (v is int && (int)v == 4) broken.Add(s);
            }
            if (broken.Count > 0) add(2, "خدمات أساسية مقفلة: " + string.Join(", ", broken), "Essential services disabled: " + string.Join(", ", broken), "services");

            // Microsoft Store
            if (!Directory.Exists(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps")) ||
                !Directory.EnumerateDirectories(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsApps"), "Microsoft.WindowsStore_*").Any())
                add(2, "مايكروسوفت ستور محذوف", "Microsoft Store is missing", "storeinstall");

            // Pending reboot
            if (Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") != null ||
                Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") != null)
                add(1, "فيه ريستارت معلّق لتحديثات أو تعريفات", "A restart is pending for updates or drivers", null);

            // Task Manager locked
            foreach (var h in new[] { "HKEY_CURRENT_USER", "HKEY_LOCAL_MACHINE" })
            {
                object v = Registry.GetValue(h + @"\Software\Microsoft\Windows\CurrentVersion\Policies\System", "DisableTaskMgr", null);
                if (v is int && (int)v == 1) { add(2, "مدير المهام مقفل", "Task Manager is locked", "taskmgr"); break; }
            }

            // Boot timer tweaks from other tools
            try
            {
                var o = new List<string>();
                Engine.Stream("bcdedit.exe", "/enum {current}", System.Text.Encoding.Default, o.Add);
                string all = string.Join("\n", o).ToLowerInvariant();
                if (all.Contains("useplatformclock") || all.Contains("disabledynamictick") || all.Contains("useplatformtick"))
                    add(1, "تعديلات إقلاع (BCD) من برنامج تويك ثاني ممكن تسبب تقطيع", "Boot (BCD) tweaks from another tool may cause stutter", "bcdreset");
                if (all.Contains("testsigning") && all.Contains("yes"))
                    add(2, "وضع الاختبار (Test Signing) مفعل ويمنع مكافح الغش", "Test Signing is on and blocks anti-cheat", "anticheat");
            }
            catch { }

            // Devices with driver problems
            try
            {
                using (var s = new ManagementObjectSearcher("SELECT Name FROM Win32_PnPEntity WHERE ConfigManagerErrorCode <> 0"))
                {
                    var bad = s.Get().Cast<ManagementObject>().Select(m => Convert.ToString(m["Name"])).Where(n => !string.IsNullOrEmpty(n)).Take(5).ToList();
                    if (bad.Count > 0) add(2, "أجهزة فيها مشكلة تعريف: " + string.Join("، ", bad), "Devices with driver problems: " + string.Join(", ", bad), "scanhw");
                }
            }
            catch { add(2, "WMI خربان (البرامج ما تقدر تقرا معلومات الجهاز)", "WMI is broken (programs can't read hardware info)", "wmi"); }

            // DNS resolution
            try { System.Net.Dns.GetHostEntry("www.microsoft.com"); }
            catch { add(2, "النت ما يترجم أسماء المواقع (مشكلة DNS)", "Internet can't resolve site names (DNS problem)", "netreset"); }

            // Proxy
            object proxy = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable", null);
            if (proxy is int && (int)proxy == 1) add(1, "فيه بروكسي مفعل ممكن يبطئ النت", "A proxy is on and may slow your internet", "proxy");

            // VC++ runtime
            if (Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64", "Installed", null) == null)
                add(1, "ملفات تشغيل Visual C++ ناقصة (أغلب الألعاب تحتاجها)", "Visual C++ runtime is missing (most games need it)", "runtimes");

            // Time sync
            object w32 = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\W32Time", "Start", null);
            if (w32 is int && (int)w32 == 4) add(1, "مزامنة الوقت مقفلة", "Time sync is disabled", "time");

            // Informational: protection / updates switched off (the user may want that)
            object rt = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection", "DisableRealtimeMonitoring", null);
            if (rt is int && (int)rt == 1) add(0, "الحماية الفورية لـ Defender مقفلة", "Defender real-time protection is off", "defender");
            object lua = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System", "EnableLUA", null);
            if (lua is int && (int)lua == 0) add(0, "UAC مقفل (تطبيقات المتجر ممكن ما تفتح)", "UAC is off (Store apps may not open)", "uac");
            object wu = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\wuauserv", "Start", null);
            if (wu is int && (int)wu == 4) add(0, "تحديثات ويندوز مقفلة", "Windows Update is off", "wuenable");

            // Performance hints that map to tweaks
            object dvr = Registry.GetValue(@"HKEY_CURRENT_USER\System\GameConfigStore", "GameDVR_Enabled", null);
            if (!(dvr is int) || (int)dvr == 1) add(1, "تسجيل الألعاب بالخلفية شغال وياكل فريمات", "Background game recording is on and costs FPS", "tweak:game.dvr");
            try
            {
                var o = new List<string>();
                Engine.Stream("powercfg.exe", "/getactivescheme", System.Text.Encoding.Default, o.Add);
                string s = string.Join(" ", o);
                if (s.Contains("a1841308-3541-4fab-bc81-f71556f20b4a") || s.Contains("381b4222-f694-41f0-9685-ff5bb260df2e"))
                    add(1, "خطة الطاقة مو على الأداء العالي", "Power plan isn't set for performance", "tweak:power.ultimate");
            }
            catch { }

            return list.OrderByDescending(i => i.Level).ToList();
        }

        static long DirSize(string path)
        {
            long total = 0;
            try
            {
                foreach (var f in new DirectoryInfo(path).EnumerateFiles("*", SearchOption.AllDirectories))
                    try { total += f.Length; } catch { }
            }
            catch { }
            return total;
        }
    }
}
