using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace JdoTweak
{
    // "Processor" and "Graphics card": one tab per vendor. Opens on the vendor this PC has;
    // the other tabs stay visible but their tweaks are locked.
    public class VendorPage : Grid
    {
        readonly MainWindow win;
        readonly Category group;
        readonly ContentControl body = new ContentControl();
        readonly StackPanel tabs = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(34, 14, 34, 0) };

        public VendorPage(MainWindow w, Category g)
        {
            win = w; group = g;
            RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            RowDefinitions.Add(new RowDefinition());
            Children.Add(tabs);
            Grid.SetRow(body, 1);
            Children.Add(body);

            var sections = App.Catalog.Categories.Where(c => c.Group == g.Id).ToList();
            var first = sections.FirstOrDefault(c => TweakPage.HasVendor(c.Id)) ?? sections.FirstOrDefault();
            foreach (var c in sections) tabs.Children.Add(Tab(c, c == first));
            if (first != null) Open(first);
        }

        FrameworkElement Tab(Category c, bool selected)
        {
            bool has = TweakPage.HasVendor(c.Id);
            var b = new RadioButton { GroupName = "vendor-" + group.Id, IsChecked = selected, Style = UI.S("Nav"), Margin = new Thickness(0, 0, 6, 0) };
            var sp = new StackPanel { Orientation = Orientation.Horizontal };
            sp.Children.Add(new TextBlock { Text = c.Title, FontSize = 14, VerticalAlignment = VerticalAlignment.Center });
            sp.Children.Add(UI.Badge(has ? L.T("vendorHere") : L.T("vendorNotHere"), has ? "#7BE0B0" : "#A4A8B8", has ? "#1F3DD68C" : "#22FFFFFF"));
            b.Content = sp;
            b.Checked += (o, e) => Open(c);
            return b;
        }

        void Open(Category c)
        {
            var page = new TweakPage(win, c);
            body.Content = page;
            Fx.Enter(page, 0, 10);
        }
    }
}
