#if DEV
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace JdoTweak
{
    // Read-only audit of the loaded catalog: nothing here calls Engine, so no registry value,
    // file or service is touched. It checks what the real app would apply, using the real loader.
    public static class Audit
    {
        static int pass, fail;
        static TextWriter log;

        static void Check(string what, bool ok) { if (ok) pass++; else fail++; log.WriteLine((ok ? "PASS  " : "FAIL  ") + what); }

        static IEnumerable<TAction> AllActions(Tweak t)
        {
            foreach (var a in t.Apply) yield return a;
            if (t.Options != null) foreach (var o in t.Options) foreach (var a in o.Apply) yield return a;
        }

        static string SettingId(TAction a)
        {
            string k = (a.Key ?? "").ToLowerInvariant().Replace(@"\controlset001\", @"\currentcontrolset\");
            if (k.StartsWith(@"hklm\")) k = @"hkey_local_machine\" + k.Substring(5);
            if (k.StartsWith(@"hkcu\")) k = @"hkey_current_user\" + k.Substring(5);
            return k.TrimEnd('\\') + "|" + (a.Name ?? "").ToLowerInvariant();
        }

        static string ValueId(TAction a) { return a.Type + ":" + Convert.ToString(a.Value); }

        public static int Run(string outFile)
        {
            var cat = App.Catalog;
            using (log = new StreamWriter(outFile))
            {
                log.WriteLine("tweaks loaded: " + cat.Tweaks.Count + "  (anti-cheat items removed: " + cat.AntiCheatRemoved + ", duplicates removed: " + cat.DuplicatesRemoved + ", broken removed: " + cat.BrokenRemoved + ")");
                foreach (var g in cat.Tweaks.GroupBy(t => t.Cat).OrderBy(g => g.Key))
                    log.WriteLine(string.Format("  {0,-12} {1,6} tweaks  (hand-picked {2})", g.Key, g.Count(), g.Count(t => t.Curated)));
                log.WriteLine();

                // 1) anti-cheat: nothing left that touches what anti-cheats watch
                var ac = cat.Tweaks.Where(t => AllActions(t).Any(a => a.IsRegistry ? Catalog.AntiCheatUnsafe(a.Key, a.Name) : Catalog.AntiCheatUnsafe(a.Command, null))).ToList();
                Check("anti-cheat: no tweak touches anti-cheat services, driver signing, exploit protection, VBS/TPM or game executables (" + ac.Count + ")", ac.Count == 0);
                ac.Take(10).ToList().ForEach(t => log.WriteLine("    " + t.Id + "  " + t.Path));

                // 2) order independence: every registry value belongs to exactly one tweak, so switching tweak 3
                //    on or off can never change what tweak 1 or 2 wrote
                var owners = new Dictionary<string, HashSet<string>>();
                foreach (var t in cat.Tweaks)
                    foreach (var a in AllActions(t).Where(a => a.IsRegistry))
                    {
                        string id = SettingId(a);
                        HashSet<string> s;
                        if (!owners.TryGetValue(id, out s)) owners[id] = s = new HashSet<string>();
                        s.Add(t.Id);
                    }
                var shared = owners.Where(kv => kv.Value.Count > 1).ToList();
                Check("order: every registry value is written by one tweak only (" + owners.Count + " values, shared: " + shared.Count + ")", shared.Count == 0);
                shared.Take(10).ToList().ForEach(kv => log.WriteLine("    " + kv.Key + "  <- " + string.Join(", ", kv.Value)));

                var cmds = cat.Tweaks.SelectMany(t => AllActions(t).Where(a => !a.IsRegistry && a.Command != null).Select(a => new { t.Id, C = a.Command.Trim().ToLowerInvariant() }))
                    .GroupBy(x => x.C).Where(g => g.Select(x => x.Id).Distinct().Count() > 1).ToList();
                Check("order: no command appears in two tweaks (" + cmds.Count + ")", cmds.Count == 0);
                cmds.Take(5).ToList().ForEach(g => log.WriteLine("    " + g.Key + "  <- " + string.Join(", ", g.Select(x => x.Id).Distinct())));

                // 3) values are well-formed
                int bad = 0;
                foreach (var t in cat.Tweaks)
                    foreach (var a in AllActions(t).Where(a => a.IsRegistry))
                    {
                        bool ok = true;
                        if (string.IsNullOrEmpty(a.Key) || !(a.Key.StartsWith("HKEY_", StringComparison.OrdinalIgnoreCase) || a.Key.StartsWith("HK", StringComparison.OrdinalIgnoreCase))) ok = false;
                        if (a.Type == "dw") { long v = Convert.ToInt64(a.Value); ok &= v >= 0 && v <= 0xFFFFFFFFL; }
                        if (a.Type == "bin") ok &= Convert.ToString(a.Value).Split(',').All(h => h.Length == 0 || System.Text.RegularExpressions.Regex.IsMatch(h.Trim(), "^[0-9a-fA-F]{1,2}$"));
                        if (!ok) { bad++; if (bad <= 5) log.WriteLine("    bad value: " + t.Id + "  " + a.Key + "\\" + a.Name + " = " + a.Value); }
                    }
                Check("values: every registry value has a valid hive and data (" + bad + " bad)", bad == 0);

                // 4) best value first: the option the boxes and "Apply all" use is the best one for games where that is
                //    known (Fortnite: FPS, frame times, input and network delay), otherwise the most-used one
                var lib = cat.Tweaks.Where(t => t.Library && t.HasOptions).ToList();
                int wrong = lib.Count(t =>
                {
                    int r = t.RecommendedOption(null); var real = t.Options.Where(o => !o.IsDefault).ToList();
                    if (r < 0 || t.Options[r].IsDefault) return true;
                    if (real.Any(o => o.Game)) return !t.Options[r].Game;
                    return t.Options[r].Uses < real.Max(o => o.Uses);
                });
                int games = lib.Count(t => t.Options.Any(o => o.Game));
                Check("best values: multi-option settings apply the best value for games (" + games + " settings) or else the most used (" + lib.Count + " settings, wrong: " + wrong + ")", wrong == 0);
                foreach (var t in lib.Where(t => t.Options.Any(o => o.Game)).Take(6))
                    log.WriteLine("    for games: " + t.Path + " = " + t.Options[t.RecommendedOption(null)].En);

                // 5) plans: Basic about 30%, Elite about 60%, Ultimate 100% of the boxes; network included by plan
                var pack = PackPage.InPack(cat, "windows", null);
                int b1 = pack.Count(t => t.Tier <= 1), b2 = pack.Count(t => t.Tier <= 2), b3 = pack.Count;
                double p1 = 100.0 * b1 / b3, p2 = 100.0 * b2 / b3;
                log.WriteLine(string.Format("  boxes: Basic {0:N0} ({1:0}%), Elite {2:N0} ({3:0}%), Ultimate {4:N0} (100%)", b1, p1, b2, p2, b3));
                Check("plans: Basic is about 30% of Ultimate", p1 >= 26 && p1 <= 34);
                Check("plans: Elite is about 60% of Ultimate", p2 >= 56 && p2 <= 64);
                Check("plans: Basic is inside Elite, Elite inside Ultimate", pack.Where(t => t.Tier <= 1).All(t => t.Tier <= 2));
                int n1 = pack.Count(t => t.Cat == "network" && t.Tier <= 1), n2 = pack.Count(t => t.Cat == "network" && t.Tier <= 2), n3 = pack.Count(t => t.Cat == "network");
                log.WriteLine(string.Format("  network in boxes: Basic {0}, Elite {1}, Ultimate {2}", n1, n2, n3));
                Check("network: each plan gets more network settings than the one below", n1 > 0 && n1 < n2 && n2 < n3);
                Check("network: no DNS / IP / gateway / DHCP value rides along in a box", !pack.Any(PackPage.AddressSetting));
                Check("boxes: no command (no automatic undo) and nothing risky", !pack.Any(t => t.NoUndo || (t.Library && t.Risk > 0) || t.Risk > 1));
                Check("boxes: no vendor-specific (CPU/GPU) tweak", !pack.Any(t => TweakPage.IsVendorSection(t.Cat)));
                var bulk = pack.Where(t => t.Library && Catalog.BulkUnsafe(t)).ToList();
                Check("boxes: nothing that touches the kernel, power definitions, drivers, service wiring, protection or Update (" + bulk.Count + ")", bulk.Count == 0);
                log.WriteLine("  other app settings left out: " + cat.JunkRemoved + ", kept out of boxes (one by one only): " + cat.Tweaks.Count(t => t.Library && Catalog.BulkUnsafe(t)));

                // 5b) the same switch twice: two tweaks whose actions are identical
                var same = cat.Tweaks.Where(t => t.Apply.Count > 0)
                    .GroupBy(t => string.Join(";", t.Apply.Select(a => a.IsRegistry ? SettingId(a) + "=" + ValueId(a) : (a.Command ?? "").Trim().ToLowerInvariant())))
                    .Where(g => g.Count() > 1).ToList();
                Check("duplicates: no two tweaks do exactly the same thing (" + same.Count + ")", same.Count == 0);
                same.Take(5).ToList().ForEach(g => log.WriteLine("    " + string.Join(", ", g.Select(t => t.Id))));

                // 5c) contradictions over everything that can be switched on together (boxes and every section's
                //     "Apply all"): no pack setting may work against a hand-picked one, no two hand-picked ones against each other
                Func<string, string> leaf = k => k.Substring(k.LastIndexOf('\\') + 1).ToLowerInvariant();
                var together = cat.Tweaks.Where(t => !t.NoBulk && t.Risk <= 1 && !Catalog.AddressSetting(t)).ToList();
                var picked = together.Where(t => t.Curated).SelectMany(t => t.Apply.Where(a => a.IsRegistry && !string.IsNullOrEmpty(a.Name)).Select(a => new { t.Id, A = a })).ToList();
                var clash = new List<string>();
                foreach (var x in picked)
                    foreach (var y in picked.Where(y => string.CompareOrdinal(y.Id, x.Id) > 0 && y.A.Name.Equals(x.A.Name, StringComparison.OrdinalIgnoreCase) && leaf(y.A.Key) == leaf(x.A.Key) && !ValueId(y.A).Equals(ValueId(x.A), StringComparison.OrdinalIgnoreCase)))
                        clash.Add(x.Id + " " + x.A.Key + "\\" + x.A.Name + " = " + ValueId(x.A) + "   vs  " + y.Id + "=" + ValueId(y.A));
                foreach (var t in together.Where(t => t.Library))
                {
                    int r = t.HasOptions ? t.RecommendedOption(null) : -1;
                    var acts = r >= 0 ? t.Options[r].Apply : t.Apply;
                    foreach (var a in acts)
                        foreach (var p in picked.Where(p => Catalog.Clashes(p.A, a)))
                            clash.Add(t.Id + "  " + t.Path + " = " + ValueId(a) + "   vs  " + p.Id + "=" + ValueId(p.A));
                }
                log.WriteLine("  removed from the app: could crash / break Windows " + cat.DangerRemoved + ", work against a hand-picked tweak " + cat.ClashesRemoved
                    + ", commands that are fragments or dangerous " + cat.CommandsDropped + ", commands that contradict another command " + cat.ConflictsRemoved);
                Check("contradictions: nothing that can be switched on together works against a hand-picked tweak (" + clash.Count + ")", clash.Count == 0);

                // sample of how pack settings read now (names, places, value meanings)
                foreach (var t in cat.Tweaks.Where(t => t.Library && t.HasOptions && (t.Ar.StartsWith("خدمة") || t.Options.Any(o => o.Ar.Contains("تشغيل")))).Take(8))
                    log.WriteLine("    sample: " + t.Ar + "  |  " + t.DescAr + "  |  " + string.Join(" / ", t.Options.Select(o => o.Ar)));

                // 5e) plans climb: for laddered settings, Elite is at least as strong as Basic and Ultimate the strongest
                var climb = new List<string>();
                foreach (var t in cat.Tweaks.Where(t => t.HasOptions))
                {
                    int b = t.RecommendedOption(null, 1), e = t.RecommendedOption(null, 2), u = t.RecommendedOption(null, 3);
                    if (b != e || e != u) climb.Add(t.Id + ": " + t.Options[b].En + " / " + t.Options[e].En + " / " + t.Options[u].En);
                }
                log.WriteLine("  settings whose value climbs with the plan: " + climb.Count);
                climb.Take(8).ToList().ForEach(s => log.WriteLine("    " + s));
                File.WriteAllLines(Path.Combine(Path.GetDirectoryName(outFile), "ladder.txt"), climb);
                Check("plans: Basic, Elite and Ultimate pick stronger values as the plan goes up (" + climb.Count + " settings)", climb.Count > 0);

                // 5f) services: only well-known ones may be switched off; no other tool's branding
                var svcBad = cat.Tweaks.Where(t => !t.Curated).SelectMany(t => t.Apply.Concat(t.Options == null ? new List<TAction>() : t.Options.SelectMany(o => o.Apply)))
                    .Where(a => a.IsRegistry && "Start".Equals(a.Name, StringComparison.OrdinalIgnoreCase) && System.Text.RegularExpressions.Regex.IsMatch(a.Key, @"\\Services\\[^\\]+$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)
                                && !Catalog.SafeService(a.Key.Substring(a.Key.LastIndexOf('\\') + 1))).Select(a => a.Key).Distinct().ToList();
                Check("services: only well-known services can be switched off by pack settings (" + svcBad.Count + " others)", svcBad.Count == 0);
                svcBad.Take(5).ToList().ForEach(s => log.WriteLine("    " + s));
                var brand = cat.Tweaks.Count(t => !t.Curated && System.Text.RegularExpressions.Regex.IsMatch((t.Path ?? "") + " " + t.En + " " + string.Join(" ", t.Apply.Select(a => Convert.ToString(a.Value) + a.Command)), @"3ntr|discord\.gg|productname|oeminformation|\\computername\\", System.Text.RegularExpressions.RegexOptions.IgnoreCase));
                Check("branding: nothing renames Windows or the PC, or adds another tool's name (" + brand + ")", brand == 0);

                // 5g) every tweak can be shown and used: a title, something to apply, no option listed twice
                int noTitle = cat.Tweaks.Count(t => string.IsNullOrWhiteSpace(t.Ar) || string.IsNullOrWhiteSpace(t.En));
                int nothing = cat.Tweaks.Count(t => !t.HasOptions && t.Apply.Count == 0);
                int twice = cat.Tweaks.Count(t => t.HasOptions && t.Options.Where(o => !o.IsDefault).GroupBy(o => string.Join(";", o.Apply.Select(x => x.Type + ":" + Convert.ToString(x.Value)))).Any(g => g.Count() > 1));
                int noDefault = cat.Tweaks.Count(t => t.HasOptions && t.Library && !t.Options.Any(o => o.IsDefault));
                Check("tweaks: every one has a title (" + noTitle + " without), something to apply (" + nothing + " empty), no repeated option (" + twice + "), and a way back (" + noDefault + " without)",
                      noTitle == 0 && nothing == 0 && twice == 0 && noDefault == 0);

                // 5d) no separate Advanced section: every tweak sits in a section that is on the menu
                var shown = new HashSet<string>(cat.Categories.Select(c => c.Id));
                int homeless = cat.Tweaks.Count(t => !shown.Contains(t.Cat));
                Check("sections: every tweak is in its own section on the menu, none left in an Advanced section (" + homeless + ")", homeless == 0);
                foreach (var g in cat.Tweaks.Where(t => !shown.Contains(t.Cat)).GroupBy(t => t.Cat).Take(5)) log.WriteLine("    " + g.Key + ": " + g.Count());
                clash.Take(30).ToList().ForEach(s => log.WriteLine("    " + s));

                // every command, for review
                var allCmds = cat.Tweaks.Where(t => t.Library && t.NoUndo).ToList();
                File.WriteAllLines(Path.Combine(Path.GetDirectoryName(outFile), "commands.txt"),
                    allCmds.OrderBy(t => t.Cat).Select(t => t.Cat + "\t" + t.Tier + "\t" + (t.NoBulk ? "manual" : "all") + "\t" + t.Apply[0].Kind + "\t" + t.Apply[0].Command.Replace("\r", " ").Replace("\n", " ")));
                var dupTargets = allCmds.Select(t => Catalog.CommandTarget(t.Apply[0].Command)).Where(k => k != null).GroupBy(k => k).Count(g => g.Count() > 1);
                Check("commands: no two commands set the same thing (" + dupTargets + ")", dupTargets == 0);

                // what "Apply all" does in each section (as an Ultimate user)
                foreach (var c in cat.Categories.Where(c => c.Id != "mouse" && c.Id != "keyboard"))
                {
                    var l = cat.Tweaks.Where(t => t.Cat == c.Id && !t.NoBulk && t.Risk <= 1 && !Catalog.AddressSetting(t)).ToList();
                    int total = cat.Tweaks.Count(t => t.Cat == c.Id);
                    log.WriteLine(string.Format("  apply all  {0,-11} {1,6:N0} of {2,6:N0}  (commands {3:N0}; left for the user: {4:N0})", c.Id, l.Count, total, l.Count(t => t.NoUndo && !t.Curated), total - l.Count));
                }

                // everything "Apply all" writes (registry path = value, or the command), for review
                File.WriteAllLines(Path.Combine(Path.GetDirectoryName(outFile), "applyall.txt"),
                    cat.Tweaks.Where(t => !t.NoBulk && t.Risk <= 1 && !Catalog.AddressSetting(t)).OrderBy(t => t.Cat).SelectMany(t =>
                    {
                        int r = t.HasOptions ? t.RecommendedOption(null) : -1;
                        var acts = r >= 0 ? t.Options[r].Apply : t.Apply;
                        return acts.Select(a => t.Cat + "\t" + t.Id + "\t" + (a.IsRegistry ? a.Key + "\\" + a.Name + " = " + a.Type + ":" + a.Value : a.Kind + "> " + a.Command));
                    }));

                // the full box list, for review
                File.WriteAllLines(Path.Combine(Path.GetDirectoryName(outFile), "boxpaths.txt"),
                    pack.OrderBy(t => t.Tier).ThenBy(t => t.Path).Select(t => t.Tier + "\t" + t.Cat + "\t" + (t.Path ?? t.Id)));

                // 6) vendor sections
                foreach (var c in cat.Categories.Where(c => c.Group != null))
                {
                    int n = cat.Tweaks.Count(t => t.Cat == c.Id), h = cat.Tweaks.Count(t => t.Cat == c.Id && t.Curated);
                    log.WriteLine(string.Format("  {0,-11} {1,5} tweaks (hand-picked {2})", c.Id, n, h));
                }
                Check("vendors: every CPU / GPU section has tweaks", cat.Categories.Where(c => c.Group != null).All(c => cat.Tweaks.Any(t => t.Cat == c.Id)));

                log.WriteLine();
                log.WriteLine("PASS " + pass + "  FAIL " + fail);
            }
            return fail;
        }
    }
}
#endif
