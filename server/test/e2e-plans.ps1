# Sign-up from the app and admin-granted plans, against a running local test instance.
#   powershell -File test\e2e-plans.ps1 -Base http://localhost:8098 -Log <server log> (owner via E2E_OWNER_EMAIL / E2E_OWNER_PASSWORD)
param([string]$Base = 'http://localhost:8098', [string]$Log)
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Check($what, $ok) { if ($ok) { $script:pass++; Write-Host "PASS  $what" } else { $script:fail++; Write-Host "FAIL  $what" -ForegroundColor Red } }
function Post($path, $body) {
  try { (Invoke-WebRequest "$Base$path" -Method Post -ContentType 'application/json' -Body ($body | ConvertTo-Json) -UseBasicParsing).Content | ConvertFrom-Json }
  catch { if ($_.ErrorDetails.Message) { return $_.ErrorDetails.Message | ConvertFrom-Json }; throw }
}
function LastCode($email) { Start-Sleep -Milliseconds 400; $m = Select-String -Path $Log -Pattern "\[mail -> $([regex]::Escape($email))\].*?(\d{6})" | Select-Object -Last 1; $m.Matches[0].Groups[1].Value }

$email = "user$(Get-Random)@test.local"; $pw = 'UserPass123!'

# --- sign-up from the app
Check 'short password refused' ((Post '/api/client/register' @{ email = $email; password = 'short' }).error -eq 'password')
Check 'bad email refused' ((Post '/api/client/register' @{ email = 'not-an-email'; password = $pw }).error -eq 'email')
Check 'sign-up sends a code' ((Post '/api/client/register' @{ email = $email; password = $pw }).ok)
Check 'cannot sign in before confirming the email' ((Post '/api/client/login' @{ email = $email; password = $pw; hwid = 'PC-1' }).error -eq 'credentials')
Check 'wrong code refused' ((Post '/api/client/confirm' @{ email = $email; code = '000000' }).error -eq 'code')
Check 'right code confirms the email' ((Post '/api/client/confirm' @{ email = $email; code = (LastCode $email) }).ok)
Check 'same email cannot sign up twice' ((Post '/api/client/register' @{ email = $email; password = $pw }).error -eq 'exists')

# --- new account: signs in, no plan
$c = Post '/api/client/login' @{ email = $email; password = $pw; hwid = 'PC-1' }
Check 'new account signs in without a key' ($c.ok)
Check 'new account has no plan (tier 0)' ($c.tier -eq 0 -and -not $c.lite)
Check 'launch re-check works without a plan' ((Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-1' }).ok)
Check 'normal user cannot list users' ((Post '/api/owner/users' @{ token = $c.token }).error -eq 'forbidden')
Check 'normal user cannot give plans' ((Post '/api/owner/plan' @{ token = $c.token; userId = 1; tier = 3 }).error -eq 'forbidden')
Check 'invalid key still refused' ((Post '/api/client/login' @{ email = $email; password = $pw; key = 'JDO-FAKE-FAKE-FAKE-FAKE'; hwid = 'PC-1' }).error -eq 'credentials')

# --- admin gives plans from the app
$o = Post '/api/client/login' @{ email = $env:E2E_OWNER_EMAIL; password = $env:E2E_OWNER_PASSWORD; hwid = 'ADMIN-PC' }
Check 'admin signs in with every plan' ($o.ok -and $o.role -eq 'owner' -and $o.tier -eq 3 -and $o.lite)
$list = Post '/api/owner/users' @{ token = $o.token; q = $email }
$u = $list.users | Where-Object email -eq $email
Check 'admin sees the new account with no plan' ($u -and $u.tier -eq 0 -and $u.verified)

Check 'admin gives Elite for 30 days' ((Post '/api/owner/plan' @{ token = $o.token; userId = $u.id; tier = 2; days = 30 }).ok)
$v = Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-1' }
Check 'user gets Elite on next check, with an end date' ($v.tier -eq 2 -and $v.expires -and -not $v.lite)

Check 'admin gives Ultimate + Lite Windows, lifetime' ((Post '/api/owner/plan' @{ token = $o.token; userId = $u.id; tier = 3; lite = $true; days = 0 }).ok)
$v = Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-1' }
Check 'user gets Ultimate + Lite, no end date' ($v.tier -eq 3 -and $v.lite -and -not $v.expires)

Check 'lite flag ignored below Ultimate' ((Post '/api/owner/plan' @{ token = $o.token; userId = $u.id; tier = 1; lite = $true }).ok)
Check 'Basic never carries Lite Windows' (-not (Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-1' }).lite)

Check 'admin removes the plan' ((Post '/api/owner/plan' @{ token = $o.token; userId = $u.id; tier = 0 }).ok)
Check 'user is back to no plan' ((Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-1' }).tier -eq 0)

Check 'invalid plan number refused' ((Post '/api/owner/plan' @{ token = $o.token; userId = $u.id; tier = 7 }).error -eq 'tier')
$me = ($list.users | Where-Object role -eq 'owner') ; if (-not $me) { $me = (Post '/api/owner/users' @{ token = $o.token; q = $env:E2E_OWNER_EMAIL }).users[0] }
Check 'admin account plan cannot be changed' ((Post '/api/owner/plan' @{ token = $o.token; userId = $me.id; tier = 0 }).error -eq 'owner')

# --- forgotten password from the app
Check 'forgot sends a code' ((Post '/api/client/forgot' @{ email = $email }).ok)
Check 'unknown email gets the same answer' ((Post '/api/client/forgot' @{ email = 'nobody@test.local' }).ok)
Check 'reset refuses a wrong code' ((Post '/api/client/reset' @{ email = $email; code = '000000'; password = 'NewPass456!' }).error -eq 'code')
$rc = LastCode $email
Check 'reset refuses a short password' ((Post '/api/client/reset' @{ email = $email; code = $rc; password = 'short' }).error -eq 'password')
Check 'reset with the right code' ((Post '/api/client/reset' @{ email = $email; code = $rc; password = 'NewPass456!' }).ok)
Check 'old sessions are signed out' ((Post '/api/client/verify' @{ token = $c.token; hwid = 'PC-1' }).error -eq 'credentials')
Check 'old password no longer works' ((Post '/api/client/login' @{ email = $email; password = $pw; hwid = 'PC-1' }).error -eq 'credentials')
Check 'new password works' ((Post '/api/client/login' @{ email = $email; password = 'NewPass456!'; hwid = 'PC-1' }).ok)

Write-Host "`nPASS $pass  FAIL $fail"
exit $fail
