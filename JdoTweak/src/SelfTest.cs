#if DEV
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using Microsoft.Win32;

namespace JdoTweak
{
    // Exercises every action type against a scratch key under HKCU, checking that
    // apply writes the value and revert restores the exact original. Never touches real settings.
    public static class SelfTest
    {
        const string K = @"HKEY_CURRENT_USER\Software\JdoTweak\SelfTest";
        static int pass, fail;
        static TextWriter log;

        public static int Run(string outFile)
        {
            using (log = new StreamWriter(outFile))
            {
                Registry.CurrentUser.DeleteSubKeyTree(@"Software\JdoTweak\SelfTest", false);

                // --- every value type: original present -> apply -> revert restores original
                Seed("Dw", 7, RegistryValueKind.DWord);
                Seed("Sz", "orig", RegistryValueKind.String);
                Seed("Bin", new byte[] { 1, 2, 3 }, RegistryValueKind.Binary);
                Seed("Msz", new[] { "a", "b" }, RegistryValueKind.MultiString);
                Seed("Esz", "%TEMP%\\x", RegistryValueKind.ExpandString);
                Seed("Qw", 5L, RegistryValueKind.QWord);
                var t1 = T("t.types",
                    A("reg", "Dw", "dw", 4294967295L), A("reg", "Sz", "sz", "new"), A("reg", "Bin", "bin", "ff,00,aa"),
                    A("reg", "Msz", "msz", "x\0y\0z"), A("reg", "Esz", "esz", "%WINDIR%\\y"), A("reg", "Qw", "qw", -1L),
                    A("reg", "Missing", "dw", 1L), A("reg", "Dw2", "del", null));
                Seed("Dw2", 9, RegistryValueKind.DWord);
                Engine.ApplyTweak(t1);
                Check("apply dword 0xFFFFFFFF", (uint)(int)Get("Dw") == 4294967295u);
                Check("apply string", (string)Get("Sz") == "new");
                Check("apply binary", ((byte[])Get("Bin")).SequenceEqual(new byte[] { 0xff, 0, 0xaa }));
                Check("apply multi-string", ((string[])Get("Msz")).SequenceEqual(new[] { "x", "y", "z" }));
                Check("apply expand-string", (string)Get("Esz") == "%WINDIR%\\y");
                Check("apply qword -1", (long)Get("Qw") == -1L);
                Check("apply new value", (int)Get("Missing") == 1);
                Check("apply delete value", Get("Dw2") == null);
                Check("state reads as applied", Engine.IsApplied(t1));
                Engine.RevertTweak(t1);
                Check("revert dword", (int)Get("Dw") == 7);
                Check("revert string", (string)Get("Sz") == "orig");
                Check("revert binary", ((byte[])Get("Bin")).SequenceEqual(new byte[] { 1, 2, 3 }));
                Check("revert multi-string", ((string[])Get("Msz")).SequenceEqual(new[] { "a", "b" }));
                Check("revert expand-string", (string)Get("Esz") == "%TEMP%\\x");
                Check("revert qword", (long)Get("Qw") == 5L);
                Check("revert removes value that didn't exist", Get("Missing") == null);
                Check("revert restores deleted value", (int)Get("Dw2") == 9);
                Check("state reads as not applied", !Engine.IsApplied(t1));

                // --- apply twice keeps the FIRST original
                var t2 = T("t.twice", A("reg", "Dw", "dw", 1L));
                Engine.ApplyTweak(t2); Engine.ApplyTweak(t2);
                Engine.RevertTweak(t2);
                Check("double apply still reverts to original", (int)Get("Dw") == 7);

                // --- options: pick 2, then 3, then Original
                var opt = new Tweak { Id = "t.opt", Options = new List<TOption> {
                    new TOption { En = "a", Apply = new List<TAction> { A("reg", "Opt", "dw", 20L) } },
                    new TOption { En = "b", Apply = new List<TAction> { A("reg", "Opt", "dw", 50L) } },
                    new TOption { En = "orig", IsDefault = true } } };
                Seed("Opt", 100, RegistryValueKind.DWord);
                Engine.ApplyOption(opt, 0); Check("option 1 applied", (int)Get("Opt") == 20 && Engine.CurrentOption(opt) == 0);
                Engine.ApplyOption(opt, 1); Check("option 2 applied", (int)Get("Opt") == 50 && Engine.CurrentOption(opt) == 1);
                Engine.ApplyOption(opt, 2); Check("Original restores real value", (int)Get("Opt") == 100);

                // --- each: every subkey gets the value
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\JdoTweak\SelfTest\Each\{A}")) k.SetValue("V", 3);
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\JdoTweak\SelfTest\Each\{B}")) { }
                var te = new Tweak { Id = "t.each", Apply = new List<TAction> { new TAction { Kind = "each", Key = K + "\\Each", Name = "V", Type = "dw", Value = 1L } } };
                Engine.ApplyTweak(te);
                Check("each: subkey A", (int)Registry.GetValue(K + "\\Each\\{A}", "V", null) == 1);
                Check("each: subkey B", (int)Registry.GetValue(K + "\\Each\\{B}", "V", null) == 1);
                Engine.RevertTweak(te);
                Check("each revert: A restored", (int)Registry.GetValue(K + "\\Each\\{A}", "V", null) == 3);
                Check("each revert: B removed", Registry.GetValue(K + "\\Each\\{B}", "V", null) == null);

                // --- delete whole key, then restore it
                using (var k = Registry.CurrentUser.CreateSubKey(@"Software\JdoTweak\SelfTest\Gone\Sub")) k.SetValue("Deep", "kept");
                var tk = new Tweak { Id = "t.delkey", Apply = new List<TAction> { new TAction { Kind = "reg", Key = K + "\\Gone", Name = "", Type = "delkey" } } };
                Engine.ApplyTweak(tk);
                Check("delete key", Registry.CurrentUser.OpenSubKey(@"Software\JdoTweak\SelfTest\Gone") == null);
                Engine.RevertTweak(tk);
                Check("deleted key restored with sub-values", (string)Registry.GetValue(K + "\\Gone\\Sub", "Deep", null) == "kept");

                // --- CMD and PowerShell commands, and a script bundle whose reg lines get backed up
                var tc = new Tweak { Id = "t.cmd", Apply = new List<TAction> { new TAction { Kind = "cmd", Command = "reg add \"HKCU\\Software\\JdoTweak\\SelfTest\" /v Cmd /t REG_DWORD /d 11 /f" } } };
                Engine.ApplyTweak(tc);
                Check("cmd command ran", (int)Get("Cmd") == 11);
                var tp = new Tweak { Id = "t.ps", Apply = new List<TAction> { new TAction { Kind = "ps", Command = "New-ItemProperty -Path 'HKCU:\\Software\\JdoTweak\\SelfTest' -Name Ps -Value 22 -PropertyType DWord -Force" } } };
                Engine.ApplyTweak(tp);
                Check("powershell command ran", (int)Get("Ps") == 22);
                Seed("Scr", 1, RegistryValueKind.DWord);
                var ts = new Tweak { Id = "t.script", Apply = new List<TAction> { new TAction { Kind = "script", Ext = ".bat", Command = "@echo off\r\nreg add \"HKCU\\Software\\JdoTweak\\SelfTest\" /v Scr /t REG_DWORD /d 99 /f\r\n" } } };
                Engine.ApplyTweak(ts);
                Check("script ran", (int)Get("Scr") == 99);
                Engine.RevertTweak(ts);
                Check("script's registry change reverted", (int)Get("Scr") == 1);

                // --- catalog integrity and load speed
                var sw = Stopwatch.StartNew();
                var cat = App.Catalog;
                int bad = 0, opts = 0;
                foreach (var t in cat.Tweaks)
                {
                    if (string.IsNullOrEmpty(t.Id) || string.IsNullOrEmpty(t.Cat) || string.IsNullOrEmpty(t.En)) bad++;
                    if (t.HasOptions) { opts += t.Options.Count; if (t.Options.Any(o => o.Apply.Any(a => a.IsRegistry && string.IsNullOrEmpty(a.Key)))) bad++; }
                    else if (t.Apply.Count == 0) bad++;
                    if (!cat.Categories.Any(c => c.Id == t.Cat)) bad++;
                }
                Check("catalog: " + cat.Tweaks.Count + " tweaks, " + opts + " options, no broken entries", bad == 0);
                Check("catalog: ids unique", cat.Tweaks.Select(t => t.Id).Distinct().Count() == cat.Tweaks.Count);
                log.WriteLine("catalog scan took " + sw.ElapsedMilliseconds + " ms");

                // --- merged page, de-duplication, single-switch revert
                Check("no tweak left in the merged categories", !cat.Tweaks.Any(t => new[] { "cpu", "ram", "gpu", "power", "gaming", "latency" }.Contains(t.Cat)));
                Check("sidebar has no merged categories", !cat.Categories.Any(c => new[] { "cpu", "ram", "gpu", "power", "gaming", "latency" }.Contains(c.Id)));
                var pk = cat.Tweaks.Where(t => t.Curated && t.Cat == "windows" && t.Risk <= 1 && !t.NoPack).ToList();
                Check("Basic / Elite / Ultimate boxes all have tweaks (" + pk.Count(t => t.Tier == 1) + "/" + pk.Count(t => t.Tier == 2) + "/" + pk.Count(t => t.Tier == 3) + ")", pk.Any(t => t.Tier == 1) && pk.Any(t => t.Tier == 2) && pk.Any(t => t.Tier == 3));
                Check("print spooler stays out of the one-click boxes", !pk.Any(t => t.Id == "win.spooler"));
                Check("duplicates removed from library (" + cat.DuplicatesRemoved + ")", cat.DuplicatesRemoved > 0);
                var seen = new HashSet<string>(); int dupSetting = 0;
                foreach (var t in cat.Tweaks.Where(x => x.Library && x.Path != null && !x.Id.StartsWith("c.")))
                    if (!seen.Add(t.Path.ToLowerInvariant())) { dupSetting++; if (dupSetting <= 8) log.WriteLine("  dup: " + t.Id + " " + t.Path); }
                Check("no setting appears twice in the library", dupSetting == 0);
                var sub0 = cat.Find("mouse.accel#0");
                Check("single switch id resolves", sub0 != null && sub0.Apply.Count == 1);
                Seed("MouseSpeedX", "keep", RegistryValueKind.String);
                var sub = new Tweak { Id = "t.parent", Apply = new List<TAction> { A("reg", "MouseSpeedX", "sz", "changed"), A("reg", "Dw", "dw", 99L) }, Revert = new List<TAction>() };
                Seed("Dw", 7, RegistryValueKind.DWord);
                var s1 = Tweak.Sub(sub, 0);
                Engine.ApplyTweak(s1);
                Check("single switch applied", (string)Get("MouseSpeedX") == "changed" && (int)Get("Dw") == 7);
                bool backed = Engine.BackedUpIds().Contains(s1.Id);
                Engine.RevertTweak(s1);
                Check("single switch is backed up and reverts", backed && (string)Get("MouseSpeedX") == "keep");

                // state reads on real tweaks must not throw (read-only)
                sw.Restart();
                int reads = 0;
                foreach (var t in cat.Tweaks.Take(3000)) { if (t.HasOptions) Engine.CurrentOption(t); else Engine.IsApplied(t); reads++; }
                log.WriteLine(reads + " state reads in " + sw.ElapsedMilliseconds + " ms");

                Registry.CurrentUser.DeleteSubKeyTree(@"Software\JdoTweak\SelfTest", false);
                foreach (var id in new[] { "t.types", "t.twice", "t.opt", "t.each", "t.delkey", "t.cmd", "t.ps", "t.script" })
                {
                    var dummy = new Tweak { Id = id, Apply = new List<TAction>(), Revert = new List<TAction>() };
                    // drop leftover backup entries without touching the registry again
                    Engine.ForgetBackup(id);
                }
                log.WriteLine();
                log.WriteLine("PASS " + pass + "  FAIL " + fail);
            }
            return fail;
        }

        static void Seed(string name, object v, RegistryValueKind kind)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(@"Software\JdoTweak\SelfTest")) k.SetValue(name, v, kind);
        }
        static object Get(string name) { using (var k = Registry.CurrentUser.OpenSubKey(@"Software\JdoTweak\SelfTest")) return k == null ? null : k.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames); }
        static TAction A(string kind, string name, string type, object v) { return new TAction { Kind = kind, Key = K, Name = name, Type = type, Value = v }; }
        static Tweak T(string id, params TAction[] a) { return new Tweak { Id = id, Apply = a.ToList(), Revert = new List<TAction>() }; }
        static void Check(string what, bool ok)
        {
            if (ok) pass++; else fail++;
            log.WriteLine((ok ? "PASS  " : "FAIL  ") + what);
        }
    }
}
#endif
