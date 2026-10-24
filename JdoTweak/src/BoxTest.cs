#if DEV
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace JdoTweak
{
    // Plan-box test, meant to run INSIDE a throw-away virtual machine (never on a real PC):
    //   --boxtest snapshot <file>       list of box tweaks that are already on (the PC's original state)
    //   --boxtest apply <1|2|3> <file>  switch the box on exactly like the Windows Boost page does
    //   --boxtest revert <file>         "Revert All" for every box tweak
    //   --boxtest compare <baseline> <file>  is every box tweak back to how the baseline found it?
    public static class BoxTest
    {
        static List<Tweak> Pack()
        {
            return PackPage.InPack(App.Catalog, "windows", App.Hardware);
        }

        // every section that has an "Apply all" button (processor / graphics only where this PC has them)
        static IEnumerable<string> AllSections()
        {
            return App.Catalog.Categories.Where(c => c.Id != "mouse" && c.Id != "keyboard" && TweakPage.HasVendor(c.Id)).Select(c => c.Id);
        }

        static bool IsOn(Tweak t)
        {
            try
            {
                if (!t.HasOptions) return Engine.IsApplied(t);
                int i = Engine.CurrentOption(t);
                return i >= 0 && !t.Options[i].IsDefault;
            }
            catch { return false; }
        }

        // Refuses to run anywhere but a QEMU virtual machine, so it can never tweak a real PC.
        static bool InsideVm()
        {
            try
            {
                using (var s = new System.Management.ManagementObjectSearcher("SELECT Manufacturer, Model FROM Win32_ComputerSystem"))
                    foreach (System.Management.ManagementObject o in s.Get())
                    {
                        string m = (Convert.ToString(o["Manufacturer"]) + " " + Convert.ToString(o["Model"])).ToUpperInvariant();
                        if (m.Contains("QEMU") || m.Contains("STANDARD PC (Q35")) return true;
                    }
            }
            catch { }
            return false;
        }

        public static int Run(string[] a)
        {
            if (!InsideVm()) { try { File.WriteAllText(a[a.Length - 1] + ".refused", "Not a QEMU virtual machine - refusing to apply anything."); } catch { } return 99; }
            App.Hardware = HardwareInfo.Read();
            App.Catalog = App.LoadCatalogForTests();
            License.Login(null, null, null, App.Hardware.Hwid());
            var pack = Pack();
            string mode = a[1];
            var sw = Stopwatch.StartNew();
            var lines = new List<string>();

            if (mode == "snapshot")
            {
                var on = pack.Where(IsOn).Select(t => t.Id).ToList();
                File.WriteAllLines(a[2], on);
                File.WriteAllLines(a[2] + ".txt", new[] { "box tweaks already on before the test: " + on.Count + " of " + pack.Count });
                return 0;
            }

            if (mode == "apply")
            {
                int k = int.Parse(a[2]);
                var list = pack.Where(t => t.Tier <= k).ToList();
                var hw = App.Hardware;
                int changed = 0, failed = 0;
                Engine.Log.Clear();
                Engine.BeginBatch();
                try
                {
                    foreach (var t in list)
                    {
                        try
                        {
                            if (t.HasOptions) { int i = t.RecommendedOption(hw, k); if (i >= 0 && !t.Options[i].IsDefault && Engine.CurrentOption(t) != i) { Engine.ApplyOption(t, i); changed++; } }
                            else if (!Engine.IsApplied(t)) { Engine.ApplyTweak(t); changed++; }
                        }
                        catch (Exception ex) { failed++; lines.Add("  error " + t.Id + ": " + ex.Message); }
                    }
                }
                finally { Engine.EndBatch(); }
                int on = list.Count(IsOn);
                lines.Insert(0, string.Format("APPLY box {0}: {1} tweaks, {2} changed, now on {3} ({4:0.0}%), exceptions {5}, write errors {6}, {7:0}s",
                    k, list.Count, changed, on, 100.0 * on / Math.Max(1, list.Count), failed, Engine.Log.Count, sw.Elapsed.TotalSeconds));
                foreach (var e in Engine.Log.Take(15)) lines.Add("  write error: " + e);
                var notOn = list.Where(t => !IsOn(t)).Take(10).ToList();
                foreach (var t in notOn) lines.Add("  not on after apply: " + t.Id + "  " + t.Path);
            }
            else if (mode == "applyall")
            {
                // "Apply all" in every section that has the button (processor / graphics only where this PC has them)
                Engine.Log.Clear();
                foreach (var c in App.Catalog.Categories.Where(c => c.Id != "mouse" && c.Id != "keyboard" && TweakPage.HasVendor(c.Id)))
                {
                    var todo = TweakPage.AllApplicable(c.Id);
                    // --boxtest applyall reg|cmd <file>: only the settings or only the commands, to find what breaks Windows
                    string only = a.Length > 3 ? a[2] : "all";
                    if (only == "reg") todo = todo.Where(t => !(t.NoUndo && !t.Curated)).ToList();
                    else if (only == "cmd") todo = todo.Where(t => t.NoUndo && !t.Curated).ToList();
                    var t0 = sw.Elapsed;
                    TweakPage.RunAll(todo);
                    lines.Add(string.Format("APPLY ALL {0}: {1} changes ({2} commands), {3:0}s", c.Id, todo.Count, todo.Count(t => t.NoUndo && !t.Curated), (sw.Elapsed - t0).TotalSeconds));
                }
                lines.Add("  write errors: " + Engine.Log.Count);
                foreach (var e in Engine.Log.Take(15)) lines.Add("  write error: " + e);

                // every setting checked one by one: is its value really there now?
                var all = AllSections().SelectMany(TweakPage.AllApplicable).Where(t => t.Apply.Concat(t.HasOptions ? t.Options.SelectMany(o => o.Apply) : new List<TAction>()).Any(x => x.IsRegistry)).ToList();
                var notOn = all.Where(t => !IsOn(t)).ToList();
                lines.Add(string.Format("CHECK every setting: {0} checked, {1} in place, {2} not in place", all.Count, all.Count - notOn.Count, notOn.Count));
                File.WriteAllLines(Path.Combine(Path.GetDirectoryName(a[a.Length - 1]), "notapplied.txt"), notOn.Select(t => t.Id + "\t" + t.Cat + "\t" + (t.Path ?? t.En)));
                foreach (var t in notOn.Take(12)) lines.Add("  not in place: " + t.Id + "  " + (t.Path ?? t.En));
            }
            else if (mode == "snapshotall")
            {
                // which "Apply all" settings are already on before the test (the PC's own state)
                var on = AllSections().SelectMany(TweakPage.AllApplicable).Where(IsOn).Select(t => t.Id).ToList();
                File.WriteAllLines(a[2], on);
                File.AppendAllLines(a[a.Length - 1], new[] { "snapshot: " + on.Count + " Apply-all settings already on" });
                return 0;
            }
            else if (mode == "compareall")
            {
                // after revert: every setting must be exactly as the snapshot found it
                var baseline = new HashSet<string>(File.ReadAllLines(a[2]));
                var now = new HashSet<string>(AllSections().SelectMany(TweakPage.AllApplicable).Where(IsOn).Select(t => t.Id));
                var stillOn = now.Where(id => !baseline.Contains(id)).ToList();
                var lost = baseline.Where(id => !now.Contains(id)).ToList();
                lines.Add(string.Format("COMPARE all settings with the original: left on by the test {0}, original lost {1}", stillOn.Count, lost.Count));
                foreach (var id in stillOn.Take(12)) lines.Add("  still on: " + id + "  " + (App.Catalog.Find(id) ?? new Tweak()).Path);
                foreach (var id in lost.Take(12)) lines.Add("  lost: " + id + "  " + (App.Catalog.Find(id) ?? new Tweak()).Path);
                File.WriteAllLines(Path.Combine(Path.GetDirectoryName(a[a.Length - 1]), "notreverted.txt"), stillOn.Concat(lost));
                File.AppendAllLines(a[a.Length - 1], lines);
                return stillOn.Count + lost.Count;
            }
            else if (mode == "revert")
            {
                var cat = App.Catalog;
                var ids = Engine.BackedUpIds().ToList();
                Engine.BeginBatch();
                try { foreach (var id in ids) try { Engine.RevertById(cat, id); } catch (Exception ex) { lines.Add("  revert error " + id + ": " + ex.Message); } }
                finally { Engine.EndBatch(); }
                lines.Insert(0, string.Format("REVERT: {0} backups restored, {1} left, {2:0}s", ids.Count, Engine.BackedUpIds().Count(), sw.Elapsed.TotalSeconds));
            }
            else if (mode == "compare")
            {
                var baseline = new HashSet<string>(File.ReadAllLines(a[2]));
                var now = new HashSet<string>(pack.Where(IsOn).Select(t => t.Id));
                var stillOn = now.Where(id => !baseline.Contains(id)).ToList();
                var lost = baseline.Where(id => !now.Contains(id)).ToList();
                lines.Add(string.Format("COMPARE with original: {0} box tweaks on now, {1} at the start; left on by the test: {2}; original values lost: {3}",
                    now.Count, baseline.Count, stillOn.Count, lost.Count));
                foreach (var id in stillOn.Take(10)) lines.Add("  still on: " + id + "  " + (App.Catalog.Find(id) ?? new Tweak()).Path);
                foreach (var id in lost.Take(10)) lines.Add("  lost: " + id + "  " + (App.Catalog.Find(id) ?? new Tweak()).Path);
                File.AppendAllLines(a[3], lines);
                return stillOn.Count + lost.Count;
            }
            File.AppendAllLines(a[a.Length - 1], lines);
            return 0;
        }
    }
}
#endif
