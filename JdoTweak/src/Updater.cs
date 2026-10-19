using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Web.Script.Serialization;

namespace JdoTweak
{
    // Checks the license server for a newer build, downloads it, verifies its
    // SHA-256 and swaps the running EXE. New tweaks ship inside each build.
    public static class Updater
    {
        static Dictionary<string, object> latest;

        public static string Check()
        {
            latest = null;
            if (string.IsNullOrEmpty(License.ApiBase)) return null;
            try
            {
                using (var wc = new WebClient())
                {
                    wc.Headers[HttpRequestHeader.UserAgent] = "JdoTweak/" + App.Version;
                    if (License.Current != null) wc.Headers[HttpRequestHeader.Authorization] = "Bearer " + License.Current.Token;
                    var d = new JavaScriptSerializer().DeserializeObject(wc.DownloadString(License.ApiBase.TrimEnd('/') + "/api/app/latest")) as Dictionary<string, object>;
                    if (d == null) return null;
                    var v = Convert.ToString(d["version"]);
                    if (new Version(v) <= new Version(App.Version)) return null;
                    latest = d;
                    return v;
                }
            }
            catch { return null; }
        }

        public static void Install()
        {
            if (latest == null) return;
            string tmp = Path.Combine(Path.GetTempPath(), "JdoTweak_update.exe");
            using (var wc = new WebClient())
            {
                if (License.Current != null) wc.Headers[HttpRequestHeader.Authorization] = "Bearer " + License.Current.Token;
                wc.DownloadFile(Convert.ToString(latest["url"]), tmp);
            }
            string want = Convert.ToString(latest["sha256"]).ToLowerInvariant();
            using (var sha = SHA256.Create())
            using (var f = File.OpenRead(tmp))
            {
                string got = BitConverter.ToString(sha.ComputeHash(f)).Replace("-", "").ToLowerInvariant();
                if (got != want) { File.Delete(tmp); throw new InvalidDataException("Update checksum mismatch"); }
            }
            string self = Process.GetCurrentProcess().MainModule.FileName;
            string cmd = Path.Combine(Path.GetTempPath(), "jdo_update.cmd");
            File.WriteAllText(cmd,
                "@echo off\r\n" +
                "timeout /t 2 /nobreak >nul\r\n" +
                ":retry\r\n" +
                "copy /y \"" + tmp + "\" \"" + self + "\" >nul || (timeout /t 1 >nul & goto retry)\r\n" +
                "del \"" + tmp + "\"\r\n" +
                "start \"\" \"" + self + "\"\r\n" +
                "del \"%~f0\"\r\n");
            Process.Start(new ProcessStartInfo("cmd.exe", "/c \"" + cmd + "\"") { CreateNoWindow = true, UseShellExecute = false });
            Environment.Exit(0);
        }
    }
}
