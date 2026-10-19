using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace JdoTweak
{
    // One category: curated "best" tweaks first, then multi-option settings, then the full library.
    public class TweakPage : Grid
    {
        const int PageSize = 25;
        readonly MainWindow win;
        readonly Category category;
        readonly List<Tweak> best, options, library;
        readonly StackPanel list = new StackPanel();
        readonly TextBox search = new TextBox();
        readonly DispatcherTimer debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        int shownOptions = PageSize, shownLibrary = PageSize;
        bool showAll;
        readonly bool embedded;

        static int UserTier { get { return License.Current == null ? 0 : License.Current.Tier; } }

        public TweakPage(MainWindow w, Category c, bool embedded = false)
        {
            win = w; category = c; this.embedded = embedded;
            var all = App.Catalog.Tweaks.Where(t => t.Cat == c.Id).ToList();
            best = all.Where(t => t.Curated).ToList();
            options = all.Where(t => !t.Curated && t.HasOptions).OrderByDescending(t => t.Packs).ToList();
            library = all.Where(t => !t.Curated && !t.HasOptions).OrderBy(t => t.Tier).ThenBy(t => t.En).ToList();

            var page = new StackPanel();
            if (!embedded) page.Children.Add(MainWindow.Header(c.Icon, c.Title, L.T("pageSub")));

            // toolbar
            var bar = new DockPanel { Margin = new Thickness(0, 0, 0, 18) };
            var btns = new StackPanel { Orientation = Orientation.Horizontal };
            var rec = UI.IconBtn("", L.T("applyRec"), "Primary", async (o, e) => await ApplyRecommended((Button)o));
            var rev = UI.IconBtn("", L.T("revertAll"), "Ghost", async (o, e) => await RevertAll((Button)o)); rev.Margin = new Thickness(10, 0, 0, 0);
            if (!embedded) btns.Children.Add(rec);
            btns.Children.Add(rev);
            DockPanel.SetDock(btns, Dock.Right);
            bar.Children.Add(btns);
            search.Margin = new Thickness(0, 0, 16, 0);
            var hint = new Grid();
            hint.Children.Add(search);
            var ph = UI.Text(L.T("searchHint"), 13.5, "Muted"); ph.IsHitTestVisible = false; ph.Margin = new Thickness(14, 10, 0, 0);
            hint.Children.Add(ph);
            search.TextChanged += (o, e) => { ph.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; debounce.Stop(); debounce.Start(); };
            debounce.Tick += (o, e) => { debounce.Stop(); shownOptions = shownLibrary = PageSize; Render(); };
            Unloaded += (o, e) => debounce.Stop();
            bar.Children.Add(hint);
            page.Children.Add(bar);
            page.Children.Add(list);
            if (embedded) Children.Add(page); else Children.Add(MainWindow.Page(page));
            Render();
        }

        IEnumerable<Tweak> Filter(IEnumerable<Tweak> src)
        {
            string q = search.Text.Trim().ToLowerInvariant();
            if (q.Length == 0) return src;
            var words = q.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
            return src.Where(t => words.All(w => t.SearchText.Contains(w)));
        }

        int stagger;

        void Render()
        {
            stagger = 0;
            list.Children.Clear();
            bool searching = search.Text.Trim().Length > 0;
            var b = Filter(best).ToList();
            var o = (showAll || searching) ? Filter(options).ToList() : new List<Tweak>();
            var l = (showAll || searching) ? Filter(library).ToList() : new List<Tweak>();
            if (b.Count > 0) { if (!embedded) list.Children.Add(Group("", L.T("secBest"), L.T("secBestD"), b.Count)); foreach (var t in b) list.Children.Add(Card(t)); }
            if (o.Count > 0)
            {
                list.Children.Add(Group("", L.T("secOptions"), L.T("secOptionsD"), o.Count));
                foreach (var t in o.Take(shownOptions)) list.Children.Add(Card(t));
                if (o.Count > shownOptions) list.Children.Add(More(o.Count - shownOptions, () => { shownOptions += PageSize * 2; Render(); }));
            }
            if (l.Count > 0)
            {
                list.Children.Add(Group("", L.T("secLibrary"), L.T("secLibraryD"), l.Count));
                foreach (var t in l.Take(shownLibrary)) list.Children.Add(Card(t));
                if (l.Count > shownLibrary) list.Children.Add(More(l.Count - shownLibrary, () => { shownLibrary += PageSize * 2; Render(); }));
            }
            if (b.Count + o.Count + l.Count == 0) { var n = UI.Text(L.T("noResults"), 14, "Muted"); n.Margin = new Thickness(4, 20, 0, 0); list.Children.Add(n); }
            int hidden = options.Count + library.Count;
            if (!searching && hidden > 0)
            {
                var more = UI.Btn((showAll ? L.T("hideAdvanced") : L.T("showAdvanced")) + "  (" + hidden.ToString("N0") + ")", "Ghost", (x, y) => { showAll = !showAll; shownOptions = shownLibrary = PageSize; Render(); });
                more.HorizontalAlignment = HorizontalAlignment.Center; more.Margin = new Thickness(0, 14, 0, 24);
                list.Children.Add(more);
            }
        }

        static FrameworkElement Group(string icon, string title, string sub, int count)
        {
            var sp = new StackPanel { Margin = new Thickness(0, 14, 0, 12) };
            var h = new StackPanel { Orientation = Orientation.Horizontal };
            h.Children.Add(UI.Icon(icon, 15));
            var t = UI.Text(title, 16, "Text", true); t.Margin = new Thickness(10, 0, 0, 0); h.Children.Add(t);
            var c = UI.Text("  " + count.ToString("N0"), 13, "Muted"); c.VerticalAlignment = VerticalAlignment.Center; h.Children.Add(c);
            sp.Children.Add(h);
            var s = UI.Text(sub, 12.5, "Muted"); s.Margin = new Thickness(25, 3, 0, 0); sp.Children.Add(s);
            return sp;
        }

        static FrameworkElement More(int remaining, Action onClick)
        {
            var b = UI.Btn(L.T("showMore") + " (" + remaining.ToString("N0") + ")", "Ghost", (o, e) => onClick());
            b.HorizontalAlignment = HorizontalAlignment.Center; b.Margin = new Thickness(0, 6, 0, 20);
            return b;
        }

        // ------------------------------------------------------------------ card
        FrameworkElement Card(Tweak t)
        {
            bool locked = t.Tier > UserTier;
            var g = new Grid();
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var info = new StackPanel { Margin = new Thickness(0, 0, 18, 0) };
            var title = new WrapPanel();
            var tt = UI.Text(t.Title, 14.5, "Text", true);
            if (!t.Curated) { tt.FlowDirection = FlowDirection.LeftToRight; }
            title.Children.Add(tt);
            title.Children.Add(UI.TierBadge(t.Tier));
            if (t.Risk == 2) title.Children.Add(UI.Badge(L.T("risk2"), "#FF8A8A", "#33FF5C5C"));
            else if (t.Risk == 1) title.Children.Add(UI.Badge(L.T("risk1"), "#FFC979", "#33FFB547"));
            if (t.Reboot) title.Children.Add(UI.Badge(L.T("reboot"), "#A4A8B8", "#22FFFFFF"));
            if (t.NoUndo) title.Children.Add(UI.Badge(L.T("noUndo"), "#A4A8B8", "#22FFFFFF"));
            if (locked) title.Children.Add(UI.Badge(L.T("locked"), "#FFD36B", "#2AF5B841"));
            info.Children.Add(title);
            if (!string.IsNullOrEmpty(t.Desc))
            {
                var d = UI.Text(t.Desc, 12.5, "Muted"); d.Margin = new Thickness(0, 5, 0, 0); d.LineHeight = 19;
                info.Children.Add(d);
            }
            if (t.Curated && !t.HasOptions && t.Apply.Count > 1) info.Children.Add(Details(t, locked));
            if (!string.IsNullOrEmpty(t.Path))
            {
                var p = UI.Text(t.Path, 10.5, "Muted"); p.FontFamily = new FontFamily("Consolas"); p.Opacity = 0.6; p.Margin = new Thickness(0, 4, 0, 0);
                p.FlowDirection = FlowDirection.LeftToRight; p.TextAlignment = L.Ar ? TextAlignment.Right : TextAlignment.Left; p.TextTrimming = TextTrimming.CharacterEllipsis; p.TextWrapping = TextWrapping.NoWrap;
                info.Children.Add(p);
            }
            g.Children.Add(info);

            var right = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
            var status = UI.Text("", 11, "Muted"); status.HorizontalAlignment = HorizontalAlignment.Center; status.Margin = new Thickness(0, 6, 0, 0);
            if (t.HasOptions)
            {
                var combo = new ComboBox { IsEnabled = !locked };
                foreach (var o in t.Options) combo.Items.Add(o);
                int cur = -1;
                try { cur = Engine.CurrentOption(t); } catch { }
                combo.SelectedIndex = cur;
                status.Text = cur < 0 ? L.T("custom") : t.Options[cur].IsDefault ? L.T("notApplied") : L.T("applied");
                status.Foreground = cur >= 0 && !t.Options[cur].IsDefault ? UI.B("Good") : UI.B("Muted");
                bool ready = true;
                combo.SelectionChanged += async (o, e) =>
                {
                    if (!ready || combo.SelectedIndex < 0) return;
                    int i = combo.SelectedIndex;
                    if (!Confirm(t)) { ready = false; combo.SelectedIndex = cur; ready = true; return; }
                    combo.IsEnabled = false; status.Text = L.T("working"); status.Foreground = UI.B("Accent");
                    await Task.Run(() => Engine.ApplyOption(t, i));
                    cur = i; combo.IsEnabled = true;
                    status.Text = t.Options[i].IsDefault ? L.T("notApplied") : L.T("applied");
                    status.Foreground = t.Options[i].IsDefault ? UI.B("Muted") : UI.B("Good");
                    if (t.Reboot) win.NeedReboot();
                };
                right.Children.Add(combo);
                if (t.Auto == "ram" && App.Hardware.RamGb > 0)
                {
                    int r = t.RecommendedOption(App.Hardware);
                    var det = UI.Text(L.T("detected") + ": " + App.Hardware.RamGb + " GB", 11, "Accent"); det.HorizontalAlignment = HorizontalAlignment.Center; det.Margin = new Thickness(0, 6, 0, 0);
                    det.Cursor = Cursors.Hand; det.ToolTip = t.Options[r].Label;
                    det.MouseLeftButtonUp += (o, e) => { if (!locked) combo.SelectedIndex = r; };
                    right.Children.Add(det);
                }
            }
            else
            {
                var sw = new ToggleButton { Style = UI.S("Switch"), IsEnabled = !locked, HorizontalAlignment = HorizontalAlignment.Center };
                bool on = false;
                try { on = Engine.IsApplied(t); } catch { }
                sw.IsChecked = on;
                status.Text = on ? L.T("applied") : L.T("notApplied");
                status.Foreground = on ? UI.B("Good") : UI.B("Muted");
                bool busy = false;
                sw.Click += async (o, e) =>
                {
                    if (busy) return;
                    bool want = sw.IsChecked == true;
                    if (want && !Confirm(t)) { sw.IsChecked = false; return; }
                    busy = true; sw.IsEnabled = false; status.Text = L.T("working"); status.Foreground = UI.B("Accent");
                    await Task.Run(() => { if (want) Engine.ApplyTweak(t); else Engine.RevertTweak(t); });
                    bool now = want;
                    try { var m = Engine.AllMatch(t.Apply); if (m.HasValue) now = m.Value; } catch { }
                    sw.IsChecked = now; sw.IsEnabled = true; busy = false;
                    status.Text = now ? L.T("applied") : L.T("notApplied");
                    status.Foreground = now ? UI.B("Good") : UI.B("Muted");
                    if (want && now != want) { status.Text = L.T("failed"); status.Foreground = UI.B("Bad"); }
                    if (t.Reboot) win.NeedReboot();
                };
                right.Children.Add(sw);
            }
            right.Children.Add(status);
            Grid.SetColumn(right, 1);
            g.Children.Add(right);

            var card = UI.Card(g, 16);
            card.Margin = new Thickness(0, 0, 0, 10);
            if (locked) card.Opacity = 0.62;
            Fx.Enter(card, Math.Min(stagger++ * 28, 420), 10);
            card.MouseEnter += (o, e) => card.Background = UI.B("CardHover");
            card.MouseLeave += (o, e) => card.Background = UI.B("Card");
            return card;
        }

        // Every value / command inside a hand-picked tweak, each with its own switch.
        FrameworkElement Details(Tweak t, bool locked)
        {
            var wrap = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
            var toggle = UI.Text("▸  " + L.T("details") + " (" + t.Apply.Count + " " + L.T("separate") + ")", 12, "Accent", true);
            toggle.Cursor = Cursors.Hand;
            var rows = new StackPanel { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0) };
            toggle.MouseLeftButtonUp += (o, e) =>
            {
                bool open = rows.Visibility != Visibility.Visible;
                if (open && rows.Children.Count == 0)
                    for (int i = 0; i < t.Apply.Count; i++) rows.Children.Add(SubRow(t, i, locked));
                rows.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
                toggle.Text = (open ? "▾  " : "▸  ") + L.T("details") + " (" + t.Apply.Count + " " + L.T("separate") + ")";
                if (open) Fx.Enter(rows, 0, 6);
            };
            wrap.Children.Add(toggle);
            wrap.Children.Add(rows);
            return wrap;
        }

        FrameworkElement SubRow(Tweak parent, int i, bool locked)
        {
            var s = Tweak.Sub(parent, i);
            var a = parent.Apply[i];
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
            var sw = new ToggleButton { Style = UI.S("Switch"), IsEnabled = !locked, RenderTransform = new ScaleTransform(0.8, 0.8), RenderTransformOrigin = new Point(0.5, 0.5) };
            bool on = false; try { on = Engine.IsApplied(s); } catch { }
            sw.IsChecked = on;
            sw.Click += async (o, e) =>
            {
                bool want = sw.IsChecked == true;
                if (want && !Confirm(s)) { sw.IsChecked = false; return; }
                sw.IsEnabled = false;
                await Task.Run(() => { if (want) Engine.ApplyTweak(s); else Engine.RevertTweak(s); });
                bool now = want;
                try { var m = Engine.AllMatch(s.Apply); if (m.HasValue) now = m.Value; } catch { }
                sw.IsChecked = now; sw.IsEnabled = true;
                if (s.Reboot) win.NeedReboot();
            };
            DockPanel.SetDock(sw, Dock.Right);
            row.Children.Add(sw);
            var txt = UI.Text(ActionText(a), 11.5, "Muted");
            txt.FontFamily = new FontFamily("Consolas"); txt.FlowDirection = FlowDirection.LeftToRight; txt.VerticalAlignment = VerticalAlignment.Center;
            txt.TextAlignment = L.Ar ? TextAlignment.Right : TextAlignment.Left; txt.Margin = new Thickness(0, 0, 10, 0);
            row.Children.Add(txt);
            return new Border { Background = UI.B("Bg"), CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(0, 0, 0, 4), Child = row };
        }

        static string ActionText(TAction a)
        {
            if (!a.IsRegistry) return (a.Kind == "ps" ? "PS> " : "> ") + a.Command;
            string leaf = a.Key.Substring(a.Key.LastIndexOf('\\') + 1);
            return (a.Kind == "each" ? leaf + "\\*\\" : leaf + "\\") + a.Name + " = " + Catalog.ValueLabel(a);
        }

        bool Confirm(Tweak t)
        {
            win.EnsureRestorePoint();
            if (t.Risk < 2) return true;
            return UI.Ask(win, L.T("riskTitle"), t.Title + "\n\n" + L.T("riskBody"), true, true);
        }

        // ------------------------------------------------------------------ bulk actions
        async Task ApplyRecommended(Button b)
        {
            win.EnsureRestorePoint();
            var hw = App.Hardware;
            var todo = best.Where(t => t.Tier <= UserTier && t.Risk == 0 && (t.MinRam == 0 || hw.RamGb >= t.MinRam) && (t.Vendor == null || t.Vendor == hw.GpuVendor)).ToList();
            b.IsEnabled = false;
            bool reboot = false;
            await Task.Run(() =>
            {
                foreach (var t in todo)
                    try
                    {
                        if (t.HasOptions) { int i = t.RecommendedOption(hw); if (i >= 0 && !t.Options[i].IsDefault) Engine.ApplyOption(t, i); }
                        else if (!Engine.IsApplied(t)) Engine.ApplyTweak(t);
                        reboot |= t.Reboot;
                    }
                    catch { }
            });
            b.IsEnabled = true;
            if (reboot) win.NeedReboot();
            Render();
        }

        async Task RevertAll(Button b)
        {
            var cat = App.Catalog;
            var todo = Engine.BackedUpIds().Select(id => cat.Find(id)).Where(t => t != null && t.Cat == category.Id).ToList();
            if (todo.Count == 0) return;
            b.IsEnabled = false;
            await Task.Run(() => { foreach (var t in todo) try { Engine.RevertById(cat, t.Id); } catch { } });
            b.IsEnabled = true;
            if (todo.Any(t => t.Reboot)) win.NeedReboot();
            Render();
        }
    }
}
