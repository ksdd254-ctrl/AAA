using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace JdoTweak
{
    // Forgotten password: email -> emailed code + new password -> signed in.
    public class ResetWindow : Window
    {
        TextBox email, code;
        PasswordBox pass, pass2;
        TextBlock error;
        Button go;
        bool codeStep;

        public ResetWindow()
        {
            Title = L.T("app");
            Width = 460; Height = 700; ResizeMode = ResizeMode.CanMinimize;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Background = UI.B("Bg"); FontFamily = new FontFamily("Segoe UI");
            UI.Chrome(this);
            Build();
        }

        static FrameworkElement Field(string label, Control box)
        {
            var f = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
            var l = UI.Text(label, 12.5, "Muted"); l.Margin = new Thickness(2, 0, 0, 6);
            f.Children.Add(l); f.Children.Add(box);
            return f;
        }

        void Build()
        {
            FlowDirection = L.Ar ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
            var root = new Grid();
            root.Children.Add(UI.TitleBar(this, false));
            var sp = new StackPanel { Margin = new Thickness(44, 56, 44, 30), VerticalAlignment = VerticalAlignment.Top };
            var logo = UI.Logo(56); logo.HorizontalAlignment = HorizontalAlignment.Center;
            sp.Children.Add(logo);
            var t = UI.Text(L.T("resetTitle"), 22, "Text", true); t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 14, 0, 4);
            sp.Children.Add(t);
            var info = UI.Text(codeStep ? string.Format(L.T("regCodeSent"), email.Text.Trim()) : L.T("resetSub"), 12.5, "Muted");
            info.HorizontalAlignment = HorizontalAlignment.Center; info.TextAlignment = TextAlignment.Center; info.Margin = new Thickness(0, 0, 0, 24);
            sp.Children.Add(info);

            if (!codeStep)
            {
                string keep = email == null ? "" : email.Text;
                email = new TextBox { FlowDirection = FlowDirection.LeftToRight, Text = keep };
                sp.Children.Add(Field(L.T("email"), email));
                email.KeyDown += async (o, e) => { if (e.Key == Key.Enter) await Next(); };
            }
            else
            {
                code = new TextBox { FlowDirection = FlowDirection.LeftToRight, FontFamily = new FontFamily("Consolas"), FontSize = 22, MaxLength = 6, TextAlignment = TextAlignment.Center };
                pass = new PasswordBox { FlowDirection = FlowDirection.LeftToRight };
                pass2 = new PasswordBox { FlowDirection = FlowDirection.LeftToRight };
                sp.Children.Add(Field(L.T("regCode"), code));
                sp.Children.Add(Field(L.T("newPass") + "  " + L.T("passRule"), pass));
                sp.Children.Add(Field(L.T("passAgain"), pass2));
                pass2.KeyDown += async (o, e) => { if (e.Key == Key.Enter) await Next(); };
            }

            error = UI.Text("", 12.5, "Bad"); error.Margin = new Thickness(2, 0, 0, 10); error.Visibility = Visibility.Collapsed;
            sp.Children.Add(error);
            go = UI.Btn(L.T(codeStep ? "resetSave" : "resetSend"), "Primary", async (o, e) => await Next());
            go.Padding = new Thickness(0, 12, 0, 12);
            sp.Children.Add(go);

            var back = UI.Text(L.T(codeStep ? "regBackEdit" : "regHaveAccount"), 12.5, "Muted");
            back.HorizontalAlignment = HorizontalAlignment.Center; back.Margin = new Thickness(0, 18, 0, 0); back.Cursor = Cursors.Hand;
            back.MouseLeftButtonUp += (o, e) => { if (codeStep) { codeStep = false; Build(); } else App.SwitchTo(new LoginWindow(), this); };
            sp.Children.Add(back);

            root.Children.Add(sp);
            Content = root;
        }

        void Fail(string key) { error.Text = L.T(key); error.Visibility = Visibility.Visible; }

        async Task Next()
        {
            error.Visibility = Visibility.Collapsed;
            string em = email.Text.Trim();
            if (!codeStep)
            {
                go.IsEnabled = false;
                string err = await Task.Run(() => License.Forgot(em));
                go.IsEnabled = true;
                if (err == "email") { Fail("regBadEmail"); return; }
                if (err != null) { Fail(err == "network" ? "netErr" : err == "mail" ? "regMailFail" : "regFailed"); return; }
                codeStep = true;
                Build();
                code.Focus();
                return;
            }
            string c = code.Text.Trim(), p = pass.Password;
            if (c.Length != 6) { Fail("regBadCode"); return; }
            if (p.Length < 8) { Fail("regBadPass"); return; }
            if (p != pass2.Password) { Fail("regMismatch"); return; }
            go.IsEnabled = false;
            string rerr = await Task.Run(() => License.Reset(em, c, p));
            if (rerr != null) { go.IsEnabled = true; Fail(rerr == "code" ? "regBadCode" : rerr == "network" ? "netErr" : "regFailed"); return; }
            string hw = App.Hardware.Hwid();
            var r = await Task.Run(() => License.Login(em, p, "", hw));
            go.IsEnabled = true;
            if (r == License.Result.Ok) App.SwitchTo(new MainWindow(), this);
            else App.SwitchTo(new LoginWindow(), this);
        }
    }
}
