# JDO x QHT - latency check (read only, changes nothing): timer resolution, DPC and interrupt time, context switches,
# and what is waking the CPU in the background. Run it while the PC is idle, and again while a game is open:
# the second run is the one that matters. Good numbers = steady frame times, no stutter.
#   timer      the finest timer a game can get (0.5 ms is the best Windows allows)
#   % DPC      time the CPU spends in driver deferred work: the lower the better, under 1 % is good
#   % Interrupt time spent answering hardware: under 1 % is good
#   spikes     the worst second: a big gap to the average means stutter even when the average looks fine
param([int]$Seconds = 20)
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force (Join-Path $root 'logs') | Out-Null
Start-Transcript (Join-Path $root ('logs\latency-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')) | Out-Null
try { $Host.UI.RawUI.WindowTitle = 'JDO x QHT - latency'; $Host.UI.RawUI.BackgroundColor = 'Black'; Clear-Host } catch { }
function Line([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Verdict([double]$v, [double]$good, [double]$ok) { if ($v -le $good) { 'GOOD' } elseif ($v -le $ok) { 'OK' } else { 'HIGH' } }
function Col([string]$v) { switch ($v) { 'GOOD' { 'Green' } 'OK' { 'Yellow' } default { 'Red' } } }

Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class JdoTimer {
  [DllImport("ntdll.dll")] static extern int NtQueryTimerResolution(out uint min, out uint max, out uint cur);
  public static void Get(out double coarsest, out double finest, out double current) {
    uint a, b, c; NtQueryTimerResolution(out a, out b, out c);
    coarsest = a / 10000.0; finest = b / 10000.0; current = c / 10000.0;
  }
}
'@ -ErrorAction SilentlyContinue

Line ''; Line 'JDO x QHT - latency check' 'Magenta'; Line "  $Seconds seconds of measuring. Leave the PC as it is." 'DarkGray'

# ---- timer ----
Line ''; Line '== Timer resolution' 'Magenta'
$co = 0.0; $fi = 0.0; $cu = 0.0
try { [JdoTimer]::Get([ref]$co, [ref]$fi, [ref]$cu) } catch { }
if ($fi -gt 0) {
  $v = Verdict $fi 0.51 1.01
  Line ("  finest available : {0:N3} ms   {1}" -f $fi, $v) (Col $v)
  Line ("  right now        : {0:N3} ms   (a game asks for the finest one; at idle 1 ms or 15.6 ms is normal)" -f $cu) 'Gray'
  $gt = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' -Name GlobalTimerResolutionRequests -ErrorAction SilentlyContinue).GlobalTimerResolutionRequests
  Line ("  global timer requests: {0}   (1 = a game's request applies to the whole system - set by JDO x QHT)" -f $(if ($null -eq $gt) { 'default' } else { $gt })) 'Gray'
} else { Line '  could not read the timer' 'Yellow' }

# ---- DPC / interrupt ----
Line ''; Line '== DPC and interrupt time (the latency that reaches your mouse and frames)' 'Magenta'
$paths = '\Processor Information(_Total)\% DPC Time', '\Processor Information(_Total)\% Interrupt Time', '\Processor Information(_Total)\DPCs Queued/sec',
         '\Processor Information(_Total)\Interrupts/sec', '\Processor Information(_Total)\% Processor Time', '\System\Context Switches/sec', '\System\Processor Queue Length'
$s = Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples $Seconds
function Stat([int]$i) { $x = @($s | ForEach-Object { $_.CounterSamples[$i].CookedValue }); [pscustomobject]@{ Avg = ($x | Measure-Object -Average).Average; Max = ($x | Measure-Object -Maximum).Maximum } }
$dpc = Stat 0; $int = Stat 1; $dq = Stat 2; $ir = Stat 3; $cpu = Stat 4; $cs = Stat 5; $q = Stat 6
$v = Verdict $dpc.Avg 0.5 1.5;  Line ("  % DPC time        avg {0,6:N2}   worst second {1,6:N2}   {2}" -f $dpc.Avg, $dpc.Max, $v) (Col $v)
$v2 = Verdict $int.Avg 0.5 1.5; Line ("  % interrupt time  avg {0,6:N2}   worst second {1,6:N2}   {2}" -f $int.Avg, $int.Max, $v2) (Col $v2)
Line ("  DPCs per second   avg {0,6:N0}   worst second {1,6:N0}" -f $dq.Avg, $dq.Max)
Line ("  interrupts / sec  avg {0,6:N0}   worst second {1,6:N0}" -f $ir.Avg, $ir.Max)
Line ("  context switches  avg {0,6:N0}   worst second {1,6:N0}" -f $cs.Avg, $cs.Max)
Line ("  CPU usage         avg {0,6:N1} %  worst second {1,6:N1} %   run queue avg {2:N1}" -f $cpu.Avg, $cpu.Max, $q.Avg)
if ($dpc.Max -gt [Math]::Max(3, $dpc.Avg * 6)) { Line '  -> there are DPC spikes: that is what feels like micro-stutter. Find the driver with LatencyMon (resplendence.com) while it happens.' 'Yellow' }

# ---- who wakes the CPU ----
Line ''; Line '== Background activity (CPU share over 10 s, programs using more than 0.2 %)' 'Magenta'
$p1 = @{}; Get-Process | ForEach-Object { $p1[$_.Id] = $_.TotalProcessorTime.TotalSeconds }
Start-Sleep -Seconds 10
$cores = [Environment]::ProcessorCount
$busy = Get-Process | ForEach-Object { if ($p1.ContainsKey($_.Id)) { [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id; Pct = (($_.TotalProcessorTime.TotalSeconds - $p1[$_.Id]) / 10 / $cores * 100); MB = [int]($_.WorkingSet64 / 1MB) } } } |
        Where-Object { $_.Pct -gt 0.2 -and $_.Name -ne 'Idle' } | Sort-Object Pct -Descending | Select-Object -First 12
if ($busy) { $busy | ForEach-Object { Line ("  {0,-34} {1,5:N2} %   {2,5} MB" -f $_.Name, $_.Pct, $_.MB) 'Gray' } } else { Line '  nothing above 0.2 % - the system is quiet' 'Green' }
$n = (Get-Process).Count; $svc = (Get-Service | Where-Object Status -eq 'Running').Count
Line ''; Line ("  {0} processes, {1} services running" -f $n, $svc) 'Gray'
$bad = Get-Process | Where-Object { $_.ProcessName -match '^(MsMpEng|SearchIndexer|TiWorker|MoUsoCoreWorker|OneDrive|SgrmBroker|CompatTelRunner|wuauclt|UsoClient|NisSrv|smartscreen|GameBar|YourPhone|Cortana|SearchApp|ShellExperienceHost|StartMenuExperienceHost)$' }
if ($bad) { Line '  known background makers running right now:' 'Yellow'; $bad | ForEach-Object { Line "    $($_.ProcessName)" 'Yellow' } } else { Line '  none of the usual background makers (updates, indexing, telemetry, Defender) is running' 'Green' }

Line ''
$allGood = ($dpc.Avg -le 0.5 -and $int.Avg -le 0.5 -and $fi -le 0.51 -and $dpc.Max -le [Math]::Max(3, $dpc.Avg * 6))
if ($allGood) { Line '== Result: GOOD - low, steady latency.' 'Green' } else { Line '== Result: see the lines marked HIGH / spikes above.' 'Yellow' }
Line "   Log: $root\logs" 'DarkGray'
Stop-Transcript | Out-Null
if ($Host.Name -eq 'ConsoleHost' -and -not $env:JDO_NOPAUSE) { Read-Host '  Press Enter to close' | Out-Null }
