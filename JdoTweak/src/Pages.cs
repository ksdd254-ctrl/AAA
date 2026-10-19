using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace JdoTweak
{
    public partial class MainWindow
    {
        // ------------------------------------------------------------------ repair
        TextBox console;
        bool running;

        FrameworkElement RepairPage()
        {
            var sp = new StackPanel();
            sp.Children.Add(Header("", L.T("repair"), L.T("repairSub")));

            // automatic scan
            var scanBox = new StackPanel();
            var sh = new DockPanel();
            var auto = UI.IconBtn("", L.T("autofixDl"), "Ghost", (o, e) => SaveAutoFix());
            auto.ToolTip = L.T("autofixDlD");
            DockPanel.SetDock(auto, Dock.Right); sh.Children.Add(auto);
            var scanBtn = UI.IconBtn("", L.T("scan"), "Primary", null);
            scanBtn.Margin = new Thickness(0, 0, 10, 0);
            DockPanel.SetDock(scanBtn, Dock.Right); sh.Children.Add(scanBtn);
            var st = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            st.Children.Add(UI.Text(L.T("scan"), 16, "Text", true));
            st.Children.Add(UI.Text(L.T("scanD"), 12.5, "Muted"));
            sh.Children.Add(st);
            scanBox.Children.Add(sh);
            var results = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
            scanBox.Children.Add(results);
            scanBtn.Click += async (o, e) =>
            {
                scanBtn.IsEnabled = false; results.Children.Clear();
                results.Children.Add(UI.Text(L.T("scanning"), 13, "Accent"));
                var issues = await Task.Run(() => Repair.Scan(cat));
                results.Children.Clear();
                if (issues.Count == 0) results.Children.Add(Row("", "Good", L.T("noIssues"), null));
                foreach (var i in issues) results.Children.Add(IssueRow(i));
                scanBtn.IsEnabled = true;
            };
            sp.Children.Add(UI.Card(scanBox));
            sp.Children.Add(UI.Gap(22));

            // console (shared by every fix)
            console = new TextBox
            {
                IsReadOnly = true, FontFamily = new FontFamily("Consolas"), FontSize = 12, Height = 190, TextWrapping = TextWrapping.Wrap,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, FlowDirection = FlowDirection.LeftToRight, Foreground = UI.B("Muted")
            };

            foreach (var g in Repair.Groups)
            {
                var fixes = Repair.Fixes.Where(f => f.Group == g.Id).ToList();
                var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 10) };
                head.Children.Add(UI.Icon(g.Icon, 15));
                var ht = UI.Text(g.Title, 15.5, "Text", true); ht.Margin = new Thickness(10, 0, 0, 0); head.Children.Add(ht);
                sp.Children.Add(head);
                var grid = new UniformGrid { Columns = 2 };
                foreach (var f in fixes) grid.Children.Add(FixCard(f));
                sp.Children.Add(grid);
            }

            sp.Children.Add(UI.Gap(10));
            sp.Children.Add(SectionTitle(L.T("output")));
            sp.Children.Add(console);
            return Page(sp);
        }

        FrameworkElement Row(string icon, string brush, string text, UIElement action)
        {
            var d = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
            if (action != null) { DockPanel.SetDock(action, Dock.Right); d.Children.Add(action); }
            var i = UI.Icon(icon, 15, brush); i.Margin = new Thickness(0, 0, 10, 0); d.Children.Add(i);
            var t = UI.Text(text, 13.5); t.VerticalAlignment = VerticalAlignment.Center; d.Children.Add(t);
            return d;
        }

        FrameworkElement IssueRow(Issue i)
        {
            Button b = null;
            if (i.FixId != null)
            {
                b = UI.Btn(L.T("fix"), i.Level == 0 ? "Ghost" : "Primary", null);
                b.Padding = new Thickness(14, 5, 14, 5);
                b.Click += async (o, e) =>
                {
                    b.IsEnabled = false;
                    if (i.FixId.StartsWith("tweak:"))
                    {
                        var t = cat.Tweaks.FirstOrDefault(x => x.Id == i.FixId.Substring(6));
                        if (t != null) await Task.Run(() => { if (t.HasOptions) Engine.ApplyOption(t, t.RecommendedOption(hw)); else Engine.ApplyTweak(t); });
                        Log("✓ " + (t != null ? t.Title : i.FixId));
                    }
                    else await RunFix(Repair.Get(i.FixId));
                    b.Content = "✓";
                };
            }
            string icon = i.Level == 2 ? "" : i.Level == 1 ? "" : "";
            string brush = i.Level == 2 ? "Bad" : i.Level == 1 ? "Warn" : "Muted";
            return Row(icon, brush, i.Title, b);
        }

        Border FixCard(Fix f)
        {
            var g = new DockPanel();
            var run = UI.Btn(L.T("run"), "Ghost", null);
            run.Padding = new Thickness(14, 6, 14, 6); run.VerticalAlignment = VerticalAlignment.Center; run.Margin = new Thickness(12, 0, 0, 0);
            run.Click += async (o, e) => { run.IsEnabled = false; await RunFix(f); run.IsEnabled = true; };
            DockPanel.SetDock(run, Dock.Right); g.Children.Add(run);
            var t = new StackPanel();
            t.Children.Add(UI.Text(f.Title, 13.5, "Text", true));
            var d = UI.Text(f.Desc, 12, "Muted"); d.Margin = new Thickness(0, 3, 0, 0); t.Children.Add(d);
            if (f.Slow) { var s = UI.Text(L.T("slow"), 11, "Warn"); s.Margin = new Thickness(0, 4, 0, 0); t.Children.Add(s); }
            g.Children.Add(t);
            var c = UI.Card(g, 14); c.Margin = new Thickness(0, 0, 10, 10);
            return c;
        }

        void Log(string line)
        {
            Dispatcher.BeginInvoke(new Action(() =>
            {
                if (console == null) return;
                console.AppendText(line + Environment.NewLine);
                console.ScrollToEnd();
            }));
        }

        async Task RunFix(Fix f)
        {
            if (f == null) return;
            if (running) { Log("… " + L.T("busy")); return; }
            running = true;
            Log("");
            Log("▶ " + f.Title);
            if (f.Script == "@revert")
            {
                var ids = new HashSet<string>(Engine.BackedUpIds());
                var list = cat.Tweaks.Where(t => ids.Contains(t.Id)).ToList();
                await Task.Run(() => { foreach (var t in list) { try { Engine.RevertTweak(t); Log("  ↺ " + t.En); } catch (Exception ex) { Log("  ✗ " + t.En + ": " + ex.Message); } } });
                Log("✓ " + list.Count + " " + L.T("reverted"));
                NeedReboot();
            }
            else
            {
                int code = await Task.Run(() => Engine.StreamPS(f.Script, line => Log("  " + line)));
                Log(code == 0 ? "✓ " + L.T("done") : "✗ " + L.T("failed") + " (" + code + ")");
            }
            running = false;
        }

        void SaveAutoFix()
        {
            try
            {
                string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "JDO_AutoFix.cmd");
                using (var s = App.Res("JDO_AutoFix.cmd"))
                using (var f = File.Create(path)) s.CopyTo(f);
                UI.Ask(this, L.T("autofixDl"), L.T("autofixSaved") + "\n" + path, false);
            }
            catch (Exception ex) { UI.Ask(this, L.T("failed"), ex.Message, false, true); }
        }

        // ------------------------------------------------------------------ polling rate tester (raw input)
        [StructLayout(LayoutKind.Sequential)]
        struct RAWINPUTDEVICE { public ushort UsagePage, Usage; public uint Flags; public IntPtr Target; }
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, uint count, uint size);

        int rawCount, pollMax;
        readonly List<int> pollSamples = new List<int>();
        Action<int> onPoll;
        DispatcherTimer pollTimer;

        void PollingInit()
        {
            var src = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
            src.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
            {
                if (msg == 0x00FF) rawCount++;   // WM_INPUT
                return IntPtr.Zero;
            });
            var dev = new[] { new RAWINPUTDEVICE { UsagePage = 1, Usage = 2, Flags = 0x100, Target = src.Handle } };  // mouse, RIDEV_INPUTSINK
            RegisterRawInputDevices(dev, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
            pollTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            pollTimer.Tick += (o, e) =>
            {
                int hz = rawCount * 4; rawCount = 0;
                if (onPoll != null) onPoll(hz);
            };
            pollTimer.Start();
        }

        static string PollLabel(int hz)
        {
            if (hz >= 6000) return "8000 Hz · 0.125 ms";
            if (hz >= 3000) return "4000 Hz · 0.25 ms";
            if (hz >= 1500) return "2000 Hz · 0.5 ms";
            if (hz >= 750) return "1000 Hz · 1 ms";
            if (hz >= 375) return "500 Hz · 2 ms";
            if (hz >= 190) return "250 Hz · 4 ms";
            if (hz >= 60) return "125 Hz · 8 ms";
            return "—";
        }

        FrameworkElement PollingPage()
        {
            var sp = new StackPanel();
            sp.Children.Add(Header("", L.T("pollTitle"), L.T("pollSub")));
            var big = UI.Text("0", 64, "Text", true); big.HorizontalAlignment = HorizontalAlignment.Center;
            var unit = UI.Text("Hz", 16, "Muted"); unit.HorizontalAlignment = HorizontalAlignment.Center;
            var label = UI.Text(L.T("pollMove"), 15, "Accent", true); label.HorizontalAlignment = HorizontalAlignment.Center; label.Margin = new Thickness(0, 12, 0, 0);
            var stats = UI.Text("", 13, "Muted"); stats.HorizontalAlignment = HorizontalAlignment.Center; stats.Margin = new Thickness(0, 8, 0, 0);
            var area = new StackPanel { Margin = new Thickness(0, 30, 0, 30) };
            area.Children.Add(big); area.Children.Add(unit); area.Children.Add(label); area.Children.Add(stats);
            var reset = UI.Btn(L.T("pollReset"), "Ghost", (o, e) => { pollMax = 0; pollSamples.Clear(); stats.Text = ""; });
            reset.HorizontalAlignment = HorizontalAlignment.Center;
            area.Children.Add(UI.Gap(14)); area.Children.Add(reset);
            var card = UI.Card(area, 30);
            card.Background = new RadialGradientBrush(Color.FromArgb(0x40, Themes.AccentColor.R, Themes.AccentColor.G, Themes.AccentColor.B), ((SolidColorBrush)UI.B("Card")).Color);
            sp.Children.Add(card);
            sp.Children.Add(UI.Gap(18));

            var tips = new StackPanel();
            tips.Children.Add(UI.Text(L.T("pollTipsT"), 15, "Text", true));
            foreach (var k in new[] { "pollTip1", "pollTip2", "pollTip3", "pollTip4" })
            {
                var t = UI.Text("•  " + L.T(k), 13, "Muted"); t.Margin = new Thickness(0, 8, 0, 0); t.LineHeight = 20;
                tips.Children.Add(t);
            }
            sp.Children.Add(UI.Card(tips));

            pollMax = 0; pollSamples.Clear();
            onPoll = hz =>
            {
                if (hz < 40) { big.Foreground = UI.B("Muted"); return; }
                pollSamples.Add(hz); if (pollSamples.Count > 40) pollSamples.RemoveAt(0);
                pollMax = Math.Max(pollMax, hz);
                big.Text = hz.ToString("N0"); big.Foreground = UI.B("Text");
                label.Text = PollLabel(pollMax);
                stats.Text = L.T("pollAvg") + " " + (int)pollSamples.Average() + " Hz  ·  " + L.T("pollMax") + " " + pollMax + " Hz";
            };
            var page = Page(sp);
            page.Unloaded += (o, e) => onPoll = null;
            return page;
        }

        // ------------------------------------------------------------------ account
        FrameworkElement AccountPage()
        {
            var sp = new StackPanel();
            sp.Children.Add(Header("", L.T("account"), null));
            var rows = new StackPanel();
            Action<string, string, bool> row = (k, v, mono) =>
            {
                var d = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
                var key = UI.Text(k, 13, "Muted"); key.Width = 160; d.Children.Add(key);
                var val = UI.Text(v, 14, "Text", true); if (mono) { val.FontFamily = new FontFamily("Consolas"); val.FlowDirection = FlowDirection.LeftToRight; }
                d.Children.Add(val);
                rows.Children.Add(d);
            };
            var u = License.Current;
            row(L.T("email"), u != null ? u.Email : "—", true);
            row(L.T("plan"), u != null ? u.PlanName + (u.WithLiteWindows ? " + " + L.T("liteWin") : "") : "—", false);
            row(L.T("expires"), u == null ? "—" : u.Expires.HasValue ? u.Expires.Value.ToLocalTime().ToString("yyyy-MM-dd") : L.T("lifetime"), false);
            row(L.T("licenseKey"), u != null && !string.IsNullOrEmpty(u.Key) ? Mask(u.Key) : "—", true);
            row(L.T("hwid"), hw.Hwid(), true);
            sp.Children.Add(UI.Card(rows, 22));
            sp.Children.Add(UI.Gap(16));

            var btns = new StackPanel { Orientation = Orientation.Horizontal };
            btns.Children.Add(UI.IconBtn("", L.T("copyHwid"), "Ghost", (o, e) => { try { Clipboard.SetText(hw.Hwid()); } catch { } }));
            var up = UI.IconBtn("", L.T("upgrade"), "Primary", (o, e) => { try { System.Diagnostics.Process.Start(App.Website + "/#plans"); } catch { } });
            up.Margin = new Thickness(10, 0, 0, 0); btns.Children.Add(up);
            var lo = UI.IconBtn("", L.T("logout"), "Ghost", (o, e) => { License.Logout(); App.SwitchTo(new LoginWindow(), this); });
            lo.Margin = new Thickness(10, 0, 0, 0); btns.Children.Add(lo);
            sp.Children.Add(btns);
            return Page(sp);
        }

        static string Mask(string key) { return key.Length <= 8 ? key : key.Substring(0, 5) + new string('•', Math.Max(0, key.Length - 9)) + key.Substring(key.Length - 4); }

        // ------------------------------------------------------------------ settings
        FrameworkElement SettingsPage()
        {
            var sp = new StackPanel();
            sp.Children.Add(Header("", L.T("settings"), null));

            var lang = new DockPanel();
            var lb = new StackPanel { Orientation = Orientation.Horizontal };
            var ar = UI.Btn("عربي", L.Ar ? "Primary" : "Ghost", (o, e) => L.Set(true));
            var en = UI.Btn("English", L.Ar ? "Ghost" : "Primary", (o, e) => L.Set(false)); en.Margin = new Thickness(8, 0, 0, 0);
            lb.Children.Add(ar); lb.Children.Add(en);
            DockPanel.SetDock(lb, Dock.Right); lang.Children.Add(lb);
            var lt = new StackPanel();
            lt.Children.Add(UI.Text(L.T("language"), 15, "Text", true));
            lt.Children.Add(UI.Text(L.T("langD"), 12.5, "Muted"));
            lang.Children.Add(lt);
            sp.Children.Add(UI.Card(lang));
            sp.Children.Add(UI.Gap(12));

            var th = new StackPanel();
            th.Children.Add(UI.Text(L.T("theme"), 15, "Text", true));
            th.Children.Add(UI.Text(L.T("themeD"), 12.5, "Muted"));
            var sw = new WrapPanel { Margin = new Thickness(0, 14, 0, 0) };
            foreach (var p in Themes.All)
            {
                var pal = p;
                var chip = new StackPanel { Orientation = Orientation.Horizontal };
                var dot = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Margin = new Thickness(0, 0, 8, 0),
                    Background = new LinearGradientBrush((Color)ColorConverter.ConvertFromString(p.Accent), (Color)ColorConverter.ConvertFromString(p.Accent2), 30) };
                chip.Children.Add(dot);
                chip.Children.Add(new TextBlock { Text = p.Name, VerticalAlignment = VerticalAlignment.Center });
                var b = new Button { Content = chip, Style = UI.S(Themes.Current == p ? "Primary" : "Ghost"), Margin = new Thickness(0, 0, 10, 10), Padding = new Thickness(12, 8, 16, 8) };
                b.Click += (o, e) => { Themes.Apply(pal, true); Build(); };
                sw.Children.Add(b);
            }
            th.Children.Add(sw);
            sp.Children.Add(UI.Card(th));
            sp.Children.Add(UI.Gap(12));

            var upd = new DockPanel();
            var ub = UI.Btn(L.T("checkUpdates"), "Ghost", null);
            DockPanel.SetDock(ub, Dock.Right); upd.Children.Add(ub);
            var ut = new StackPanel();
            ut.Children.Add(UI.Text(L.T("updates"), 15, "Text", true));
            var uv = UI.Text(L.T("version") + " " + App.Version + "  ·  " + L.T("catalog") + " " + cat.Version + (cat.LibraryVersion != null ? " / " + cat.LibraryVersion : ""), 12.5, "Muted");
            ut.Children.Add(uv);
            upd.Children.Add(ut);
            ub.Click += async (o, e) =>
            {
                ub.IsEnabled = false;
                var r = await Task.Run(() => Updater.Check());
                ub.IsEnabled = true;
                if (r == null) UI.Ask(this, L.T("updates"), L.T("upToDate"), false);
                else if (UI.Ask(this, L.T("updates"), L.T("updateAvail") + " " + r, true)) await Task.Run(() => Updater.Install());
            };
            sp.Children.Add(UI.Card(upd));
            sp.Children.Add(UI.Gap(12));

            var bk = new DockPanel();
            var openBk = UI.Btn(L.T("openBackup"), "Ghost", (o, e) => { try { System.Diagnostics.Process.Start(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "JdoTweak")); } catch { } });
            DockPanel.SetDock(openBk, Dock.Right); bk.Children.Add(openBk);
            var bt = new StackPanel();
            bt.Children.Add(UI.Text(L.T("backupT"), 15, "Text", true));
            bt.Children.Add(UI.Text(Engine.BackedUpIds().Count() + " " + L.T("backupD"), 12.5, "Muted"));
            bk.Children.Add(bt);
            sp.Children.Add(UI.Card(bk));
            return Page(sp);
        }
    }
}
