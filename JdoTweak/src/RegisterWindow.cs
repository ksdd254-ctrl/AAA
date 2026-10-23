using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace JdoTweak
{
    // New account from inside the app: email + password -> emailed code -> signed in.
    // New accounts have no plan; the admin gives them one from the Owner Panel.
    public class RegisterWindow : Window
    {
        TextBox email, code;
        PasswordBox pass, pass2;
        TextBlock error, info;
        Button go;
        bool codeStep;

        public RegisterWindow()
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
            var t = UI.Text(L.T(codeStep ? "regCodeTitle" : "regTitle"), 22, "Text", true); t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 14, 0, 4);
            sp.Children.Add(t);
            info = UI.Text(codeStep ? string.Format(L.T("regCodeSent"), email.Text.Trim()) : L.T("regSub"), 12.5, "Muted");
            info.HorizontalAlignment = HorizontalAlignment.Center; info.TextAlignment = TextAlignment.Center; info.Margin = new Thickness(0, 0, 0, 24);
            sp.Children.Add(info);

            if (!codeStep)
            {
                string keep = email == null ? "" : email.Text;
                email = new TextBox { FlowDirection = FlowDirection.LeftToRight, Text = keep };
                pass = new PasswordBox { FlowDirection = FlowDirection.LeftToRight };
                pass2 = new PasswordBox { FlowDirection = FlowDirection.LeftToRight };
                sp.Children.Add(Field(L.T("email"), email));
                sp.Children.Add(Field(L.T("password") + "  " + L.T("passRule"), pass));
                sp.Children.Add(Field(L.T("passAgain"), pass2));
                pass2.KeyDown += async (o, e) => { if (e.Key == Key.Enter) await Next(); };
            }
            else
            {
                code = new TextBox { FlowDirection = FlowDirection.LeftToRight, FontFamily = new FontFamily("Consolas"), FontSize = 22, MaxLength = 6, TextAlignment = TextAlignment.Center };
                sp.Children.Add(Field(L.T("regCode"), code));
                code.KeyDown += async (o, e) => { if (e.Key == Key.Enter) await Next(); };
                var resend = UI.Text(L.T("regResend"), 12.5, "Accent"); resend.Cursor = Cursors.Hand; resend.Margin = new Thickness(2, -6, 0, 12);
                resend.MouseLeftButtonUp += async (o, e) =>
                {
                    string em = email.Text.Trim();
                    await Task.Run(() => License.Resend(em));
                    info.Text = string.Format(L.T("regCodeSent"), em);
                };
                sp.Children.Add(resend);
            }

            error = UI.Text("", 12.5, "Bad"); error.Margin = new Thickness(2, 0, 0, 10); error.Visibility = Visibility.Collapsed;
            sp.Children.Add(error);
            go = UI.Btn(L.T(codeStep ? "regConfirm" : "regCreate"), "Primary", async (o, e) => await Next());
            go.Padding = new Thickness(0, 12, 0, 12);
            sp.Children.Add(go);

            var back = UI.Text(L.T(codeStep ? "regBackEdit" : "regHaveAccount"), 12.5, "Muted");
            back.HorizontalAlignment = HorizontalAlignment.Center; back.Margin = new Thickness(0, 18, 0, 0); back.Cursor = Cursors.Hand;
            back.MouseLeftButtonUp += (o, e) => { if (codeStep) { codeStep = false; Build(); } else App.SwitchTo(new LoginWindow(), this); };
            sp.Children.Add(back);

            var note = UI.Text(L.T("regNoPlan"), 11.5, "Muted"); note.HorizontalAlignment = HorizontalAlignment.Center; note.TextAlignment = TextAlignment.Center; note.Margin = new Thickness(0, 22, 0, 0);
            sp.Children.Add(note);

            root.Children.Add(sp);
            Content = root;
        }

        void Fail(string key)
        {
            error.Text = L.T(key);
            error.Visibility = Visibility.Visible;
        }

        static string ErrKey(string err)
        {
            switch (err)
            {
                case "exists": return "regExists";
                case "email": return "regBadEmail";
                case "password": return "regBadPass";
                case "code": return "regBadCode";
                case "mail": return "regMailFail";
                case "network": return "netErr";
                default: return "regFailed";
            }
        }

        async Task Next()
        {
            error.Visibility = Visibility.Collapsed;
            string em = email.Text.Trim();
            if (!codeStep)
            {
                if (pass.Password.Length < 8) { Fail("regBadPass"); return; }
                if (pass.Password != pass2.Password) { Fail("regMismatch"); return; }
                string p = pass.Password;
                go.IsEnabled = false;
                string err = await Task.Run(() => License.Register(em, p));
                go.IsEnabled = true;
                if (err != null) { Fail(ErrKey(err)); return; }
                passwordKept = p;
                codeStep = true;
                Build();
                code.Focus();
                return;
            }
            string c = code.Text.Trim();
            if (c.Length != 6) { Fail("regBadCode"); return; }
            go.IsEnabled = false;
            string cerr = await Task.Run(() => License.Confirm(em, c));
            if (cerr != null) { go.IsEnabled = true; Fail(ErrKey(cerr)); return; }
            // Verified: sign straight in (no key - the account starts without a plan).
            string pw = passwordKept, hw = App.Hardware.Hwid();
            var r = await Task.Run(() => License.Login(em, pw, "", hw));
            go.IsEnabled = true;
            if (r == License.Result.Ok) App.SwitchTo(new MainWindow(), this);
            else App.SwitchTo(new LoginWindow(), this);
        }

        string passwordKept;
    }
}
