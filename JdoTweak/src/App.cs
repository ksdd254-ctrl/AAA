using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Principal;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Markup;

namespace JdoTweak
{
    public static class App
    {
        public const string Version = "1.0.0";
        // The site and the license server share one domain, so links follow the build's -Api address.
        public static string Website { get { return string.IsNullOrEmpty(License.ApiBase) ? "https://jdo-tweak.com" : License.ApiBase.TrimEnd('/'); } }

        public static Catalog Catalog;
        public static HardwareInfo Hardware;
        public static Task<HardwareInfo> HardwareTask;
        public static Application Wpf;

        [STAThread]
        public static void Main(string[] args)
        {
#if DEV
            if (args.Length >= 2 && args[0] == "--snap") { Snapshot(args[1], args.Length > 2 && args[2] == "en"); return; }
            if (args.Length >= 2 && args[0] == "--selftest")
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                Catalog = LoadCatalog();
                File.WriteAllText(args[1] + ".load", "catalog load ms: " + sw.ElapsedMilliseconds);
                Environment.Exit(SelfTest.Run(args[1]));
            }
#endif
            if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
            {
                MessageBox.Show("Please run JDO Tweak as administrator.\nشغّل البرنامج كمسؤول.", "JDO Tweak", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            Wpf = new Application { ShutdownMode = ShutdownMode.OnLastWindowClose };
            using (var s = Res("Theme.xaml")) Wpf.Resources = (ResourceDictionary)XamlReader.Load(s);
            Wpf.DispatcherUnhandledException += (o, e) =>
            {
                MessageBox.Show(e.Exception.Message, "JDO Tweak", MessageBoxButton.OK, MessageBoxImage.Error);
                e.Handled = true;
            };
            L.Load();
            Themes.Load();
            EnsureShortcuts();

            HardwareTask = Task.Run(() => HardwareInfo.Read());
            Catalog = LoadCatalog();

            // Resume a saved session, otherwise ask the user to sign in.
            Hardware = HardwareTask.Result;
            var r = License.Resume(Hardware.Hwid());
            Window first = r == License.Result.Ok ? (Window)new MainWindow() : new LoginWindow();
            Wpf.Run(first);
        }

        // First run: put the app on the desktop and in the Start menu, pointing at wherever the EXE lives.
        static void EnsureShortcuts()
        {
            const string k = @"HKEY_CURRENT_USER\Software\JdoTweak";
            string exe = System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName;
            try
            {
                if (string.Equals(Microsoft.Win32.Registry.GetValue(k, "ShortcutTarget", null) as string, exe, StringComparison.OrdinalIgnoreCase)) return;
                string name = "JDO Tweak.lnk";   // WScript.Shell cannot save non-ANSI (Arabic) file names
                var shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
                foreach (var dir in new[] { Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Environment.GetFolderPath(Environment.SpecialFolder.Programs) })
                {
                    dynamic lnk = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { Path.Combine(dir, name) });
                    lnk.TargetPath = exe;
                    lnk.WorkingDirectory = Path.GetDirectoryName(exe);
                    lnk.IconLocation = exe + ",0";
                    lnk.Description = "JDO Al-Shayeb Tweak";
                    lnk.Save();
                }
                Microsoft.Win32.Registry.SetValue(k, "ShortcutTarget", exe);
            }
            catch (Exception ex) { try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "jdo_shortcut.log"), ex.ToString()); } catch { } }
        }

        public static Stream Res(string name)
        {
            var asm = Assembly.GetExecutingAssembly();
            foreach (var n in asm.GetManifestResourceNames())
                if (n.EndsWith(name, StringComparison.OrdinalIgnoreCase)) return asm.GetManifestResourceStream(n);
            return null;
        }

        static string ReadRes(string name, bool gz)
        {
            var s = Res(name);
            if (s == null) return null;
            using (s)
            using (var r = new StreamReader(gz ? (Stream)new GZipStream(s, CompressionMode.Decompress) : s))
                return r.ReadToEnd();
        }

        static Catalog LoadCatalog()
        {
            var c = Catalog.Parse(ReadRes("tweaks.json", false));
            var s = Res("library.tsv.gz");
            if (s != null)
                using (s)
                using (var r = new StreamReader(new GZipStream(s, CompressionMode.Decompress)))
                    c.LoadTsv(r);
            return c;
        }

#if DEV
        // Renders every page to PNG off-screen so the UI can be checked without a display.
        static void Snapshot(string dir, bool english)
        {
            Wpf = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            using (var s = Res("Theme.xaml")) Wpf.Resources = (ResourceDictionary)XamlReader.Load(s);
            L.Ar = !english;
            Themes.Load();
            Hardware = HardwareInfo.Read();
            Catalog = LoadCatalog();
            License.Login(null, null, null, Hardware.Hwid());
            Directory.CreateDirectory(dir);
            var pages = new[] { "login", "register", "dashboard", "cat:windows", "cat:intel", "cat:amd", "cat:mouse", "cat:network", "cat:advanced", "repair", "polling", "account", "settings", "owner" };
            int i = 0;
            Window w = null;
            var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
            t.Tick += (o, e) =>
            {
                if (w != null)
                {
                    var root = (FrameworkElement)w.Content;
                    var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap((int)root.ActualWidth, (int)root.ActualHeight, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                    // Draw through a VisualBrush so right-to-left layouts aren't mirrored in the image.
                    var dv = new System.Windows.Media.DrawingVisual();
                    using (var dc = dv.RenderOpen())
                    {
                        var r = new Rect(0, 0, root.ActualWidth, root.ActualHeight);
                        dc.DrawRectangle(w.Background, null, r);
                        if (w.FlowDirection == FlowDirection.RightToLeft) dc.PushTransform(new System.Windows.Media.MatrixTransform(-1, 0, 0, 1, r.Width, 0));
                        dc.DrawRectangle(new System.Windows.Media.VisualBrush(root), null, r);
                    }
                    bmp.Render(dv);
                    var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                    enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
                    using (var f = File.Create(Path.Combine(dir, (i - 1).ToString("00") + "_" + pages[i - 1].Replace(":", "_") + ".png"))) enc.Save(f);
                }
                if (i >= pages.Length) { t.Stop(); Wpf.Shutdown(); return; }
                if (pages[i] == "login" || pages[i] == "register") { if (w != null) w.Close(); w = pages[i] == "login" ? (Window)new LoginWindow() : new RegisterWindow(); w.Left = -20000; w.Show(); }
                else
                {
                    if (!(w is MainWindow)) { if (w != null) w.Close(); w = new MainWindow { Left = -20000, WindowStartupLocation = WindowStartupLocation.Manual }; w.Show(); }
                    ((MainWindow)w).Navigate(pages[i]);
                }
                i++;
            };
            t.Start();
            Wpf.Run();
        }
#endif

        public static void SwitchTo(Window next, Window current)
        {
            next.Show();
            current.Close();
        }
    }
}
