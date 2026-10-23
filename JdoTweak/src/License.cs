using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace JdoTweak
{
    // WebClient has no timeout of its own; without one a dead server freezes sign-in for 100 seconds.
    public class TimeoutClient : WebClient
    {
        protected override WebRequest GetWebRequest(Uri address)
        {
            var r = base.GetWebRequest(address);
            if (r != null) r.Timeout = 10000;
            return r;
        }
    }

    public class Session
    {
        public string Email, Token, Key;
        public string LiteUrl;
        public string Role = "user";   // user | owner (owner can post news and releases)
        public bool IsOwner { get { return Role == "owner" || Role == "admin"; } }
        public int Tier;            // 1 Basic, 2 Elite, 3 Ultimate
        public DateTime? Expires;   // null = lifetime
        public bool WithLiteWindows;
        public string PlanName { get { return Tier <= 0 ? L.T("noPlan") : L.T("tier" + Math.Min(3, Tier)); } }
        public bool HasPlan { get { return Tier > 0; } }
    }

    // Talks to the JDO license server. The server owns every decision
    // (key valid, bound HWID, expiry, locked, tier) so nothing in the
    // client can be patched to unlock a higher plan on its own.
    public static class License
    {
        // Set to your server address once it's deployed (see server/README).
        public const string ApiBase = BuildInfo.ApiBase;

        static readonly string File = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "JdoTweak", "session.bin");
        static readonly byte[] Entropy = Encoding.UTF8.GetBytes("JDO-Session-v1");

        public static Session Current;

        public static bool DevBuild
        {
            get
            {
#if DEV
                return true;
#else
                return false;
#endif
            }
        }

        public enum Result { Ok, BadCredentials, HwidMismatch, Expired, Locked, Network }

        public static Result Login(string email, string password, string key, string hwid)
        {
            if (DevBuild && string.IsNullOrEmpty(ApiBase))
            {
                Current = new Session { Email = string.IsNullOrEmpty(email) ? "dev@jdo.local" : email, Tier = 3, Token = "dev", Key = "DEV", Role = "owner", WithLiteWindows = true };
                return Result.Ok;
            }
            var r = Post("/api/client/login", new Dictionary<string, object> { { "email", email }, { "password", password }, { "key", key }, { "hwid", hwid }, { "version", App.Version } });
            return Accept(r, key);
        }

        // Re-checks the saved session with the server on every launch.
        public static Result Resume(string hwid)
        {
            if (DevBuild && string.IsNullOrEmpty(ApiBase)) return Login(null, null, null, hwid);
            var saved = LoadSaved();
            if (saved == null) return Result.BadCredentials;
            var r = Post("/api/client/verify", new Dictionary<string, object> { { "token", saved.Token }, { "hwid", hwid }, { "version", App.Version } });
            return Accept(r, saved.Key);
        }

        static Result Accept(Dictionary<string, object> r, string key)
        {
            if (r == null) return Result.Network;
            object ok;
            if (!r.TryGetValue("ok", out ok) || !(ok is bool) || !(bool)ok)
            {
                string err = r.ContainsKey("error") ? Convert.ToString(r["error"]) : "";
                if (err == "hwid") return Result.HwidMismatch;
                if (err == "expired") return Result.Expired;
                if (err == "locked") return Result.Locked;
                return Result.BadCredentials;
            }
            Current = new Session
            {
                Email = Convert.ToString(r["email"]),
                Token = Convert.ToString(r["token"]),
                Tier = Convert.ToInt32(r["tier"]),
                Key = key,
                WithLiteWindows = r.ContainsKey("lite") && r["lite"] is bool && (bool)r["lite"],
                Role = r.ContainsKey("role") ? Convert.ToString(r["role"]) : "user",
                LiteUrl = r.ContainsKey("liteUrl") ? Convert.ToString(r["liteUrl"]) : null,
            };
            if (r.ContainsKey("expires") && r["expires"] != null)
            {
                DateTime d;
                if (DateTime.TryParse(Convert.ToString(r["expires"]), null, System.Globalization.DateTimeStyles.RoundtripKind, out d)) Current.Expires = d;
            }
            Save(Current);
            return Result.Ok;
        }

        public static void Logout()
        {
            try { if (System.IO.File.Exists(File)) System.IO.File.Delete(File); } catch { }
            Current = null;
        }

        // Authenticated call for the owner dashboard (news / releases). The server checks the role.
        public static Dictionary<string, object> OwnerPost(string path, Dictionary<string, object> body)
        {
            if (Current == null) return null;
            body["token"] = Current.Token;
            return Post(path, body);
        }

        // ---------------- sign-up from the app
        // Returns null on success, otherwise the server's error word (exists, email, password, code, mail) or "network".
        public static string Register(string email, string password)
        {
            if (string.IsNullOrEmpty(ApiBase)) return DevBuild ? null : "network";
            return ErrorOf(Post("/api/client/register", new Dictionary<string, object> { { "email", email }, { "password", password } }));
        }

        public static string Confirm(string email, string code)
        {
            if (string.IsNullOrEmpty(ApiBase)) return DevBuild ? null : "network";
            return ErrorOf(Post("/api/client/confirm", new Dictionary<string, object> { { "email", email }, { "code", code } }));
        }

        public static string Forgot(string email)
        {
            return ErrorOf(Post("/api/client/forgot", new Dictionary<string, object> { { "email", email } }));
        }

        public static string Reset(string email, string code, string password)
        {
            return ErrorOf(Post("/api/client/reset", new Dictionary<string, object> { { "email", email }, { "code", code }, { "password", password } }));
        }

        public static void Resend(string email)
        {
            Post("/api/client/resend", new Dictionary<string, object> { { "email", email } });
        }

        static string ErrorOf(Dictionary<string, object> r)
        {
            if (r == null) return "network";
            object ok;
            if (r.TryGetValue("ok", out ok) && ok is bool && (bool)ok) return null;
            return r.ContainsKey("error") ? Convert.ToString(r["error"]) : "server";
        }

        // ---------------- admin: accounts and their plans
        public class Account
        {
            public int Id, Tier;
            public string Email, Role, Expires;
            public bool Lite, Verified, Banned, Ended;
        }

        public static List<Account> OwnerUsers(string q)
        {
            var list = new List<Account>();
            var r = OwnerPost("/api/owner/users", new Dictionary<string, object> { { "q", q ?? "" } });
            if (r == null || !r.ContainsKey("users")) return null;
            foreach (var o in (object[])r["users"])
            {
                var d = o as Dictionary<string, object>;
                if (d == null) continue;
                list.Add(new Account
                {
                    Id = Convert.ToInt32(d["id"]), Email = Convert.ToString(d["email"]), Role = Convert.ToString(d["role"]),
                    Tier = Convert.ToInt32(d["tier"]), Lite = d["lite"] is bool && (bool)d["lite"],
                    Expires = d["expires"] == null ? null : Convert.ToString(d["expires"]),
                    Verified = d["verified"] is bool && (bool)d["verified"], Banned = d["banned"] is bool && (bool)d["banned"],
                    Ended = d["ended"] is bool && (bool)d["ended"],
                });
            }
            return list;
        }

        public static string OwnerSetPlan(int userId, int tier, bool lite, int days)
        {
            return ErrorOf(OwnerPost("/api/owner/plan", new Dictionary<string, object> { { "userId", userId }, { "tier", tier }, { "lite", lite }, { "days", days } }));
        }

        public static List<Dictionary<string, object>> News()
        {
            var list = new List<Dictionary<string, object>>();
            var r = Post("/api/news", new Dictionary<string, object> { { "token", Current != null ? Current.Token : "" }, { "lang", L.Ar ? "ar" : "en" } });
            if (r != null && r.ContainsKey("items"))
                foreach (var o in (object[])r["items"]) { var d = o as Dictionary<string, object>; if (d != null) list.Add(d); }
            return list;
        }

        static Dictionary<string, object> Post(string path, Dictionary<string, object> body)
        {
            if (string.IsNullOrEmpty(ApiBase)) return null;
            try
            {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288; // TLS 1.2 / 1.3
                var js = new JavaScriptSerializer();
                using (var wc = new TimeoutClient())
                {
                    wc.Encoding = Encoding.UTF8;
                    wc.Headers[HttpRequestHeader.ContentType] = "application/json";
                    wc.Headers[HttpRequestHeader.UserAgent] = "JdoTweak/" + App.Version;
                    string resp = wc.UploadString(ApiBase.TrimEnd('/') + path, js.Serialize(body));
                    return js.DeserializeObject(resp) as Dictionary<string, object>;
                }
            }
            catch (WebException ex)
            {
                // 4xx responses still carry a JSON error body
                try
                {
                    if (ex.Response != null)
                        using (var s = new StreamReader(ex.Response.GetResponseStream()))
                            return new JavaScriptSerializer().DeserializeObject(s.ReadToEnd()) as Dictionary<string, object>;
                }
                catch { }
                return null;
            }
            catch { return null; }
        }

        static void Save(Session s)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(File));
                string json = new JavaScriptSerializer().Serialize(new Dictionary<string, object> { { "email", s.Email }, { "token", s.Token }, { "key", s.Key } });
                System.IO.File.WriteAllBytes(File, ProtectedData.Protect(Encoding.UTF8.GetBytes(json), Entropy, DataProtectionScope.CurrentUser));
            }
            catch { }
        }

        static Session LoadSaved()
        {
            try
            {
                if (!System.IO.File.Exists(File)) return null;
                var json = Encoding.UTF8.GetString(ProtectedData.Unprotect(System.IO.File.ReadAllBytes(File), Entropy, DataProtectionScope.CurrentUser));
                var d = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(json);
                return new Session { Email = Convert.ToString(d["email"]), Token = Convert.ToString(d["token"]), Key = Convert.ToString(d["key"]) };
            }
            catch { return null; }
        }
    }
}
