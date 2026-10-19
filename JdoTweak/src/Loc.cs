using System;
using System.Collections.Generic;
using Microsoft.Win32;

namespace JdoTweak
{
    // Arabic / English strings. Every visible string goes through L.T().
    public static class L
    {
        public static bool Ar = true;
        public static event Action Changed;

        static readonly Dictionary<string, string[]> S = new Dictionary<string, string[]>
        {
            { "app",          new[] { "جدو الشايب تويك", "JDO Al-Shayeb Tweak" } },
            { "tagline",      new[] { "أعلى فريمات · أقل ديلاي", "Max FPS · Min Delay" } },
            { "dashboard",    new[] { "الرئيسية", "Dashboard" } },
            { "repair",       new[] { "الفحص والإصلاح", "Scan & Repair" } },
            { "account",      new[] { "حسابي", "My Account" } },
            { "settings",     new[] { "الإعدادات", "Settings" } },
            { "tweaks",       new[] { "التويكات", "Tweaks" } },
            { "tools",        new[] { "الأدوات", "Tools" } },

            { "tier1",        new[] { "بيسك", "Basic" } },
            { "tier2",        new[] { "إيليت", "Elite" } },
            { "tier3",        new[] { "ألتميت", "Ultimate" } },
            { "risk1",        new[] { "متوسط", "Moderate" } },
            { "risk2",        new[] { "خطر", "Risky" } },
            { "reboot",       new[] { "يحتاج ريستارت", "Restart needed" } },
            { "locked",       new[] { "يحتاج ترقية", "Upgrade required" } },
            { "applied",      new[] { "مفعّل", "Applied" } },
            { "notApplied",   new[] { "غير مفعّل", "Not applied" } },
            { "custom",       new[] { "قيمة مخصصة", "Custom value" } },
            { "applyRec",     new[] { "تطبيق الموصى به", "Apply Recommended" } },
            { "revertAll",    new[] { "إرجاع الكل", "Revert All" } },
            { "working",      new[] { "جاري التطبيق...", "Applying..." } },
            { "done",         new[] { "تم", "Done" } },
            { "failed",       new[] { "فشل", "Failed" } },
            { "ofApplied",    new[] { "مفعّل من", "applied of" } },
            { "detected",     new[] { "تم الكشف", "Detected" } },

            { "riskTitle",    new[] { "تنبيه قبل التفعيل", "Before you apply" } },
            { "riskBody",     new[] { "هذا التويك يقلل من حماية ويندوز أو يغير شي حساس. تقدر ترجعه بأي وقت من نفس الزر. تبي تكمل؟", "This tweak lowers Windows protection or changes something sensitive. You can revert it any time from the same switch. Continue?" } },
            { "rebootTitle",  new[] { "ريستارت مطلوب", "Restart needed" } },
            { "rebootBody",   new[] { "بعض التغييرات تحتاج إعادة تشغيل عشان تشتغل. تبي تعيد التشغيل الحين؟", "Some changes need a restart to take effect. Restart now?" } },
            { "yes",          new[] { "نعم", "Yes" } },
            { "no",           new[] { "لا", "No" } },
            { "ok",           new[] { "تمام", "OK" } },
            { "cancel",       new[] { "إلغاء", "Cancel" } },

            { "hwTitle",      new[] { "جهازك", "Your PC" } },
            { "usageTitle",   new[] { "الاستهلاك المباشر", "Live Usage" } },
            { "cpu",          new[] { "المعالج", "Processor" } },
            { "gpu",          new[] { "كرت الشاشة", "Graphics" } },
            { "ram",          new[] { "الرامات", "Memory" } },
            { "disk",         new[] { "الهارد", "Storage" } },
            { "net",          new[] { "الشبكة", "Network" } },
            { "board",        new[] { "المذربورد", "Motherboard" } },
            { "os",           new[] { "النظام", "System" } },
            { "mouse",        new[] { "الماوس", "Mouse" } },
            { "keyboard",     new[] { "الكيبورد", "Keyboard" } },
            { "monitor",      new[] { "الشاشة", "Display" } },
            { "photo",        new[] { "صورة", "Photo" } },
            { "cores",        new[] { "نواة", "cores" } },
            { "threads",      new[] { "مسار", "threads" } },
            { "loading",      new[] { "جاري القراءة...", "Reading..." } },
            { "restorePoint", new[] { "إنشاء نقطة استعادة", "Create Restore Point" } },
            { "rpDone",       new[] { "تم إنشاء نقطة الاستعادة", "Restore point created" } },
            { "rpAsk",        new[] { "أول مرة تطبق تويكات؟ ننصحك تسوي نقطة استعادة قبل. نسويها الحين؟", "First time applying tweaks? We recommend a restore point first. Create one now?" } },
            { "tweaksActive", new[] { "تويك مفعّل", "tweaks active" } },
            { "quickBoost",   new[] { "تسريع بضغطة", "One-Click Boost" } },
            { "quickBoostD",  new[] { "يطبق كل التويكات الموصى بها والآمنة المتاحة في باقتك.", "Applies every safe, recommended tweak included in your plan." } },

            { "scan",         new[] { "فحص الجهاز", "Scan PC" } },
            { "scanD",        new[] { "يفحص المشاكل الشائعة ويعطيك زر إصلاح لكل وحدة.", "Checks for common problems and gives you a fix button for each." } },
            { "scanning",     new[] { "جاري الفحص...", "Scanning..." } },
            { "noIssues",     new[] { "ما فيه مشاكل. جهازك سليم!", "No problems found. Your PC is healthy!" } },
            { "fix",          new[] { "إصلاح", "Fix" } },
            { "run",          new[] { "تشغيل", "Run" } },
            { "sfc",          new[] { "إصلاح ملفات النظام (SFC)", "Repair System Files (SFC)" } },
            { "sfcD",         new[] { "يفحص ملفات ويندوز ويصلح التالف منها.", "Scans Windows files and repairs damaged ones." } },
            { "dism",         new[] { "إصلاح صورة الويندوز (DISM)", "Repair Windows Image (DISM)" } },
            { "dismD",        new[] { "ينزل نسخة سليمة من ملفات ويندوز من مايكروسوفت ويصلح فيها.", "Downloads clean Windows files from Microsoft and repairs with them." } },
            { "store",        new[] { "إرجاع / إصلاح مايكروسوفت ستور", "Restore / Repair Microsoft Store" } },
            { "storeD",       new[] { "إذا المتجر محذوف ينزله من جديد كامل، وإذا موجود يصلحه.", "Reinstalls the Store in full if it was removed, or repairs it if present." } },
            { "netReset",     new[] { "إعادة ضبط الشبكة", "Reset Network" } },
            { "netResetD",    new[] { "يصلح مشاكل النت والبنق بإعادة ضبط Winsock و IP و DNS.", "Fixes internet and ping issues by resetting Winsock, IP and DNS." } },
            { "cleanTemp",    new[] { "تنظيف الملفات المؤقتة", "Clean Temporary Files" } },
            { "cleanTempD",   new[] { "يحذف الملفات المؤقتة ويفضي مساحة.", "Deletes temporary files to free space." } },
            { "revertEvery",  new[] { "إرجاع كل التويكات", "Revert Every Tweak" } },
            { "revertEveryD", new[] { "يرجع كل شي غيره البرنامج للقيم الأصلية حقت جهازك.", "Restores everything this app changed to your PC's original values." } },
            { "output",       new[] { "المخرجات", "Output" } },

            { "iss.store",    new[] { "مايكروسوفت ستور غير موجود", "Microsoft Store is missing" } },
            { "iss.disk",     new[] { "مساحة الهارد C قليلة", "Drive C is low on space" } },
            { "iss.temp",     new[] { "ملفات مؤقتة كثيرة", "Lots of temporary files" } },
            { "iss.svc",      new[] { "خدمة مهمة متوقفة", "An essential service is stopped" } },
            { "iss.reboot",   new[] { "فيه ريستارت معلّق", "A restart is pending" } },
            { "iss.power",    new[] { "خطة الطاقة على التوفير", "Power plan is set to power saving" } },
            { "iss.gamedvr",  new[] { "تسجيل الألعاب بالخلفية شغال", "Background game recording is on" } },

            { "login",        new[] { "تسجيل الدخول", "Sign In" } },
            { "email",        new[] { "الإيميل", "Email" } },
            { "password",     new[] { "كلمة المرور", "Password" } },
            { "licenseKey",   new[] { "مفتاح الترخيص", "License Key" } },
            { "activate",     new[] { "تفعيل", "Activate" } },
            { "logout",       new[] { "تسجيل خروج", "Sign Out" } },
            { "plan",         new[] { "الباقة", "Plan" } },
            { "expires",      new[] { "ينتهي", "Expires" } },
            { "lifetime",     new[] { "مدى الحياة", "Lifetime" } },
            { "hwid",         new[] { "بصمة الجهاز", "Device ID" } },
            { "noAccount",    new[] { "ما عندك حساب؟ اشترك من الموقع", "No account? Subscribe on the website" } },
            { "loginErr",     new[] { "الإيميل أو كلمة المرور أو المفتاح غير صحيح", "Wrong email, password or key" } },
            { "hwidErr",      new[] { "هذا المفتاح مربوط بجهاز ثاني. تواصل مع الدعم لإعادة التعيين.", "This key is bound to another PC. Contact support to reset it." } },
            { "netErr",       new[] { "ما قدرنا نتصل بالسيرفر. تأكد من النت.", "Couldn't reach the server. Check your internet." } },
            { "devMode",      new[] { "نسخة المطور", "Developer build" } },

            { "language",     new[] { "اللغة", "Language" } },
            { "langD",        new[] { "غيّر لغة البرنامج.", "Change the app language." } },
            { "updates",      new[] { "التحديثات", "Updates" } },
            { "checkUpdates", new[] { "فحص التحديثات", "Check for Updates" } },
            { "upToDate",     new[] { "البرنامج على آخر إصدار", "You're on the latest version" } },
            { "version",      new[] { "الإصدار", "Version" } },
            { "catalog",      new[] { "قاعدة التويكات", "Tweak catalog" } },
            { "updateAvail",  new[] { "فيه تحديث جديد. تبي تثبته الحين؟ الإصدار", "A new update is available. Install now? Version" } },
            { "openBackup",   new[] { "فتح المجلد", "Open Folder" } },
            { "backupT",      new[] { "النسخ الاحتياطي", "Backups" } },
            { "backupD",      new[] { "تويك محفوظ قيمته الأصلية وتقدر ترجعه", "tweaks have their original values saved and can be reverted" } },

            { "restartNow",   new[] { "ريستارت الحين", "Restart Now" } },
            { "welcome",      new[] { "هلا", "Welcome" } },
            { "tweaksTotal",  new[] { "تويك", "tweaks" } },
            { "changesTotal", new[] { "تعديل", "changes" } },
            { "search",       new[] { "بحث", "Search" } },
            { "searchHint",   new[] { "ابحث باسم التويك أو الريجستري...", "Search by tweak name or registry path..." } },
            { "secBest",      new[] { "الأفضل", "Best Picks" } },
            { "secBestD",     new[] { "أقوى التويكات المجربة، مختارة يدوياً ومع شرح كامل.", "The strongest proven tweaks, hand-picked and fully explained." } },
            { "secOptions",   new[] { "إعدادات بأكثر من خيار", "Multi-Option Settings" } },
            { "secOptionsD",  new[] { "كل إعداد مع القيم اللي تستخدمها باكات التويك. الخيار الأول ★ هو الأكثر استخداماً.", "Each setting with the values tweak packs use. The first option ★ is the most popular." } },
            { "secLibrary",   new[] { "مكتبة التويكات الكاملة", "Full Tweak Library" } },
            { "secLibraryD",  new[] { "كل ملفات التويك بعد التنظيف وحذف المكرر. القيم الأصلية تنحفظ قبل أي تغيير.", "Every tweak file after cleaning and de-duplication. Original values are saved before any change." } },
            { "showMore",     new[] { "عرض المزيد", "Show More" } },
            { "noResults",    new[] { "ما فيه نتائج", "No results" } },

            { "repairSub",    new[] { "فحص تلقائي وإصلاح لمشاكل الويندوز والبرامج والتويكات.", "Automatic scan and fixes for Windows, app and tweak problems." } },
            { "autofixDl",    new[] { "تحميل أداة الإصلاح التلقائي", "Download Auto-Fix Tool" } },
            { "autofixDlD",   new[] { "ملف CMD يكتشف المشاكل ويصلحها تلقائياً، حتى لو البرنامج ما يفتح.", "A CMD file that finds and fixes problems automatically, even if the app won't open." } },
            { "autofixSaved", new[] { "انحفظ على سطح المكتب. شغله بدبل كليك.", "Saved to your desktop. Double-click to run it." } },
            { "slow",         new[] { "ياخذ وقت", "Takes a while" } },
            { "busy",         new[] { "فيه إصلاح شغال، انتظر يخلص", "A fix is already running, please wait" } },
            { "reverted",     new[] { "تويك رجع للأصل", "tweaks reverted" } },

            { "pollTitle",    new[] { "فحص استجابة الماوس", "Mouse Polling Rate" } },
            { "pollSub",      new[] { "يقيس سرعة استجابة الماوس الحقيقية (Polling Rate) بالهرتز.", "Measures your mouse's real polling rate in Hz." } },
            { "pollMove",     new[] { "حرّك الماوس بسرعة بشكل دوائر", "Move your mouse quickly in circles" } },
            { "pollReset",    new[] { "إعادة القياس", "Reset" } },
            { "pollAvg",      new[] { "المعدل", "Average" } },
            { "pollMax",      new[] { "الأعلى", "Peak" } },
            { "pollTipsT",    new[] { "كيف تغير الاستجابة (1ms / 2ms / 8ms)", "How to change polling (1ms / 2ms / 8ms)" } },
            { "pollTip1",     new[] { "الاستجابة تتغير من برنامج الماوس نفسه (Logitech G HUB، Razer Synapse، SteelSeries GG...) أو زر تحت الماوس.", "Polling is set in the mouse's own software (Logitech G HUB, Razer Synapse, SteelSeries GG...) or a button under the mouse." } },
            { "pollTip2",     new[] { "1000Hz = 1ms هو الأفضل لأغلب الأجهزة. 4000/8000Hz تحتاج معالج قوي وممكن تسبب تقطيع.", "1000Hz = 1ms suits most PCs. 4000/8000Hz need a strong CPU and can cause stutter." } },
            { "pollTip3",     new[] { "125Hz = 8ms (الماوسات العادية) · 500Hz = 2ms · 1000Hz = 1ms", "125Hz = 8ms (basic mice) · 500Hz = 2ms · 1000Hz = 1ms" } },
            { "pollTip4",     new[] { "ركب الماوس في منفذ USB خلفي مباشر بالمذربورد، مو في هب أو منفذ أمامي.", "Plug the mouse straight into a rear motherboard USB port, not a hub or front port." } },

            { "liteWin",      new[] { "ويندوز مخفف", "Lite Windows" } },
            { "pageSub",      new[] { "فعّل اللي تبي، وكل شي ينرجع للأصل بضغطة.", "Turn on what you want. Everything can be undone in one click." } },
            { "showAdvanced", new[] { "عرض الخيارات المتقدمة", "Show advanced options" } },
            { "hideAdvanced", new[] { "إخفاء الخيارات المتقدمة", "Hide advanced options" } },
            { "packSub",      new[] { "أربع خانات بس. اختر مستواك والبرنامج يطبق الأنسب لجهازك.", "Just four boxes. Pick your level and the app applies what suits your PC." } },
            { "pack1D",       new[] { "الأساسيات الآمنة: أولويات المعالج والألعاب، إيقاف تسجيل الألعاب، خطة طاقة قوية، وتنظيف الويندوز من الإعلانات.", "The safe essentials: CPU and game priorities, no background game recording, a high-performance power plan, and Windows cleaned of ads." } },
            { "pack2D",       new[] { "كل البيسك + تحسينات أعمق للمعالج والرامات وكرت الشاشة وتقليل الديلي.", "Everything in Basic plus deeper CPU, RAM, GPU and input-delay tuning." } },
            { "pack3D",       new[] { "كل الإيليت + أقوى تحسينات الأداء. فيها تحسينات متوسطة الخطر ويتم تأكيدها قبل التفعيل.", "Everything in Elite plus the strongest performance tweaks. Includes moderate-risk items, confirmed before applying." } },
            { "pack4D",       new[] { "كل الألتميت + نسخة ويندوز مخففة جاهزة للتحميل.", "Everything in Ultimate plus a ready-to-install lite Windows image." } },
            { "includes",     new[] { "يشمل", "Includes" } },
            { "pack1B",       new[] { "أولوية للعبة على البرامج الخلفية|خطة طاقة الأداء العالي|إيقاف تسجيل الألعاب بالخلفية (Game DVR)|إيقاف الإعلانات والتطبيقات المفروضة", "Games get priority over background apps|High-performance power plan|Background game recording (Game DVR) off|Ads and auto-installed apps off" } },
            { "pack1W",       new[] { "مناسبة لأي جهاز، وآمنة تماماً.", "Suits any PC and is completely safe." } },
            { "pack2B",       new[] { "كل مميزات البيسك|المعالج على أقصى سرعة وبدون ركن الأنوية|إيقاف ضغط الرام والتحميل المسبق|أقل ديلاي للماوس والكيبورد وكرت الشاشة", "Everything in Basic|CPU at full speed with no core parking|Memory compression and preloading off|Lower delay for mouse, keyboard and GPU" } },
            { "pack2W",       new[] { "مناسبة للاعبين اللي يبون فريمات أعلى وبنق أثبت.", "For gamers who want higher FPS and steadier ping." } },
            { "pack3B",       new[] { "كل مميزات الإيليت|أعلى أولوية لكرت الشاشة ومنافذ USB|إيقاف مقاطعة كرت الشاشة|أقصى أداء ممكن من الويندوز", "Everything in Elite|Top priority for the GPU and USB ports|GPU preemption off|The most performance Windows can give" } },
            { "pack3W",       new[] { "للمحترفين. فيها تويكات متوسطة الخطر، وتقدر ترجعها بضغطة.", "For enthusiasts. Includes moderate-risk tweaks you can undo in one click." } },
            { "pack4B",       new[] { "كل مميزات الألتميت|نسخة ويندوز مخففة بدون برامج زايدة|أخف على الرام والمعالج من البداية", "Everything in Ultimate|A lite Windows build without bloat|Lighter on RAM and CPU from the first boot" } },
            { "pack4W",       new[] { "لأقصى أداء: تثبيت ويندوز جديد خفيف.", "For maximum performance: a fresh, light Windows install." } },
            { "boxOn",        new[] { "مفعّلة", "On" } },
            { "boxPartial",   new[] { "مفعّلة جزئياً", "Partly on" } },
            { "boxOff",       new[] { "غير مفعّلة", "Off" } },
            { "expiredErr",   new[] { "اشتراكك انتهى. جدده من الموقع.", "Your subscription has expired. Renew it on the website." } },
            { "lockedErr",    new[] { "هذا الحساب أو المفتاح موقوف. تواصل مع الدعم.", "This account or key is suspended. Contact support." } },
            { "forgotPass",   new[] { "نسيت كلمة المرور؟", "Forgot your password?" } },
            { "keyHint",      new[] { "المفتاح يوصلك على الإيميل بعد الشراء.", "Your key is emailed to you after purchase." } },
            { "optHint",      new[] { "اختر قيمة. الخيار ★ هو الأكثر استخداماً، و\"الأصلي\" يرجع قيمة جهازك.", "Pick a value. ★ is the most used one, and \"Original\" restores your PC's value." } },
            { "libDescS",     new[] { "يغير الإعداد \"{0}\" في {1}. ينرجع للأصل بضغطة.", "Changes the \"{0}\" setting in {1}. Can be undone in one click." } },
            { "partial",      new[] { "جزئي", "partial" } },
            { "packRisk",     new[] { "هذا المستوى فيه تحسينات متوسطة الخطر. تقدر ترجعها بأي وقت. تكمل؟", "This level has moderate-risk tweaks. You can undo them any time. Continue?" } },
            { "downloadLite", new[] { "تحميل الويندوز المخفف", "Download Lite Windows" } },
            { "liteSoon",     new[] { "رابط الويندوز المخفف بيوصلك على الإيميل. ما انضاف بعد.", "Your Lite Windows link will be emailed to you. It hasn't been added yet." } },
            { "showAll",      new[] { "عرض كل التويكات الفردية", "Show every individual tweak" } },
            { "hideAll",      new[] { "إخفاء التويكات الفردية", "Hide individual tweaks" } },
            { "details",      new[] { "التفاصيل", "Details" } },
            { "separate",     new[] { "أمر منفصل", "separate commands" } },
            { "noUndo",       new[] { "ما ينرجع تلقائي", "No auto-undo" } },
            { "theme",        new[] { "الثيم", "Theme" } },
            { "themeD",       new[] { "اختر ألوان البرنامج.", "Pick the app's colours." } },
            { "owner",        new[] { "لوحة المالك", "Owner Panel" } },
            { "ownerSub",     new[] { "انشر إعلانات وتحديثات توصل لكل المستخدمين.", "Post announcements and updates that reach every user." } },
            { "postNews",     new[] { "نشر إعلان", "Post an Announcement" } },
            { "postNewsD",    new[] { "يطلع للمستخدمين في الصفحة الرئيسية داخل البرنامج.", "Shows on every user's dashboard inside the app." } },
            { "titleAr",      new[] { "العنوان (عربي)", "Title (Arabic)" } },
            { "titleEn",      new[] { "العنوان (إنجليزي)", "Title (English)" } },
            { "bodyAr",       new[] { "النص (عربي)", "Text (Arabic)" } },
            { "bodyEn",       new[] { "النص (إنجليزي)", "Text (English)" } },
            { "publish",      new[] { "نشر", "Publish" } },
            { "published",    new[] { "تم النشر", "Published" } },
            { "noServer",     new[] { "السيرفر لسا ما تربط", "The server isn't connected yet" } },
            { "pubRelease",   new[] { "نشر تحديث للبرنامج", "Publish an App Update" } },
            { "pubReleaseD",  new[] { "كل المستخدمين ينبهون وينزل لهم التحديث تلقائياً.", "Every user is notified and the update installs automatically." } },
            { "downloadUrl",  new[] { "رابط التحميل", "Download URL" } },
            { "notes",        new[] { "ملاحظات التحديث", "Release notes" } },
            { "openAdmin",    new[] { "فتح لوحة الموقع", "Open Website Admin" } },
            { "usersKeys",    new[] { "المستخدمين والمفاتيح", "Users & Keys" } },
            { "usersKeysD",   new[] { "الإيميلات، الرتب، الوصول المجاني، قفل وفتح المفاتيح، المدة، ريست الجهاز.", "Emails, roles, free access, lock/unlock keys, durations, device resets." } },
            { "copyHwid",     new[] { "نسخ بصمة الجهاز", "Copy Device ID" } },
            { "upgrade",      new[] { "ترقية الباقة", "Upgrade Plan" } },
        };

        public static string T(string key)
        {
            string[] v;
            if (!S.TryGetValue(key, out v)) return key;
            return Ar ? v[0] : v[1];
        }

        public static string T(string key, bool arabic)
        {
            string[] v;
            return S.TryGetValue(key, out v) ? v[arabic ? 0 : 1] : key;
        }

        public static string Pick(string ar, string en) { return Ar ? (ar ?? en) : (en ?? ar); }

        public static void Set(bool arabic)
        {
            Ar = arabic;
            try { Registry.SetValue(@"HKEY_CURRENT_USER\Software\JdoTweak", "Lang", arabic ? "ar" : "en"); } catch { }
            if (Changed != null) Changed();
        }

        public static void Load()
        {
            try
            {
                object v = Registry.GetValue(@"HKEY_CURRENT_USER\Software\JdoTweak", "Lang", null);
                if (v != null) Ar = (string)v != "en";
            }
            catch { }
        }
    }
}
