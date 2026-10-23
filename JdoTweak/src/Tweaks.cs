using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace JdoTweak
{
    public class TAction
    {
        public string Kind;      // reg | each | cmd | ps | script
        public string Key;       // full registry path (reg / each)
        public string Name;      // value name
        public string Type;      // dw | qw | sz | esz | msz | bin | del | delkey
        public object Value;
        public string Command;   // cmd / ps / script body
        public string Ext;       // script extension (.bat .cmd .ps1)

        public bool IsRegistry { get { return Kind == "reg" || Kind == "each"; } }
    }

    public class TOption
    {
        public string Ar, En;
        public bool IsDefault, Game;   // Game: the value chosen as best for games, ahead of the most-used one
        public int Gb, Uses;
        public List<TAction> Apply = new List<TAction>();
        public string Label { get { return L.Pick(Ar, En); } }
        public override string ToString() { return Label; }
    }

    public class Tweak
    {
        public string Id, Cat, Ar, En, DescAr, DescEn, Auto, Vendor, Path;
        public int Tier, Risk, MinRam, Packs;
        public bool Reboot, Library, Curated, NoUndo, NoPack;
        public bool NoBulk;   // fine one by one, never in "Apply all" (turns off Windows protection / Update / Store, network commands, risky)
        public string SearchText;

        // One switch inside a hand-picked tweak (one value or one command), cached so the
        // details panel and "revert all" always talk about the same object.
        static readonly Dictionary<string, Tweak> subs = new Dictionary<string, Tweak>();
        public static Tweak Sub(Tweak parent, int i)
        {
            string id = parent.Id + "#" + i;
            Tweak s;
            lock (subs)
            {
                if (!subs.TryGetValue(id, out s))
                    subs[id] = s = new Tweak
                    {
                        Id = id, Cat = parent.Cat, Tier = parent.Tier, Risk = parent.Risk, Reboot = parent.Reboot,
                        Apply = new List<TAction> { parent.Apply[i] },
                        Revert = parent.Revert.Count == parent.Apply.Count ? new List<TAction> { parent.Revert[i] } : new List<TAction>()
                    };
            }
            return s;
        }
        public List<TAction> Apply = new List<TAction>();
        public List<TAction> Revert = new List<TAction>();
        public List<TOption> Options;

        public bool HasOptions { get { return Options != null && Options.Count > 0; } }
        public string Title { get { return L.Pick(Ar, En); } }
        public string Desc { get { return L.Pick(DescAr, DescEn); } }

        // Settings whose value climbs with the plan: Basic is already better than Windows' default, Elite goes
        // further, Ultimate takes the strongest value. {basic, elite, ultimate}; a missing value falls back to the plan below.
        static readonly Dictionary<string, string[]> Ladder = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
        {
            { "Win32PrioritySeparation", new[] { "26", "38", "40" } },
            { "MouseDataQueueSize", new[] { "50", "25", "20" } },
            { "KeyboardDataQueueSize", new[] { "50", "25", "20" } },
            { "SystemResponsiveness", new[] { "10", "5", "0" } },
            { "MenuShowDelay", new[] { "100", "50", "0" } },
            { "MouseHoverTime", new[] { "100", "50", "10" } },
            { "WaitToKillServiceTimeout", new[] { "5000", "3000", "2000" } },
            { "WaitToKillAppTimeout", new[] { "5000", "3000", "2000" } },
            { "HungAppTimeout", new[] { "3000", "2000", "1000" } },
            { "TcpTimedWaitDelay", new[] { "60", "30", "30" } },
        };

        // The option for a plan level (1 Basic, 2 Elite, 3 Ultimate): the ladder above when the setting has one.
        public int RecommendedOption(HardwareInfo hw, int tier)
        {
            if (HasOptions && tier >= 1)
            {
                var a = Options.SelectMany(o => o.Apply).FirstOrDefault(x => x.IsRegistry && !string.IsNullOrEmpty(x.Name));
                string[] steps;
                if (a != null && Ladder.TryGetValue(a.Name, out steps))
                    for (int k = Math.Min(tier, 3); k >= 1; k--)
                    {
                        int i = Options.FindIndex(o => !o.IsDefault && o.Apply.Count > 0 && Convert.ToString(o.Apply[0].Value) == steps[k - 1]);
                        if (i >= 0) return i;
                    }
            }
            return RecommendedOption(hw);
        }

        // Index of the option the user should pick by default (RAM size, recommended, etc.)
        public int RecommendedOption(HardwareInfo hw)
        {
            if (!HasOptions) return -1;
            if (Auto == "ram" && hw != null && hw.RamGb > 0)
            {
                int best = -1;
                for (int i = 0; i < Options.Count; i++)
                    if (Options[i].Gb > 0 && Options[i].Gb <= hw.RamGb + 1) best = i;
                if (best >= 0) return best;
            }
            for (int i = 0; i < Options.Count; i++)
                if (Options[i].En.Contains("Recommended")) return i;
            for (int i = 0; i < Options.Count; i++)
                if (!Options[i].IsDefault) return i;
            return 0;
        }
    }

    public class Category
    {
        public string Id, Ar, En, Icon, Group;   // Group: sections shown together as tabs (cpu, gpu)
        public string Title { get { return L.Pick(Ar, En); } }
    }

    public class Catalog
    {
        public string Version;
        public List<Category> Categories = new List<Category>();
        public List<Category> Groups = new List<Category>();
        public List<Tweak> Tweaks = new List<Tweak>();

        public string LibraryVersion;
        public int DuplicatesRemoved;

        // The interface has one "Windows Debloat" page for all performance tweaks.
        static readonly HashSet<string> Merged = new HashSet<string> { "cpu", "ram", "gpu", "power", "gaming", "latency", "windows" };
        public static string MapCat(string c) { return c != null && Merged.Contains(c) ? "windows" : c; }

        // Tweaks that only make sense on one hardware vendor get their own section (Processor: Intel / AMD Ryzen,
        // Graphics card: NVIDIA / AMD Radeon / Intel), outside the plan boxes, so one vendor's driver settings
        // never land on another vendor's PC.
        const System.Text.RegularExpressions.RegexOptions RxOpt = System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.Compiled;
        const string DisplayClass = @"\{4d36e968-e325-11ce-bfc1-08002be10318\}";
        static readonly System.Text.RegularExpressions.Regex GpuNvidiaRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(nvlddmkm|nvhda|nvstor|nvsvc|nvtelemetry\w*|nvcontainer\w*|nvdisplay\w*)|\\software\\(wow6432node\\)?nvidia( corporation)?\\|\\nvtweak\\|" + DisplayClass + @"\|(rm\w+|nv\w+|powermizer\w*|perflevelsrc)$", RxOpt);
        static readonly System.Text.RegularExpressions.Regex GpuAmdRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(amdkmdag|amdkmdap|amdwddmg|amdgpuv|amdkmpfd|atikmdag|atikmpag|amdfendr\w*|amdacpbus|amdlog|amdxe|amdwdm\w*)|\\software\\(wow6432node\\)?(amd|ati technologies)\\|radeon|" + DisplayClass + @"\|(enableulps\w*|pp_\w+|kmd_\w+|dal\w+|enableaspm\w+|stuttermode|main3d\w*)$", RxOpt);
        static readonly System.Text.RegularExpressions.Regex GpuIntelRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(igfx\w*|cphs|intelgfx\w*)|\\software\\intel\\(display|gmm|igfx\w*)|igfxcui|\\intel\\gmm", RxOpt);
        static readonly System.Text.RegularExpressions.Regex CpuIntelRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(intelppm|intelpep|iastor\w*|ipf\w*|dptf\w*|heci\w*|mei\w*|intelpmt|intelide|intel\w*)|\bintelppm\b", RxOpt);
        static readonly System.Text.RegularExpressions.Regex CpuAmdRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(amdppm|amdi2c|amdgpio\w*|amdpsp|amdsata\w*|amdxata|amdsbs|amdpcidev|amdmicropep|amd\w*)|\bamdppm\b", RxOpt);

        // The packs' "advanced" folder is not a section of its own: each of its tweaks goes to the section it belongs to.
        static readonly System.Text.RegularExpressions.Regex NetworkRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(tcpip6?|afd|dnscache|psched|nlasvc|lanman\w+|netbt|ndisuio|rasman|dhcp|nsi|wcmsvc|wlansvc)(\\|\||$)|\\qos(\\|\||$)|\\psched(\\|\||$)|internet settings|\\tcpip(\\|\||$)|\\dnsclient(\\|\||$)|wifinetworkmanager|\\networklist(\\|\||$)|^(netsh|ipconfig|route)\b|-net(adapter|tcp|ipinterface)|dnsclient", RxOpt);
        static readonly System.Text.RegularExpressions.Regex PrivacyRx = new System.Text.RegularExpressions.Regex(
            @"datacollection|advertisinginfo|privacy|capabilityaccessmanager|diagtrack|dmwappush|telemetry|\\wdi(\\|\||$)|error reporting|\\appcompat(\\|\||$)|cloudcontent|contentdeliverymanager|\\location|activityfeed|\\inputpersonalization|speech_onecore|feedback|\\siuf(\\|\||$)|customer experience|\\ceip|\\sqmclient|\\autologger(\\|\||$)|\\winevt(\\|\||$)|wevtutil", RxOpt);
        static readonly System.Text.RegularExpressions.Regex StorageRx = new System.Text.RegularExpressions.Regex(
            @"\\filesystem(\\|\||$)|\\storage|\\disk(\\|\||$)|\\volumecaches|\\storagesense|\\defrag|^fsutil\b|^dism\b.*reservedstorage|\\backuprestore|\\systemrestore", RxOpt);
        static readonly System.Text.RegularExpressions.Regex MouseRx = new System.Text.RegularExpressions.Regex(@"control panel\\mouse|\\mouclass|\\mouhid|\\cursors(\\|\||$)", RxOpt);
        static readonly System.Text.RegularExpressions.Regex KeyboardRx = new System.Text.RegularExpressions.Regex(@"control panel\\keyboard|\\kbdclass|\\kbdhid|control panel\\accessibility\\(keyboard|stickykeys|togglekeys|filterkeys)", RxOpt);
        static readonly System.Text.RegularExpressions.Regex ControllerRx = new System.Text.RegularExpressions.Regex(
            @"\\joystick(\\|\||$)|\\gameinput(\\|\||$)|\\services\\(xboxgip|gameinputsvc|hidgame|xinputhid)(\\|\||$)|gamepad|xinput", RxOpt);
        public static bool IsController(string keyOrText) { return ControllerRx.IsMatch(keyOrText ?? ""); }

        public static string SectionFor(string keyOrText)
        {
            string s = keyOrText ?? "";
            if (ControllerRx.IsMatch(s)) return "controller";
            if (MouseRx.IsMatch(s)) return "mouse";
            if (KeyboardRx.IsMatch(s)) return "keyboard";
            if (NetworkRx.IsMatch(s)) return "network";
            if (PrivacyRx.IsMatch(s)) return "privacy";
            if (StorageRx.IsMatch(s)) return "storage";
            return "windows";
        }

        public static string VendorCat(string cat, string keyOrText, string name)
        {
            string s = (keyOrText ?? "") + "|" + (name ?? "");
            // graphics first: "amd..." services include both Radeon drivers and Ryzen chipset drivers
            if (GpuNvidiaRx.IsMatch(s)) return "gpu_nvidia";
            if (GpuAmdRx.IsMatch(s)) return "gpu_amd";
            if (GpuIntelRx.IsMatch(s)) return "gpu_intel";
            if (CpuIntelRx.IsMatch(s)) return "cpu_intel";
            if (CpuAmdRx.IsMatch(s)) return "cpu_amd";
            return cat;
        }

        // Settings that game anti-cheats (Vanguard, EasyAntiCheat, BattlEye, FACEIT) depend on or watch:
        // their own processes and services, driver signing, exploit protection (DEP / ASLR / CFG / SEHOP),
        // injection points, VBS / HVCI / Secure Boot / TPM, and per-game executable overrides.
        // Anything matching is left out of the app entirely.
        static readonly System.Text.RegularExpressions.Regex AntiCheatRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(vgk|vgc|easyanticheat\w*|beservice|bedaisy|faceit\w*|esportal\w*|xigncode\w*|nprotect\w*|gameguard\w*|mhyprot\w*)(\\|\||$)" +
            @"|\\image file execution options\\(vgc|vgk|vgtray|easyanticheat\w*|beservice\w*|faceit\w*|valorant\S*|fortniteclient\S*|r5apex\S*|cs2|csgo|cod\S*|modernwarfare\S*|tslgame\S*|rainbowsix\S*|overwatch\S*|eldenring\S*)\.exe" +
            @"|\\image file execution options\\[^\\|]+\|(debugger|globalflag|verifierdlls|mitigationoptions|mitigationauditoptions)$" +
            @"|appinit_dlls|loadappinit_dlls|requiresignedappinit" +
            @"|\\control\\ci\\|testsigning|nointegritychecks|ddisable_integrity|driversigning|kerneldebug" +
            @"|\\session manager\\kernel\|(mitigationoptions|mitigationauditoptions|disableexceptionchainvalidation|kernelsehopenabled)$" +
            @"|\\configuration manager\|disableexceptionchainvalidation$|\\memory management\|moveimages$|set-processmitigation|\bnx\s+(alwaysoff|optout)" +
            @"|\\deviceguard\\|\\deviceguard\||hypervisorenforcedcodeintegrity|enablevirtualizationbasedsecurity|credentialguard|lsacfgflags|systemguard|hypervisorlaunchtype" +
            @"|secureboot|\\autologger\\tpm\w*\||\\services\\tpm(\\|\||$)", RxOpt);

        public static bool AntiCheatUnsafe(string keyOrText, string name)
        {
            string s = (keyOrText ?? "") + "|" + (name ?? "");
            if (s.IndexOf(@"\WINEVT\", StringComparison.OrdinalIgnoreCase) >= 0) return false;   // event-log channel settings only
            return AntiCheatRx.IsMatch(s);
        }
        public int AntiCheatRemoved;

        // Plans by share of each section's library: Basic gets the most-used 30%, Elite 60%, Ultimate everything.
        // Hand-picked tweaks keep the tier they were written with.
        // Shares are worked out separately for what goes into the plan boxes and for the rest,
        // so the boxes themselves come out at 30% / 60% / 100%.
        void Retier()
        {
            foreach (var g in Tweaks.Where(t => t.Library).GroupBy(t => t.Cat + "|" + BoxEligible(t)))
            {
                var list = g.OrderByDescending(t => t.Packs).ThenBy(t => t.Id, StringComparer.Ordinal).ToList();
                for (int i = 0; i < list.Count; i++)
                {
                    double share = (i + 1) / (double)list.Count;
                    list[i].Tier = share <= 0.30 ? 1 : share <= 0.60 ? 2 : 3;
                }
            }
        }

        // Settings copied from someone else's PC that do nothing on another one: other apps' settings,
        // per-game and per-adapter IDs, a DHCPv6 identity, and leftovers with renamed values. Left out of the app.
        static readonly System.Text.RegularExpressions.Regex JunkRx = new System.Text.RegularExpressions.Regex(
            @"\\software\\(wow6432node\\)?(sysinternals|hone|openshell|classicshell|google|mozilla|valve|epic games|discord|spotify|microsoft\\office|bluestacks\w*|smartgaga|ldplayer\w*|memu\w*|nox\w*|mojang|officialhawk|ibluecombo|roblox|echox|lav|tencent|txgameassistant|garena|netease)(\\|\||$)" +
            @"|\\directx\\usergpupreferences\|(?!directxuserglobalsettings$)|\\directx\\graphicssettings\|(?!swapeffectupgrade)|\\directx\\\{|\\direct3d\\drivers(\\|\|)" +
            @"|\\joystick\\oem(\\|\||$)|\\gameinput\\devices(\\|\||$)" +   // someone else's controllers, by device ID
            @"|\\policies\\(google|mozilla|brave\w*)(\\|\||$)|\\gameconfigstore\\children\\|\\resourcepolicystore\\|\\currentversion\\qualitycompat(\\|\|)|\\backgroundmodel(\\|\|)" +
            @"|\\interfaces\\\{[0-9a-f-]+\}(\\|\||$)|\\probe\\\{|\\services\\(vxd|class|adf|msftproxy)(\\|\||$)|\\services\\tcpip\\mojang|\\currentcontrolset\\software\\|\\control\\class\{" +
            @"|^hkey_local_machine\\system\||\\currentversion\\(run|runonce|runservices|runservicesonce)(\\|\|)|\\explorer\\startupapproved\\|^hkey_current_user\\environment\||\\appcompatflags\\layers(\\|\|)" +
            @"|\|(proxyserver|proxyoverride|autoconfigurl|hostname|nv hostname|computername)$|\\(user )?shell folders(\\|\|)|\\currentversion\\ext(\\|\|)|\\microsoft\\directx\|" +
            // another tool's branding: Windows' name, owner, OEM / support info, computer name, its own right-click menu entries
            @"|\\windows nt\\currentversion\|(productname|registeredowner|registeredorganization|editionid|displayversion|releaseid|currentbuild\w*|buildlab\w*|installationtype)$|\\oeminformation(\\|\|)|\\computername\\" +
            @"|\\(directory\\background|desktopbackground|directory|folder|drive|allfilesystemobjects|\*|lnkfile|exefile)\\shell(ex)?(\\|\|)|\\group policy\\datastore(\\|\|)" +
            @"|\\software\\(wow6432node\\)?(policies\\)?(smart-x|vivaldi|javasoft|piriform|firestorm|\{?[0-9a-f]{8}-[0-9a-f-]+\}?)(\\|\||$)|\\shareddlls(\\|\|)|\\services\\tcpip\\enum(\\|\|)" +
            @"|\\microsoft\\(windowsnt|windowsselfhost)\\|\\onedrive\\accounts\\|\\directinput\\[^\\|]+\.exe" +
            @"|\\services\\[^\\|]+\|(start_old|start_alt|stop|wsearch)$|\\sharedaccess\\epoch(\\|\|)" +
            @"|\|(dhcpv6duid|dhcpv6iaid|[^|\\]+\.(org|off|old|bak)|_help)$", RxOpt);
        public int JunkRemoved;
        static readonly System.Text.RegularExpressions.Regex BrandRx = new System.Text.RegularExpressions.Regex(
            @"3ntr|yzxmu|discord\.gg|discord\s*:|insta(gram)?\s*:|instagram\.com|youtube\.com/|t\.me/|alpha\s*game\s*mode|tiktok\.com", RxOpt);

        // Values that are fine to set one at a time but not thousands at once from other people's packs:
        // kernel, memory, power definitions, drivers and device instances, DMA, service wiring, the network
        // stack's bindings, sign-in, file types, and anything that turns off Windows protection, Update or the Store.
        // In the box test these took a VM to a blue screen. They stay available one by one with a restore point.
        static readonly System.Text.RegularExpressions.Regex BulkUnsafeRx = new System.Text.RegularExpressions.Regex(
            @"\\control\\(session manager|power|processor|class|graphicsdrivers|video|wmi|lsa|securityproviders|safeboot|crashcontrol|nsi|networkprovider|servicegrouporder|grouporderlist|pnp|deviceclasses|criticaldevicedatabase|firmwareresources|bootdriverflags|storport|usbflags|kernel-power|ci|deviceguard)(\\|\||$)" +
            @"|\\services\\(dxgkrnl|ndis|pci|acpi\w*|usb\w*|storport|stornvme|storahci|disk|partmgr|volmgr\w*|volsnap|iastor\w*|nvme\w*|vdrvroot|compositebus|umbus|msisadrv|hdaudbus|basicrender|basicdisplay|monitor|kbdhid|mouhid|kbdclass|mouclass|i8042prt|xinputhid|tsddd|w32time|lfsvc|netbt|dns|nsi|tdx|wfplwfs|rdyboost|fvevol|ehstorclass|wudf\w*|ntfs|fltmgr)(\\|\||$)" +
            @"|\\services\\[^\\|]+\|(dependonservice|dependongroup|imagepath|type|group|tag|errorcontrol|objectname|servicedll|servicesidtype|requiredprivileges|failureactions|launchprotected)$" +
            @"|\\services\\(rpcss|dcomlaunch|rpceptmapper|lsm|samss|eventlog|eventsystem|winmgmt|plugplay|power|profsvc|schedule|themes|audiosrv|audioendpointbuilder|dhcp|dnscache|nlasvc|netprofm|lanmanworkstation|lanmanserver|cryptsvc|brokerinfrastructure|systemeventsbroker|timebrokersvc|coremessagingregistrar|staterepository|usermanager|gpsvc|fontcache|tokenbroker|camsvc|wlansvc|wwansvc|netman|netsetupsvc|tcpip6?|afd|bfe|mpssvc|keyiso|vaultsvc|appinfo|shellhwdetection|sens|wpnservice|wpnuserservice\w*|cdpsvc|cdpusersvc\w*|seclogon|stisvc|wiaservice|spooler|bthserv|bthavctpsvc|hidserv|dispbrokerdesktopsvc|displayenhancementservice|textinputmanagementservice)\|start$" +
            @"|\\services\\(windefend|wdnissvc|wdfilter|wdboot|wdnisdrv|securityhealthservice|sense|wscsvc|wuauserv|usosvc|waasmedicsvc|bits|dosvc|installservice|clipsvc|appxsvc|licensemanager|wlidsvc|tokenbroker|sgrmbroker|sgrmagent)(\\|\||$)" +
            @"|\\linkage(\\|\|)|\\winsock2?(\\|\|)|\\parameters\\protocol_catalog|\\image file execution options\\|\\winlogon(\\|\|)|\\windowsruntime\\|\\policymanager\\" +
            @"|^hkey_classes_root\\|\\software\\(wow6432node\\)?classes\\|\\featuremanagement(\\|\|)|\\winevt(\\|\|)|\\control\\filesystem(\\|\|)|\\services\\pshed(\\|\|)" +
            @"|\\explorer\\(advanced|visualeffects)\\|\\explorer\\(startmenu|foldertypes|commandstore|folderdescriptions|kindmap|autoplayhandlers|shellserviceobjects|volumecaches|desktop\\namespace|mycomputer\\namespace|browser helper objects|shellexecutehooks)(\\|\|)|\\shell extensions(\\|\|)" +
            @"|^hkey_local_machine\\software\\(wow6432node\\)?microsoft\\windows\\currentversion\\explorer\\(?!(hidedesktopicons|flyoutmenusettings|serialize)(\\|\|))" +
            // network: only the well-known TCP / AFD tuning values, never adapter, lease, route or Winsock data
            @"|\\services\\tcpip6?\\parameters\\(?!interfaces\|)|\\services\\tcpip6?\\parameters(\\interfaces)?\|(?!(tcpackfrequency|tcpnodelay|tcpdelackticks|defaultttl|tcptimedwaitdelay|maxuserports|tcp1323opts|sackopts|tcpmaxdupacks|enablepmtudiscovery|enablepmtubhdetect|tcpmaxdataretransmissions|keepalivetime|keepaliveinterval|maxfreetcbs|maxhashtablesize|tcpnumconnections|numtcbtablepartitions|maxconnectionsperserver|maxconnectionsper1_0server|globalmaxtcpwindowsize|tcpwindowsize|tcpmaxconnectretransmissions|tcpfinwait2delay|disabletaskoffload|enabledca|enablerss|enabletcpa|enableicmpredirect|disableipsourcerouting|synattackprotect|enableconnectionratelimiting|tcpcreateandconnecttcbratelimitdepth|disableusertossetting|tcpmaxsendfree|stricttimewaitseqcheck|enablewsd|enableheuristics|tcpmaxconnectresponseretransmissions|tcpusrfc1122urgentpointer)$)" +
            @"|\\services\\afd\\parameters\|\w*(buffersize|buffermultiplier|buffercount|transmitfilecount)$|\\services\\(lanmanserver|lanmanworkstation|mrxsmb\w*|netlogon)(\\|\|)" +
            @"|\\internet settings\\(zones|lockdown_zones|zonemap\w*)(\\|\|)|\\policies\\microsoft\\windows\\currentversion\\internet settings(\\|\|)|\|(proxyenable|databasepath)$" +
            @"|\\terminal serv(er|ices)(\\|\|)|\\group policy(\\|\|)|\\policies\\microsoft\\(fve|edge|edgeupdate|mrt|devicehealthattestationservice)(\\|\|)|\\systemcertificates\\|systemrestore|\\control\\print\\" +
            @"|\\services\\(xusb\w*|bthport|bthusb|bthenum|hidusb|hidclass|rasman|tcpip6?)\|" +
            // svchost grouping is the hand-picked "group services by RAM size" tweak's job; per-service switches would fight it
            @"|\|svchostsplitdisable$|\\performance\|(disable performance counters|collect timeout)$|\\services\\[^\\|]+\|(description|displayname)$|\\services\\[^\\|]+\\security(\\|\|)|\|internetmtu$|\\services\\(gpuenergydrv|hidusbf|atierecord)(\\|\|)" +
            @"|\\services\\(xusb\w*|bthport|bthusb|bthenum|hidusb|hidclass|hidparse|rasman)\\" +
            @"|\\policies\\system\|(enablelua|consentpromptbehavior\w+|promptonsecuredesktop|enableinstallerdetection|enablesecureuiapaths|enablevirtualization|filteradministratortoken|validateadmincodesignatures|localaccounttokenfilterpolicy|enableuiadesktoptoggle)$" +
            @"|windows defender|windows security health|smartscreen|\\windowsupdate(\\|\|)|\\windowsstore(\\|\|)|\\deliveryoptimization(\\|\|)|\\appx(\\|\|)" +
            @"|\|(dmaremappingcompatible\w*|mtu|mss|disabledcomponents|ipautoconfigurationenabled|dontadddefaultgatewaydefault|deadgwdetectdefault|forwardbroadcasts|enableactiveprobing|activednsprobe\w*|activewebprobe\w*|enableautodoh|nodetype|tracknblowner|portauth\w*)$", RxOpt);
        public static bool BulkUnsafe(Tweak t) { return t.Path != null && BulkUnsafeRx.IsMatch(PipePath(t.Path)); }

        // Services Windows can't run without. Pack settings that change how they start are left out of the app.
        const string CriticalServices = "rpcss|dcomlaunch|rpceptmapper|lsm|samss|eventlog|eventsystem|winmgmt|plugplay|power|profsvc|schedule|themes|audiosrv|audioendpointbuilder|dhcp|dnscache|nlasvc|netprofm|nsi|lanmanworkstation|cryptsvc|brokerinfrastructure|systemeventsbroker|timebrokersvc|coremessagingregistrar|staterepository|usermanager|gpsvc|fontcache|tokenbroker|camsvc|wlansvc|netman|tcpip6?|afd|bfe|mpssvc|keyiso|vaultsvc|appinfo|wpnservice|cdpsvc|dispbrokerdesktopsvc|textinputmanagementservice|hidserv|sens|seclogon|mmcss|ndu|dps|wdiservicehost|wdisystemhost|trustedinstaller|msiserver|sgrmbroker|clipsvc";
        // The only services a pack may switch off or change the startup of: well known ones nobody needs for
        // sound, input, network, storage, search, sign-in or security. Every other service or driver startup
        // change is removed from the app (packs disabled audio, keyboard and storage drivers, which broke PCs).
        static readonly System.Text.RegularExpressions.Regex SafeServiceRx = new System.Text.RegularExpressions.Regex(
            @"^(diagtrack|dmwappushservice|dmwappushsvc|mapsbroker|retaildemo|lfsvc|wersvc|wercplsupport|walletservice|phonesvc|diagnosticshub\.standardcollector\.service|diagsvc|fax|" +
            @"xblauthmanager|xblgamesave|xboxnetapisvc|xbgm|bcastdvruserservice\w*|wmpnetworksvc|remoteregistry|sysmain|pcasvc|trkwks|wpcmonsvc|wisvc|sharedrealitysvc|perceptionsimulation|" +
            @"semgrsvc|smsrouter|messagingservice\w*|onesyncsvc\w*|pimindexmaintenancesvc\w*|unistoresvc\w*|userdatasvc\w*|ajrouter|nettcpportsharing|ssh-agent|sshd|homegrouplistener|homegroupprovider|" +
            @"adobeflashplayerupdatesvc|edgeupdate|edgeupdatem|gupdate|gupdatem|mozillamaintenance|nvtelemetrycontainer|fhsvc|appvclient|uevagentservice|vmic\w+|hvhost|" +
            @"scardsvr|scdeviceenum|scpolicysvc|cscservice|irmon|wmanservice|wmansvc|retaildemo|icssvc|mixedrealityopenxrsvc|spectrum|dusmsvc|pushtoinstall|" +
            @"troubleshootingsvc|wpcmon|tiledatamodelsvc|aelookupsvc|adobearmservice|googlechromeelevationservice|microsoftedgeelevationservice|braveelevationservice|brave|bravem)$", RxOpt);
        public static bool SafeService(string svc) { return svc != null && SafeServiceRx.IsMatch(svc.Trim('"')); }

        // Services and features that protect Windows or keep it updated (Defender, firewall, Update, Store).
        const string ProtectionServices = "windefend|wdnissvc|wdfilter|wdboot|wdnisdrv|securityhealthservice|sense|wscsvc|wuauserv|usosvc|waasmedicsvc|bits|dosvc|installservice|appxsvc|licensemanager|wlidsvc|sgrmagent|mpssvc|mpsdrv|bfe";

        // Pack settings that can crash Windows or leave it unbootable when applied (kernel and memory, driver and
        // device settings, DMA, power definitions, boot / safe mode, service wiring, network bindings and addresses
        // that cut the connection, file types of programs). Removed from the app entirely.
        static readonly System.Text.RegularExpressions.Regex DangerRx = new System.Text.RegularExpressions.Regex(
            @"\\control\\(session manager|processor|class|graphicsdrivers|video|safeboot|nsi|networkprovider|servicegrouporder|grouporderlist|pnp|deviceclasses|criticaldevicedatabase|firmwareresources|bootdriverflags|storport|usbflags|kernel-power|ci|deviceguard)(\\|\||$)" +
            @"|\\control\\power\\(powersettings|user)(\\|\|)|\\featuremanagement(\\|\|)" +
            @"|\\services\\(dxgkrnl|ndis|pci|acpi\w*|usb\w*|storport|stornvme|storahci|disk|partmgr|volmgr\w*|volsnap|iastor\w*|nvme\w*|vdrvroot|compositebus|umbus|msisadrv|hdaudbus|basicrender|basicdisplay|monitor|xinputhid|tsddd|tdx|wfplwfs|rdyboost|fvevol|ehstorclass|ntfs|fltmgr|xusb\w*|bthport|bthusb|bthenum|hidusb|hidclass|hidparse|gpuenergydrv|pshed)(\\|\|)" +
            @"|\\services\\(" + CriticalServices + @")\|start$" +
            @"|\\services\\[^\\|]+\|(dependonservice|dependongroup|imagepath|type|group|tag|errorcontrol|objectname|servicedll|servicesidtype|requiredprivileges|failureactions|launchprotected|description|displayname)$|\\services\\[^\\|]+\\security(\\|\|)" +
            @"|\|dmaremappingcompatible\w*$|\\linkage(\\|\|)|\\winsock2?(\\|\|)|\\parameters\\protocol_catalog|\\image file execution options\\|\\winlogon(\\|\|)" +
            @"|\\services\\tcpip6?\\parameters\\(persistentroutes|adapters|dnsregisteredadapters|winsock)(\\|\|)" +
            @"|\\services\\tcpip6?\\parameters(\\interfaces)?\|(ipenablerouter\w*|dhcp\w*|lease\w*|t1|t2|interfacemetric|addresstype|ipconfig|llinterface|ntecontextlist|enabledeadgwdetect|performrouterdiscovery\w*|ipautoconfiguration\w*|dontadddefaultgateway\w*|deadgwdetectdefault|forwardbroadcasts|usezerobroadcast)$" +
            @"|\|(mtu|mss|maxmtu|enableactiveprobing|activednsprobe\w*|activewebprobe\w*|nodetype|tracknblowner|portauth\w*)$" +
            @"|\\(exefile|batfile|cmdfile|comfile|lnkfile|regfile|\.exe|\.lnk|\.bat|\.cmd|\.com|\.reg)(\\|\|)" +
            // breaks Windows features: Task Manager needs the performance counters, Start needs search
            @"|\\performance\|(disable performance counters|collect timeout)$|\\windows search\|(disablesearch|searchontaskbarmode|preventindexingoutlook)$|\\search\\disablesearch(\\|\|)" +
            @"|\\policies\\(explorer|system)\|(nofind|disabletaskmgr|noclose|nocontrolpanel|norun|disableregistrytools|disablecmd)$", RxOpt);
        public int DangerRemoved;

        // Turns off Windows protection, Update or the Store: kept one by one, never in "Apply all" or a box.
        static readonly System.Text.RegularExpressions.Regex ProtectRx = new System.Text.RegularExpressions.Regex(
            @"windows defender|windows security health|smartscreen|\\windowsupdate(\\|\|)|\\windowsstore(\\|\|)|\\deliveryoptimization(\\|\|)|\\appx(\\|\|)|\\policies\\microsoft\\(mrt|fve|devicehealthattestationservice)(\\|\|)" +
            @"|\\policies\\system\|(enablelua|consentpromptbehavior\w+|promptonsecuredesktop|enableinstallerdetection|enablesecureuiapaths|enablevirtualization|filteradministratortoken|validateadmincodesignatures|localaccounttokenfilterpolicy)$" +
            @"|systemrestore|\\systemcertificates\\|\\terminal serv(er|ices)(\\|\|)|\\control\\(lsa|securityproviders)(\\|\|)|\\autologger\\defender\w*" +
            @"|\\firewallpolicy(\\|\|)|\\policies\\microsoft\\windowsfirewall(\\|\|)" +
            // app permissions (microphone for Discord, camera, ...): one by one only, never forced off in bulk
            @"|\\appprivacy(\\|\|)|\\consentstore\\(microphone|webcam)(\\|\|)" +
            @"|\\services\\(" + ProtectionServices + @")(\\|\||$)", RxOpt);

        // ---------------------------------------------------------------- commands
        // Dropped from the app: script fragments that do nothing alone, anything that deletes (tasks, features,
        // files, packages), stops / starts services mid-way, restarts the PC, downloads or runs hidden code,
        // touches boot settings, turns off TRIM, or changes how a critical service starts.
        static readonly System.Text.RegularExpressions.Regex CmdDropRx = new System.Text.RegularExpressions.Regex(
            @"^(wmic|echo|goto|if|set(?!-)|pause|exit|cls|title|color|chcp|timeout|choice|call|for|setlocal|endlocal|rem|cd|start(?!-)|copy|xcopy|move|mkdir|md|del|erase|rd|rmdir|attrib|cacls|icacls|takeown|bcdedit|diskpart|format|shutdown|taskkill|tasklist|vssadmin|wbadmin|cipher|cleanmgr|sfc|chkdsk|regsvr32|rundll32|msiexec|curl|bitsadmin|certutil|powershell|cmd|explorer|control|mmc|gpupdate|ping|tracert|net|reg|label|find|findstr|type|ren|runas|::|@)\b" +
            @"|^sc(\.exe)?\s+(?!config\b)|^sc(\.exe)?\s+config\s+\S+\s+(?!start\s*=)|^sc(\.exe)?\s+config\s+\S+\s+(depend|binpath|obj|type|displayname|group|password)\s*=|^sc(\.exe)?\s+config\s+\S+\s+start\s*=\s*(boot|system|enabled|autoz)\b" +
            @"|^sc(\.exe)?\s+config\s+""?(" + CriticalServices + @")""?\s|set-service\b.*-name\s+""?(" + CriticalServices + @")""?(\s|$)" +
            @"|^schtasks(\.exe)?\b.*/(delete|create|run|end|query)\b" +
            @"|^dism(\.exe)?\b.*/(remove-|cleanup-image|add-|get-|enable-feature\s*/featurename:\W?netfx3)|^dism(\.exe)?\s*(\||$)" +
            @"|^fsutil\b.*\b(query|usn|deletejournal|disabledeletenotify\s+(refs\s+)?1|repair|hardlink|setzerodata)\b|^fsutil\s+(file|volume)\b" +
            @"|^powercfg(\.exe)?\b.*\s[-/](setactive|s|delete|d|import|duplicatescheme|restoredefaultschemes|changename|export|h|hibernate)(\s|$)|^powercfg\.cpl" +
            @"|^(start-sleep|start-transcript|stop-transcript|add-type|new-psdrive|remove-psdrive|set-executionpolicy|new-service|remove-service|start-process|stop-process|start-service|stop-service|restart-service|suspend-service|restart-computer|stop-computer|takeown\S*|remove-item|new-item|copy-item|move-item|rename-item|remove-appx\S*|get-\S+|write-\S+|invoke-\S+|new-folderforced|remove-keys|start-debloat|stop-edgepdf|set-windowssearchsetting|set-timerresolution|set-physicaldisk|clear-\S+|read-host|out-\S+|if|foreach|for|function|try|catch|return|exit|param|import-\S+|install-\S+|uninstall-\S+|enable-computerrestore|checkpoint-computer|disable-computerrestore)\b|^[\$\{\}\(\)#]" +
            @"|activescripteventconsumer|__eventfilter|downloadstring|downloadfile|\biex\b|frombase64|encodedcommand|bcdedit|\bdel\s|\brd\s|rmdir|shutdown|restart-computer" +
            @"|(set|new)-itemproperty\b.*(session manager|memory management|\\services\\|control\\class|graphicsdrivers|control\\power|winlogon|image file execution|linkage|winsock|safeboot)", RxOpt);
        // Kept one by one only: network commands (they can cut the connection) and anything that turns off protection / Update / Store.
        static readonly System.Text.RegularExpressions.Regex CmdNoBulkRx = new System.Text.RegularExpressions.Regex(
            @"^(netsh|ipconfig|route|arp|nbtstat|nslookup)\b|-net(adapter|tcp|ipinterface|ipv4|ipv6|offload|firewall|qos|transport|route|neighbor|lbfo)\w*|dnsclient|-netadapter" +
            @"|\b(" + ProtectionServices + @")\b|set-mppreference|add-mppreference|windows defender|windowsupdate|updateorchestrator|waasmedic|exploitguard|smartscreen|windowsstore", RxOpt);

        static string CleanCmd(string c, bool ps)
        {
            c = (c ?? "").Trim();
            if (!ps) c = System.Text.RegularExpressions.Regex.Replace(c, @"\s*>\s*\$null\s*$", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);   // PowerShell redirection in a CMD line
            return c;
        }

        // What a command sets (one service's startup, one task, one feature, one power setting...), so commands that
        // set the same thing to different values can be told apart: only one of them may stay.
        static readonly System.Text.RegularExpressions.Regex[] TargetRx =
        {
            new System.Text.RegularExpressions.Regex(@"^sc(?:\.exe)?\s+config\s+""?([^\s""]+)""?\s+start\s*=", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^set-service\s+(?:-name\s+)?[""']?([^\s""']+)[""']?.*-startuptype", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^schtasks(?:\.exe)?\s+/change\b.*?/tn\s+""([^""]+)""", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^schtasks(?:\.exe)?\s+/change\b.*?/tn\s+(\S+)", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^dism(?:\.exe)?\b.*?/(?:enable|disable)-feature\s*/featurename:\W?([\w\.-]+)", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^fsutil\s+behavior\s+set\s+(\w+(?:\s+refs)?)", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^powercfg(?:\.exe)?\s+[-/]set(?:ac|dc)valueindex\s+(\S+\s+\S+\s+\S+)", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^powercfg(?:\.exe)?\s+[-/](change\s+[-/]?\S+)", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^powercfg(?:\.exe)?\s+[-/]attributes\s+(\S+\s+\S+)", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^wevtutil(?:\.exe)?\s+sl\s+""?([^""]+?)""?\s+/", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^(?:set|new)-itemproperty\s+(?:-path\s+)?[""']?([^""']+?)[""']?\s+(?:-name\s+)?[""']?([^""'\s]+)", RxOpt),
            new System.Text.RegularExpressions.Regex(@"^dism(?:\.exe)?\b.*?/(set-reservedstoragestate)", RxOpt),
        };

        // PowerShell lines must start with a real command; anything else is a piece of someone's script
        // (their own functions, variables, loops) and does nothing on its own.
        static readonly System.Text.RegularExpressions.Regex PsKnownRx = new System.Text.RegularExpressions.Regex(
            @"^(set-itemproperty|new-itemproperty|remove-itemproperty|set-service|disable-scheduledtask|enable-scheduledtask|disable-mmagent|enable-mmagent|set-mmagent|disable-windowsoptionalfeature|enable-windowsoptionalfeature|set-mppreference|add-mppreference|set-net\S*|enable-net\S*|disable-net\S*|set-dnsclient\S*|remove-netfirewallrule|new-netfirewallrule|powercfg(\.exe)?|schtasks(\.exe)?|sc(\.exe)?|dism(\.exe)?|fsutil|wevtutil(\.exe)?|netsh)\b", RxOpt);
        static readonly System.Text.RegularExpressions.Regex FsutilKnownRx = new System.Text.RegularExpressions.Regex(
            @"^fsutil\s+behavior\s+set\s+(disablelastaccess|disable8dot3|mftzone|disabledeletenotify|encryptpagingfile|disablecompression|disableencryption|bugcheckoncorrupt|memoryusage|symlinkevaluation)\b", RxOpt);
        // "sc config X start= disabled" / "Set-Service X -StartupType Disabled" / "Set-ItemProperty -Path HKLM:\.. -Name N -Value V"
        // as registry actions. null: not such a command. Empty list: a service packs may not touch.
        static readonly System.Text.RegularExpressions.Regex ScStartRx = new System.Text.RegularExpressions.Regex(@"^sc(?:\.exe)?\s+config\s+""?([^\s""]+)""?\s+start\s*=\s*""?([a-z-]+)", RxOpt);
        static readonly System.Text.RegularExpressions.Regex SetServiceRx = new System.Text.RegularExpressions.Regex(@"^set-service\s+(?:-name\s+)?[""']?([^\s""']+)[""']?.*?-startuptype\s+[""']?([a-z]+)", RxOpt);
        static readonly System.Text.RegularExpressions.Regex SetItemRx = new System.Text.RegularExpressions.Regex(
            @"^(?:set|new)-itemproperty\s+(?:-path\s+)?[""']?([^""']+?)[""']?\s+(?:-name\s+)?[""']?([^""'\s]+)[""']?\s+(?:-value\s+)?[""']?([^""'\s]+)[""']?(?:\s+-(?:type|propertytype)\s+(\w+))?", RxOpt);
        static List<TAction> CommandAsRegistry(string c)
        {
            var m = ScStartRx.Match(c);
            if (!m.Success) m = SetServiceRx.Match(c);
            if (m.Success)
            {
                string svc = m.Groups[1].Value, mode = m.Groups[2].Value.ToLowerInvariant();
                long start = mode.StartsWith("auto") ? 2 : mode == "delayed-auto" ? 2 : mode == "demand" || mode == "manual" ? 3 : mode == "disabled" ? 4 : -1;
                if (start < 0 || !SafeService(svc)) return new List<TAction>();
                string key = @"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\" + svc;
                var list = new List<TAction> { new TAction { Kind = "reg", Key = key, Name = "Start", Type = "dw", Value = start } };
                if (mode == "delayed-auto") list.Add(new TAction { Kind = "reg", Key = key, Name = "DelayedAutostart", Type = "dw", Value = 1L });
                return list;
            }
            m = SetItemRx.Match(c);
            if (m.Success)
            {
                string p = System.Text.RegularExpressions.Regex.Replace(m.Groups[1].Value, @"^registry::", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                p = System.Text.RegularExpressions.Regex.Replace(p, @"^hklm:\\?", @"HKEY_LOCAL_MACHINE\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                p = System.Text.RegularExpressions.Regex.Replace(p, @"^hkcu:\\?", @"HKEY_CURRENT_USER\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                p = System.Text.RegularExpressions.Regex.Replace(p, @"^hku\\", @"HKEY_USERS\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                p = FixKey(p.TrimEnd('\\'));
                if (p == null || p.IndexOf(@"\Default_User\", StringComparison.OrdinalIgnoreCase) >= 0) return new List<TAction>();
                string v = m.Groups[3].Value, type = m.Groups[4].Value.ToLowerInvariant();
                long n;
                bool num = type != "string" && type != "expandstring" && long.TryParse(v, out n);
                if (num && (long.Parse(v) < 0 || long.Parse(v) > 0xFFFFFFFFL)) return new List<TAction>();
                return new List<TAction> { new TAction { Kind = "reg", Key = p, Name = m.Groups[2].Value, Type = num ? (type == "qword" ? "qw" : "dw") : "sz", Value = num ? (object)long.Parse(v) : v } };
            }
            return null;
        }

        public static string CommandTarget(string c) { return CmdTarget(c); }
        static string CmdTarget(string c)
        {
            for (int i = 0; i < TargetRx.Length; i++)
            {
                var m = TargetRx[i].Match(c);
                if (!m.Success) continue;
                string g = m.Groups[1].Value + (m.Groups.Count > 2 ? "|" + m.Groups[2].Value : "");
                int kind = i == 1 ? 0 : i == 3 ? 2 : i;   // Set-Service and sc config both set a service's startup
                g = System.Text.RegularExpressions.Regex.Replace(g.ToLowerInvariant(), @"\s+", " ").Trim();
                if (kind == 2) g = g.TrimStart('\\');      // "\Microsoft\Windows\X" and "Microsoft\Windows\X" are the same task
                return kind + ":" + g;
            }
            return null;
        }
        public int CommandsDropped, ConflictsRemoved;

        // One command per target (the one most packs use). A service whose startup is also a registry tweak
        // keeps the registry tweak, which can be undone exactly.
        void ResolveCommands()
        {
            var startKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var regValues = new HashSet<string>();
            foreach (var t in Tweaks)
                foreach (var a in t.Apply.Concat(t.Options == null ? new List<TAction>() : t.Options.SelectMany(o => o.Apply)))
                {
                    if (!a.IsRegistry) continue;
                    regValues.Add(NormPath(a.Key, a.Name));
                    string svc;
                    if ("Start".Equals(a.Name, StringComparison.OrdinalIgnoreCase) && (svc = ServiceName(a.Key)) != null) startKeys.Add(svc);
                }
            var drop = new HashSet<Tweak>();
            // commands turned into registry values: a value another tweak already writes stays with that tweak,
            // and of several commands writing the same value only the most used one stays
            var owned = new HashSet<string>(Tweaks.Where(t => !t.Id.StartsWith("c."))
                .SelectMany(t => t.Apply.Concat(t.Options == null ? new List<TAction>() : t.Options.SelectMany(o => o.Apply)))
                .Where(a => a.IsRegistry).Select(a => NormPath(a.Key, a.Name)));
            foreach (var g in Tweaks.Where(t => t.Id.StartsWith("c.") && !t.NoUndo).GroupBy(t => NormPath(t.Apply[0].Key, t.Apply[0].Name)))
            {
                if (owned.Contains(g.Key)) { foreach (var t in g) drop.Add(t); continue; }
                foreach (var t in g.OrderByDescending(t => t.Packs).ThenBy(t => t.Id, StringComparer.Ordinal).Skip(1)) drop.Add(t);
            }
            foreach (var g in Tweaks.Where(t => t.Library && t.NoUndo).Select(t => new { T = t, K = CmdTarget(t.Apply[0].Command) }).Where(x => x.K != null).GroupBy(x => x.K))
            {
                if (g.Key.StartsWith("0:") && startKeys.Contains(g.Key.Substring(2))) { foreach (var x in g) drop.Add(x.T); continue; }
                if (g.Key.StartsWith("10:"))
                {
                    // Set-ItemProperty of a value that is already a registry tweak (which can be undone exactly)
                    string p = System.Text.RegularExpressions.Regex.Replace(g.Key.Substring(3), @"^registry::", "", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                    p = System.Text.RegularExpressions.Regex.Replace(p, @"^hklm:\\?", @"HKEY_LOCAL_MACHINE\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                    p = System.Text.RegularExpressions.Regex.Replace(p, @"^hkcu:\\?", @"HKEY_CURRENT_USER\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                    p = System.Text.RegularExpressions.Regex.Replace(p, @"^hkcr:\\?", @"HKCR\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                    int bar = p.LastIndexOf('|');
                    if (bar > 0 && regValues.Contains(NormPath(p.Substring(0, bar), p.Substring(bar + 1)))) { foreach (var x in g) drop.Add(x.T); continue; }
                }
                foreach (var x in g.OrderByDescending(x => x.T.Packs).ThenBy(x => x.T.Id, StringComparer.Ordinal).Skip(1)) drop.Add(x.T);
            }
            ConflictsRemoved += drop.Count;
            Tweaks.RemoveAll(drop.Contains);
        }

        // "key\name" -> "key|name" so the rules above can tell a key from a value name.
        static string PipePath(string path)
        {
            int i = path.LastIndexOf('\\');
            return i < 0 ? path : path.Substring(0, i) + "|" + path.Substring(i + 1);
        }

        // Library settings safe to switch on in bulk from a plan box: registry only (exact undo), no risk flag,
        // used by 2+ packs, and never an address setting (DNS / IP / gateway / DHCP).
        static readonly System.Text.RegularExpressions.Regex AddressRx = new System.Text.RegularExpressions.Regex(
            @"\\(nameserver|dhcpnameserver|searchlist|domain|dhcpdomain|ipaddress|subnetmask|defaultgateway|enabledhcp|dhcpserver|registrationenabled)$", RxOpt);
        public static bool AddressSetting(Tweak t) { return t.Path != null && AddressRx.IsMatch(t.Path); }
        // A pack setting that writes the same setting as a hand-picked tweak but a different value works against it
        // (Fast Startup on vs off, QoS 10% vs 0%, ...). It is removed from the app.
        // MMCSS task profiles are the exception: each task (Games, Audio, ...) has its own priorities.
        public int ClashesRemoved;
        void MarkClashes()
        {
            var picked = new Dictionary<string, List<TAction>>(StringComparer.OrdinalIgnoreCase);
            foreach (var t in Tweaks.Where(t => t.Curated && t.Risk <= 1))
                foreach (var a in t.Apply.Where(a => a.IsRegistry && !string.IsNullOrEmpty(a.Name)))
                {
                    List<TAction> l;
                    if (!picked.TryGetValue(a.Name, out l)) picked[a.Name] = l = new List<TAction>();
                    l.Add(a);
                }
            var drop = new HashSet<Tweak>();
            foreach (var t in Tweaks.Where(t => t.Library && (t.Id.StartsWith("s.") || (t.Id.StartsWith("c.") && !t.NoUndo))))
            {
                int r = t.HasOptions ? t.RecommendedOption(null) : -1;
                var acts = r >= 0 ? t.Options[r].Apply : t.Apply;
                foreach (var a in acts)
                {
                    List<TAction> l;
                    if (string.IsNullOrEmpty(a.Name) || !picked.TryGetValue(a.Name, out l)) continue;
                    if (l.Any(c => Clashes(c, a))) { drop.Add(t); break; }
                }
            }
            ClashesRemoved = drop.Count;
            Tweaks.RemoveAll(drop.Contains);
        }
        // Does pack value b work against hand-picked value a? A distinctive name (HiberbootEnabled, TcpAckFrequency...)
        // is the same setting wherever it is written; a generic one (Start, Enabled, Priority...) only on a key of the same name.
        public static bool Clashes(TAction a, TAction b)
        {
            if (!a.IsRegistry || !b.IsRegistry || string.IsNullOrEmpty(a.Name) || !a.Name.Equals(b.Name, StringComparison.OrdinalIgnoreCase) || SameValue(a, b)) return false;
            bool generic = GenericName.IsMatch(b.Name) || b.Key.IndexOf(@"\Tasks\", StringComparison.OrdinalIgnoreCase) >= 0;
            return Leaf(a.Key).Equals(Leaf(b.Key), StringComparison.OrdinalIgnoreCase) || !generic;
        }
        static readonly System.Text.RegularExpressions.Regex GenericName = new System.Text.RegularExpressions.Regex(
            @"^(start|enabled?|disabled?|value|default|\(default\)|state|status|flags|mode|type|level|priority|gpu priority|scheduling category|sfio priority|background only|clock rate|affinity|latency sensitive|attributes|acsettingindex|dcsettingindex|version|data)$", RxOpt);
        static string Leaf(string key) { return key.Substring(key.LastIndexOf('\\') + 1); }
        static bool SameValue(TAction x, TAction y)
        {
            return x.Type == y.Type && string.Equals(Convert.ToString(x.Value), Convert.ToString(y.Value), StringComparison.OrdinalIgnoreCase);
        }

        public static bool BoxEligible(Tweak t)
        {
            return t.Library && t.Risk == 0 && !t.NoUndo && !t.NoPack && !t.NoBulk && t.Packs >= 2 && t.Id != null && t.Id.StartsWith("s.") && !AddressSetting(t) && !BulkUnsafe(t);
        }

        // Paths copied from regedit start with "Computer\"; anything not starting at a real hive is broken.
        static string FixKey(string key)
        {
            if (key.StartsWith(@"Computer\", StringComparison.OrdinalIgnoreCase)) key = key.Substring(9);
            return System.Text.RegularExpressions.Regex.IsMatch(key, @"^HKEY_(LOCAL_MACHINE|CURRENT_USER|USERS|CLASSES_ROOT|CURRENT_CONFIG)\\", System.Text.RegularExpressions.RegexOptions.IgnoreCase)
                && key.IndexOf('$') < 0 && key.IndexOf("{}", StringComparison.Ordinal) < 0 ? key : null;
        }
        public int BrokenRemoved;

        readonly HashSet<string> curatedSettings = new HashSet<string>();
        readonly HashSet<string> curatedCommands = new HashSet<string>();

        static string NormPath(string key, string name)
        {
            key = System.Text.RegularExpressions.Regex.Replace(key ?? "", @"^HKLM\\", @"HKEY_LOCAL_MACHINE\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            key = System.Text.RegularExpressions.Regex.Replace(key, @"^HKCU\\", @"HKEY_CURRENT_USER\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            key = System.Text.RegularExpressions.Regex.Replace(key, @"^HKCR\\|^HKEY_CLASSES_ROOT\\", @"HKEY_LOCAL_MACHINE\SOFTWARE\Classes\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            key = System.Text.RegularExpressions.Regex.Replace(key, @"\\ControlSet00\d\\", @"\CurrentControlSet\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            key = System.Text.RegularExpressions.Regex.Replace(key, @"\s*\\+\s*", @"\");   // doubled or padded separators
            return (key.TrimEnd('\\') + "|" + (name ?? "")).ToLowerInvariant();
        }
        static string NormCmd(string c) { return System.Text.RegularExpressions.Regex.Replace(c ?? "", @"\s+", " ").Trim().ToLowerInvariant(); }

        void IndexCurated()
        {
            Action<IEnumerable<TAction>> add = list =>
            {
                foreach (var a in list)
                    if (a.IsRegistry) curatedSettings.Add(NormPath(a.Key, a.Name));
                    else if (a.Command != null) curatedCommands.Add(NormCmd(a.Command));
            };
            foreach (var t in Tweaks)
            {
                add(t.Apply); add(t.Revert);
                if (t.Options != null) foreach (var o in t.Options) add(o.Apply);
            }
        }

        public static Catalog Parse(string json) { var c = new Catalog(); c.Merge(json, true); return c; }

        Dictionary<string, Tweak> index;
        public Tweak Find(string id)
        {
            if (index == null) { index = new Dictionary<string, Tweak>(); foreach (var t in Tweaks) index[t.Id] = t; }
            int h = id.IndexOf('#');
            if (h < 0) { Tweak t; return index.TryGetValue(id, out t) ? t : null; }
            Tweak parent; int i;
            if (!index.TryGetValue(id.Substring(0, h), out parent) || !int.TryParse(id.Substring(h + 1), out i) || i < 0 || i >= parent.Apply.Count) return null;
            return Tweak.Sub(parent, i);
        }

        // Curated catalog first, then the generated library (option + bundle tweaks).
        public void Merge(string json, bool curated)
        {
            var js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 64 };
            var root = (Dictionary<string, object>)js.DeserializeObject(json);
            if (curated) Version = Str(root, "version"); else LibraryVersion = Str(root, "version");
            if (root.ContainsKey("categories"))
                foreach (Dictionary<string, object> d in (object[])root["categories"])
                    Categories.Add(new Category { Id = Str(d, "id"), Ar = Str(d, "ar"), En = Str(d, "en"), Icon = Str(d, "icon"), Group = Str(d, "group") });
            if (root.ContainsKey("groups"))
                foreach (Dictionary<string, object> d in (object[])root["groups"])
                    Groups.Add(new Category { Id = Str(d, "id"), Ar = Str(d, "ar"), En = Str(d, "en"), Icon = Str(d, "icon") });
            var known = new HashSet<string>(Tweaks.Select(x => x.Id));
            foreach (Dictionary<string, object> d in (object[])root["tweaks"])
            {
                var t = new Tweak
                {
                    Id = Str(d, "id"), Cat = MapCat(Str(d, "cat")), Ar = Str(d, "ar"), En = Str(d, "en"),
                    DescAr = Str(d, "dar"), DescEn = Str(d, "den"), Auto = Str(d, "auto"), Vendor = Str(d, "vendor"),
                    Path = Str(d, "path"), NoPack = d.ContainsKey("nopack") && (bool)d["nopack"],
                    Tier = Int(d, "tier", 1), Risk = Int(d, "risk", 0), MinRam = Int(d, "minRam", 0), Packs = Int(d, "packs", 0),
                    Reboot = d.ContainsKey("reboot") && (bool)d["reboot"],
                    Library = d.ContainsKey("lib") && (bool)d["lib"],
                    Curated = curated
                };
                if (!known.Add(t.Id)) continue;
                t.SearchText = ((t.Ar ?? "") + " " + (t.En ?? "") + " " + (t.Path ?? "") + " " + (t.DescEn ?? "")).ToLowerInvariant();
                t.Apply = Actions(d, "apply");
                t.Revert = Actions(d, "revert");
                if (d.ContainsKey("options"))
                {
                    t.Options = new List<TOption>();
                    foreach (Dictionary<string, object> o in (object[])d["options"])
                        t.Options.Add(new TOption
                        {
                            Ar = Str(o, "ar"), En = Str(o, "en"), Gb = Int(o, "gb", 0), Uses = Int(o, "uses", 0),
                            IsDefault = o.ContainsKey("def") && (bool)o["def"],
                            Apply = Actions(o, "apply")
                        });
                }
                Tweaks.Add(t);
            }
            if (curated) IndexCurated();
        }

        // Library v2: one line per registry value ("S") or command ("C"), tab separated.
        public void LoadTsv(TextReader r)
        {
            string line = r.ReadLine();
            if (line == null || !line.StartsWith("#JDOLIB")) return;
            LibraryVersion = line.Split('\t').Last();
            var known = new HashSet<string>(Tweaks.Select(x => x.Id));
            var byPath = new Dictionary<string, Tweak>();
            while ((line = r.ReadLine()) != null)
            {
                var f = line.Split('\t');
                if (BrandRx.IsMatch(line)) { JunkRemoved++; continue; }   // another tool advertising itself (its name, Discord, Instagram) in a value
                try
                {
                    var t = new Tweak { Library = true, Cat = MapCat(f[1]), Tier = int.Parse(f[2]), Risk = int.Parse(f[3]), Packs = int.Parse(f[4]) };
                    if (f[0] == "S")
                    {
                        bool each = f[5] == "1";
                        string key = f[6], name = f[7], src = f[8];
                        if (key.IndexOf('!') >= 0 || key.IndexOf('%') >= 0) continue;   // unexpanded script variable, not a real path
                        key = FixKey(key);
                        if (key == null) { BrokenRemoved++; continue; }
                        f[6] = key;
                        if (AntiCheatUnsafe(key, name)) { AntiCheatRemoved++; continue; }
                        if (JunkRx.IsMatch(key + "|" + name)) { JunkRemoved++; continue; }
                        if (DangerRx.IsMatch(key + "|" + name)) { DangerRemoved++; continue; }
                        if (name.Equals("Start", StringComparison.OrdinalIgnoreCase) && ServiceName(key) != null && !SafeService(ServiceName(key))) { DangerRemoved++; continue; }   // only well-known services may be switched off
                        t.NoBulk = ProtectRx.IsMatch(key + "|" + name) || t.Risk >= 2;
                        t.Cat = VendorCat(t.Cat, key, name);
                        if (t.Cat == "advanced" || IsController(key + "|" + name)) t.Cat = SectionFor(key + "|" + name);
                        if (curatedSettings.Contains(NormPath(key, name))) { DuplicatesRemoved++; continue; }   // already a hand-picked tweak
                        t.Id = "s." + StableHash((each ? "*" : "") + key + "|" + name);
                        t.Path = key + "\\" + name;
                        string title = name == "(key)" ? Words(key.Substring(key.LastIndexOf('\\') + 1)) + " (key)" : name == "" ? Words(key.Substring(key.LastIndexOf('\\') + 1)) : Words(name);
                        // a bare "Enabled" / "Value" says nothing: name it after its key too
                        if (System.Text.RegularExpressions.Regex.IsMatch(name, @"^(enabled?|disabled?|value|default|state|status|flags|mode|type|level|on|off|active|setting)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                            title = Words(key.Substring(key.LastIndexOf('\\') + 1)) + " · " + Words(name);
                        string svc = ServiceName(key);
                        if (svc != null && name.Equals("Start", StringComparison.OrdinalIgnoreCase))
                        { t.Ar = "خدمة " + svc + ": طريقة التشغيل"; t.En = svc + " service: startup type"; }
                        else t.Ar = t.En = title;
                        t.DescAr = string.Format(L.T("libDescS", true), title, Area(key, true)) + (t.Packs > 1 ? "  ·  يستخدمه " + t.Packs + " باك" : "");
                        t.DescEn = string.Format(L.T("libDescS", false), title, Area(key, false)) + (t.Packs > 1 ? "  ·  Used by " + t.Packs + " packs" : "");
                        var opts = new List<TOption>();
                        for (int i = 9; i < f.Length; i++)
                        {
                            var p = f[i].Split('\x1F');
                            var a = new TAction { Kind = each ? "each" : "reg", Key = key, Name = name, Type = p[0] };
                            if (p[0] == "dw" || p[0] == "qw") a.Value = long.Parse(p[1]);
                            if (p[0] == "dw" && ((long)a.Value < 0 || (long)a.Value > 0xFFFFFFFFL)) continue;   // doesn't fit a DWORD: broken value
                            if (p[0] == "bin" && !System.Text.RegularExpressions.Regex.IsMatch(p[1], "^([0-9a-fA-F]{1,2},?)*$")) continue;
                            else if (p[0] == "msz") a.Value = p[1].Replace('\x1E', '\0');
                            else if (p[0] != "del" && p[0] != "delkey") a.Value = p[1];
                            int uses; int.TryParse(p.Length > 2 ? p[2] : "1", out uses);
                            string star = opts.Count == 0 && f.Length > 10 ? "  ★" : "";
                            opts.Add(new TOption { Ar = ValueLabel(a, true) + star, En = ValueLabel(a, false) + star, Uses = uses, Apply = new List<TAction> { a } });
                        }
                        if (opts.Count == 0) { BrokenRemoved++; continue; }   // every value was broken
                        if (!GameBestFirst(opts, key, name)) { t.NoBulk = true; t.NoPack = true; }
                        if (opts.Count == 1) t.Apply = opts[0].Apply;   // single value: on/off switch, off restores the original
                        else
                        {
                            opts.Add(new TOption { Ar = "الأصلي (قيمة جهازك)", En = "Original (your PC's value)", IsDefault = true });
                            t.Options = opts;
                        }
                    }
                    else if (f[0] == "C")
                    {
                        // a PowerShell cmdlet filed as CMD would only fail in cmd.exe
                        if (f[5] != "ps" && System.Text.RegularExpressions.Regex.IsMatch(f[6].Trim(), @"^[A-Za-z]+-[A-Za-z]+")) f[5] = "ps";
                        string text = CleanCmd(f[6], f[5] == "ps");
                        if (curatedCommands.Contains(NormCmd(text))) { DuplicatesRemoved++; continue; }
                        if (AntiCheatUnsafe(text, null)) { AntiCheatRemoved++; continue; }
                        if (text.Length == 0 || CmdDropRx.IsMatch(text) || (f[5] == "ps" && !PsKnownRx.IsMatch(text))
                            || (text.StartsWith("fsutil", StringComparison.OrdinalIgnoreCase) && !FsutilKnownRx.IsMatch(text))
                            || System.Text.RegularExpressions.Regex.IsMatch(text, @"^set-service\b.*-status\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase))
                        { CommandsDropped++; continue; }
                        t.NoBulk = CmdNoBulkRx.IsMatch(text) || t.Risk >= 2;
                        t.Cat = VendorCat(t.Cat, text, null);
                        if (t.Cat == "advanced" || IsController(text)) t.Cat = SectionFor(text);
                        t.Id = "c." + StableHash(text.ToLowerInvariant());
                        t.Ar = t.En = text.Length > 110 ? text.Substring(0, 107) + "..." : text;
                        t.Path = text.Length > 110 ? text : null;
                        t.DescAr = "أمر " + (f[5] == "ps" ? "PowerShell" : "CMD") + "  ·  من: " + f[7] + (Engine.CanUndo(text) ? "  ·  ينرجع بزر \"إرجاع الكل\"" : "  ·  ما ينرجع تلقائياً (ينرجع من نقطة الاستعادة)");
                        t.DescEn = (f[5] == "ps" ? "PowerShell" : "CMD") + " command  ·  From: " + f[7] + (Engine.CanUndo(text) ? "  ·  undone by \"Revert all\"" : "  ·  no automatic undo (the restore point covers it)");
                        t.Apply = new List<TAction> { new TAction { Kind = f[5] == "ps" ? "ps" : "cmd", Command = text } };
                        t.NoUndo = true;
                        // Commands that only set a registry value or a service's startup become registry tweaks,
                        // so "Revert all" brings them back exactly (and the same safety rules apply to them).
                        var asReg = CommandAsRegistry(text);
                        if (asReg != null)
                        {
                            if (asReg.Count == 0) { CommandsDropped++; continue; }   // a service we never let packs touch
                            string rk = asReg[0].Key + "|" + asReg[0].Name;
                            if (JunkRx.IsMatch(rk) || DangerRx.IsMatch(rk)) { DangerRemoved++; continue; }
                            if (curatedSettings.Contains(NormPath(asReg[0].Key, asReg[0].Name))) { DuplicatesRemoved++; continue; }
                            t.Apply = asReg;
                            t.NoUndo = false;
                            t.NoBulk |= ProtectRx.IsMatch(rk);
                            t.DescAr = "إعداد من أمر " + (f[5] == "ps" ? "PowerShell" : "CMD") + "  ·  من: " + f[7] + "  ·  ينرجع للأصل بضغطة";
                            t.DescEn = "Setting from a " + (f[5] == "ps" ? "PowerShell" : "CMD") + " command  ·  From: " + f[7] + "  ·  can be undone in one click";
                        }
                    }
                    else continue;
                    if (!known.Add(t.Id)) continue;
                    if (f[0] == "S")
                    {
                        // The same value can arrive twice: once as "every adapter under this key" and once
                        // as a value written on the parent key itself. Keep the one that does the real work.
                        string pk = NormPath(f[6], f[7]);
                        bool isEach = f[5] == "1";
                        Tweak old;
                        if (byPath.TryGetValue(pk, out old))
                        {
                            DuplicatesRemoved++;
                            if (!isEach || old.Apply.Concat(old.Options == null ? new List<TAction>() : old.Options.SelectMany(o => o.Apply)).Any(a => a.Kind == "each")) continue;
                            Tweaks.Remove(old);
                        }
                        byPath[pk] = t;
                    }
                    t.SearchText = (t.En + " " + t.Ar + " " + (t.Path ?? "") + " " + t.DescEn + " " + t.DescAr).ToLowerInvariant();
                    Tweaks.Add(t);
                }
                catch { }
            }
            ResolveCommands();
            MarkClashes();
            index = null;
            Retier();
        }

        // For settings with several values, the one that helps games most (Fortnite and other competitive games:
        // more FPS, steadier frame times, lower input and network delay) goes first, so the boxes and "Apply all" pick it.
        // Settings not listed keep the value most packs use. Values are what the setting means at that name, not a guess.
        static readonly Dictionary<string, string> GameBest = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            // CPU / scheduler
            { "Win32PrioritySeparation", "26" }, { "SystemResponsiveness", "0" }, { "NetworkThrottlingIndex", "4294967295" },
            { "GPU Priority", "8" }, { "Priority", "6" }, { "Scheduling Category", "High" }, { "SFIO Priority", "High" }, { "Background Only", "False" },
            { "PowerThrottlingOff", "1" }, { "GlobalTimerResolutionRequests", "1" },
            // memory
            { "DisablePagingExecutive", "1" }, { "LargeSystemCache", "0" }, { "EnablePrefetcher", "0" }, { "EnableSuperfetch", "0" },
            // game mode, game bar and background recording
            { "AutoGameModeEnabled", "1" }, { "AllowAutoGameMode", "1" }, { "GameDVR_Enabled", "0" }, { "AppCaptureEnabled", "0" }, { "AllowGameDVR", "0" },
            { "HistoricalCaptureEnabled", "0" }, { "AudioCaptureEnabled", "0" }, { "GameDVR_FSEBehaviorMode", "2" }, { "GameDVR_FSEBehavior", "2" },
            { "GameDVR_HonorUserFSEBehaviorMode", "1" }, { "GameDVR_DXGIHonorFSEWindowsCompatible", "1" }, { "GameDVR_EFSEFeatureFlags", "0" },
            { "UseNexusForGameBarEnabled", "0" }, { "ShowStartupPanel", "0" },
            // graphics
            { "HwSchMode", "2" }, { "EnableTransparency", "0" }, { "VisualFXSetting", "2" },
            // input and desktop responsiveness
            { "MenuShowDelay", "0" }, { "MouseHoverTime", "10" }, { "WaitToKillServiceTimeout", "2000" }, { "WaitToKillAppTimeout", "2000" },
            { "HungAppTimeout", "1000" }, { "AutoEndTasks", "1" }, { "MouseSpeed", "0" }, { "MouseThreshold1", "0" }, { "MouseThreshold2", "0" },
            // network latency (TCP only - no addresses)
            { "TcpAckFrequency", "1" }, { "TCPNoDelay", "1" }, { "TcpDelAckTicks", "0" }, { "NonBestEffortLimit", "0" }, { "DefaultTTL", "64" },
            { "MaxUserPorts", "65534" }, { "TcpTimedWaitDelay", "30" }, { "Tcp1323Opts", "1" }, { "SackOpts", "1" }, { "TcpMaxDupAcks", "2" },
        };
        static readonly System.Text.RegularExpressions.Regex MmcssName = new System.Text.RegularExpressions.Regex(@"^(priority|gpu priority|scheduling category|sfio priority|background only)$", RxOpt);
        // Returns false when the setting has a known best value for games and none of its values is it
        // (a pack that turns Game Mode off, say): such a setting stays out of "Apply all" and the boxes.
        static bool GameBestFirst(List<TOption> opts, string key, string name)
        {
            string want;
            if (name == null || !GameBest.TryGetValue(name, out want)) return true;
            if (MmcssName.IsMatch(name) && !key.EndsWith(@"\Tasks\Games", StringComparison.OrdinalIgnoreCase)) return true;   // only the Games profile
            int i = opts.FindIndex(o => !o.IsDefault && o.Apply.Count == 1 && string.Equals(Convert.ToString(o.Apply[0].Value), want, StringComparison.OrdinalIgnoreCase));
            if (i < 0) return false;
            var best = opts[i];
            foreach (var o in opts) { o.Ar = o.Ar.Replace("  ★", ""); o.En = o.En.Replace("  ★", ""); }
            opts.RemoveAt(i);
            opts.Insert(0, best);
            best.Game = true;
            best.Ar += "  ★ للألعاب"; best.En += "  ★ for games";
            return true;
        }

        public static string ValueLabel(TAction a) { return ValueLabel(a, L.Ar); }

        public static string ValueLabel(TAction a, bool ar)
        {
            switch (a.Type)
            {
                case "del": return ar ? "حذف القيمة" : "Delete value";
                case "delkey": return ar ? "حذف المفتاح" : "Delete key";
                case "bin": return "Binary (" + (Convert.ToString(a.Value).Split(',').Length) + " bytes)";
                case "msz": return Convert.ToString(a.Value).Replace("\0", " | ");
                case "dw":
                case "qw":
                    long v = Convert.ToInt64(a.Value);
                    string m = Meaning(a, v, ar);
                    if (m != null) return m + "  (" + v + ")";
                    return v > 255 || v < 0 ? v + "  (0x" + v.ToString("X") + ")" : v.ToString();
                default:
                    string s = Convert.ToString(a.Value);
                    return s.Length > 48 ? s.Substring(0, 45) + "..." : s == "" ? "\"\"" : s;
            }
        }

        // What a number means, where it is clear from the setting: service startup types and on/off switches.
        static readonly System.Text.RegularExpressions.Regex OffName = new System.Text.RegularExpressions.Regex(@"^(?i:disable|hide|deny|block|prevent|turnoff|suppress)|^No[A-Z_]", System.Text.RegularExpressions.RegexOptions.Compiled);
        static readonly System.Text.RegularExpressions.Regex OnName = new System.Text.RegularExpressions.Regex(@"^(enable|allow|show|use[A-Z]|turnon)|(enabled|allowed|active)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.Compiled);
        static string Meaning(TAction a, long v, bool ar)
        {
            string n = a.Name ?? "";
            if (n.Equals("Start", StringComparison.OrdinalIgnoreCase) && ServiceName(a.Key) != null)
            {
                switch (v)
                {
                    case 0: return ar ? "مع الإقلاع" : "Boot";
                    case 1: return ar ? "مع النظام" : "System";
                    case 2: return ar ? "تلقائي" : "Automatic";
                    case 3: return ar ? "يدوي" : "Manual";
                    case 4: return ar ? "معطّلة" : "Disabled";
                }
                return null;
            }
            if (v != 0 && v != 1) return null;
            string nn = n.Replace(" ", "");
            if (OffName.IsMatch(nn)) return v == 1 ? (ar ? "إيقاف" : "Off") : (ar ? "تشغيل" : "On");
            if (OnName.IsMatch(nn)) return v == 1 ? (ar ? "تشغيل" : "On") : (ar ? "إيقاف" : "Off");
            return null;
        }

        // "...\Services\Name" or "...\Services\Name\..." -> Name
        static string ServiceName(string key)
        {
            var m = System.Text.RegularExpressions.Regex.Match(key ?? "", @"\\Services\\([^\\]+)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            return m.Success ? m.Groups[1].Value : null;
        }

        // A readable name for where a setting lives, instead of the bare registry key.
        static readonly string[][] Areas =
        {
            new[] { @"\\services\\(tcpip6?|afd|dnscache|psched|nlasvc|lanman\w+|netbt|ndis)(\\|$)|\\qos(\\|$)|\\psched(\\|$)|internet settings", "الشبكة والإنترنت", "network and internet" },
            new[] { @"gamedvr|gamebar|gameconfigstore|\\games(\\|$)", "الألعاب وتسجيلها", "games and game recording" },
            new[] { @"multimedia\\systemprofile", "أولويات الألعاب والوسائط (MMCSS)", "game and media priorities (MMCSS)" },
            new[] { @"\\control\\prioritycontrol", "أولوية المعالج", "CPU priority" },
            new[] { @"\\session manager|\\memory management", "النظام (الذاكرة والنواة)", "system (memory and kernel)" },
            new[] { @"\\control\\power|\\power(\\|$)", "الطاقة", "power" },
            new[] { @"graphicsdrivers|\\dwm(\\|$)|direct3d|directx|directdraw|avalon\.graphics", "الرسوميات وكرت الشاشة", "graphics" },
            new[] { @"control panel\\mouse|\\mouclass|\\mouhid", "الماوس", "mouse" },
            new[] { @"control panel\\keyboard|\\kbdclass|\\kbdhid|control panel\\accessibility", "الكيبورد والوصول", "keyboard and accessibility" },
            new[] { @"datacollection|advertisinginfo|privacy|capabilityaccessmanager|\\diagtrack|telemetry|\\wdi(\\|$)|error reporting", "الخصوصية والتتبع", "privacy and tracking" },
            new[] { @"\\explorer(\\|$)|\\shell(\\|$)|control panel\\desktop|\\themes(\\|$)", "الواجهة وسطح المكتب", "interface and desktop" },
            new[] { @"\\search(\\|$)|windows search|\\wsearch", "البحث", "search" },
            new[] { @"\\winevt(\\|$)|\\wmi\\autologger", "سجلات الأحداث", "event logs" },
            new[] { @"\\filesystem(\\|$)|\\storage|\\disk(\\|$)|\\volumecaches", "التخزين", "storage" },
            new[] { @"\\notifications|pushnotifications", "الإشعارات", "notifications" },
            new[] { @"\\policies\\", "سياسات الويندوز", "Windows policies" },
        };
        static readonly List<KeyValuePair<System.Text.RegularExpressions.Regex, string[]>> AreaRx =
            Areas.Select(x => new KeyValuePair<System.Text.RegularExpressions.Regex, string[]>(new System.Text.RegularExpressions.Regex(x[0], RxOpt), x)).ToList();
        static string Area(string key, bool ar)
        {
            string svc = ServiceName(key);
            foreach (var kv in AreaRx)
                if (kv.Key.IsMatch(key)) return kv.Value[ar ? 1 : 2] + (svc != null ? " · " + svc : "");
            if (svc != null) return (ar ? "خدمة " : "service ") + svc;
            return key.Substring(key.LastIndexOf('\\') + 1);
        }

        public static string Words(string s)
        {
            s = System.Text.RegularExpressions.Regex.Replace(s ?? "", "([a-z0-9])([A-Z])", "$1 $2");
            s = System.Text.RegularExpressions.Regex.Replace(s, "([A-Z]+)([A-Z][a-z])", "$1 $2");
            return System.Text.RegularExpressions.Regex.Replace(s.Replace('_', ' '), @"\s+", " ").Trim();
        }

        static string StableHash(string s)
        {
            using (var md5 = System.Security.Cryptography.MD5.Create())
                return BitConverter.ToString(md5.ComputeHash(Encoding.UTF8.GetBytes(s.ToLowerInvariant())), 0, 8).Replace("-", "").ToLowerInvariant();
        }

        static List<TAction> Actions(Dictionary<string, object> d, string field)
        {
            var list = new List<TAction>();
            if (!d.ContainsKey(field)) return list;
            foreach (Dictionary<string, object> a in (object[])d[field])
            {
                var x = new TAction();
                if (a.ContainsKey("reg")) { x.Kind = "reg"; x.Key = Str(a, "reg"); }
                else if (a.ContainsKey("each")) { x.Kind = "each"; x.Key = Str(a, "each"); }
                else if (a.ContainsKey("cmd")) { x.Kind = "cmd"; x.Command = Str(a, "cmd"); }
                else if (a.ContainsKey("ps")) { x.Kind = "ps"; x.Command = Str(a, "ps"); }
                else if (a.ContainsKey("script")) { x.Kind = "script"; x.Command = Str(a, "script"); x.Ext = Str(a, "ext") ?? ".bat"; }
                if (x.IsRegistry)
                {
                    x.Name = Str(a, "n") ?? "";
                    if (a.ContainsKey("delkey")) x.Type = "delkey";
                    else if (a.ContainsKey("del")) x.Type = "del";
                    else if (a.ContainsKey("dw")) { x.Type = "dw"; x.Value = Convert.ToInt64(a["dw"]); }
                    else if (a.ContainsKey("qw")) { x.Type = "qw"; x.Value = Convert.ToInt64(a["qw"]); }
                    else if (a.ContainsKey("sz")) { x.Type = "sz"; x.Value = Str(a, "sz"); }
                    else if (a.ContainsKey("esz")) { x.Type = "esz"; x.Value = Str(a, "esz"); }
                    else if (a.ContainsKey("msz")) { x.Type = "msz"; x.Value = Str(a, "msz"); }
                    else if (a.ContainsKey("bin")) { x.Type = "bin"; x.Value = Str(a, "bin"); }
                }
                list.Add(x);
            }
            return list;
        }

        static string Str(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v != null ? v.ToString() : null; }
        static int Int(Dictionary<string, object> d, string k, int def) { object v; return d.TryGetValue(k, out v) && v != null ? Convert.ToInt32(v) : def; }
    }

    // Applies / reverts tweaks. Every registry value is backed up before its
    // first change so "revert" restores the PC's real original value.
    public static class Engine
    {
        static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "JdoTweak");
        static readonly string BackupFile = Path.Combine(Dir, "backup.json");
        static Dictionary<string, object> backup;   // tweakId -> { "values": [...], "applied": bool }
        public static readonly List<string> Log = new List<string>();

        // ---------- registry helpers ----------
        static RegistryKey Hive(string path, out string sub)
        {
            int i = path.IndexOf('\\');
            string h = (i < 0 ? path : path.Substring(0, i)).ToUpperInvariant();
            sub = i < 0 ? "" : path.Substring(i + 1);
            RegistryHive hive;
            switch (h)
            {
                case "HKLM": case "HKEY_LOCAL_MACHINE": hive = RegistryHive.LocalMachine; break;
                case "HKCU": case "HKEY_CURRENT_USER": hive = RegistryHive.CurrentUser; break;
                case "HKCR": case "HKEY_CLASSES_ROOT": hive = RegistryHive.ClassesRoot; break;
                case "HKU": case "HKEY_USERS": hive = RegistryHive.Users; break;
                case "HKCC": case "HKEY_CURRENT_CONFIG": hive = RegistryHive.CurrentConfig; break;
                default: throw new ArgumentException("Unknown hive: " + h);
            }
            return RegistryKey.OpenBaseKey(hive, RegistryView.Registry64);
        }

        public static object Read(string path, string name, out RegistryValueKind kind)
        {
            kind = RegistryValueKind.Unknown;
            try
            {
                string sub;
                using (var b = Hive(path, out sub))
                using (var k = b.OpenSubKey(sub))
                {
                    if (k == null) return null;
                    object v = k.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                    if (v != null) kind = k.GetValueKind(name);
                    return v;
                }
            }
            catch { return null; }
        }

        static void Write(string path, string name, string type, object value)
        {
            string sub;
            if (type == "regfile") { Shell("reg.exe", "import \"" + value + "\"", 60); return; }
            if (type == "newkey") { RemoveCreatedKey(path); return; }
            using (var b = Hive(path, out sub))
            {
                if (type == "delkey") { b.DeleteSubKeyTree(sub, false); return; }
                if (type == "del")
                {
                    bool loggerLeftover = false;
                    using (var k = b.OpenSubKey(sub, true))
                    {
                        if (k != null)
                        {
                            k.DeleteValue(name, false);
                            // an ETW logger key without its GUID is one a tweak created (backups from older versions
                            // don't know that): Windows tries to start it at boot and crashes - remove it
                            loggerLeftover = System.Text.RegularExpressions.Regex.IsMatch(sub, @"\\WMI\\Autologger\\[^\\]+$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)
                                             && k.GetValue("GUID") == null && k.SubKeyCount == 0;
                        }
                    }
                    if (loggerLeftover) b.DeleteSubKeyTree(sub, false);
                    return;
                }
                using (var k = b.CreateSubKey(sub))
                {
                    if (type == "dw") k.SetValue(name, unchecked((int)(uint)Convert.ToInt64(value)), RegistryValueKind.DWord);
                    else if (type == "qw") k.SetValue(name, Convert.ToInt64(value), RegistryValueKind.QWord);
                    else if (type == "esz") k.SetValue(name, Convert.ToString(value), RegistryValueKind.ExpandString);
                    else if (type == "msz") k.SetValue(name, Convert.ToString(value).Split(new[] { '\0' }, StringSplitOptions.RemoveEmptyEntries), RegistryValueKind.MultiString);
                    else if (type == "bin") k.SetValue(name, HexBytes(Convert.ToString(value)), RegistryValueKind.Binary);
                    else k.SetValue(name, Convert.ToString(value), RegistryValueKind.String);
                }
            }
        }

        static byte[] HexBytes(string s)
        {
            return s.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(h => Convert.ToByte(h.Trim(), 16)).ToArray();
        }
        static string BytesHex(byte[] b) { return string.Join(",", b.Select(x => x.ToString("x2"))); }

        // "HKLM\A\B\C" where only HKLM\A exists -> "HKLM\A\B" (the key a write would create first); null if it exists.
        static string TopMissingKey(string path)
        {
            if (KeyExists(path)) return null;
            string top = path;
            for (int i = path.LastIndexOf('\\'); i > 0; i = path.LastIndexOf('\\', i - 1))
            {
                string parent = path.Substring(0, i);
                if (parent.IndexOf('\\') < 0) break;   // the hive itself
                if (KeyExists(parent)) break;
                top = parent;
            }
            return top;
        }

        // Deletes a key this app created: it did not exist before, so the PC's original state is "no key at all".
        // Windows may have written into it meanwhile (an ETW logger records its "Status"), so it goes even when not empty.
        static void RemoveCreatedKey(string path)
        {
            string sub;
            using (var b = Hive(path, out sub)) b.DeleteSubKeyTree(sub, false);
        }

        static bool KeyExists(string path)
        {
            try { string sub; using (var b = Hive(path, out sub)) using (var k = b.OpenSubKey(sub)) return k != null; }
            catch { return false; }
        }

        static IEnumerable<string> Expand(TAction a)
        {
            if (a.Kind == "reg") { yield return a.Key; yield break; }
            string sub; string[] names;
            try
            {
                using (var b = Hive(a.Key, out sub))
                using (var k = b.OpenSubKey(sub)) { names = k == null ? new string[0] : k.GetSubKeyNames(); }
            }
            catch { names = new string[0]; }
            foreach (var n in names)
            {
                if (n.Equals("Properties", StringComparison.OrdinalIgnoreCase) || n.Equals("Configuration", StringComparison.OrdinalIgnoreCase)) continue;
                yield return a.Key + "\\" + n;
            }
        }

        static bool Matches(string path, TAction a)
        {
            if (a.Type == "delkey") return !KeyExists(path);
            RegistryValueKind kind;
            object cur = Read(path, a.Name, out kind);
            if (a.Type == "del") return cur == null;
            if (cur == null) return false;
            if (a.Type == "sz" || a.Type == "esz") return string.Equals(Convert.ToString(cur), Convert.ToString(a.Value), StringComparison.OrdinalIgnoreCase);
            if (a.Type == "bin") return cur is byte[] && BytesHex((byte[])cur) == Convert.ToString(a.Value).ToLowerInvariant().Replace(" ", "");
            if (a.Type == "msz") return cur is string[] && string.Join("\0", (string[])cur) == Convert.ToString(a.Value).TrimEnd('\0');
            try
            {
                long c = kind == RegistryValueKind.DWord ? (long)(uint)(int)cur : Convert.ToInt64(cur);
                return c == Convert.ToInt64(a.Value);
            }
            catch { return false; }
        }

        // True if every registry action in the list is already in place.
        // Returns null when the list has no registry actions to check.
        public static bool? AllMatch(List<TAction> list)
        {
            bool any = false;
            foreach (var a in list.Where(x => x.IsRegistry))
            {
                foreach (var p in Expand(a)) { any = true; if (!Matches(p, a)) return false; }
            }
            return any ? (bool?)true : null;
        }

        // ---------- state ----------
        public static bool IsApplied(Tweak t)
        {
            var m = AllMatch(t.Apply);
            if (m.HasValue) return m.Value;
            return FlagApplied(t.Id);
        }

        public static int CurrentOption(Tweak t)
        {
            for (int i = 0; i < t.Options.Count; i++)
            {
                var m = AllMatch(t.Options[i].Apply);
                if (m.HasValue && m.Value) return i;
            }
            // No value written at all usually means Windows default.
            for (int i = 0; i < t.Options.Count; i++)
                if (t.Options[i].IsDefault && t.Options[i].Apply.Where(a => a.IsRegistry).All(a => { RegistryValueKind k; return Read(a.Key, a.Name, out k) == null; }))
                    return i;
            return -1;
        }

        // ---------- apply / revert ----------
        public static void ApplyTweak(Tweak t)
        {
            bool first = !BackedUpIds().Contains(t.Id);   // keep the very first original state, like the registry backup
            string undo = first && t.Apply.Any(a => !a.IsRegistry) ? CaptureUndo(t.Apply) : null;
            Backup(t, t.Apply);
            Run(t.Apply);
            SetFlag(t.Id, true);
            SetUndo(t.Id, undo);
        }

        public static void ApplyOption(Tweak t, int index)
        {
            var o = t.Options[index];
            if (o.IsDefault)
            {
                // Generated options have no known Windows default: restore the backed-up original.
                bool hadBackup = BackedUpIds().Contains(t.Id);
                RevertTweak(t);
                if (o.Apply.Count > 0 && (!hadBackup || t.Curated)) Run(o.Apply);
                return;
            }
            Backup(t, o.Apply);
            Run(o.Apply);
            SetFlag(t.Id, true);
        }

        public static void RevertTweak(Tweak t)
        {
            Load();
            object entry;
            if (backup.TryGetValue(t.Id, out entry))
            {
                var e = (Dictionary<string, object>)entry;
                foreach (Dictionary<string, object> v in RestoreOrder((IEnumerable)e["values"]))
                {
                    try
                    {
                        string type = (string)v["type"];
                        Write((string)v["path"], (string)v["name"], type, v.ContainsKey("value") ? v["value"] : null);
                    }
                    catch (Exception ex) { Log.Add("restore: " + ex.Message); }
                }
                Run(t.Revert.Where(a => !a.IsRegistry).ToList());
                // commands: put back the state read before they ran (scheduled task on/off, power value, ...)
                if (e.ContainsKey("undo"))
                    foreach (var u in Convert.ToString(e["undo"]).Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries))
                        try { Shell("cmd.exe", "/c " + u, 60); } catch (Exception ex) { Log.Add("undo: " + ex.Message); }
                backup.Remove(t.Id);
                Save();
            }
            else Run(t.Revert);
            SetFlag(t.Id, false);
        }

        // Reverts anything this app changed, including single switches inside a tweak ("id#2").
        // A tweak an older version applied that is no longer in the app is still put back, straight from its backup.
        public static bool RevertById(Catalog cat, string id)
        {
            var t = cat.Find(id);
            if (t == null) return RevertBackupOnly(id);
            // with a backup, "revert" means the PC's own original value - not the option labelled "Default"
            // (a PC that had 38 before must get 38 back, not Windows' 2)
            if (t.HasOptions && !BackedUpIds().Contains(t.Id)) { int d = t.Options.FindIndex(o => o.IsDefault); if (d >= 0) { ApplyOption(t, d); return true; } }
            RevertTweak(t);
            return true;
        }

        public static void Run(List<TAction> list)
        {
            foreach (var a in list)
            {
                try
                {
                    if (a.IsRegistry) { foreach (var p in Expand(a)) Write(p, a.Name, a.Type, a.Value); }
                    else if (a.Kind == "cmd") Shell("cmd.exe", "/c " + a.Command, 120);
                    else if (a.Kind == "ps") PowerShell(a.Command, 120);
                    else if (a.Kind == "script") RunScript(a.Command, a.Ext);
                }
                catch (Exception ex) { Log.Add(a.Key + "\\" + a.Name + ": " + ex.Message); }
            }
        }

        static readonly System.Text.RegularExpressions.Regex RegAddLine = new System.Text.RegularExpressions.Regex(
            @"(?im)^\s*reg(?:\.exe)?\s+(?:add|delete)\s+""?([^""\r\n]+?)""?\s+/v\s+""?([^""/\r\n]+?)""?\s+");

        // Script bundles: back up every value their "reg add/delete" lines touch.
        static IEnumerable<TAction> ScriptRegTargets(TAction s)
        {
            foreach (System.Text.RegularExpressions.Match m in RegAddLine.Matches(s.Command ?? ""))
            {
                string key = m.Groups[1].Value.Trim();
                if (key.Contains("%")) continue;
                yield return new TAction { Kind = "reg", Key = key, Name = m.Groups[2].Value.Trim(), Type = "sz" };
            }
        }

        static void Backup(Tweak t, List<TAction> list)
        {
            Load();
            if (backup.ContainsKey(t.Id)) return;   // keep the very first original values
            var vals = new List<object>();
            var targets = list.Where(x => x.IsRegistry).Concat(list.Where(x => x.Kind == "script").SelectMany(ScriptRegTargets));
            foreach (var a in targets)
                foreach (var p in Expand(a))
                {
                    if (a.Type == "delkey")
                    {
                        if (!KeyExists(p)) continue;
                        string file = Path.Combine(Dir, "keys", t.Id.Replace('.', '_') + "_" + vals.Count + ".reg");
                        Directory.CreateDirectory(Path.GetDirectoryName(file));
                        Shell("reg.exe", "export \"" + p + "\" \"" + file + "\" /y", 60);
                        vals.Add(new Dictionary<string, object> { { "path", p }, { "name", "" }, { "type", "regfile" }, { "value", file } });
                        continue;
                    }
                    // a key that does not exist yet is created by the write: remember the topmost missing one so
                    // "revert" removes it again. Leaving it empty is not the same as before - an empty
                    // WMI\Autologger\X key, for one, makes Windows start a broken logger and crash at boot.
                    string top = TopMissingKey(p);
                    if (top != null && !vals.Any(o => "newkey".Equals(((Dictionary<string, object>)o)["type"]) && string.Equals((string)((Dictionary<string, object>)o)["path"], top, StringComparison.OrdinalIgnoreCase)))
                        vals.Add(new Dictionary<string, object> { { "path", top }, { "name", "" }, { "type", "newkey" } });
                    RegistryValueKind kind;
                    object cur;
                    try { cur = Read(p, a.Name, out kind); } catch { continue; }
                    var v = new Dictionary<string, object> { { "path", p }, { "name", a.Name } };
                    if (cur == null) v["type"] = "del";
                    else if (kind == RegistryValueKind.DWord) { v["type"] = "dw"; v["value"] = (long)(uint)(int)cur; }
                    else if (kind == RegistryValueKind.QWord) { v["type"] = "qw"; v["value"] = Convert.ToInt64(cur); }
                    else if (kind == RegistryValueKind.String) { v["type"] = "sz"; v["value"] = Convert.ToString(cur); }
                    else if (kind == RegistryValueKind.ExpandString) { v["type"] = "esz"; v["value"] = Convert.ToString(cur); }
                    else if (kind == RegistryValueKind.MultiString) { v["type"] = "msz"; v["value"] = string.Join("\0", (string[])cur); }
                    else if (kind == RegistryValueKind.Binary) { v["type"] = "bin"; v["value"] = BytesHex((byte[])cur); }
                    else continue;
                    vals.Add(v);
                }
            backup[t.Id] = new Dictionary<string, object> { { "values", vals }, { "applied", true }, { "at", DateTime.Now.ToString("s") } };
            Save();
        }

        static bool FlagApplied(string id)
        {
            Load();
            object e;
            if (!backup.TryGetValue(id, out e)) return false;
            var d = (Dictionary<string, object>)e;
            return d.ContainsKey("applied") && (bool)d["applied"];
        }

        static void SetFlag(string id, bool on)
        {
            Load();
            object e;
            if (backup.TryGetValue(id, out e)) ((Dictionary<string, object>)e)["applied"] = on;
            else if (on) backup[id] = new Dictionary<string, object> { { "values", new object[0] }, { "applied", true } };
            Save();
        }

        public static IEnumerable<string> BackedUpIds() { Load(); return backup.Keys.ToList(); }

        // Original values first, then the keys this app created (only removable once their values are gone).
        static IEnumerable<Dictionary<string, object>> RestoreOrder(IEnumerable values)
        {
            var all = values.Cast<Dictionary<string, object>>().ToList();
            return all.Where(v => !"newkey".Equals(v["type"])).Concat(all.Where(v => "newkey".Equals(v["type"])));
        }

        // Restores a backup without the tweak that made it (original values, then the saved undo commands).
        public static bool RevertBackupOnly(string id)
        {
            Load();
            object entry;
            if (!backup.TryGetValue(id, out entry)) return false;
            var e = (Dictionary<string, object>)entry;
            if (e.ContainsKey("values"))
                foreach (Dictionary<string, object> v in RestoreOrder((IEnumerable)e["values"]))
                    try { Write((string)v["path"], (string)v["name"], (string)v["type"], v.ContainsKey("value") ? v["value"] : null); }
                    catch (Exception ex) { Log.Add("restore: " + ex.Message); }
            if (e.ContainsKey("undo"))
                foreach (var u in Convert.ToString(e["undo"]).Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries))
                    try { Shell("cmd.exe", "/c " + u, 60); } catch { }
            backup.Remove(id);
            Save();
            return true;
        }

        public static void ForgetBackup(string id) { Load(); if (backup.Remove(id)) Save(); }

        static void Load()
        {
            if (backup != null) return;
            try
            {
                if (File.Exists(BackupFile))
                {
                    var d = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(BackupFile)) as Dictionary<string, object>;
                    if (d != null) { backup = d; return; }
                }
            }
            catch { }
            backup = new Dictionary<string, object>();
        }

        // While applying a whole box (thousands of tweaks) the backup file is written once at the end,
        // not after every tweak.
        static int batch;
        public static void BeginBatch() { lock (typeof(Engine)) batch++; }
        public static void EndBatch() { lock (typeof(Engine)) { if (--batch <= 0) { batch = 0; Save(); } } }

        static void Save()
        {
            if (batch > 0) return;
            try
            {
                Directory.CreateDirectory(Dir);
                File.WriteAllText(BackupFile, new JavaScriptSerializer().Serialize(backup));
            }
            catch (Exception ex) { Log.Add("backup save: " + ex.Message); }
        }

        // ---------- processes ----------
        public static int Shell(string file, string args, int timeoutSec)
        {
            var psi = new ProcessStartInfo(file, args) { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden };
            using (var p = Process.Start(psi))
            {
                if (!p.WaitForExit(timeoutSec * 1000)) { try { p.Kill(); } catch { } return -1; }
                return p.ExitCode;
            }
        }

        // "Apply all": every CMD command in one batch file and every PowerShell command in one script
        // (thousands of separate windows would take far longer). One failing command never stops the rest.
        // Before that, the current state of what each command changes is read, so "Revert all" can put it back.
        public static void RunCommands(List<Tweak> list)
        {
            var had = new HashSet<string>(BackedUpIds());
            var undo = list.ToDictionary(t => t.Id, t => had.Contains(t.Id) ? null : CaptureUndo(t.Apply));
            var cmd = list.SelectMany(t => t.Apply).Where(a => a.Kind == "cmd").Select(a => a.Command).ToList();
            var ps = list.SelectMany(t => t.Apply).Where(a => a.Kind == "ps").Select(a => "try { " + a.Command + " } catch { }").ToList();
            if (cmd.Count > 0) RunScript("@echo off\r\n" + string.Join("\r\n", cmd) + "\r\n", ".cmd", 1800);
            if (ps.Count > 0) RunScript("$ErrorActionPreference = 'SilentlyContinue'\r\n" + string.Join("\r\n", ps) + "\r\n", ".ps1", 1800);
            foreach (var t in list) { SetFlag(t.Id, true); SetUndo(t.Id, undo[t.Id]); }
        }

        // ---------- undo for commands: read the state first, keep the command that restores it
        static readonly System.Text.RegularExpressions.Regex TaskRx = new System.Text.RegularExpressions.Regex(@"^schtasks(?:\.exe)?\s+/change\b.*?/tn\s+(""[^""]+""|\S+).*?/(enable|disable)\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        static readonly System.Text.RegularExpressions.Regex PowerRx = new System.Text.RegularExpressions.Regex(@"^powercfg(?:\.exe)?\s+[-/]set(ac|dc)valueindex\s+(\S+)\s+(\S+)\s+(\S+)\s+\S+", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        static readonly System.Text.RegularExpressions.Regex FsRx = new System.Text.RegularExpressions.Regex(@"^fsutil\s+behavior\s+set\s+(\w+)(\s+refs)?\s+\S+", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        static readonly System.Text.RegularExpressions.Regex EvtRx = new System.Text.RegularExpressions.Regex(@"^wevtutil(?:\.exe)?\s+sl\s+(""[^""]+""|\S+)\s+/e:(true|false)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        public static bool CanUndo(string c)
        {
            c = (c ?? "").Trim();
            return TaskRx.IsMatch(c) || PowerRx.IsMatch(c) || FsRx.IsMatch(c) || EvtRx.IsMatch(c);
        }

        static string CaptureUndo(List<TAction> list)
        {
            var undo = new List<string>();
            foreach (var a in list.Where(a => !a.IsRegistry && a.Command != null))
            {
                try
                {
                    string c = a.Command.Trim(), u = null, o;
                    var m = TaskRx.Match(c);
                    if (m.Success)
                    {
                        o = Capture("schtasks.exe", "/query /tn " + m.Groups[1].Value + " /fo csv /nh");
                        if (o.Length > 0) u = "schtasks /change /tn " + m.Groups[1].Value + (o.IndexOf("\"Disabled\"", StringComparison.OrdinalIgnoreCase) >= 0 ? " /disable" : " /enable");
                    }
                    else if ((m = PowerRx.Match(c)).Success)
                    {
                        o = Capture("powercfg.exe", "/query " + m.Groups[2].Value + " " + m.Groups[3].Value + " " + m.Groups[4].Value);
                        var hex = System.Text.RegularExpressions.Regex.Matches(o, @"0x([0-9a-fA-F]{8})\s*$", System.Text.RegularExpressions.RegexOptions.Multiline);
                        if (hex.Count >= 2)   // last two lines: current AC value, then current DC value
                        {
                            var v = hex[m.Groups[1].Value.ToLowerInvariant() == "ac" ? hex.Count - 2 : hex.Count - 1].Groups[1].Value;
                            u = "powercfg -set" + m.Groups[1].Value + "valueindex " + m.Groups[2].Value + " " + m.Groups[3].Value + " " + m.Groups[4].Value + " " + Convert.ToInt64(v, 16);
                        }
                    }
                    else if ((m = FsRx.Match(c)).Success)
                    {
                        o = Capture("fsutil.exe", "behavior query " + m.Groups[1].Value + m.Groups[2].Value);
                        var v = System.Text.RegularExpressions.Regex.Match(o, @"=\s*(\d+)");
                        if (v.Success) u = "fsutil behavior set " + m.Groups[1].Value + m.Groups[2].Value + " " + v.Groups[1].Value;
                    }
                    else if ((m = EvtRx.Match(c)).Success)
                    {
                        o = Capture("wevtutil.exe", "gl " + m.Groups[1].Value);
                        var v = System.Text.RegularExpressions.Regex.Match(o, @"enabled:\s*(true|false)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                        if (v.Success) u = "wevtutil sl " + m.Groups[1].Value + " /e:" + v.Groups[1].Value.ToLowerInvariant();
                    }
                    if (u != null) undo.Add(u);
                }
                catch { }
            }
            return undo.Count == 0 ? null : string.Join("\r\n", undo);
        }

        static string Capture(string file, string args)
        {
            var psi = new ProcessStartInfo(file, args) { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            using (var p = Process.Start(psi))
            {
                string o = p.StandardOutput.ReadToEnd();
                p.WaitForExit(20000);
                return p.ExitCode == 0 ? o : "";
            }
        }

        static void SetUndo(string id, string undo)
        {
            if (undo == null) return;
            Load();
            object e;
            if (backup.TryGetValue(id, out e) && !((Dictionary<string, object>)e).ContainsKey("undo")) { ((Dictionary<string, object>)e)["undo"] = undo; Save(); }
        }

        static void RunScript(string body, string ext) { RunScript(body, ext, 300); }

        static void RunScript(string body, string ext, int timeoutSec)
        {
            string dir = Path.Combine(Path.GetTempPath(), "JdoTweak");
            Directory.CreateDirectory(dir);
            string file = Path.Combine(dir, Guid.NewGuid().ToString("N") + ext);
            try
            {
                if (ext == ".ps1")
                {
                    File.WriteAllText(file, body, new UTF8Encoding(true));
                    Shell("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\"", timeoutSec);
                }
                else
                {
                    File.WriteAllText(file, body, Encoding.Default);
                    Shell("cmd.exe", "/c \"\"" + file + "\" < nul\"", timeoutSec);
                }
            }
            finally { try { File.Delete(file); } catch { } }
        }

        public static int PowerShell(string script, int timeoutSec)
        {
            string enc = Convert.ToBase64String(Encoding.Unicode.GetBytes("$ErrorActionPreference='SilentlyContinue'; " + script));
            return Shell("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + enc, timeoutSec);
        }

        // Streams a process's output line by line (used by the repair tools).
        public static int Stream(string file, string args, Encoding enc, Action<string> onLine)
        {
            var psi = new ProcessStartInfo(file, args)
            {
                CreateNoWindow = true, UseShellExecute = false,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = enc, StandardErrorEncoding = enc
            };
            using (var p = new Process { StartInfo = psi })
            {
                p.OutputDataReceived += (s, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) onLine(e.Data.Replace("\0", "")); };
                p.ErrorDataReceived += (s, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) onLine(e.Data.Replace("\0", "")); };
                p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine();
                p.WaitForExit();
                return p.ExitCode;
            }
        }

        public static int StreamPS(string script, Action<string> onLine)
        {
            string enc = Convert.ToBase64String(Encoding.Unicode.GetBytes("[Console]::OutputEncoding=[Text.Encoding]::UTF8; " + script));
            return Stream("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + enc, Encoding.UTF8, onLine);
        }

        public static bool CreateRestorePoint()
        {
            // Windows only allows one restore point per 24h unless this is 0.
            Write(@"HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore", "SystemRestorePointCreationFrequency", "dw", 0L);
            int code = PowerShell("Enable-ComputerRestore -Drive \"$env:SystemDrive\\\"; Checkpoint-Computer -Description 'Jdo X Abu Qht' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; exit 0", 300);
            return code == 0;
        }
    }
}
