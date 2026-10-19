using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;
using Microsoft.Win32;

namespace JdoTweak
{
    public class Palette
    {
        public string Id, Ar, En;
        public string Bg, Side, Card, CardHover, Line, Text, Muted, Accent, Accent2, OnAccent;
        public string Name { get { return L.Pick(Ar, En); } }
    }

    // Colour themes, switchable at runtime. Every template uses DynamicResource,
    // so swapping these brushes recolours the whole app instantly.
    public static class Themes
    {
        public static readonly List<Palette> All = new List<Palette>
        {
            new Palette { Id = "neon",    Ar = "نيون",   En = "Neon",    Bg = "#0B0B14", Side = "#10101C", Card = "#151524", CardHover = "#1C1C30", Line = "#26263C", Text = "#F1F0FF", Muted = "#8E8CAB", Accent = "#A78BFA", Accent2 = "#22D3EE", OnAccent = "#0B0B14" },
            new Palette { Id = "gold",    Ar = "ذهبي",   En = "Gold",    Bg = "#0D0E12", Side = "#121319", Card = "#181A22", CardHover = "#1E212B", Line = "#262935", Text = "#F2F3F7", Muted = "#8B90A3", Accent = "#F5B841", Accent2 = "#FF8A3D", OnAccent = "#15120A" },
            new Palette { Id = "crimson", Ar = "أحمر",   En = "Crimson", Bg = "#0E0A0C", Side = "#140D10", Card = "#1B1216", CardHover = "#24171C", Line = "#33212A", Text = "#FFF1F3", Muted = "#A88C94", Accent = "#FF4D6D", Accent2 = "#FF9A3D", OnAccent = "#140A0C" },
            new Palette { Id = "ice",     Ar = "ثلجي",   En = "Ice",     Bg = "#090D12", Side = "#0D131A", Card = "#121A23", CardHover = "#17222D", Line = "#20303E", Text = "#EEF7FF", Muted = "#86A0B5", Accent = "#38BDF8", Accent2 = "#34D399", OnAccent = "#06121A" },
        };

        public static Palette Current = All[0];

        static Color C(string hex) { return (Color)ColorConverter.ConvertFromString(hex); }

        public static void Load()
        {
            string id = null;
            try { id = Registry.GetValue(@"HKEY_CURRENT_USER\Software\JdoTweak", "Theme", null) as string; } catch { }
            Apply(All.Find(p => p.Id == id) ?? All[0], false);
        }

        public static void Apply(Palette p, bool save)
        {
            Current = p;
            var r = Application.Current.Resources;
            Action<string, string> set = (k, hex) => { var b = new SolidColorBrush(C(hex)); b.Freeze(); r[k] = b; };
            set("Bg", p.Bg); set("Side", p.Side); set("Card", p.Card); set("CardHover", p.CardHover); set("Line", p.Line);
            set("Text", p.Text); set("Muted", p.Muted); set("Accent", p.Accent); set("Accent2", p.Accent2); set("OnAccent", p.OnAccent);
            var dim = C(p.Accent); dim.A = 0x2E;
            var db = new SolidColorBrush(dim); db.Freeze(); r["AccentDim"] = db;
            var g = new LinearGradientBrush(C(p.Accent), C(p.Accent2), 20); g.Freeze(); r["AccentGrad"] = g;
            r["GlowColor"] = C(p.Accent);
            if (save) try { Registry.SetValue(@"HKEY_CURRENT_USER\Software\JdoTweak", "Theme", p.Id); } catch { }
        }

        public static Color AccentColor { get { return C(Current.Accent); } }
        public static Color Accent2Color { get { return C(Current.Accent2); } }
    }

    // Small animation helpers used across the UI.
    public static class Fx
    {
        static readonly IEasingFunction Ease = new CubicEase { EasingMode = EasingMode.EaseOut };

        // Fade + slide up, optionally delayed (for staggered lists).
        public static void Enter(UIElement e, int delayMs = 0, double dy = 14)
        {
            var tt = new TranslateTransform(0, dy);
            e.RenderTransform = tt;
            double final = e.Opacity;            // keep the element's own opacity (e.g. dimmed locked cards)
            e.Opacity = 0;
            var begin = TimeSpan.FromMilliseconds(delayMs);
            var fade = new DoubleAnimation(0, final, TimeSpan.FromMilliseconds(320)) { BeginTime = begin, EasingFunction = Ease };
            var move = new DoubleAnimation(dy, 0, TimeSpan.FromMilliseconds(380)) { BeginTime = begin, EasingFunction = Ease };
            // Release the animation when done so later changes to Opacity actually take effect.
            fade.Completed += (o, a) => { e.BeginAnimation(UIElement.OpacityProperty, null); e.Opacity = final; };
            move.Completed += (o, a) => { tt.BeginAnimation(TranslateTransform.YProperty, null); tt.Y = 0; };
            e.BeginAnimation(UIElement.OpacityProperty, fade);
            tt.BeginAnimation(TranslateTransform.YProperty, move);
        }

        // Lift and glow on hover.
        public static void Hover(FrameworkElement card)
        {
            var glow = new System.Windows.Media.Effects.DropShadowEffect { Color = Themes.AccentColor, BlurRadius = 0, ShadowDepth = 0, Opacity = 0 };
            card.Effect = glow;
            card.MouseEnter += (o, e) =>
            {
                glow.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.OpacityProperty, new DoubleAnimation(0.35, TimeSpan.FromMilliseconds(200)));
                glow.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.BlurRadiusProperty, new DoubleAnimation(22, TimeSpan.FromMilliseconds(200)));
                var tt = card.RenderTransform as TranslateTransform;
                if (tt != null && !tt.IsFrozen) tt.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-2, TimeSpan.FromMilliseconds(180)) { EasingFunction = Ease });
            };
            card.MouseLeave += (o, e) =>
            {
                glow.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.OpacityProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(250)));
                glow.BeginAnimation(System.Windows.Media.Effects.DropShadowEffect.BlurRadiusProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(250)));
                var tt = card.RenderTransform as TranslateTransform;
                if (tt != null && !tt.IsFrozen) tt.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromMilliseconds(220)) { EasingFunction = Ease });
            };
        }

        // Slowly rotating gradient, used on the logo.
        public static Brush Shimmer()
        {
            var b = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1), MappingMode = BrushMappingMode.RelativeToBoundingBox };
            b.GradientStops.Add(new GradientStop(Themes.AccentColor, 0));
            b.GradientStops.Add(new GradientStop(Themes.Accent2Color, 1));
            var rot = new RotateTransform(0, 0.5, 0.5);
            b.RelativeTransform = rot;
            rot.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(8)) { RepeatBehavior = RepeatBehavior.Forever });
            return b;
        }

        // Soft breathing glow behind an element.
        public static void Pulse(UIElement e, double from = 0.55, double to = 1)
        {
            e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(from, to, TimeSpan.FromSeconds(2.2)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase() });
        }
    }
}
