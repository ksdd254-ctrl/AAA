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
        public bool IsDefault;
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
        public string Id, Ar, En, Icon;
        public string Title { get { return L.Pick(Ar, En); } }
    }

    public class Catalog
    {
        public string Version;
        public List<Category> Categories = new List<Category>();
        public List<Tweak> Tweaks = new List<Tweak>();

        public string LibraryVersion;
        public int DuplicatesRemoved;

        // The interface has one "Windows Debloat" page for all performance tweaks.
        static readonly HashSet<string> Merged = new HashSet<string> { "cpu", "ram", "gpu", "power", "gaming", "latency", "windows" };
        public static string MapCat(string c) { return c != null && Merged.Contains(c) ? "windows" : c; }

        // Tweaks that only make sense on one hardware vendor get their own page, outside the plan boxes,
        // so Intel driver settings never land on an AMD PC (and the other way round).
        static readonly System.Text.RegularExpressions.Regex IntelRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(intelppm|iastor|intel|igfx|ipf|dptf|heci|mei\w*|intelpmt)|\\software\\intel\\|igfxcui|\bintelppm\b",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.Compiled);
        static readonly System.Text.RegularExpressions.Regex AmdRx = new System.Text.RegularExpressions.Regex(
            @"\\services\\(amd|ati\w*\\)|\\software\\(amd|ati technologies)\\|radeon|\bamdppm\b|\{4d36e968-e325-11ce-bfc1-08002be10318\}\|(enableulps|pp_\w+|kmd_\w+|dal\w+)$",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.Compiled);

        public static string VendorCat(string cat, string keyOrText, string name)
        {
            string s = (keyOrText ?? "") + "|" + (name ?? "");
            if (IntelRx.IsMatch(s)) return "intel";
            if (AmdRx.IsMatch(s)) return "amd";
            return cat;
        }

        readonly HashSet<string> curatedSettings = new HashSet<string>();
        readonly HashSet<string> curatedCommands = new HashSet<string>();

        static string NormPath(string key, string name)
        {
            key = System.Text.RegularExpressions.Regex.Replace(key ?? "", @"^HKLM\\", @"HKEY_LOCAL_MACHINE\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            key = System.Text.RegularExpressions.Regex.Replace(key, @"^HKCU\\", @"HKEY_CURRENT_USER\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            key = System.Text.RegularExpressions.Regex.Replace(key, @"\\ControlSet00\d\\", @"\CurrentControlSet\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
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
                    Categories.Add(new Category { Id = Str(d, "id"), Ar = Str(d, "ar"), En = Str(d, "en"), Icon = Str(d, "icon") });
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
                try
                {
                    var t = new Tweak { Library = true, Cat = MapCat(f[1]), Tier = int.Parse(f[2]), Risk = int.Parse(f[3]), Packs = int.Parse(f[4]) };
                    if (f[0] == "S")
                    {
                        bool each = f[5] == "1";
                        string key = f[6], name = f[7], src = f[8];
                        if (key.IndexOf('!') >= 0 || key.IndexOf('%') >= 0) continue;   // unexpanded script variable, not a real path
                        t.Cat = VendorCat(t.Cat, key, name);
                        if (curatedSettings.Contains(NormPath(key, name))) { DuplicatesRemoved++; continue; }   // already a hand-picked tweak
                        t.Id = "s." + StableHash((each ? "*" : "") + key + "|" + name);
                        t.Path = key + "\\" + name;
                        string title = name == "(key)" ? Words(key.Substring(key.LastIndexOf('\\') + 1)) + " (key)" : name == "" ? Words(key.Substring(key.LastIndexOf('\\') + 1)) : Words(name);
                        t.Ar = t.En = title;
                        string where = key.Substring(key.LastIndexOf('\\') + 1);
                        t.DescAr = string.Format(L.T("libDescS", true), title, where) + (t.Packs > 1 ? "  ·  يستخدمه " + t.Packs + " باك" : "");
                        t.DescEn = string.Format(L.T("libDescS", false), title, where) + (t.Packs > 1 ? "  ·  Used by " + t.Packs + " packs" : "");
                        var opts = new List<TOption>();
                        for (int i = 9; i < f.Length; i++)
                        {
                            var p = f[i].Split('\x1F');
                            var a = new TAction { Kind = each ? "each" : "reg", Key = key, Name = name, Type = p[0] };
                            if (p[0] == "dw" || p[0] == "qw") a.Value = long.Parse(p[1]);
                            else if (p[0] == "msz") a.Value = p[1].Replace('\x1E', '\0');
                            else if (p[0] != "del" && p[0] != "delkey") a.Value = p[1];
                            int uses; int.TryParse(p.Length > 2 ? p[2] : "1", out uses);
                            string label = ValueLabel(a);
                            opts.Add(new TOption { Ar = label + (opts.Count == 0 && f.Length > 10 ? "  ★" : ""), En = label + (opts.Count == 0 && f.Length > 10 ? "  ★" : ""), Uses = uses, Apply = new List<TAction> { a } });
                        }
                        if (opts.Count == 1) t.Apply = opts[0].Apply;   // single value: on/off switch, off restores the original
                        else
                        {
                            opts.Add(new TOption { Ar = "الأصلي (قيمة جهازك)", En = "Original (your PC's value)", IsDefault = true });
                            t.Options = opts;
                        }
                    }
                    else if (f[0] == "C")
                    {
                        string text = f[6];
                        if (curatedCommands.Contains(NormCmd(text))) { DuplicatesRemoved++; continue; }
                        t.Cat = VendorCat(t.Cat, text, null);
                        t.Id = "c." + StableHash(text.ToLowerInvariant());
                        t.Ar = t.En = text.Length > 110 ? text.Substring(0, 107) + "..." : text;
                        t.Path = text.Length > 110 ? text : null;
                        t.DescAr = "أمر " + (f[5] == "ps" ? "PowerShell" : "CMD") + "  ·  من: " + f[7] + "  ·  ما ينرجع تلقائياً";
                        t.DescEn = (f[5] == "ps" ? "PowerShell" : "CMD") + " command  ·  From: " + f[7] + "  ·  no automatic undo";
                        t.Apply = new List<TAction> { new TAction { Kind = f[5] == "ps" ? "ps" : "cmd", Command = text } };
                        t.NoUndo = true;
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
                    t.SearchText = (t.En + " " + (t.Path ?? "") + " " + t.DescEn).ToLowerInvariant();
                    Tweaks.Add(t);
                }
                catch { }
            }
        }

        public static string ValueLabel(TAction a)
        {
            switch (a.Type)
            {
                case "del": return L.Ar ? "حذف القيمة" : "Delete value";
                case "delkey": return L.Ar ? "حذف المفتاح" : "Delete key";
                case "bin": return "Binary (" + (Convert.ToString(a.Value).Split(',').Length) + " bytes)";
                case "msz": return Convert.ToString(a.Value).Replace("\0", " | ");
                case "dw":
                case "qw":
                    long v = Convert.ToInt64(a.Value);
                    return v > 255 || v < 0 ? v + "  (0x" + v.ToString("X") + ")" : v.ToString();
                default:
                    string s = Convert.ToString(a.Value);
                    return s.Length > 48 ? s.Substring(0, 45) + "..." : s == "" ? "\"\"" : s;
            }
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
            using (var b = Hive(path, out sub))
            {
                if (type == "delkey") { b.DeleteSubKeyTree(sub, false); return; }
                if (type == "del")
                {
                    using (var k = b.OpenSubKey(sub, true)) { if (k != null) k.DeleteValue(name, false); }
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
        public static void ApplyTweak(Tweak t) { Backup(t, t.Apply); Run(t.Apply); SetFlag(t.Id, true); }

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
                foreach (Dictionary<string, object> v in (IEnumerable)e["values"])
                {
                    try
                    {
                        string type = (string)v["type"];
                        Write((string)v["path"], (string)v["name"], type, v.ContainsKey("value") ? v["value"] : null);
                    }
                    catch (Exception ex) { Log.Add("restore: " + ex.Message); }
                }
                Run(t.Revert.Where(a => !a.IsRegistry).ToList());
                backup.Remove(t.Id);
                Save();
            }
            else Run(t.Revert);
            SetFlag(t.Id, false);
        }

        // Reverts anything this app changed, including single switches inside a tweak ("id#2").
        public static bool RevertById(Catalog cat, string id)
        {
            var t = cat.Find(id);
            if (t == null) return false;
            if (t.HasOptions) { int d = t.Options.FindIndex(o => o.IsDefault); if (d >= 0) { ApplyOption(t, d); return true; } }
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

        static void RunScript(string body, string ext)
        {
            string dir = Path.Combine(Path.GetTempPath(), "JdoTweak");
            Directory.CreateDirectory(dir);
            string file = Path.Combine(dir, Guid.NewGuid().ToString("N") + ext);
            try
            {
                if (ext == ".ps1")
                {
                    File.WriteAllText(file, body, new UTF8Encoding(true));
                    Shell("powershell.exe", "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + file + "\"", 300);
                }
                else
                {
                    File.WriteAllText(file, body, Encoding.Default);
                    Shell("cmd.exe", "/c \"\"" + file + "\" < nul\"", 300);
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
            int code = PowerShell("Enable-ComputerRestore -Drive \"$env:SystemDrive\\\"; Checkpoint-Computer -Description 'JDO Tweak' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop; exit 0", 300);
            return code == 0;
        }
    }
}
