<#
  End-to-end verification that ONE trial converted to a paid subscription.

  WHY THIS EXISTS: on 2026-08-16/17 two subscribers were debited at PhonePe while
  Neon still said `trialing` — they paid and lost premium for two days, and
  nothing surfaced it. The cron bug is fixed (docs/autopay-debits.md), but the
  first conversion to run entirely on the fixed code still has to be WATCHED,
  because a silent failure looks exactly like success.

  Checks three independent layers, because any one of them can lie:
    1. Neon  — did the row actually become a paying subscriber?
    2. Neon  — is anything else stuck mid-debit?
    3. KV    — did the GA4 purchase event reach Google? (the receipt key is only
               written after GA4 returns OK, so it cannot be faked by intent)

  Usage:
    powershell -File tools/verify-conversion.ps1 -MerchantSubId DKS_S_...
    powershell -File tools/verify-conversion.ps1 -MerchantSubId DKS_S_... -SelfDestruct TaskName

  Must run from a machine with workers/.dev.vars and a wrangler login — that is
  why this cannot be a cloud routine.
#>
param(
  [Parameter(Mandatory = $true)][string]$MerchantSubId,
  [string]$OrderId = "",
  [string]$ReportDir = "$env:USERPROFILE\Desktop",
  [string]$SelfDestruct = ""
)

$ErrorActionPreference = "Continue"
$workers = Split-Path -Parent $PSScriptRoot
Set-Location $workers

$stamp  = Get-Date -Format "yyyy-MM-dd_HHmm"
$report = Join-Path $ReportDir "arul-billing-check_$stamp.txt"
$lines  = New-Object System.Collections.Generic.List[string]

function Add-Line { param([string]$t) $lines.Add($t); Write-Output $t }

Add-Line "Arul billing verification - $(Get-Date -Format 'yyyy-MM-dd HH:mm') IST"
Add-Line "Subscription: $MerchantSubId"
Add-Line ("=" * 70)

# ── 1. Did this subscription actually become a paying one? ────────────────────
Add-Line "`n[1] Subscription state (Neon)"
$q = "SELECT merchant_subscription_id, status, current_period_end > now() AS entitled, " +
     "to_char(current_period_end,'YYYY-MM-DD HH24:MI') AS period_end, redemption_order_id " +
     "FROM subscriptions WHERE merchant_subscription_id = '$MerchantSubId'"
$subJson = & node tools/prod-query.mjs $q 2>&1 | Out-String
Add-Line $subJson.Trim()

$converted = ($subJson -match '"status":\s*"active"') -and ($subJson -match '"entitled":\s*true')

# ── 2. Is anything at all stuck mid-debit? ────────────────────────────────────
Add-Line "`n[2] Fleet-wide stuck-debit check"
$health = & node tools/verify-debits.mjs 2>&1 | Out-String
$healthOk = ($LASTEXITCODE -eq 0)
Add-Line $health.Trim()

# ── 3. Did the purchase reach GA4? ────────────────────────────────────────────
# The KV key is written ONLY after GA4 accepts the Measurement Protocol call, so
# its presence is a receipt, not an intention.
Add-Line "`n[3] GA4 purchase receipts (KV)"
$kv = & npx wrangler kv key list --namespace-id 8bf33c34e2ec41cd8ca98611dc5a70fb --remote --prefix "ga4:purchase:" 2>&1 | Out-String
Add-Line $kv.Trim()

$purchaseReported = $false
if ($OrderId -ne "") {
  $purchaseReported = $kv -match [regex]::Escape($OrderId)
  Add-Line "`nLooking for order $OrderId -> $(if ($purchaseReported) { 'FOUND' } else { 'NOT FOUND' })"
}

# ── Verdict ───────────────────────────────────────────────────────────────────
Add-Line "`n$("=" * 70)"
$verdict = if ($converted -and $healthOk -and ($OrderId -eq "" -or $purchaseReported)) {
  "PASS - trial converted to paid, nothing stuck, purchase reported to GA4."
} elseif ($converted) {
  "PARTIAL - the subscription IS active and paid, but another check failed. Read above."
} else {
  "FAIL - $MerchantSubId did not convert. Do NOT re-notify or re-run redemptions: " +
  "the money may already have been taken. Read docs/autopay-debits.md and check the " +
  "PhonePe order state first."
}
Add-Line $verdict

$lines -join "`r`n" | Out-File -FilePath $report -Encoding utf8
Write-Output "`nReport written to: $report"

# Pop it so the result is seen rather than sitting in a file nobody opens.
try { Start-Process notepad.exe $report } catch { }

# ── Self-destruct ─────────────────────────────────────────────────────────────
# One-shot by design: a stale task firing every day for a subscription that was
# settled long ago is noise, and noise is what hid the original bug.
if ($SelfDestruct -ne "") {
  try {
    schtasks /Delete /TN $SelfDestruct /F | Out-Null
    Write-Output "Scheduled task '$SelfDestruct' removed."
  } catch {
    Write-Output "Could not remove task '$SelfDestruct' - delete it manually: schtasks /Delete /TN $SelfDestruct /F"
  }
}
