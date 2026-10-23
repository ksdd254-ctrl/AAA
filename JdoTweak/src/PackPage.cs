using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;

namespace JdoTweak
{
    // "Windows Boost": every performance tweak (CPU, RAM, GPU, power, games, delay, debloat)
    // condensed into four boxes. Boxes 1-3 are levels: switching one on applies it and every
    // level below it. Box 4 is the Lite Windows download. A box is locked unless the plan allows it.
    public class PackPage : Grid
    {
        readonly MainWindow win;
        readonly List<Tweak> pack;
        readonly ToggleButton[] sw = new ToggleButton[4];
        readonly TextBlock[] st = new TextBlock[4];
        bool busy;

        static Session User { get { return License.Current; } }
        static int UserTier { get { return User == null ? 0 : User.Tier; } }

        public PackPage(MainWindow w, Category c)
        {
            win = w;
            var hw = App.Hardware;
            pack = InPack(App.Catalog, c.Id, hw);

            var page = new StackPanel();
            var head = new DockPanel();
            var rev = UI.IconBtn("", L.T("revertAll"), "Ghost", async (o, e) => await RevertEverything((Button)o));
            rev.VerticalAlignment = VerticalAlignment.Top;
            DockPanel.SetDock(rev, Dock.Right);
            head.Children.Add(rev);
            head.Children.Add(MainWindow.Header(c.Icon, c.Title, L.T("packSub")));
            page.Children.Add(head);

            var grid = new UniformGrid { Columns = 2 };
            for (int k = 1; k <= 3; k++) grid.Children.Add(LevelBox(k));
            grid.Children.Add(LiteBox());
            page.Children.Add(grid);

            Children.Add(MainWindow.Page(page));
            Refresh();
        }

        // What a box applies: the hand-picked tweaks, plus every library setting that is safe to
        // switch on in bulk - registry only (so it can be undone exactly), no risk flag, and used
        // by at least two packs. Commands (no automatic undo) and risky items stay out.
        public static List<Tweak> InPack(Catalog cat, string catId, HardwareInfo hw)
        {
            return cat.Tweaks.Where(t => t.Cat == catId && !t.NoPack && (
                    (t.Curated && t.Risk <= 1 && (t.MinRam == 0 || hw == null || hw.RamGb >= t.MinRam) && (t.Vendor == null || hw == null || t.Vendor == hw.GpuVendor))
                    || (t.Library && t.Risk == 0 && !t.NoUndo && t.Packs >= 2 && t.Id.StartsWith("s."))))
                .ToList();
        }

        IEnumerable<Tweak> Level(int k) { return pack.Where(t => t.Tier <= k); }

        // ------------------------------------------------------------------ boxes
        FrameworkElement LevelBox(int k)
        {
            bool locked = k > UserTier;
            var own = pack.Where(t => t.Tier == k && t.Curated).ToList();
            int total = Level(k).Count();

            var sp = new StackPanel();
            var top = new WrapPanel();
            var name = UI.Text(L.T("tier" + k), 20, "Text", true);
            top.Children.Add(name);
            top.Children.Add(UI.TierBadge(k));
            if (locked) top.Children.Add(UI.Badge(L.T("locked"), "#FFD36B", "#2AF5B841"));
            sp.Children.Add(top);

            var d = UI.Text(L.T("pack" + k + "D"), 13, "Muted"); d.Margin = new Thickness(0, 6, 0, 0); d.LineHeight = 20;
            sp.Children.Add(d);
            sp.Children.Add(Bullets("pack" + k + "B"));
            var who = UI.Text(L.T("pack" + k + "W"), 12, "Accent"); who.Margin = new Thickness(0, 10, 0, 0);
            sp.Children.Add(who);

            var foot = new DockPanel { Margin = new Thickness(0, 16, 0, 0) };
            var sw1 = new ToggleButton { Style = UI.S("Switch"), IsEnabled = !locked };
            sw[k - 1] = sw1;
            DockPanel.SetDock(sw1, Dock.Right);
            foot.Children.Add(sw1);
            var s = UI.Text(total + " " + L.T("changesTotal"), 12, "Muted"); s.VerticalAlignment = VerticalAlignment.Center;
            st[k - 1] = s;
            foot.Children.Add(s);
            sp.Children.Add(foot);

            if (locked)
            {
                var up = UI.IconBtn("", L.T("upgrade"), "Ghost", (o, e) => UI.Ask(Window.GetWindow((DependencyObject)o), L.T("upgrade"), L.T("upgradeHow"), false));
                up.HorizontalAlignment = HorizontalAlignment.Left; up.Margin = new Thickness(0, 12, 0, 0);
                sp.Children.Add(up);
            }

            sw1.Click += async (o, e) => await Toggle(k, sw1.IsChecked == true);

            var box = UI.Card(sp, 22);
            box.Margin = new Thickness(0, 0, 14, 14);
            if (locked) box.Opacity = 0.6;
            Fx.Enter(box, (k - 1) * 70, 14);
            return box;
        }

        // Short "what you get" list; items are separated by | in the translation.
        static FrameworkElement Bullets(string key)
        {
            var sp = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
            foreach (var line in L.T(key).Split('|'))
            {
                var row = new DockPanel { Margin = new Thickness(0, 3, 0, 0) };
                var ck = UI.Text("✓", 12.5, "Good", true); ck.Margin = new Thickness(0, 0, 8, 0);
                row.Children.Add(ck);
                row.Children.Add(UI.Text(line.Trim(), 12.5, "Text"));
                sp.Children.Add(row);
            }
            return sp;
        }

        FrameworkElement LiteBox()
        {
            bool has = User != null && User.WithLiteWindows;
            var sp = new StackPanel();
            var top = new WrapPanel();
            top.Children.Add(UI.Text(L.T("tier3") + " + " + L.T("liteWin"), 20, "Text", true));
            if (!has) top.Children.Add(UI.Badge(L.T("locked"), "#FFD36B", "#2AF5B841"));
            sp.Children.Add(top);
            var d = UI.Text(L.T("pack4D"), 13, "Muted"); d.Margin = new Thickness(0, 6, 0, 0); d.LineHeight = 20;
            sp.Children.Add(d);
            sp.Children.Add(Bullets("pack4B"));
            var who = UI.Text(L.T("pack4W"), 12, "Accent"); who.Margin = new Thickness(0, 10, 0, 0);
            sp.Children.Add(who);
            var b = has ? UI.IconBtn("", L.T("downloadLite"), "Primary", (o, e) =>
                {
                    string url = User.LiteUrl;
                    if (string.IsNullOrEmpty(url)) { UI.Ask(win, L.T("liteWin"), L.T("liteSoon"), false); return; }
                    try { System.Diagnostics.Process.Start(url); } catch { }
                })
                : UI.IconBtn("", L.T("upgrade"), "Ghost", (o, e) => UI.Ask(Window.GetWindow((DependencyObject)o), L.T("upgrade"), L.T("upgradeHow"), false));
            b.HorizontalAlignment = HorizontalAlignment.Left; b.Margin = new Thickness(0, 18, 0, 0);
            sp.Children.Add(b);
            var box = UI.Card(sp, 22);
            box.Margin = new Thickness(0, 0, 14, 14);
            if (!has) box.Opacity = 0.6;
            Fx.Enter(box, 210, 14);
            return box;
        }

        // ------------------------------------------------------------------ state
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

        async void Refresh()
        {
            var counts = await Task.Run(() =>
            {
                var r = new int[3, 2];                       // [level, applied/total]
                var state = pack.ToDictionary(t => t, IsOn);
                for (int k = 1; k <= 3; k++) { var lv = Level(k).ToList(); r[k - 1, 0] = lv.Count(t => state[t]); r[k - 1, 1] = lv.Count; }
                return r;
            });
            for (int k = 0; k < 3; k++)
            {
                int a = counts[k, 0], n = counts[k, 1];
                // A few values can't be written on every PC (protected keys, missing drivers),
                // so a box counts as on once almost everything in it is applied.
                bool on = n > 0 && a >= n * 0.97;
                sw[k].IsChecked = on;
                st[k].Text = (on ? "✓ " + L.T("boxOn") : a > 0 ? L.T("boxPartial") : L.T("boxOff")) + "  ·  " + n.ToString("N0") + " " + L.T("changesTotal");
                st[k].Foreground = on ? UI.B("Good") : a > 0 ? UI.B("Warn") : UI.B("Muted");
            }
        }

        async Task Toggle(int k, bool want)
        {
            if (busy) { sw[k - 1].IsChecked = !want; return; }
            var hw = App.Hardware;
            if (want)
            {
                win.EnsureRestorePoint();
                if (Level(k).Any(t => t.Risk == 1) && !UI.Ask(win, L.T("riskTitle"), L.T("tier" + k) + "\n\n" + L.T("packRisk"), true, true)) { sw[k - 1].IsChecked = false; return; }
            }
            busy = true;
            foreach (var s in sw) s.IsEnabled = false;
            st[k - 1].Text = L.T("working"); st[k - 1].Foreground = UI.B("Accent");
            bool reboot = false;
            await Task.Run(() =>
            {
                var list = want ? Level(k).ToList() : pack.Where(t => t.Tier >= k).ToList();
                Engine.BeginBatch();
                try
                {
                foreach (var t in list)
                {
                    try
                    {
                        if (want)
                        {
                            if (t.HasOptions) { int i = t.RecommendedOption(hw); if (i >= 0 && !t.Options[i].IsDefault && Engine.CurrentOption(t) != i) Engine.ApplyOption(t, i); }
                            else if (!Engine.IsApplied(t)) Engine.ApplyTweak(t);
                        }
                        else if (IsOn(t))
                        {
                            if (t.HasOptions) Engine.ApplyOption(t, t.Options.FindIndex(o => o.IsDefault));
                            else Engine.RevertTweak(t);
                        }
                        reboot |= t.Reboot;
                    }
                    catch { }
                }
                }
                finally { Engine.EndBatch(); }
            });
            busy = false;
            for (int i = 0; i < 3; i++) sw[i].IsEnabled = i + 1 <= UserTier;
            if (reboot) win.NeedReboot();
            Refresh();
        }

        async Task RevertEverything(Button b)
        {
            var cat = App.Catalog;
            var todo = Engine.BackedUpIds().Select(id => cat.Find(id)).Where(t => t != null && t.Cat == "windows").ToList();
            b.IsEnabled = false;
            await Task.Run(() =>
            {
                Engine.BeginBatch();
                try { foreach (var t in todo) try { Engine.RevertById(cat, t.Id); } catch { } }
                finally { Engine.EndBatch(); }
            });
            b.IsEnabled = true;
            if (todo.Any(t => t.Reboot)) win.NeedReboot();
            Refresh();
        }
    }
}
