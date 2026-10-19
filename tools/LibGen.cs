// JDO Tweak - library generator (fast C# version)
// Every registry value and every command becomes its own tweak - nothing is bundled.
//   * values from real tweak files (not whole-registry exports) are all included
//   * values that only exist inside registry exports are included when >= MinPacks packs use them
//   * conflicting values for the same setting become options, most-used first
// Output: tab-separated, gzip-compressed library the app loads at start.
// Usage: LibGen.exe <cleanDir> <settings.csv> <out.tsv.gz>
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

static class LibGen
{
    const int DumpLimit = 400;   // a .reg with more values than this is a registry export, not a tweak
    const int MinPacks = 5;

    class Setting
    {
        public string Key, Name, Each, Src;
        public bool FromTweakFile;
        public Dictionary<string, int> Values = new Dictionary<string, int>();   // "type\x1Fdata" -> uses
        public int Packs;
    }
    class Cmd { public string Text, Ext, Src; public int Uses; }

    static readonly Dictionary<string, Setting> settings = new Dictionary<string, Setting>(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, Cmd> commands = new Dictionary<string, Cmd>(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, int[]> popularity = new Dictionary<string, int[]>(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, Dictionary<string, int>> valueUses = new Dictionary<string, Dictionary<string, int>>(StringComparer.OrdinalIgnoreCase);
    static int dumpFiles, tweakFiles, scriptFiles, skippedLines;

    static readonly Dictionary<string, string> Hives = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    { { "HKLM", "HKEY_LOCAL_MACHINE" }, { "HKCU", "HKEY_CURRENT_USER" }, { "HKCR", "HKEY_CLASSES_ROOT" }, { "HKU", "HKEY_USERS" }, { "HKCC", "HKEY_CURRENT_CONFIG" } };

    static int Main(string[] a)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        LoadPopularity(a[1]);
        Console.WriteLine("popularity: " + popularity.Count + "  (" + sw.Elapsed.TotalSeconds.ToString("0") + "s)");
        foreach (var tree in new[] { "Tweaks", "Network" })
        {
            string root = Path.Combine(a[0], tree);
            if (!Directory.Exists(root)) continue;
            foreach (var f in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
            {
                string ext = Path.GetExtension(f).ToLowerInvariant();
                string rel = f.Substring(root.Length + 1);
                try
                {
                    if (ext == ".reg") ParseReg(f, rel);
                    else if (ext == ".bat" || ext == ".cmd" || ext == ".ps1") { scriptFiles++; ParseScript(f, rel, ext); }
                }
                catch (Exception ex) { Console.Error.WriteLine(rel + ": " + ex.Message); }
            }
        }
        Console.WriteLine("parsed: tweakFiles=" + tweakFiles + " dumps=" + dumpFiles + " scripts=" + scriptFiles + "  (" + sw.Elapsed.TotalSeconds.ToString("0") + "s)");
        Write(a[2]);
        Console.WriteLine("done in " + sw.Elapsed.TotalSeconds.ToString("0") + "s");
        return 0;
    }

    // settings.csv from analyze.ps1: Key,Name,TopValue,TopCount,Variants,AllValues,Packs
    static void LoadPopularity(string csv)
    {
        var rx = new Regex(@"^(\w+)=(.*) x(\d+)$");
        foreach (var line in File.ReadLines(csv).Skip(1))
        {
            var c = SplitCsv(line);
            if (c.Count < 7) continue;
            string id = (c[0] + "|" + c[1]);
            int packs; int.TryParse(c[6], out packs);
            popularity[id] = new[] { packs };
            var vu = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var part in c[5].Split(new[] { " | " }, StringSplitOptions.None))
            {
                var m = rx.Match(part);
                if (!m.Success) continue;
                string t = TypeCode(m.Groups[1].Value);
                if (t == null) continue;
                vu[t + "\x1F" + NormData(t, m.Groups[2].Value)] = int.Parse(m.Groups[3].Value);
            }
            valueUses[id] = vu;
        }
    }

    static List<string> SplitCsv(string line)
    {
        var r = new List<string>(); var sb = new StringBuilder(); bool q = false;
        for (int i = 0; i < line.Length; i++)
        {
            char ch = line[i];
            if (q) { if (ch == '"') { if (i + 1 < line.Length && line[i + 1] == '"') { sb.Append('"'); i++; } else q = false; } else sb.Append(ch); }
            else if (ch == '"') q = true;
            else if (ch == ',') { r.Add(sb.ToString()); sb.Clear(); }
            else sb.Append(ch);
        }
        r.Add(sb.ToString());
        return r;
    }

    static string TypeCode(string t)
    {
        switch (t.ToUpperInvariant())
        {
            case "REG_DWORD": return "dw"; case "REG_QWORD": return "qw"; case "REG_SZ": return "sz";
            case "REG_EXPAND_SZ": return "esz"; case "REG_MULTI_SZ": return "msz"; case "REG_BINARY": return "bin"; case "DELETE": return "del";
        }
        return null;
    }

    static string NormData(string t, string d)
    {
        d = d.Trim();
        if (t == "dw" || t == "qw")
        {
            ulong v;
            if (d.StartsWith("0x", StringComparison.OrdinalIgnoreCase) && ulong.TryParse(d.Substring(2), System.Globalization.NumberStyles.HexNumber, null, out v)) return ((long)v).ToString();
            long l; if (long.TryParse(d, out l)) return l.ToString();
            if (ulong.TryParse(d, out v)) return ((long)v).ToString();
            return null;
        }
        if (t == "bin") return d.ToLowerInvariant().Replace(" ", "");
        return d;
    }

    static string NormKey(string k)
    {
        k = k.Trim().Trim('"').TrimEnd('\\');
        int i = k.IndexOf('\\');
        string h = i < 0 ? k : k.Substring(0, i);
        string full;
        if (Hives.TryGetValue(h, out full)) k = full + (i < 0 ? "" : k.Substring(i));
        k = Regex.Replace(k, @"\\ControlSet00\d\\", @"\CurrentControlSet\", RegexOptions.IgnoreCase);
        return k;
    }

    // Returns null when the key belongs to one specific machine/device; sets each=true when it
    // should apply to every subkey (network interfaces, display/network adapter class entries).
    static string MapKey(string k, out bool each)
    {
        each = false;
        if (Regex.IsMatch(k, @"^HKEY_USERS\\S-1-", RegexOptions.IgnoreCase)) return null;
        if (Regex.IsMatch(k, @"\\Enum\\|\\DriverDatabase\\|\\Uninstall\\\{|\\Installer\\|\\MuiCache|\\RecentDocs|\\UserAssist|\\Shell\\Bags|\\ShellNoRoam|\\ComDlg32|\\TypedPaths|\\RunMRU|\\WordWheelQuery|\\FeatureUsage|\\Store\\|\\AppCompatFlags\\Compatibility Assistant", RegexOptions.IgnoreCase)) return null;
        var m = Regex.Match(k, @"^(.+\\Tcpip6?\\Parameters\\Interfaces)\\\{[0-9a-f-]+\}$", RegexOptions.IgnoreCase);
        if (m.Success) { each = true; return m.Groups[1].Value; }
        m = Regex.Match(k, @"^(.+\\Control\\Class\\\{[0-9a-f-]+\})\\\d{4}$", RegexOptions.IgnoreCase);
        if (m.Success) { each = true; return m.Groups[1].Value; }
        if (Regex.IsMatch(k, @"\\Interfaces\\\{[0-9a-f-]+\}\\|\\Class\\\{[0-9a-f-]+\}\\\d{4}\\", RegexOptions.IgnoreCase)) return null;
        return k;
    }

    static void AddSetting(string rawKey, string name, string type, string data, string src, bool fromTweak)
    {
        bool each;
        string key = MapKey(NormKey(rawKey), out each);
        if (key == null || type == null || data == null) { skippedLines++; return; }
        string id = (each ? "*" : "") + key + "|" + name;
        Setting s;
        if (!settings.TryGetValue(id, out s))
        {
            s = new Setting { Key = key, Name = name, Each = each ? "1" : "", Src = src };
            int[] p; popularity.TryGetValue(NormKey(rawKey) + "|" + name, out p);
            s.Packs = p != null ? p[0] : 1;
            settings[id] = s;
        }
        if (fromTweak && !s.FromTweakFile) { s.FromTweakFile = true; s.Src = src; }
        string v = type + "\x1F" + data;
        if (!s.Values.ContainsKey(v))
        {
            Dictionary<string, int> vu; int uses = 1;
            if (valueUses.TryGetValue(NormKey(rawKey) + "|" + name, out vu)) vu.TryGetValue(v, out uses);
            s.Values[v] = Math.Max(1, uses);
        }
    }

    static void ParseReg(string file, string rel)
    {
        string text = File.ReadAllText(file);
        text = Regex.Replace(text, @"\\\r?\n\s*", "");
        var lines = text.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        int values = lines.Count(l => l.Length > 0 && (l[0] == '"' || l[0] == '@'));
        bool tweak = values <= DumpLimit;
        if (tweak) tweakFiles++; else dumpFiles++;
        string key = null;
        var rxVal = new Regex(@"^(@|""((?:[^""\\]|\\.)*)"")\s*=\s*(.*)$");
        foreach (var raw in lines)
        {
            string l = raw.Trim();
            if (l.Length == 0 || l[0] == ';') continue;
            if (l[0] == '[' && l.EndsWith("]"))
            {
                key = l.Substring(1, l.Length - 2);
                if (key.StartsWith("-")) { AddSetting(key.Substring(1), "(key)", "delkey", "", rel, tweak); key = null; }
                continue;
            }
            if (key == null) continue;
            var m = rxVal.Match(l);
            if (!m.Success) continue;
            string name = m.Groups[1].Value == "@" ? "" : m.Groups[2].Value.Replace("\\\\", "\\").Replace("\\\"", "\"");
            string v = m.Groups[3].Value.Trim();
            string type = null, data = null;
            if (v == "-") { type = "del"; data = ""; }
            else if (v.StartsWith("dword:", StringComparison.OrdinalIgnoreCase)) { type = "dw"; data = NormData("dw", "0x" + v.Substring(6)); }
            else if (v.StartsWith("hex(b):", StringComparison.OrdinalIgnoreCase)) { type = "qw"; data = HexQword(v.Substring(7)); }
            else if (v.StartsWith("hex(2):", StringComparison.OrdinalIgnoreCase)) { type = "esz"; data = HexString(v.Substring(7)); }
            else if (v.StartsWith("hex(7):", StringComparison.OrdinalIgnoreCase)) { type = "msz"; data = HexString(v.Substring(7)); }
            else if (v.StartsWith("hex:", StringComparison.OrdinalIgnoreCase)) { type = "bin"; data = v.Substring(4).ToLowerInvariant().Replace(" ", ""); }
            else if (v.Length >= 2 && v[0] == '"' && v[v.Length - 1] == '"') { type = "sz"; data = v.Substring(1, v.Length - 2).Replace("\\\\", "\\").Replace("\\\"", "\""); }
            AddSetting(key, name, type, data, rel, tweak);
        }
    }

    static string HexQword(string h)
    {
        var b = h.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(x => Convert.ToByte(x.Trim(), 16)).ToArray();
        if (b.Length != 8) return null;
        return BitConverter.ToInt64(b, 0).ToString();
    }

    static string HexString(string h)
    {
        try
        {
            var b = h.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Select(x => Convert.ToByte(x.Trim(), 16)).ToArray();
            return Encoding.Unicode.GetString(b).TrimEnd('\0');
        }
        catch { return null; }
    }

    static readonly Regex RegAdd = new Regex(@"^\s*@?reg(?:\.exe)?\s+add\s+""?([^""]+?)""?\s+(?:/v\s+""?([^""/]*?)""?|/ve)\s+(?:/t\s+(\w+)\s+)?(?:/d\s+""?([^""]*?)""?\s+)?/f", RegexOptions.IgnoreCase);
    static readonly Regex RegDel = new Regex(@"^\s*@?reg(?:\.exe)?\s+delete\s+""?([^""]+?)""?\s+/v\s+""?([^""/]+?)""?\s+/f", RegexOptions.IgnoreCase);
    static readonly Regex CmdStart = new Regex(@"^\s*@?(powercfg|netsh|sc(\.exe)?\s+(config|stop|start|failure)|fsutil|bcdedit|schtasks|dism|wmic|net\s+(stop|start)|takeown|icacls|wevtutil|cipher|Disable-MMAgent|Enable-MMAgent|(Set|New|Remove|Disable|Enable|Stop|Start|Reset|Clear|Add|Unregister|Register)-[A-Za-z]+)\b", RegexOptions.IgnoreCase);

    static void ParseScript(string file, string rel, string ext)
    {
        var enc = ext == ".ps1" ? Encoding.UTF8 : Encoding.Default;
        foreach (var raw in File.ReadAllLines(file, enc))
        {
            string l = raw.Trim();
            if (l.Length < 6) continue;
            l = Regex.Replace(l, @"\s*(>\s*nul|2>\s*&1|2>\s*nul|>nul\s+2>&1|\|\s*Out-Null)\s*", " ", RegexOptions.IgnoreCase).Trim();
            var m = RegAdd.Match(l);
            if (m.Success)
            {
                string t = TypeCode(m.Groups[3].Success && m.Groups[3].Value != "" ? m.Groups[3].Value : "REG_SZ");
                string d = m.Groups[4].Success ? m.Groups[4].Value : "";
                if (d.Contains("%") || t == null) { skippedLines++; continue; }
                if (t == "bin") d = Regex.Replace(d, "(..)(?!$)", "$1,").ToLowerInvariant();
                AddSetting(m.Groups[1].Value, m.Groups[2].Success ? m.Groups[2].Value.Trim() : "", t, t == "dw" || t == "qw" ? NormData(t, d) : d, rel, true);
                continue;
            }
            m = RegDel.Match(l);
            if (m.Success) { AddSetting(m.Groups[1].Value, m.Groups[2].Value.Trim(), "del", "", rel, true); continue; }
            if (!CmdStart.IsMatch(l)) continue;
            // Lines that depend on the surrounding script (variables, loops) can't run on their own.
            if (Regex.IsMatch(l, @"%[^%\s]+%|%%|%~|![A-Za-z_]+!") || (ext == ".ps1" && Regex.IsMatch(l, @"\$(?!true\b|false\b|null\b|env:)[A-Za-z_]", RegexOptions.IgnoreCase)))
            { skippedLines++; continue; }
            if (l.EndsWith("{") || l.EndsWith("(") || l.EndsWith("`") || l.EndsWith("^")) { skippedLines++; continue; }
            string norm = Regex.Replace(l, @"\s+", " ").ToLowerInvariant();
            Cmd c;
            if (commands.TryGetValue(norm, out c)) c.Uses++;
            else commands[norm] = new Cmd { Text = l, Ext = ext == ".ps1" ? "ps" : "cmd", Src = rel, Uses = 1 };
        }
    }

    // ---------------- categories / tiers / risk ----------------
    static readonly string[][] CatRules =
    {
        new[] { "advanced", @"defender|smartscreen|deviceguard|enablelua|\buac\b|featuresettingsoverride|mitigation|sehop|firewall|securityhealth|wscsvc|hvci|\bvbs\b|tamper|windowsupdate|wuauserv|usosvc|waasmedic|exploit|DisableAntiSpyware|MpPreference|ExceptionChain|KernelSEHOP|ProtectionMode|CodeIntegrity|CredentialGuard|LsaCfg" },
        new[] { "mouse",    @"mouse|mouclass|pointer|smoothmouse|cursor" },
        new[] { "keyboard", @"keyboard|kbdclass|stickykeys|togglekeys|keyboard response|filterkeys" },
        new[] { "network",  @"\\tcpip|psched|lanman|\\afd\\|\\ndis|netsh|\\dnscache|\{4d36e972|\bqos\b|winsock|\\netbt|\bdns\b|tcp|udp|\bnagle|internet settings|Set-Net|NetAdapter|\\nla" },
        new[] { "gpu",      @"nvidia|nvlddmkm|\bamd\b|radeon|graphicsdrivers|\\dwm|\{4d36e968|directx|direct3d|\bgpu\b|nvcpl|nvtweak|igfx|\bmpo\b|overlay|\\amdkmdag|\\amdkmdap|\\umd\b" },
        new[] { "power",    @"power|powercfg|throttl|hibernat|coalescing|latencytolerance|\bidle\b|parking|\bcstate" },
        new[] { "cpu",      @"prioritycontrol|win32priorityseparation|processor|\bcpu\b|\\kernel\b|distributetimers|threaddpc|dpcwatchdog|affinity|perfoptions|cpupriorityclass|iopriority|\\Image File Execution" },
        new[] { "ram",      @"memory management|\bmemory|pagingfiles|pagefile|svchost|sysmain|superfetch|prefetch|mmagent|largesystemcache|iopagelock" },
        new[] { "latency",  @"latency|delay|timer|\bdpc\b|interrupt|\bmsi\b|\birq\b|responsiveness|\bhpet\b|\btick|timeout|\\multimedia\\systemprofile" },
        new[] { "gaming",   @"\bgame|gamedvr|gamebar|gameconfigstore|fortnite|valorant|\bcs2\b|csgo|warzone|apex|minecraft|roblox|steam|epicgames|\bfps\b|xbox" },
        new[] { "privacy",  @"telemetry|datacollection|privacy|advertisinginfo|diagtrack|siuf|activity|\blocation|capabilityaccessmanager|tracking|cortana|feedback|ceip|sqm|census|inputpersonalization|contentdelivery" },
        new[] { "storage",  @"fsutil|ntfs|\\disk\\|storage|\bssd\b|\btrim\b|defrag|storport|8dot3|lastaccess|\bnvme\b|\\stornvme|\\storahci" },
    };
    static readonly Regex[] CatRx = CatRules.Select(r => new Regex(r[1], RegexOptions.IgnoreCase | RegexOptions.Compiled)).ToArray();
    static string Category(string text)
    {
        for (int i = 0; i < CatRx.Length; i++) if (CatRx[i].IsMatch(text)) return CatRules[i][0];
        return "windows";
    }
    static readonly Regex RiskHigh = new Regex(@"defender|smartscreen|deviceguard|enablelua|featuresettingsoverride|mitigation|sehop|firewall|securityhealth|hvci|tamper|DisableAntiSpyware|wuauserv|usosvc|windowsupdate|takeown|icacls|cipher|\bdel\b|\brd\b|format |diskpart|wevtutil|ExceptionChain|CodeIntegrity|LsaCfg", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex RiskMid = new Regex(@"\\services\\[^\\]+\\start\b|sc(\.exe)? +config|start= *disabled|threadpriority|preemption|bcdedit|Remove-Appx|appxpackage|schtasks|\|\(key\)|delkey|Stop-Service|Disable-", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    static string Clean(string s) { return (s ?? "").Replace("\t", " ").Replace("\r", " ").Replace("\n", " "); }

    static void Write(string outFile)
    {
        int sCount = 0, oCount = 0, cCount = 0;
        using (var fs = File.Create(outFile))
        using (var gz = new GZipStream(fs, CompressionLevel.Optimal))
        using (var w = new StreamWriter(gz, new UTF8Encoding(false)))
        {
            w.WriteLine("#JDOLIB\t2\t" + DateTime.Now.ToString("yyyy.MM.dd"));
            var catCount = new Dictionary<string, int>();
            foreach (var kv in settings.OrderByDescending(x => x.Value.Packs).ThenBy(x => x.Key, StringComparer.OrdinalIgnoreCase))
            {
                var s = kv.Value;
                if (!s.FromTweakFile && s.Packs < MinPacks) continue;
                // one-pack oddities outside the performance categories are noise, not tweaks

                var vals = s.Values.Where(v => v.Key.Split('\x1F')[1] != null).OrderByDescending(v => v.Value).Take(12).ToList();
                if (vals.Count == 0) continue;
                string path = s.Key + "\\" + s.Name;
                string cat = Category(path);
                int tier = s.Packs >= 20 ? 1 : s.Packs >= 5 ? 2 : 3;
                int risk = RiskHigh.IsMatch(path) ? 2 : RiskMid.IsMatch(path + "|" + vals[0].Key) ? 1 : 0;
                var sb = new StringBuilder();
                sb.Append("S\t").Append(cat).Append('\t').Append(tier).Append('\t').Append(risk).Append('\t').Append(s.Packs).Append('\t')
                  .Append(s.Each).Append('\t').Append(Clean(s.Key)).Append('\t').Append(Clean(s.Name)).Append('\t').Append(Clean(s.Src));
                foreach (var v in vals)
                {
                    var p = v.Key.Split('\x1F');
                    sb.Append('\t').Append(p[0]).Append('\x1F').Append(Clean(p[1]).Replace("\0", "\x1E")).Append('\x1F').Append(v.Value);
                }
                w.WriteLine(sb.ToString());
                sCount++; oCount += vals.Count;
                int n; catCount.TryGetValue(cat, out n); catCount[cat] = n + 1;
            }
            foreach (var c in commands.Values.OrderByDescending(x => x.Uses))
            {
                string cat = Category(c.Text);
                int risk = RiskHigh.IsMatch(c.Text) ? 2 : RiskMid.IsMatch(c.Text) ? 1 : 0;
                int tier = c.Uses >= 20 ? 1 : c.Uses >= 5 ? 2 : 3;
                w.WriteLine("C\t" + cat + "\t" + tier + "\t" + risk + "\t" + c.Uses + "\t" + c.Ext + "\t" + Clean(c.Text) + "\t" + Clean(c.Src));
                cCount++;
                int n; catCount.TryGetValue(cat, out n); catCount[cat] = n + 1;
            }
            Console.WriteLine("settings=" + sCount + " values=" + oCount + " commands=" + cCount + " skippedLines=" + skippedLines);
            Console.WriteLine(string.Join(" ", catCount.OrderByDescending(x => x.Value).Select(x => x.Key + "=" + x.Value)));
        }
    }
}
