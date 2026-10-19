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
            sp.Children.Add(UI.Gap(14));

            // users & keys live on the website admin
            var web = new DockPanel();
            var open = UI.IconBtn("", L.T("openAdmin"), "Ghost", (o, e) => { try { System.Diagnostics.Process.Start(App.Website + "/admin"); } catch { } });
            DockPanel.SetDock(open, Dock.Right); web.Children.Add(open);
            var wt = new StackPanel();
            wt.Children.Add(UI.Text(L.T("usersKeys"), 15, "Text", true));
            wt.Children.Add(UI.Text(L.T("usersKeysD"), 12.5, "Muted"));
            web.Children.Add(wt);
            sp.Children.Add(UI.Card(web));
            return Page(sp);
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
