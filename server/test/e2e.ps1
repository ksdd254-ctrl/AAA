# End-to-end check of the license server against a running local instance.
#   powershell -File test\e2e.ps1 [-Base http://localhost:8080]
param([string]$Base = 'http://localhost:8080')
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot '..\server.log'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "PASS  $what" } else { $script:fail++; Write-Host "FAIL  $what" -ForegroundColor Red } }
function Post($path, $body, $session) {
  try { $r = Invoke-WebRequest "$Base$path" -Method Post -ContentType 'application/json' -Body ($body | ConvertTo-Json) -WebSession $session -UseBasicParsing; return $r.Content | ConvertFrom-Json }
  catch { if ($_.ErrorDetails.Message) { return $_.ErrorDetails.Message | ConvertFrom-Json }; throw }
}
function LastCode($email) { Start-Sleep -Milliseconds 300; $m = Select-String -Path $log -Pattern "\[mail -> $([regex]::Escape($email))\].*?(\d{6})" | Select-Object -Last 1; return $m.Matches[0].Groups[1].Value }

$email = "e2e$(Get-Random)@test.local"; $pw = 'TestPass123!'
$web = New-Object Microsoft.PowerShell.Commands.WebRequestSession

$r = Post '/api/auth/register' @{ email = $email; password = $pw } $web
Check 'register sends a code' ($r.ok -and $r.next -eq 'verify')
Check 'wrong code rejected' (-not (Post '/api/auth/verify' @{ email = $email; code = '000000' } $web).ok)
$r = Post '/api/auth/verify' @{ email = $email; code = (LastCode $email) } $web
Check 'correct code verifies and signs in' ($r.ok -and $r.user.email -eq $email)
Check 'no download before paying' ($r.user.download -eq $null)

$r = Post '/api/checkout' @{ plan = 'elite' } $web
Check 'checkout creates an order' ($r.ok -and $r.url)
Invoke-WebRequest "$Base$($r.url)" -WebSession $web -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue | Out-Null
$me = (Invoke-WebRequest "$Base/api/me" -WebSession $web -UseBasicParsing).Content | ConvertFrom-Json
$key = $me.user.licenses[0].key
Check 'paid order issues an Elite key' ($key -match '^JDO-(\w{4}-){3}\w{4}$' -and $me.user.licenses[0].tier -eq 2)
Check 'purchase email sent with key' ((Select-String -Path $log -Pattern ([regex]::Escape($key))) -ne $null)
Check 'download unlocked after paying' ($me.user.download -ne $null)

$c = Post '/api/client/login' @{ email = $email; password = $pw; key = $key; hwid = 'PC-A' } $null
Check 'program sign-in with key' ($c.ok -and $c.tier -eq 2 -and $c.role -eq 'user')
Check 'wrong password refused' ((Post '/api/client/login' @{ email = $email; password = 'nope'; key = $key; hwid = 'PC-A' } $null).error -eq 'credentials')
Check 'key refused on a second PC' ((Post '/api/client/login' @{ email = $email; password = $pw; key = $key; hwid = 'PC-B' } $null).error -eq 'hwid')
Check 'session re-check on launch' ((Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-A' } $null).ok)
Check 'stolen token on another PC refused' ((Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-B' } $null).error -eq 'hwid')
Check 'another user cannot use this key' (-not (Post '/api/client/login' @{ email = 'x@y.z'; password = $pw; key = $key; hwid = 'PC-A' } $null).ok)
Check 'normal user blocked from owner actions' ((Post '/api/owner/news' @{ token = $c.token; titleEn = 'hack' } $null).error -eq 'forbidden')

# owner actions through the website admin API (needs an owner web session)
if ($env:E2E_OWNER_EMAIL) {
  $own = New-Object Microsoft.PowerShell.Commands.WebRequestSession
  Check 'owner signs in' ((Post '/api/auth/login' @{ email = $env:E2E_OWNER_EMAIL; password = $env:E2E_OWNER_PASSWORD } $own).ok)
  $lic = ((Invoke-WebRequest "$Base/api/admin/licenses?q=$key" -WebSession $own -UseBasicParsing).Content | ConvertFrom-Json).licenses[0]
  Post "/api/admin/licenses/$($lic.id)" @{ action = 'lock' } $own | Out-Null
  Check 'locked key stops the program' ((Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-A' } $null).error -eq 'locked')
  Post "/api/admin/licenses/$($lic.id)" @{ action = 'unlock' } $own | Out-Null
  Post "/api/admin/licenses/$($lic.id)" @{ action = 'reset_hwid' } $own | Out-Null
  Check 'after device reset, key works on new PC' ((Post '/api/client/login' @{ email = $email; password = $pw; key = $key; hwid = 'PC-B' } $null).ok)
  $g = Post '/api/admin/licenses' @{ email = $email; tier = 3; days = 1 } $own
  Check 'owner creates a 1-day Ultimate key' ($g.ok -and $g.key)
  Post '/api/admin/news' @{ titleAr = 'تجربة'; titleEn = 'Test news' } $own | Out-Null
  $n = Post '/api/news' @{ lang = 'en' } $null
  Check 'announcement reaches users' ($n.items[0].title -eq 'Test news')
  $u = ((Invoke-WebRequest "$Base/api/admin/users?q=$email" -WebSession $own -UseBasicParsing).Content | ConvertFrom-Json).users[0]
  Post "/api/admin/users/$($u.id)" @{ free_tier = 3 } $own | Out-Null
  Check 'free access lets user in without a key' ((Post '/api/client/login' @{ email = $email; password = $pw; hwid = 'PC-C' } $null).tier -eq 3)
  $nid = ((Invoke-WebRequest "$Base/api/admin/news" -WebSession $own -UseBasicParsing).Content | ConvertFrom-Json).news[0].id
  Post "/api/admin/news/$nid/delete" @{} $own | Out-Null
}
Write-Host "`nPASS $pass  FAIL $fail"
exit $fail
