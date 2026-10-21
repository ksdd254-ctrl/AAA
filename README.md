# جدو الشايب تويك — JDO Al-Shayeb Tweak

Windows tweaking and repair app (Arabic / English) with plan tiers and license keys.

## Layout

| Path | What it is |
|---|---|
| `JdoTweak/src/` | Desktop app source (C# 5, WPF, .NET Framework 4.8 — builds with the compiler built into Windows) |
| `JdoTweak/Data/tweaks.json` | Hand-picked tweaks (bilingual, with options, revert values, tiers, risk levels) |
| `JdoTweak/Data/library.json` | Generated library: option tweaks + every cleaned pack file (built by `tools/gen_catalog.ps1`) |
| `JdoTweak/Data/JDO_AutoFix.cmd` | Stand-alone auto-repair tool users can download from the app |
| `JdoTweak/build.ps1` | Build script → `JdoTweak/dist/JdoTweak.exe` |
| `tools/analyze.ps1` | Reads every tweak file and counts how often each setting/value is used |
| `tools/clean.ps1` | Cleans the raw packs into `E:\JDO_CLEAN` (dedupe, remove spoofer/boot/TaskCache, split network) |
| `tools/gen_catalog.ps1` | Turns the analysis + clean packs into `library.json` |
| `tools/litewin/build.ps1` | Builds the Lite Windows ISO (Windows 10 22H2 Pro, Fortnite + Store only) from an official ISO |
| `tools/litewin/files/` | What goes into that image: `autounattend.xml`, first-boot scripts, and `C:\JDO` (tools menu + drivers) |

## Lite Windows build

```powershell
powershell -ExecutionPolicy Bypass -File tools\litewin\build.ps1 -Iso C:\Users\1\Desktop\Windows.iso   # as admin
```

Output goes to `E:\win 10 JDO` (`-Work` to change): `JDO_Lite_W10_22H2.iso`, `build.log`, a copy of the builder,
`drivers\` (this PC's network drivers, exported automatically) and `drivers-extra\` (put any other `.inf` drivers here
before building, e.g. Intel LAN or AMD chipset; they are added to the image too). `-KeepDefender` keeps Defender on,
`-NoMitigations` turns Spectre/Meltdown mitigations off.

## Build

```powershell
powershell -ExecutionPolicy Bypass -File JdoTweak\build.ps1 -Dev   # developer build, skips sign-in
powershell -ExecutionPolicy Bypass -File JdoTweak\build.ps1        # release build, needs the license server
```

Set `License.ApiBase` in `src/License.cs` to the server URL before a release build.

## Plans

| Plan | Price | Gets |
|---|---|---|
| Basic | $10 | Tier-1 tweaks |
| Elite | $25 | Tier 1 + 2 |
| Ultimate | $35 | Everything (all tiers + full library) |
| Ultimate + Lite Windows | $45 | Everything + the lite Windows image |

## Pack cleaning rules (`tools/clean.ps1`)

Removed: exact-duplicate files and lines (first one kept), boot/BCD edits, Task Scheduler breakers
(TaskCache edits, deleting the Tasks folder, disabling the Schedule service), serial/HWID/BIOS identity
changes, MAC address changes, static IP / DHCP changes, and cheat files (aim, recoil, spoofer, .gpc).

Kept: everything else — including Defender / UAC / Windows Update / Store / Xbox tweaks.

Network lines are moved out of mixed files into `E:\JDO_CLEAN\Network`.
Every removed item is listed with its reason in `E:\JDO_CLEAN\_Reports\removed.csv`.
