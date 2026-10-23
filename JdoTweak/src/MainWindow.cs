using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;

namespace JdoTweak
{
    public partial class MainWindow : Window
    {
        Catalog cat { get { return App.Catalog; } }
        HardwareInfo hw { get { return App.Hardware; } }
        Session user { get { return License.Current; } }

        ContentControl content;
        Border rebootBar;
        string page = "dashboard";
        UsageMonitor monitor;
        DispatcherTimer timer;
        readonly Dictionary<string, Queue<double>> history = new Dictionary<string, Queue<double>>();
        Action<UsageMonitor> onSample;

        public MainWindow()
        {
            Title = L.T("app");
            Width = 1240; Height = 800; MinWidth = 1000; MinHeight = 640;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = UI.B("Bg"); FontFamily = new FontFamily("Segoe UI");
            UI.Chrome(this);
            Build();
            L.Changed += Build;
            StartMonitor();
            SourceInitialized += (o, e) => PollingInit();
            Closed += (o, e) => { L.Changed -= Build; if (timer != null) timer.Stop(); if (monitor != null) monitor.Dispose(); };
        }

        // ------------------------------------------------------------------ shell
        void Build()
        {
            Title = L.T("app");
            Background = UI.B("Bg");     // follows the theme when it changes
            FlowDirection = L.Ar ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
            var root = new Grid();
            root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
            root.ColumnDefinitions.Add(new ColumnDefinition());

            // sidebar
            var side = new DockPanel { Background = UI.B("Side") };
            var brand = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(22, 22, 22, 18) };
            brand.Children.Add(UI.Logo(38));
            var bt = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            bt.Children.Add(UI.Text(L.Ar ? "جدو الشايب" : "JDO Al-Shayeb", 16, "Text", true));
            bt.Children.Add(UI.Text("TWEAK", 11, "Accent", true));
            brand.Children.Add(bt);
            DockPanel.SetDock(brand, Dock.Top);
            side.Children.Add(brand);

            var foot = new StackPanel { Margin = new Thickness(0, 6, 0, 14) };
            if (user != null && user.IsOwner) foot.Children.Add(Nav("owner", "", L.T("owner")));
            foot.Children.Add(Nav("account", "", L.T("account")));
            foot.Children.Add(Nav("settings", "", L.T("settings")));
            DockPanel.SetDock(foot, Dock.Bottom);
            side.Children.Add(foot);

            var navList = new StackPanel();
            navList.Children.Add(Nav("dashboard", "", L.T("dashboard")));
            navList.Children.Add(Section(L.T("tweaks")));
            foreach (var c in cat.Categories) navList.Children.Add(Nav("cat:" + c.Id, c.Icon, c.Title));
            navList.Children.Add(Section(L.T("tools")));
            navList.Children.Add(Nav("repair", "", L.T("repair")));
            navList.Children.Add(Nav("polling", "", L.T("pollTitle")));
            side.Children.Add(new ScrollViewer { Content = navList, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
            root.Children.Add(side);

            // main area
            var main = new Grid();
            main.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
            main.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            main.RowDefinitions.Add(new RowDefinition());
            main.Children.Add(UI.TitleBar(this, true));

            rebootBar = new Border { Background = UI.Hex("#2A2312"), Padding = new Thickness(24, 10, 24, 10), Visibility = Visibility.Collapsed };
            var rb = new DockPanel();
            var rbtn = UI.Btn(L.T("restartNow"), "Primary", (o, e) => { if (UI.Ask(this, L.T("rebootTitle"), L.T("rebootBody"), true)) Engine.Shell("shutdown.exe", "/r /t 3", 10); });
            rbtn.Padding = new Thickness(14, 6, 14, 6);
            DockPanel.SetDock(rbtn, Dock.Right);
            rb.Children.Add(rbtn);
            var rt = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            rt.Children.Add(UI.Icon("", 15, "Warn"));
            var rtt = UI.Text(L.T("reboot") + " — " + L.T("rebootBody"), 13, "Warn"); rtt.Margin = new Thickness(10, 0, 0, 0);
            rt.Children.Add(rtt);
            rb.Children.Add(rt);
            rebootBar.Child = rb;
            Grid.SetRow(rebootBar, 1);
            main.Children.Add(rebootBar);

            var glow = new Border
            {
                IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Top, Height = 420,
                Background = new RadialGradientBrush { GradientOrigin = new Point(0.85, 0), Center = new Point(0.85, 0), RadiusX = 0.7, RadiusY = 1,
                    GradientStops = new GradientStopCollection { new GradientStop(Color.FromArgb(0x30, Themes.AccentColor.R, Themes.AccentColor.G, Themes.AccentColor.B), 0), new GradientStop(Color.FromArgb(0x10, Themes.Accent2Color.R, Themes.Accent2Color.G, Themes.Accent2Color.B), 0.5), new GradientStop(Colors.Transparent, 1) } }
            };
            Grid.SetRowSpan(glow, 3);
            main.Children.Insert(0, glow);
            Fx.Pulse(glow);

            content = new ContentControl();
            Grid.SetRow(content, 2);
            main.Children.Add(content);
            Grid.SetColumn(main, 1);
            root.Children.Add(main);

            Content = root;
            Show(page);
        }

        UIElement Section(string text)
        {
            var t = UI.Text(text.ToUpperInvariant(), 11, "Muted", true);
            t.Margin = new Thickness(26, 18, 0, 6); t.Opacity = 0.7;
            return t;
        }

        RadioButton Nav(string id, string icon, string text)
        {
            var g = new DockPanel();
            var ic = new TextBlock { Text = icon, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 15, Width = 22, VerticalAlignment = VerticalAlignment.Center };
            g.Children.Add(ic);
            var tx = new TextBlock { Text = text, Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            g.Children.Add(tx);
            var r = new RadioButton { Content = g, Style = UI.S("Nav"), GroupName = "nav", IsChecked = page == id, Tag = id };
            r.Checked += (o, e) => Show(id);
            return r;
        }

        void Show(string id)
        {
            page = id;
            onSample = null;
            onPoll = null;
            FrameworkElement el;
            if (id == "dashboard") el = Dashboard();
            else if (id == "cat:windows") el = new PackPage(this, cat.Categories.First(c => c.Id == "windows"));
            else if (id.StartsWith("cat:") && cat.Categories.Any(c => c.Id == id.Substring(4))) el = new TweakPage(this, cat.Categories.First(c => c.Id == id.Substring(4)));
            else if (id == "repair") el = RepairPage();
            else if (id == "polling") el = PollingPage();
            else if (id == "account") el = AccountPage();
            else if (id == "owner") el = OwnerPage();
            else if (id == "settings") el = SettingsPage();
            else { page = "dashboard"; el = Dashboard(); }
            content.Content = el;
            Fx.Enter(el, 0, 18);
        }

        public void NeedReboot() { rebootBar.Visibility = Visibility.Visible; }

        public void Navigate(string id) { page = id; Build(); }

        public static ScrollViewer Page(UIElement inner)
        {
            return new ScrollViewer { Content = new Border { Padding = new Thickness(34, 8, 34, 34), Child = inner }, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        }

        public static FrameworkElement Header(string icon, string title, string sub)
        {
            var sp = new StackPanel { Margin = new Thickness(0, 0, 0, 22) };
            var h = new StackPanel { Orientation = Orientation.Horizontal };
            if (icon != null) { var i = UI.Icon(icon, 24); i.Margin = new Thickness(0, 0, 14, 0); h.Children.Add(i); }
            h.Children.Add(UI.Text(title, 26, "Text", true));
            sp.Children.Add(h);
            if (sub != null) { var s = UI.Text(sub, 13.5, "Muted"); s.Margin = new Thickness(0, 6, 0, 0); sp.Children.Add(s); }
            return sp;
        }

        // ------------------------------------------------------------------ restore point (first use)
        public bool EnsureRestorePoint()
        {
            const string k = @"HKEY_CURRENT_USER\Software\JdoTweak";
            if (Registry.GetValue(k, "RestoreAsked", null) != null) return true;
            Registry.SetValue(k, "RestoreAsked", 1);
            if (UI.Ask(this, L.T("restorePoint"), L.T("rpAsk"), true))
            {
                Cursor = Cursors.Wait;
                bool ok = Engine.CreateRestorePoint();
                Cursor = null;
                if (ok) UI.Ask(this, L.T("restorePoint"), L.T("rpDone"), false);
            }
            return true;
        }

        // ------------------------------------------------------------------ dashboard
        FrameworkElement Dashboard()
        {
            var sp = new StackPanel();

            // hero
            var hero = new Grid();
            hero.ColumnDefinitions.Add(new ColumnDefinition());
            hero.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var ht = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            ht.Children.Add(UI.Text(L.T("welcome") + (user != null ? " " + user.Email.Split('@')[0] : ""), 26, "Text", true));
            int active = cat.Tweaks.Count(t => t.Curated && SafeApplied(t));
var stat = UI.Text(active + " " + L.T("tweaksActive"), 13.5, "Muted");
            stat.Margin = new Thickness(0, 6, 0, 0);
            ht.Children.Add(stat);
            hero.Children.Add(ht);
            var boost = UI.IconBtn("", L.T("quickBoost"), "Primary", async (o, e) => await QuickBoost((Button)o));
            boost.Padding = new Thickness(22, 12, 22, 12); boost.FontSize = 14;
            boost.ToolTip = L.T("quickBoostD");
            Grid.SetColumn(boost, 1);
            hero.Children.Add(boost);
            var heroCard = new Border
            {
                CornerRadius = new CornerRadius(18), Padding = new Thickness(26, 22, 26, 22), BorderBrush = UI.B("Line"), BorderThickness = new Thickness(1), Child = hero,
                Background = new LinearGradientBrush(Color.FromArgb(0x40, Themes.AccentColor.R, Themes.AccentColor.G, Themes.AccentColor.B), Color.FromArgb(0x14, Themes.Accent2Color.R, Themes.Accent2Color.G, Themes.Accent2Color.B), 0)
            };
            sp.Children.Add(heroCard);
            sp.Children.Add(UI.Gap(18));
            if (user != null && !user.HasPlan) { sp.Children.Add(NoPlanCard()); sp.Children.Add(UI.Gap(18)); }
            var newsHost = new StackPanel();
            sp.Children.Add(newsHost);
            LoadNews(newsHost);
            sp.Children.Add(UI.Gap(6));

            // live usage
            sp.Children.Add(SectionTitle(L.T("usageTitle")));
            var usage = new UniformGrid { Columns = 4 };
            var gauges = new Dictionary<string, Tuple<TextBlock, TextBlock, Polyline>>();
            foreach (var kv in new[] { new[] { "cpu", "", "#F5B841" }, new[] { "gpu", "", "#3DD68C" }, new[] { "ram", "", "#6EA8FE" }, new[] { "disk", "", "#C08BFF" } })
            {
                var g = new Grid();
                var top = new DockPanel();
                var ic = UI.Icon(kv[1], 15, "Muted"); top.Children.Add(ic);
                var lbl = UI.Text(L.T(kv[0]), 12.5, "Muted"); lbl.Margin = new Thickness(8, 0, 0, 0); lbl.VerticalAlignment = VerticalAlignment.Center;
                top.Children.Add(lbl);
                var val = UI.Text("—", 28, "Text", true);
                var sub = UI.Text("", 11.5, "Muted");
                var line = new Polyline { Stroke = UI.Hex(kv[2]), StrokeThickness = 2, Height = 44, Stretch = Stretch.None, Margin = new Thickness(0, 6, 0, 0), FlowDirection = FlowDirection.LeftToRight, Tag = kv[0] };
                var col = new StackPanel();
                col.Children.Add(top); col.Children.Add(val); col.Children.Add(sub); col.Children.Add(line);
                var card = UI.Card(col, 16); card.Margin = new Thickness(0, 0, 12, 0);
                usage.Children.Add(card);
                gauges[kv[0]] = Tuple.Create(val, sub, line);
            }
            sp.Children.Add(usage);
            onSample = m =>
            {
                Push("cpu", m.Cpu); Push("gpu", m.Gpu); Push("ram", m.Ram); Push("disk", m.Disk);
                Set(gauges["cpu"], m.Cpu, hw.Devices.Where(d => d.Kind == "cpu").Select(d => d.Name).FirstOrDefault());
                Set(gauges["gpu"], m.Gpu, hw.Devices.Where(d => d.Kind == "gpu").Select(d => d.Name).FirstOrDefault());
                Set(gauges["ram"], m.Ram, m.RamUsedGb.ToString("0.0") + " / " + m.RamTotalGb.ToString("0") + " GB");
                Set(gauges["disk"], m.Disk, hw.Devices.Where(d => d.Kind == "disk").Select(d => d.Name).FirstOrDefault());
            };

            // hardware
            sp.Children.Add(UI.Gap(26));
            var hwHead = new DockPanel();
            var rp = UI.IconBtn("", L.T("restorePoint"), "Ghost", async (o, e) =>
            {
                var b = (Button)o; b.IsEnabled = false;
                bool ok = await Task.Run(() => Engine.CreateRestorePoint());
                b.IsEnabled = true;
                UI.Ask(this, L.T("restorePoint"), ok ? L.T("rpDone") : L.T("failed"), false);
            });
            DockPanel.SetDock(rp, Dock.Right);
            hwHead.Children.Add(rp);
            hwHead.Children.Add(SectionTitle(L.T("hwTitle")));
            sp.Children.Add(hwHead);
            var grid = new UniformGrid { Columns = 2 };
            var order = new[] { "cpu", "gpu", "ram", "board", "disk", "mouse", "keyboard", "monitor", "net", "os" };
            var icons = new Dictionary<string, string> { { "cpu", "" }, { "gpu", "" }, { "ram", "" }, { "board", "" }, { "disk", "" }, { "mouse", "" }, { "keyboard", "" }, { "monitor", "" }, { "net", "" }, { "os", "" } };
            foreach (var d in hw.Devices.OrderBy(x => Array.IndexOf(order, x.Kind)))
                grid.Children.Add(DeviceCard(d, icons.ContainsKey(d.Kind) ? icons[d.Kind] : ""));
            sp.Children.Add(grid);
            return Page(sp);
        }

        // Shown to accounts the admin hasn't given a plan yet.
        FrameworkElement NoPlanCard()
        {
            var row = new DockPanel();
            var refresh = UI.IconBtn("", L.T("refreshPlan"), "Primary", async (o, e) => await RefreshPlan((Button)o));
            refresh.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(refresh, Dock.Right);
            row.Children.Add(refresh);
            var ic = UI.Icon("", 22, "Warn"); ic.Margin = new Thickness(0, 0, 14, 0);
            row.Children.Add(ic);
            var t = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            t.Children.Add(UI.Text(L.T("noPlanT"), 16, "Text", true));
            var d = UI.Text(L.T("noPlanD"), 13, "Muted"); d.Margin = new Thickness(0, 4, 0, 0);
            t.Children.Add(d);
            row.Children.Add(t);
            var c = UI.Card(row, 20);
            c.BorderBrush = UI.B("Warn");
            return c;
        }

        // Asks the server again, so a plan the admin just granted shows up without signing out.
        public async Task RefreshPlan(Button b)
        {
            if (b != null) b.IsEnabled = false;
            string hwid = hw.Hwid();
            var r = await Task.Run(() => License.Resume(hwid));
            if (b != null) b.IsEnabled = true;
            if (r == License.Result.Ok) { Build(); if (user != null && !user.HasPlan) UI.Ask(this, L.T("refreshPlan"), L.T("stillNoPlan"), false); }
            else UI.Ask(this, L.T("refreshPlan"), L.T("netErr"), false, true);
        }

        static TextBlock SectionTitle(string s) { var t = UI.Text(s, 16, "Text", true); t.Margin = new Thickness(0, 0, 0, 12); return t; }

        void Push(string k, double v)
        {
            Queue<double> q;
            if (!history.TryGetValue(k, out q)) history[k] = q = new Queue<double>();
            q.Enqueue(v); while (q.Count > 60) q.Dequeue();
        }

        void Set(Tuple<TextBlock, TextBlock, Polyline> g, double pct, string sub)
        {
            g.Item1.Text = pct.ToString("0") + "%";
            g.Item1.Foreground = pct > 90 ? UI.B("Bad") : pct > 70 ? UI.B("Warn") : UI.B("Text");
            g.Item2.Text = sub ?? "";
            var key = history.First(h => g.Item3.Tag == null ? false : (string)g.Item3.Tag == h.Key);
            g.Item3.Points = Spark(key.Value, 200, 44);
        }

        static PointCollection Spark(IEnumerable<double> vals, double w, double h)
        {
            var pts = new PointCollection();
            var a = vals.ToArray();
            for (int i = 0; i < a.Length; i++) pts.Add(new Point(w - (a.Length - 1 - i) * (w / 59.0), h - a[i] / 100.0 * h));
            return pts;
        }

        Border DeviceCard(Device d, string icon)
        {
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var pic = new Border { Width = 54, Height = 54, CornerRadius = new CornerRadius(12), Background = UI.B("AccentDim"), Margin = new Thickness(0, 0, 14, 0) };
            pic.Child = new TextBlock { Text = icon, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 24, Foreground = UI.B("Accent"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            g.Children.Add(pic);
            var t = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            t.Children.Add(UI.Text(L.T(d.Kind == "board" ? "board" : d.Kind == "os" ? "os" : d.Kind), 11.5, "Muted"));
            var n = UI.Text(d.Name, 14, "Text", true); n.FlowDirection = FlowDirection.LeftToRight; n.TextAlignment = L.Ar ? TextAlignment.Right : TextAlignment.Left;
            t.Children.Add(n);
            if (!string.IsNullOrEmpty(d.Detail)) { var dt = UI.Text(d.Detail, 11.5, "Muted"); dt.FlowDirection = FlowDirection.LeftToRight; dt.TextAlignment = L.Ar ? TextAlignment.Right : TextAlignment.Left; t.Children.Add(dt); }
            Grid.SetColumn(t, 1); g.Children.Add(t);
            if (d.Kind != "os")
            {
                var b = UI.IconBtn("", L.T("photo"), "Ghost", (o, e) =>
                {
                    try { System.Diagnostics.Process.Start("https://www.google.com/search?tbm=isch&q=" + Uri.EscapeDataString(d.Name)); } catch { }
                });
                b.Padding = new Thickness(10, 5, 10, 5); b.VerticalAlignment = VerticalAlignment.Center; b.Margin = new Thickness(10, 0, 0, 0);
                Grid.SetColumn(b, 2); g.Children.Add(b);
            }
            var c = UI.Card(g, 14); c.Margin = new Thickness(0, 0, 12, 12);
            return c;
        }

        void StartMonitor()
        {
            Task.Run(() => { monitor = new UsageMonitor(); });
            timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            timer.Tick += async (o, e) =>
            {
                if (monitor == null) return;
                var m = monitor;
                await Task.Run(() => m.Sample());
                if (onSample != null) onSample(m);
            };
            timer.Start();
        }

        static bool SafeApplied(Tweak t) { try { if (!t.HasOptions) return Engine.IsApplied(t); int i = Engine.CurrentOption(t); return i >= 0 && !t.Options[i].IsDefault; } catch { return false; } }

        async Task QuickBoost(Button b)
        {
            if (user == null) return;
            if (!user.HasPlan) { UI.Ask(this, L.T("noPlanT"), L.T("noPlanD"), false); return; }
            EnsureRestorePoint();
            b.IsEnabled = false;
            var list = cat.Tweaks.Where(t => t.Curated && t.Tier <= user.Tier && t.Risk == 0 && (t.MinRam == 0 || hw.RamGb >= t.MinRam) && (t.Vendor == null || t.Vendor == hw.GpuVendor)).ToList();
            bool reboot = false;
            await Task.Run(() =>
            {
                foreach (var t in list)
                {
                    try
                    {
                        if (t.HasOptions) { int i = t.RecommendedOption(hw); if (i >= 0 && !t.Options[i].IsDefault) Engine.ApplyOption(t, i); }
                        else if (!Engine.IsApplied(t)) Engine.ApplyTweak(t);
                        if (t.Reboot) reboot = true;
                    }
                    catch { }
                }
            });
            b.IsEnabled = true;
            if (reboot) NeedReboot();
            UI.Ask(this, L.T("quickBoost"), list.Count + " " + L.T("tweaksActive"), false);
            Show("dashboard");
        }
    }
}
