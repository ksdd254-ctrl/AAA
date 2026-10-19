using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shell;

namespace JdoTweak
{
    // Small helpers so pages read like layout, not plumbing.
    public static class UI
    {
        public static Brush B(string key) { return (Brush)Application.Current.Resources[key]; }
        public static Style S(string key) { return (Style)Application.Current.Resources[key]; }
        public static SolidColorBrush Hex(string hex) { return new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); }

        public static TextBlock Text(string s, double size = 13, string brush = "Text", bool bold = false)
        {
            return new TextBlock { Text = s, FontSize = size, Foreground = B(brush), FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap };
        }

        public static TextBlock Icon(string glyph, double size = 16, string brush = "Accent")
        {
            return new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = size, Foreground = B(brush), VerticalAlignment = VerticalAlignment.Center };
        }

        public static Border Card(UIElement child, double pad = 18)
        {
            var b = new Border { Background = B("Card"), CornerRadius = new CornerRadius(14), Padding = new Thickness(pad), Child = child, BorderBrush = B("Line"), BorderThickness = new Thickness(1), RenderTransform = new TranslateTransform() };
            Fx.Hover(b);
            return b;
        }

        public static Button Btn(string text, string style, RoutedEventHandler click)
        {
            var b = new Button { Content = text, Style = S(style) };
            if (click != null) b.Click += click;
            return b;
        }

        public static Button IconBtn(string glyph, string text, string style, RoutedEventHandler click)
        {
            var sp = new StackPanel { Orientation = Orientation.Horizontal };
            sp.Children.Add(new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 13, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
            sp.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
            var b = new Button { Content = sp, Style = S(style) };
            if (click != null) b.Click += click;
            return b;
        }

        public static Border Badge(string text, string fg, string bg)
        {
            return new Border
            {
                Background = Hex(bg), CornerRadius = new CornerRadius(6), Padding = new Thickness(7, 2, 7, 2), Margin = new Thickness(6, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = text, FontSize = 10.5, Foreground = Hex(fg), FontWeight = FontWeights.SemiBold }
            };
        }

        public static Border TierBadge(int tier)
        {
            if (tier == 3) return Badge(L.T("tier3"), "#FFD36B", "#33F5B841");
            if (tier == 2) return Badge(L.T("tier2"), "#9DB8FF", "#262F5BFF");
            return Badge(L.T("tier1"), "#7BE0B0", "#1F3DD68C");
        }

        public static FrameworkElement Gap(double h) { return new Border { Height = h }; }

        // Themed yes/no or OK dialog.
        public static bool Ask(Window owner, string title, string body, bool yesNo, bool danger = false)
        {
            var w = new Window
            {
                Owner = owner, Width = 440, SizeToContent = SizeToContent.Height, WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
                WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = B("Side"), FlowDirection = L.Ar ? FlowDirection.RightToLeft : FlowDirection.LeftToRight,
                FontFamily = new FontFamily("Segoe UI"), ShowInTaskbar = false, AllowsTransparency = false
            };
            WindowChrome.SetWindowChrome(w, new WindowChrome { CaptionHeight = 0, ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(0) });
            bool result = false;
            var sp = new StackPanel { Margin = new Thickness(26) };
            var head = new StackPanel { Orientation = Orientation.Horizontal };
            head.Children.Add(Icon(danger ? "" : "", 20, danger ? "Bad" : "Accent"));
            var t = Text(title, 17, "Text", true); t.Margin = new Thickness(10, 0, 0, 0); t.VerticalAlignment = VerticalAlignment.Center;
            head.Children.Add(t);
            sp.Children.Add(head);
            var b = Text(body, 13.5, "Muted"); b.Margin = new Thickness(0, 14, 0, 22); b.LineHeight = 21;
            sp.Children.Add(b);
            var btns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
            if (yesNo)
            {
                var no = Btn(L.T("no"), "Ghost", (o, e) => w.Close()); no.Margin = new Thickness(0, 0, 10, 0);
                btns.Children.Add(no);
            }
            btns.Children.Add(Btn(yesNo ? L.T("yes") : L.T("ok"), "Primary", (o, e) => { result = true; w.Close(); }));
            sp.Children.Add(btns);
            w.Content = new Border { BorderBrush = B("Line"), BorderThickness = new Thickness(1), Child = sp };
            w.MouseLeftButtonDown += (o, e) => { try { w.DragMove(); } catch { } };
            w.ShowDialog();
            return result;
        }

        // Shared custom title bar (drag area + min / max / close).
        public static Grid TitleBar(Window w, bool canMax)
        {
            var g = new Grid { Height = 40, Background = Brushes.Transparent, VerticalAlignment = VerticalAlignment.Top };
            var btns = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, FlowDirection = FlowDirection.LeftToRight };
            Func<string, RoutedEventHandler, Button> mk = (glyph, h) =>
            {
                var b = new Button { Content = glyph, Style = S("Chrome") };
                WindowChrome.SetIsHitTestVisibleInChrome(b, true);
                b.Click += h;
                return b;
            };
            btns.Children.Add(mk("", (o, e) => w.WindowState = WindowState.Minimized));
            if (canMax) btns.Children.Add(mk("", (o, e) => w.WindowState = w.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized));
            var close = mk("", (o, e) => w.Close());
            close.MouseEnter += (o, e) => close.Background = Hex("#E81123");
            btns.Children.Add(close);
            g.Children.Add(btns);
            return g;
        }

        public static void Chrome(Window w)
        {
            WindowChrome.SetWindowChrome(w, new WindowChrome
            {
                CaptionHeight = 40, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = new Thickness(0),
                CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false
            });
        }

        public static FrameworkElement Logo(double size)
        {
            var g = new Grid { Width = size, Height = size };
            g.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(size * 0.28),
                Background = Fx.Shimmer(),
                Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Themes.AccentColor, BlurRadius = size * 0.45, ShadowDepth = 0, Opacity = 0.5 }
            });
            g.Children.Add(new TextBlock
            {
                Text = "ج", FontSize = size * 0.6, FontWeight = FontWeights.Bold, Foreground = B("OnAccent"),
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, -size * 0.08, 0, 0)
            });
            return g;
        }
    }

    // ------------------------------------------------------------------
    public class LoginWindow : Window
    {
        TextBox email, key;
        PasswordBox pass;
        TextBlock error;
        Button go;

        public LoginWindow()
        {
            Title = L.T("app");
            Width = 460; Height = 740; ResizeMode = ResizeMode.CanMinimize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = UI.B("Bg"); FontFamily = new FontFamily("Segoe UI");
            UI.Chrome(this);
            Build();
            L.Changed += Build;
            Closed += (o, e) => L.Changed -= Build;
        }

        void Build()
        {
            FlowDirection = L.Ar ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
            var root = new Grid();
            root.Children.Add(UI.TitleBar(this, false));

            var sp = new StackPanel { Margin = new Thickness(44, 56, 44, 30), VerticalAlignment = VerticalAlignment.Top };
            var logo = UI.Logo(64); logo.HorizontalAlignment = HorizontalAlignment.Center;
            sp.Children.Add(logo);
            var t = UI.Text(L.T("app"), 24, "Text", true); t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 16, 0, 2);
            sp.Children.Add(t);
            var tg = UI.Text(L.T("tagline"), 13, "Accent"); tg.HorizontalAlignment = HorizontalAlignment.Center; tg.Margin = new Thickness(0, 0, 0, 30);
            sp.Children.Add(tg);

            Func<string, Control, FrameworkElement> field = (label, box) =>
            {
                var f = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
                var l = UI.Text(label, 12.5, "Muted"); l.Margin = new Thickness(2, 0, 0, 6);
                f.Children.Add(l); f.Children.Add(box);
                return f;
            };
            email = new TextBox { FlowDirection = FlowDirection.LeftToRight };
            pass = new PasswordBox { FlowDirection = FlowDirection.LeftToRight };
            key = new TextBox { FlowDirection = FlowDirection.LeftToRight, CharacterCasing = CharacterCasing.Upper, FontFamily = new FontFamily("Consolas") };
            sp.Children.Add(field(L.T("email"), email));
            sp.Children.Add(field(L.T("password"), pass));
            sp.Children.Add(field(L.T("licenseKey"), key));
            var kh = UI.Text(L.T("keyHint"), 11.5, "Muted"); kh.Margin = new Thickness(2, -8, 0, 12);
            sp.Children.Add(kh);

            error = UI.Text("", 12.5, "Bad"); error.Margin = new Thickness(2, 0, 0, 10); error.Visibility = Visibility.Collapsed;
            sp.Children.Add(error);

            go = UI.Btn(L.T("activate"), "Primary", async (o, e) => await Submit());
            go.Padding = new Thickness(0, 12, 0, 12);
            sp.Children.Add(go);
            pass.KeyDown += async (o, e) => { if (e.Key == Key.Enter) await Submit(); };
            key.KeyDown += async (o, e) => { if (e.Key == Key.Enter) await Submit(); };

            var link = UI.Text(L.T("noAccount"), 12.5, "Accent");
            link.HorizontalAlignment = HorizontalAlignment.Center; link.Margin = new Thickness(0, 18, 0, 0); link.Cursor = Cursors.Hand;
            link.TextDecorations = TextDecorations.Underline;
            link.MouseLeftButtonUp += (o, e) => { try { System.Diagnostics.Process.Start(App.Website); } catch { } };
            sp.Children.Add(link);
            var forgot = UI.Text(L.T("forgotPass"), 12.5, "Muted");
            forgot.HorizontalAlignment = HorizontalAlignment.Center; forgot.Margin = new Thickness(0, 10, 0, 0); forgot.Cursor = Cursors.Hand;
            forgot.MouseLeftButtonUp += (o, e) => { try { System.Diagnostics.Process.Start(App.Website + "/account"); } catch { } };
            sp.Children.Add(forgot);

            var lang = UI.Text(L.Ar ? "English" : "عربي", 12.5, "Muted");
            lang.HorizontalAlignment = HorizontalAlignment.Center; lang.Margin = new Thickness(0, 14, 0, 0); lang.Cursor = Cursors.Hand;
            lang.MouseLeftButtonUp += (o, e) => L.Set(!L.Ar);
            sp.Children.Add(lang);

            var hw = UI.Text(L.T("hwid") + ": " + App.Hardware.Hwid(), 11, "Muted");
            hw.HorizontalAlignment = HorizontalAlignment.Center; hw.Margin = new Thickness(0, 22, 0, 0); hw.FontFamily = new FontFamily("Consolas");
            hw.FlowDirection = FlowDirection.LeftToRight;
            sp.Children.Add(hw);
            if (License.DevBuild) { var d = UI.Text(L.T("devMode"), 11, "Warn"); d.HorizontalAlignment = HorizontalAlignment.Center; sp.Children.Add(d); }

            root.Children.Add(sp);
            Content = root;
        }

        async System.Threading.Tasks.Task Submit()
        {
            go.IsEnabled = false; error.Visibility = Visibility.Collapsed;
            string e = email.Text.Trim(), p = pass.Password, k = key.Text.Trim(), h = App.Hardware.Hwid();
            var r = await System.Threading.Tasks.Task.Run(() => License.Login(e, p, k, h));
            go.IsEnabled = true;
            if (r == License.Result.Ok) { App.SwitchTo(new MainWindow(), this); return; }
            error.Text = r == License.Result.HwidMismatch ? L.T("hwidErr")
                       : r == License.Result.Network ? L.T("netErr")
                       : r == License.Result.Expired ? L.T("expiredErr")
                       : r == License.Result.Locked ? L.T("lockedErr")
                       : L.T("loginErr");
            error.Visibility = Visibility.Visible;
        }
    }
}
