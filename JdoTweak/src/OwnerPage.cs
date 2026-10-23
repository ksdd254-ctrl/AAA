using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace JdoTweak
{
    public partial class MainWindow
    {
        // ------------------------------------------------------------------ owner dashboard (owner account only)
        FrameworkElement OwnerPage()
        {
            var sp = new StackPanel();
            sp.Children.Add(Header("", L.T("owner"), L.T("ownerSub")));
            sp.Children.Add(UsersCard());
            sp.Children.Add(UI.Gap(14));

            // announcement composer
            var news = new StackPanel();
            news.Children.Add(UI.Text(L.T("postNews"), 16, "Text", true));
            news.Children.Add(UI.Text(L.T("postNewsD"), 12.5, "Muted"));
            var titleAr = Field(news, L.T("titleAr"), false, false);
            var titleEn = Field(news, L.T("titleEn"), false, true);
            var bodyAr = Field(news, L.T("bodyAr"), true, false);
            var bodyEn = Field(news, L.T("bodyEn"), true, true);
            var status = UI.Text("", 12.5, "Muted"); status.Margin = new Thickness(0, 10, 0, 0);
            var post = UI.IconBtn("", L.T("publish"), "Primary", null);
            post.HorizontalAlignment = HorizontalAlignment.Left; post.Margin = new Thickness(0, 14, 0, 0);
            post.Click += async (o, e) =>
            {
                post.IsEnabled = false;
                var body = new Dictionary<string, object> { { "titleAr", titleAr.Text }, { "titleEn", titleEn.Text }, { "bodyAr", bodyAr.Text }, { "bodyEn", bodyEn.Text } };
                var r = await Task.Run(() => License.OwnerPost("/api/owner/news", body));
                post.IsEnabled = true;
                bool ok = r != null && r.ContainsKey("ok") && r["ok"] is bool && (bool)r["ok"];
                status.Text = ok ? "✓ " + L.T("published") : "✗ " + (string.IsNullOrEmpty(License.ApiBase) ? L.T("noServer") : L.T("failed"));
                status.Foreground = ok ? UI.B("Good") : UI.B("Bad");
                if (ok) { titleAr.Text = titleEn.Text = bodyAr.Text = bodyEn.Text = ""; }
            };
            news.Children.Add(post);
            news.Children.Add(status);
            sp.Children.Add(UI.Card(news, 22));
            sp.Children.Add(UI.Gap(14));

            // release publisher
            var rel = new StackPanel();
            rel.Children.Add(UI.Text(L.T("pubRelease"), 16, "Text", true));
            rel.Children.Add(UI.Text(L.T("pubReleaseD"), 12.5, "Muted"));
            var ver = Field(rel, L.T("version"), false, true);
            var url = Field(rel, L.T("downloadUrl"), false, true);
            var sha = Field(rel, "SHA-256", false, true);
            var notes = Field(rel, L.T("notes"), true, false);
            var rstatus = UI.Text("", 12.5, "Muted"); rstatus.Margin = new Thickness(0, 10, 0, 0);
            var rbtn = UI.IconBtn("", L.T("publish"), "Primary", null);
            rbtn.HorizontalAlignment = HorizontalAlignment.Left; rbtn.Margin = new Thickness(0, 14, 0, 0);
            rbtn.Click += async (o, e) =>
            {
                rbtn.IsEnabled = false;
                var body = new Dictionary<string, object> { { "version", ver.Text.Trim() }, { "url", url.Text.Trim() }, { "sha256", sha.Text.Trim().ToLowerInvariant() }, { "notes", notes.Text } };
                var r = await Task.Run(() => License.OwnerPost("/api/owner/release", body));
                rbtn.IsEnabled = true;
                bool ok = r != null && r.ContainsKey("ok") && r["ok"] is bool && (bool)r["ok"];
                rstatus.Text = ok ? "✓ " + L.T("published") : "✗ " + (string.IsNullOrEmpty(License.ApiBase) ? L.T("noServer") : L.T("failed"));
                rstatus.Foreground = ok ? UI.B("Good") : UI.B("Bad");
            };
            rel.Children.Add(rbtn);
            rel.Children.Add(rstatus);
            sp.Children.Add(UI.Card(rel, 22));
            return Page(sp);
        }

        // ------------------------------------------------------------------ accounts and their plans
        static readonly int[] PlanDays = { 0, 30, 90, 365 };

        FrameworkElement UsersCard()
        {
            var box = new StackPanel();
            box.Children.Add(UI.Text(L.T("usersT"), 16, "Text", true));
            box.Children.Add(UI.Text(L.T("usersD"), 12.5, "Muted"));

            var bar = new DockPanel { Margin = new Thickness(0, 14, 0, 10) };
            var reload = UI.IconBtn("", L.T("refresh"), "Ghost", null);
            DockPanel.SetDock(reload, Dock.Right);
            bar.Children.Add(reload);
            var search = new TextBox { FlowDirection = FlowDirection.LeftToRight, Margin = new Thickness(0, 0, 10, 0) };
            bar.Children.Add(search);
            box.Children.Add(bar);

            var list = new StackPanel();
            box.Children.Add(list);
            Func<Task> load = async () =>
            {
                list.Children.Clear();
                list.Children.Add(UI.Text(L.T("loading"), 12.5, "Muted"));
                string q = search.Text.Trim();
                var users = await Task.Run(() => License.OwnerUsers(q));
                list.Children.Clear();
                if (users == null) { list.Children.Add(UI.Text(string.IsNullOrEmpty(License.ApiBase) ? L.T("noServer") : L.T("netErr"), 12.5, "Bad")); return; }
                if (users.Count == 0) { list.Children.Add(UI.Text(L.T("noResults"), 12.5, "Muted")); return; }
                foreach (var u in users) list.Children.Add(UserRow(u));
            };
            reload.Click += async (o, e) => await load();
            search.KeyDown += async (o, e) => { if (e.Key == System.Windows.Input.Key.Enter) await load(); };
            var _ = load();
            return UI.Card(box, 22);
        }

        FrameworkElement UserRow(License.Account u)
        {
            var g = new Grid { Margin = new Thickness(0, 0, 0, 8) };
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var em = UI.Text(u.Email, 13.5, "Text", true); em.FlowDirection = FlowDirection.LeftToRight; em.TextAlignment = L.Ar ? TextAlignment.Right : TextAlignment.Left;
            info.Children.Add(em);
            string plan = u.Role == "owner" ? L.T("adminRole")
                        : u.Tier == 0 ? (u.Ended ? L.T("planEnded") : L.T("noPlan"))
                        : L.T("tier" + u.Tier) + (u.Lite ? " + " + L.T("liteWin") : "");
            string until = u.Role != "owner" && u.Tier > 0 ? "  ·  " + (u.Expires == null ? L.T("lifetime") : L.T("until") + " " + u.Expires.Substring(0, 10)) : "";
            string status = !u.Verified ? "  ·  " + L.T("notVerified") : u.Banned ? "  ·  " + L.T("banned") : "";
            var pl = UI.Text(plan + until + status, 12, u.Tier > 0 || u.Role == "owner" ? "Good" : "Muted");
            info.Children.Add(pl);
            g.Children.Add(info);

            if (u.Role != "owner")
            {
                var ctl = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                var planBox = new ComboBox { MinWidth = 170, Margin = new Thickness(0, 0, 8, 0) };
                foreach (var k in new[] { "noPlan", "tier1", "tier2", "tier3", "tier3lite" }) planBox.Items.Add(k == "tier3lite" ? L.T("tier3") + " + " + L.T("liteWin") : L.T(k));
                planBox.SelectedIndex = u.Tier == 3 && u.Lite ? 4 : u.Tier;
                var daysBox = new ComboBox { MinWidth = 120, Margin = new Thickness(0, 0, 8, 0) };
                foreach (var k in new[] { "lifetime", "days30", "days90", "days365" }) daysBox.Items.Add(L.T(k));
                daysBox.SelectedIndex = 0;
                var save = UI.Btn(L.T("save"), "Primary", null);
                save.Padding = new Thickness(14, 6, 14, 6);
                save.Click += async (o, e) =>
                {
                    int sel = planBox.SelectedIndex;
                    int tier = sel == 4 ? 3 : sel;
                    bool lite = sel == 4;
                    int days = PlanDays[Math.Max(0, daysBox.SelectedIndex)];
                    save.IsEnabled = false;
                    string err = await Task.Run(() => License.OwnerSetPlan(u.Id, tier, lite, days));
                    save.IsEnabled = true;
                    if (err != null) { pl.Text = "✗ " + L.T("failed"); pl.Foreground = UI.B("Bad"); return; }
                    u.Tier = tier; u.Lite = lite;
                    u.Expires = tier > 0 && days > 0 ? DateTime.UtcNow.AddDays(days).ToString("yyyy-MM-dd") : null;
                    pl.Text = "✓ " + (tier == 0 ? L.T("noPlan") : L.T("tier" + tier) + (lite ? " + " + L.T("liteWin") : "") + "  ·  " + (u.Expires == null ? L.T("lifetime") : L.T("until") + " " + u.Expires));
                    pl.Foreground = UI.B(tier > 0 ? "Good" : "Muted");
                };
                ctl.Children.Add(planBox); ctl.Children.Add(daysBox); ctl.Children.Add(save);
                Grid.SetColumn(ctl, 1);
                g.Children.Add(ctl);
            }
            return new Border { Background = UI.B("Bg"), CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 8), Child = g };
        }

        static TextBox Field(Panel parent, string label, bool multi, bool ltr)
        {
            var l = UI.Text(label, 12.5, "Muted"); l.Margin = new Thickness(2, 14, 0, 6);
            parent.Children.Add(l);
            var tb = new TextBox { AcceptsReturn = multi, TextWrapping = multi ? TextWrapping.Wrap : TextWrapping.NoWrap, MinHeight = multi ? 90 : 0, VerticalContentAlignment = VerticalAlignment.Top };
            if (ltr) tb.FlowDirection = FlowDirection.LeftToRight;
            parent.Children.Add(tb);
            return tb;
        }

        // ------------------------------------------------------------------ announcements (everyone)
        async void LoadNews(Panel host)
        {
            var items = await Task.Run(() => { try { return License.News(); } catch { return new List<Dictionary<string, object>>(); } });
            foreach (var n in items)
            {
                string title = Convert.ToString(n.ContainsKey("title") ? n["title"] : "");
                string body = Convert.ToString(n.ContainsKey("body") ? n["body"] : "");
                var g = new DockPanel();
                var ic = UI.Icon("", 18); ic.Margin = new Thickness(0, 0, 14, 0); ic.VerticalAlignment = VerticalAlignment.Top;
                g.Children.Add(ic);
                var t = new StackPanel();
                t.Children.Add(UI.Text(title, 14.5, "Text", true));
                if (body != "") { var b = UI.Text(body, 12.5, "Muted"); b.Margin = new Thickness(0, 4, 0, 0); t.Children.Add(b); }
                g.Children.Add(t);
                var card = UI.Card(g, 16);
                card.BorderBrush = UI.B("Accent"); card.Margin = new Thickness(0, 0, 0, 12);
                host.Children.Add(card);
                Fx.Enter(card);
            }
        }
    }
}
