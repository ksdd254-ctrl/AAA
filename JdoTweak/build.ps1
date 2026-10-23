# Builds JdoTweak.exe with the C# compiler that ships with Windows (.NET Framework 4.8).
# No SDK or Visual Studio needed. The result runs on any Windows 10/11 PC as-is.
#   powershell -ExecutionPolicy Bypass -File build.ps1          -> release build (license server required)
#   powershell -ExecutionPolicy Bypass -File build.ps1 -Dev     -> developer build (skips sign-in)
#   -Version 1.0.1                                             -> version number; raise it for every update you publish
param([switch]$Dev, [string]$Api = "", [string]$Version = "1.0.0")
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fw   = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$wpf  = "$fw\WPF"
$out  = Join-Path $here 'dist'
$obj  = Join-Path $here 'obj'
New-Item -ItemType Directory -Force $out, $obj | Out-Null

# Generated tweak library (tools\LibGen.exe E:\JDO_CLEAN analysis\settings.csv JdoTweak\Data\library.tsv.gz)
$gz = Join-Path $here 'Data\library.tsv.gz'

$refs = @(
  "$wpf\PresentationFramework.dll", "$wpf\PresentationCore.dll", "$wpf\WindowsBase.dll", "$fw\System.Xaml.dll",
  "$fw\System.dll", "$fw\System.Core.dll", "$fw\System.Xml.dll", "$fw\System.Management.dll", "$fw\System.Security.dll",
  "$fw\System.Web.Extensions.dll", "$fw\System.ServiceProcess.dll", "$fw\Microsoft.CSharp.dll", "$fw\System.Net.dll"
) | ForEach-Object { "/r:`"$_`"" }

$res = @("/resource:`"$here\src\Theme.xaml`",JdoTweak.Theme.xaml",
         "/resource:`"$here\Data\tweaks.json`",JdoTweak.tweaks.json",
         "/resource:`"$here\Data\JDO_AutoFix.cmd`",JdoTweak.JDO_AutoFix.cmd")
if (Test-Path $gz) { $res += "/resource:`"$gz`",JdoTweak.library.tsv.gz" }

$icon = Join-Path $here 'Data\app.ico'
$cscArgs = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/langversion:5', '/utf8output',
          "/out:`"$out\JdoTweak.exe`"", "/win32manifest:`"$here\app.manifest`"") + $refs + $res
if (Test-Path $icon) { $cscArgs += "/win32icon:`"$icon`"" }
if ($Dev) { $cscArgs += '/define:DEV' }
if (-not $Dev -and -not $Api) { throw "Release build needs -Api https://your-domain" }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "-Version must look like 1.2.3" }
Set-Content "$obj\BuildInfo.cs" "namespace JdoTweak { static class BuildInfo { public const string ApiBase = `"$Api`"; public const string Version = `"$Version`"; } }" -Encoding UTF8
$cscArgs += "`"$obj\BuildInfo.cs`""
$cscArgs += (Get-ChildItem "$here\src\*.cs" | ForEach-Object { "`"$($_.FullName)`"" })

& "$fw\csc.exe" @cscArgs
if ($LASTEXITCODE -ne 0) { throw "Build failed" }
$size = [math]::Round((Get-Item "$out\JdoTweak.exe").Length / 1MB, 1)
Write-Host "Built $out\JdoTweak.exe v$Version ($size MB)$(if ($Dev) { ' [DEV]' })" -ForegroundColor Green
