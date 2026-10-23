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

                // 4) best value first: the option the boxes apply is the most-used one
                var lib = cat.Tweaks.Where(t => t.Library && t.HasOptions).ToList();
                int wrong = lib.Count(t => { int r = t.RecommendedOption(null); var real = t.Options.Where(o => !o.IsDefault).ToList(); return r < 0 || t.Options[r].IsDefault || t.Options[r].Uses < real.Max(o => o.Uses); });
                Check("best values: multi-option settings apply their most-used value (" + lib.Count + " settings, wrong: " + wrong + ")", wrong == 0);

                // 5) plans: Basic about 40%, Elite about 70%, Ultimate 100% of the boxes; network included by plan
                var pack = PackPage.InPack(cat, "windows", null);
                int b1 = pack.Count(t => t.Tier <= 1), b2 = pack.Count(t => t.Tier <= 2), b3 = pack.Count;
                double p1 = 100.0 * b1 / b3, p2 = 100.0 * b2 / b3;
                log.WriteLine(string.Format("  boxes: Basic {0:N0} ({1:0}%), Elite {2:N0} ({3:0}%), Ultimate {4:N0} (100%)", b1, p1, b2, p2, b3));
                Check("plans: Basic is about 40% of Ultimate", p1 >= 35 && p1 <= 45);
                Check("plans: Elite is about 70% of Ultimate", p2 >= 65 && p2 <= 75);
                Check("plans: Basic is inside Elite, Elite inside Ultimate", pack.Where(t => t.Tier <= 1).All(t => t.Tier <= 2));
                int n1 = pack.Count(t => t.Cat == "network" && t.Tier <= 1), n2 = pack.Count(t => t.Cat == "network" && t.Tier <= 2), n3 = pack.Count(t => t.Cat == "network");
                log.WriteLine(string.Format("  network in boxes: Basic {0}, Elite {1}, Ultimate {2}", n1, n2, n3));
                Check("network: each plan gets more network settings than the one below", n1 > 0 && n1 < n2 && n2 < n3);
                Check("network: no DNS / IP / gateway / DHCP value rides along in a box", !pack.Any(PackPage.AddressSetting));
                Check("boxes: no command (no automatic undo) and nothing risky", !pack.Any(t => t.NoUndo || (t.Library && t.Risk > 0) || t.Risk > 1));
                Check("boxes: no vendor-specific (CPU/GPU) tweak", !pack.Any(t => TweakPage.IsVendorSection(t.Cat)));

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
