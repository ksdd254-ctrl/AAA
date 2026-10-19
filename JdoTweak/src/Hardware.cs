using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace JdoTweak
{
    public class Device
    {
        public string Kind;     // cpu gpu ram disk board os mouse keyboard monitor net
        public string Name;
        public string Detail;
        public string Vendor;
    }

    public class HardwareInfo
    {
        public List<Device> Devices = new List<Device>();
        public int RamGb;
        public string GpuVendor = "";
        public string BoardSerial = "", CpuId = "", SystemUuid = "";
        public bool HasSsd;

        static readonly Dictionary<string, string> UsbVendors = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            {"046D","Logitech"},{"1532","Razer"},{"1038","SteelSeries"},{"1B1C","Corsair"},{"0951","HyperX"},{"03F0","HyperX"},
            {"3434","Keychron"},{"1E7D","ROCCAT"},{"2516","Cooler Master"},{"0B05","ASUS ROG"},{"045E","Microsoft"},{"413C","Dell"},
            {"17EF","Lenovo"},{"046A","Cherry"},{"3367","Endgame Gear"},{"361D","Finalmouse"},{"3554","Pulsar"},{"373B","Lamzu"},
            {"320F","Glorious"},{"258A","Glorious / Sinowealth"},{"093A","Pixart"},{"1EA7","Sharkoon"},{"04D9","Holtek"},
            {"1A2C","China Resource"},{"0C45","Microdia"},{"04F2","Chicony"},{"1D57","Xenta"},{"25A7","Areson"},{"248A","Maxxter"},
            {"2EA8","Zowie"},{"1AF3","Zowie (BenQ)"},{"0D8C","C-Media"},{"28DA","Wooting"},{"31E3","Wooting"},{"3299","Ajazz"},
            {"05AC","Apple"},{"0603","Novatek"},{"2F68","Hoksi"},{"36A7","ATK"},{"3710","VXE"},{"1915","Nordic (wireless)"},{"0416","Winbond"},
            {"1BCF","Sunplus"},{"0461","Primax"},{"0E8F","GreenAsia"},{"2A7A","Bloody (A4Tech)"},{"09DA","A4Tech"},{"145F","Trust"},{"1D50","OpenMoko"}
        };

        public static HardwareInfo Read()
        {
            var h = new HardwareInfo();
            h.ReadAll();
            return h;
        }

        static IEnumerable<ManagementObject> Q(string query, string scope = @"root\cimv2")
        {
            var list = new List<ManagementObject>();
            try
            {
                using (var s = new ManagementObjectSearcher(scope, query))
                    foreach (ManagementObject o in s.Get()) list.Add(o);
            }
            catch { }
            return list;
        }

        static string P(ManagementObject o, string prop)
        {
            try { object v = o[prop]; return v == null ? "" : v.ToString().Trim(); } catch { return ""; }
        }

        void Add(string kind, string name, string detail, string vendor = null)
        {
            if (string.IsNullOrWhiteSpace(name)) return;
            Devices.Add(new Device { Kind = kind, Name = Clean(name), Detail = detail, Vendor = vendor });
        }

        static string Clean(string s) { return Regex.Replace(s.Replace("(R)", "").Replace("(TM)", "").Replace("(tm)", ""), @"\s+", " ").Trim(); }

        void ReadAll()
        {
            foreach (var o in Q("SELECT Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, ProcessorId FROM Win32_Processor"))
            {
                CpuId = P(o, "ProcessorId");
                Add("cpu", P(o, "Name"), P(o, "NumberOfCores") + " " + L.T("cores") + " · " + P(o, "NumberOfLogicalProcessors") + " " + L.T("threads") + " · " + (Convert.ToDouble("0" + P(o, "MaxClockSpeed")) / 1000.0).ToString("0.0") + " GHz");
            }

            foreach (var o in Q("SELECT Name, DriverVersion, PNPDeviceID FROM Win32_VideoController"))
            {
                string name = P(o, "Name");
                if (name.IndexOf("Basic Display", StringComparison.OrdinalIgnoreCase) >= 0 || name.IndexOf("Remote", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                string pnp = P(o, "PNPDeviceID").ToUpperInvariant();
                if (pnp.Contains("VEN_10DE")) GpuVendor = "nvidia";
                else if (pnp.Contains("VEN_1002") && GpuVendor == "") GpuVendor = "amd";
                else if (pnp.Contains("VEN_8086") && GpuVendor == "") GpuVendor = "intel";
                long vram = GpuMemory(name);
                Add("gpu", name, (vram > 0 ? (vram / 1073741824.0).ToString("0") + " GB VRAM · " : "") + "Driver " + P(o, "DriverVersion"));
            }

            long total = 0; var sticks = new List<string>(); string speed = "", maker = "", ddr = "";
            foreach (var o in Q("SELECT Capacity, Speed, ConfiguredClockSpeed, Manufacturer, PartNumber, SMBIOSMemoryType FROM Win32_PhysicalMemory"))
            {
                long cap; long.TryParse(P(o, "Capacity"), out cap); total += cap;
                sticks.Add((cap / 1073741824).ToString());
                string sp = P(o, "ConfiguredClockSpeed"); if (sp == "" || sp == "0") sp = P(o, "Speed");
                speed = sp;
                string mk = P(o, "Manufacturer"); if (Regex.IsMatch(mk, @"(?i)^(unknown|undefined|0+|)$")) mk = "";
                string part = P(o, "PartNumber"); if (Regex.IsMatch(part, @"(?i)^(unknown|0+|)$")) part = "";
                if (maker == "") maker = (mk + " " + part).Trim();
                switch (P(o, "SMBIOSMemoryType")) { case "34": ddr = "DDR5"; break; case "26": ddr = "DDR4"; break; case "24": ddr = "DDR3"; break; }
            }
            RamGb = (int)Math.Round(total / 1073741824.0);
            Add("ram", (RamGb + " GB " + ddr + (maker == "" ? "" : " · " + maker)).Trim(), sticks.Count + " x " + string.Join("+", sticks.Distinct()) + " GB" + (speed != "" ? " · " + speed + " MT/s" : ""));

            foreach (var o in Q("SELECT Manufacturer, Product, SerialNumber FROM Win32_BaseBoard"))
            {
                BoardSerial = P(o, "SerialNumber");
                Add("board", P(o, "Manufacturer") + " " + P(o, "Product"), "");
            }
            foreach (var o in Q("SELECT UUID FROM Win32_ComputerSystemProduct")) SystemUuid = P(o, "UUID");

            // Physical disks with SSD / NVMe detection
            var disks = Q("SELECT FriendlyName, MediaType, BusType, Size FROM MSFT_PhysicalDisk", @"root\Microsoft\Windows\Storage");
            if (disks.Any())
                foreach (var o in disks)
                {
                    string media = P(o, "MediaType") == "4" ? "SSD" : P(o, "MediaType") == "3" ? "HDD" : "";
                    if (P(o, "BusType") == "17") media = "NVMe SSD";
                    if (media.Contains("SSD")) HasSsd = true;
                    long size; long.TryParse(P(o, "Size"), out size);
                    Add("disk", P(o, "FriendlyName"), (size / 1000000000) + " GB " + media);
                }
            else
                foreach (var o in Q("SELECT Model, Size, PNPDeviceID, InterfaceType FROM Win32_DiskDrive"))
                {
                    long size; long.TryParse(P(o, "Size"), out size);
                    string model = P(o, "Model"), pnp = P(o, "PNPDeviceID").ToUpperInvariant();
                    string media = pnp.Contains("NVME") || model.ToUpperInvariant().Contains("NVME") ? "NVMe SSD"
                                 : Regex.IsMatch(model, @"(?i)ssd|solid") ? "SSD" : P(o, "InterfaceType") == "USB" ? "USB" : "";
                    if (media.Contains("SSD")) HasSsd = true;
                    Add("disk", model, (size / 1000000000) + " GB " + media);
                }

            foreach (var o in Q("SELECT Caption, BuildNumber, OSArchitecture FROM Win32_OperatingSystem"))
                Add("os", P(o, "Caption"), "Build " + P(o, "BuildNumber") + " · " + P(o, "OSArchitecture"));

            foreach (var o in Q("SELECT Name FROM Win32_DesktopMonitor"))
            {
                string n = P(o, "Name");
                if (n.IndexOf("Generic", StringComparison.OrdinalIgnoreCase) < 0 && n.IndexOf("Default", StringComparison.OrdinalIgnoreCase) < 0) Add("monitor", n, "");
            }
            ReadMonitors();

            ReadInput();

            foreach (var o in Q("SELECT Name, Speed FROM Win32_NetworkAdapter WHERE PhysicalAdapter = TRUE AND NetEnabled = TRUE"))
            {
                long sp; long.TryParse(P(o, "Speed"), out sp);
                Add("net", P(o, "Name"), sp > 0 ? (sp / 1000000) + " Mbps" : "");
            }
        }

        // Real monitor model names come from the EDID, not Win32_DesktopMonitor.
        void ReadMonitors()
        {
            foreach (var o in Q("SELECT UserFriendlyName, ManufacturerName FROM WmiMonitorID", @"root\wmi"))
            {
                string name = Edid(o, "UserFriendlyName"), maker = Edid(o, "ManufacturerName");
                if (name != "") Add("monitor", name, maker);
            }
        }

        static string Edid(ManagementObject o, string prop)
        {
            try
            {
                var arr = o[prop] as ushort[];
                if (arr == null) return "";
                return new string(arr.TakeWhile(c => c != 0).Select(c => (char)c).ToArray()).Trim();
            }
            catch { return ""; }
        }

        // Mouse / keyboard: WMI only says "HID-compliant mouse", so read the name
        // the device itself reports over USB, then map the vendor ID to a brand.
        // Gaming keyboards expose a mouse interface (and mice a keyboard one) for macros,
        // so a device's real type is the class of its primary interface (MI_00 / no MI).
        void ReadInput()
        {
            var best = new Dictionary<string, Tuple<int, string, ManagementObject>>();
            foreach (var o in Q("SELECT Name, DeviceID, PNPClass FROM Win32_PnPEntity WHERE (PNPClass = 'Mouse' OR PNPClass = 'Keyboard') AND Present = TRUE"))
            {
                string id = P(o, "DeviceID");
                var m = Regex.Match(id, @"VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase);
                string key = m.Success ? m.Groups[1].Value.ToUpperInvariant() + m.Groups[2].Value.ToUpperInvariant() : id;
                if (!m.Success && !id.StartsWith("ACPI", StringComparison.OrdinalIgnoreCase)) continue;
                var mi = Regex.Match(id, @"MI_(\d+)", RegexOptions.IgnoreCase);
                int rank = (mi.Success ? int.Parse(mi.Groups[1].Value) * 10 : 0) + (id.IndexOf("COL", StringComparison.OrdinalIgnoreCase) >= 0 ? 1 : 0);
                Tuple<int, string, ManagementObject> cur;
                if (!best.TryGetValue(key, out cur) || rank < cur.Item1)
                    best[key] = Tuple.Create(rank, P(o, "PNPClass").Equals("Mouse", StringComparison.OrdinalIgnoreCase) ? "mouse" : "keyboard", o);
            }
            foreach (var kv in best.OrderBy(k => k.Value.Item2 == "mouse" ? 0 : 1))
            {
                var o = kv.Value.Item3;
                string kind = kv.Value.Item2;
                string vid = kv.Key.Length == 8 ? kv.Key.Substring(0, 4) : "";
                string pid = kv.Key.Length == 8 ? kv.Key.Substring(4) : "";

                string name = BusName(o);
                if (name == "") name = UsbParentName(vid, pid);
                if (name == "") name = P(o, "Name");
                string brand = "";
                if (vid != "") UsbVendors.TryGetValue(vid, out brand);
                // Only name the brand when the device gives no model name of its own;
                // many vendor IDs belong to the chip maker, not the brand on the box.
                if (!string.IsNullOrEmpty(brand) && IsGeneric(name)) name = brand + " " + L.T(kind);
                Add(kind, name, vid != "" ? "VID " + vid + " · PID " + pid : "", brand);
            }
        }

        static bool IsGeneric(string n)
        {
            return Regex.IsMatch(n, @"(?i)hid[- ]compliant|usb input device|composite|standard ps/2|hid keyboard device|^usb receiver$|receiver|wireless device");
        }

        static string BusName(ManagementObject o)
        {
            try
            {
                var inParams = o.GetMethodParameters("GetDeviceProperties");
                inParams["devicePropertyKeys"] = new[] { "DEVPKEY_Device_BusReportedDeviceDesc" };
                var r = o.InvokeMethod("GetDeviceProperties", inParams, null);
                var props = r["deviceProperties"] as ManagementBaseObject[];
                if (props != null && props.Length > 0 && props[0]["Data"] != null)
                {
                    string s = props[0]["Data"].ToString().Trim();
                    if (s != "" && !IsGeneric(s)) return s;
                }
            }
            catch { }
            return "";
        }

        static string UsbParentName(string vid, string pid)
        {
            if (vid == "") return "";
            foreach (var o in Q("SELECT Name, DeviceID FROM Win32_PnPEntity WHERE DeviceID LIKE 'USB\\\\VID_" + vid + "&PID_" + pid + "%'"))
            {
                string n = BusName(o);
                if (n != "") return n;
                n = P(o, "Name");
                if (!IsGeneric(n)) return n;
            }
            return "";
        }

        static long GpuMemory(string name)
        {
            try
            {
                using (var k = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"))
                    foreach (var sub in k.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(sub, @"^\d{4}$")) continue;
                        using (var g = k.OpenSubKey(sub))
                        {
                            if (g == null) continue;
                            var desc = g.GetValue("DriverDesc") as string;
                            if (desc == null || !name.StartsWith(desc.Trim(), StringComparison.OrdinalIgnoreCase)) continue;
                            object q = g.GetValue("HardwareInformation.qwMemorySize");
                            if (q != null) return Convert.ToInt64(q);
                            object m = g.GetValue("HardwareInformation.MemorySize");
                            if (m is byte[]) return BitConverter.ToUInt32((byte[])m, 0);
                            if (m != null) return Convert.ToInt64(m);
                        }
                    }
            }
            catch { }
            return 0;
        }

        // Device fingerprint used to bind a license to one PC.
        public string Hwid()
        {
            string raw = (BoardSerial + "|" + CpuId + "|" + SystemUuid).ToUpperInvariant();
            using (var sha = SHA256.Create())
            {
                var b = sha.ComputeHash(Encoding.UTF8.GetBytes("JDO-HWID-v1|" + raw));
                var hex = BitConverter.ToString(b).Replace("-", "");
                return hex.Substring(0, 8) + "-" + hex.Substring(8, 8) + "-" + hex.Substring(16, 8) + "-" + hex.Substring(24, 8);
            }
        }
    }

    // Live usage numbers, sampled once a second on a background thread.
    public class UsageMonitor : IDisposable
    {
        public double Cpu, Gpu, Ram, Disk;
        public double RamUsedGb, RamTotalGb, NetKbps;

        PerformanceCounter cpu, disk;
        List<PerformanceCounter> gpu = new List<PerformanceCounter>(), net = new List<PerformanceCounter>();
        DateTime gpuRefresh = DateTime.MinValue;

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORYSTATUSEX { public uint dwLength, dwMemoryLoad; public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual; }
        [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);

        public UsageMonitor()
        {
            try { cpu = new PerformanceCounter("Processor Information", "% Processor Utility", "_Total"); cpu.NextValue(); }
            catch { try { cpu = new PerformanceCounter("Processor", "% Processor Time", "_Total"); cpu.NextValue(); } catch { } }
            try { disk = new PerformanceCounter("PhysicalDisk", "% Idle Time", "_Total"); disk.NextValue(); } catch { }
            try
            {
                foreach (var n in new PerformanceCounterCategory("Network Interface").GetInstanceNames())
                { var c = new PerformanceCounter("Network Interface", "Bytes Total/sec", n); c.NextValue(); net.Add(c); }
            }
            catch { }
        }

        void RefreshGpu()
        {
            foreach (var c in gpu) c.Dispose();
            gpu.Clear();
            try
            {
                foreach (var n in new PerformanceCounterCategory("GPU Engine").GetInstanceNames())
                    if (n.EndsWith("engtype_3D")) { var c = new PerformanceCounter("GPU Engine", "Utilization Percentage", n); c.NextValue(); gpu.Add(c); }
            }
            catch { }
            gpuRefresh = DateTime.Now;
        }

        public void Sample()
        {
            try { if (cpu != null) Cpu = Math.Min(100, cpu.NextValue()); } catch { }
            try { if (disk != null) Disk = Math.Max(0, Math.Min(100, 100 - disk.NextValue())); } catch { }
            // GPU engine instances change as processes start and stop.
            if ((DateTime.Now - gpuRefresh).TotalSeconds > 10) RefreshGpu();
            double g = 0;
            foreach (var c in gpu) { try { g += c.NextValue(); } catch { } }
            Gpu = Math.Min(100, g);
            double b = 0;
            foreach (var c in net) { try { b += c.NextValue(); } catch { } }
            NetKbps = b * 8 / 1000;
            var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) };
            if (GlobalMemoryStatusEx(ref m))
            {
                Ram = m.dwMemoryLoad;
                RamTotalGb = m.ullTotalPhys / 1073741824.0;
                RamUsedGb = (m.ullTotalPhys - m.ullAvailPhys) / 1073741824.0;
            }
        }

        public void Dispose()
        {
            if (cpu != null) cpu.Dispose();
            if (disk != null) disk.Dispose();
            foreach (var c in gpu) c.Dispose();
            foreach (var c in net) c.Dispose();
        }
    }
}
