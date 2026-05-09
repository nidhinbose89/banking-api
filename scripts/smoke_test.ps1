# Smoke test for the Banking API (HTTPS with self-signed cert).
# Usage: .\scripts\smoke_test.ps1 [BASE_URL]
# Supports Windows PowerShell 5.1 and PowerShell 7+.

param(
    [string]$BaseUrl = "https://banking-api-alb-1168095763.ap-southeast-1.elb.amazonaws.com"
)

if ($PSVersionTable.PSVersion.Major -ge 6) {
    $script:SkipCertCheck = @{ SkipCertificateCheck = $true }
} else {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::CheckCertificateRevocationList = $false
    $script:SkipCertCheck = @{}
}

if ($PSVersionTable.PSVersion.Major -ge 6) {
    $script:SmokeSkipHttpError = @{ SkipHttpErrorCheck = $true }
} else {
    $script:SmokeSkipHttpError = @{}
}

$ErrorActionPreference = "Stop"
$Total = 10
$BaseUrl = $BaseUrl.TrimEnd("/")
# Unique per run so repeat runs against the same DB do not reuse idempotency keys from earlier smoke tests.
$SmokeNonce = ([guid]::NewGuid().ToString("N")).Substring(0, 8)

function Complete-SmokeWebResponse {
    param($WebResponse)
    return [pscustomobject]@{
        StatusCode = [int]$WebResponse.StatusCode
        Content    = [string]$WebResponse.Content
    }
}

function Invoke-SmokeRequest {
    param(
        [ValidateSet("GET", "POST")]
        [string]$Method,
        [string]$Path,
        [hashtable]$Headers = @{},
        [string]$Body = $null
    )
    $uri = "$BaseUrl$Path"
    $params = @{
        Uri = $uri
    }
    switch ($Method) {
        "GET" {
            $params.Method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Get
        }
        "POST" {
            $params.Method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Post
        }
    }
    if ($Headers.Count -gt 0) {
        $params.Headers = $Headers
    }
    if ($Method -eq "POST") {
        if ([string]::IsNullOrWhiteSpace($Body)) {
            throw "Invoke-SmokeRequest: POST requires a non-empty Body"
        }
        $params.ContentType = "application/json"
        $params.Body = $Body
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $params.TimeoutSec = 30
        $web = Invoke-WebRequest @params @script:SkipCertCheck @script:SmokeSkipHttpError
        return Complete-SmokeWebResponse $web
    }

    try {
        $web = Invoke-WebRequest @params @script:SkipCertCheck
        return Complete-SmokeWebResponse $web
    } catch {
        $ex = $_.Exception
        while ($null -ne $ex -and $ex -isnot [System.Net.WebException]) {
            $ex = $ex.InnerException
        }
        if ($ex -isnot [System.Net.WebException]) {
            throw
        }
        $resp = $ex.Response
        if ($null -eq $resp) { throw }
        $code = [int]$resp.StatusCode
        $content = ""
        try {
            $s = $resp.GetResponseStream()
            if ($null -ne $s) {
                $ms = New-Object System.IO.MemoryStream
                try {
                    $s.CopyTo($ms)
                    $content = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
                } finally {
                    $ms.Dispose()
                    $s.Dispose()
                }
            }
        } finally {
            $resp.Dispose()
        }
        return [pscustomobject]@{
            StatusCode = $code
            Content    = $content
        }
    }
}

function Assert-DecimalEqual {
    param(
        [object]$Actual,
        [decimal]$Expected,
        [string]$Context
    )
    if ($null -eq $Actual) {
        Write-Error "$Context balance/new_balance is null"
        exit 1
    }
    [decimal]$da = 0
    if ($Actual -is [decimal]) {
        $da = $Actual
    } elseif ($Actual -is [string]) {
        if (-not [decimal]::TryParse(
                $Actual,
                [System.Globalization.NumberStyles]::Any,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$da)) {
            Write-Error "$Context could not parse balance/new_balance: '$Actual'"
            exit 1
        }
    } else {
        try {
            $da = [decimal]$Actual
        } catch {
            Write-Error "$Context could not parse balance/new_balance: '$Actual'"
            exit 1
        }
    }
    if ($da -ne $Expected) {
        Write-Error "$Context expected balance/new_balance $Expected got $da (raw '$Actual')"
        exit 1
    }
}

# --- [1/10] Health ---
$r = Invoke-SmokeRequest -Method GET -Path "/health"
if ($r.StatusCode -ne 200) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[1/$Total] Health check ... FAIL"
    exit 1
}
$h = $r.Content | ConvertFrom-Json
if ($h.status -ne "ok") {
    Write-Host "Actual body: $($r.Content)"
    Write-Error "[1/$Total] Health check ... FAIL"
    exit 1
}
Write-Host "[1/$Total] Health check ... PASS"

# --- [2/10] Version ---
$r = Invoke-SmokeRequest -Method GET -Path "/version"
if ($r.StatusCode -ne 200) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[2/$Total] Version check ... FAIL"
    exit 1
}
Write-Host "Version response: $($r.Content)"
$v = $r.Content | ConvertFrom-Json
$sha = $v.version
Write-Host "[2/$Total] Version check ... PASS (sha=$sha)"

# --- [3/10] Create account ---
$r = Invoke-SmokeRequest -Method POST -Path "/accounts" -Body '{"holder_name": "Smoke Test User", "opening_balance": 1000}'
if ($r.StatusCode -ne 201) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[3/$Total] Create account ... FAIL"
    exit 1
}
$acc = $r.Content | ConvertFrom-Json
$accountId = $acc.id
if ($null -eq $accountId) {
    Write-Host "Could not parse account id from: $($r.Content)"
    Write-Error "[3/$Total] Create account ... FAIL"
    exit 1
}
Write-Host "[3/$Total] Create account ... PASS (id=$accountId)"

# --- [4/10] Get balance ---
$r = Invoke-SmokeRequest -Method GET -Path "/accounts/$accountId/balance"
if ($r.StatusCode -ne 200) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[4/$Total] Get balance ... FAIL"
    exit 1
}
$bal = ($r.Content | ConvertFrom-Json).balance
Assert-DecimalEqual -Actual "$bal" -Expected 1000 -Context "[4/$Total] Get balance"
Write-Host "[4/$Total] Get balance ... PASS"

# --- [5/10] Deposit ---
$r = Invoke-SmokeRequest -Method POST -Path "/accounts/$accountId/deposit" `
    -Headers @{ "Idempotency-Key" = "smoke-deposit-1-$SmokeNonce" } `
    -Body '{"amount": 500}'
if ($r.StatusCode -ne 200) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[5/$Total] Deposit ... FAIL"
    exit 1
}
$dep1 = $r.Content | ConvertFrom-Json
Assert-DecimalEqual -Actual "$($dep1.new_balance)" -Expected 1500 -Context "[5/$Total] Deposit"
Write-Host "[5/$Total] Deposit ... PASS"

# --- [6/10] Idempotency replay ---
$r = Invoke-SmokeRequest -Method POST -Path "/accounts/$accountId/deposit" `
    -Headers @{ "Idempotency-Key" = "smoke-deposit-1-$SmokeNonce" } `
    -Body '{"amount": 500}'
if ($r.StatusCode -ne 200) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[6/$Total] Idempotency replay ... FAIL"
    exit 1
}
$dep2 = $r.Content | ConvertFrom-Json
if ($dep1.account_id -ne $dep2.account_id -or $dep1.type -ne $dep2.type -or
    [decimal]$dep1.transaction_id -ne [decimal]$dep2.transaction_id -or
    [decimal]$dep1.amount -ne [decimal]$dep2.amount -or
    [decimal]$dep1.new_balance -ne [decimal]$dep2.new_balance) {
    Write-Host "Replay response differs. First: $($dep1 | ConvertTo-Json -Compress) Second: $($dep2 | ConvertTo-Json -Compress)"
    Write-Error "[6/$Total] Idempotency replay ... FAIL"
    exit 1
}
Assert-DecimalEqual -Actual "$($dep2.new_balance)" -Expected 1500 -Context "[6/$Total] Idempotency replay"
Write-Host "[6/$Total] Idempotency replay ... PASS"

# --- [7/10] Idempotency conflict ---
$r = Invoke-SmokeRequest -Method POST -Path "/accounts/$accountId/deposit" `
    -Headers @{ "Idempotency-Key" = "smoke-deposit-1-$SmokeNonce" } `
    -Body '{"amount": 999}'
if ($r.StatusCode -ne 422) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[7/$Total] Idempotency conflict ... FAIL"
    exit 1
}
Write-Host "[7/$Total] Idempotency conflict ... PASS"

# --- [8/10] Withdraw ---
$r = Invoke-SmokeRequest -Method POST -Path "/accounts/$accountId/withdraw" `
    -Headers @{ "Idempotency-Key" = "smoke-withdraw-1-$SmokeNonce" } `
    -Body '{"amount": 200}'
if ($r.StatusCode -ne 200) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[8/$Total] Withdraw ... FAIL"
    exit 1
}
$w = $r.Content | ConvertFrom-Json
Assert-DecimalEqual -Actual "$($w.new_balance)" -Expected 1300 -Context "[8/$Total] Withdraw"
Write-Host "[8/$Total] Withdraw ... PASS"

# --- [9/10] Insufficient funds ---
$r = Invoke-SmokeRequest -Method POST -Path "/accounts/$accountId/withdraw" `
    -Headers @{ "Idempotency-Key" = "smoke-withdraw-fail-$SmokeNonce" } `
    -Body '{"amount": 999999}'
if ($r.StatusCode -ne 422) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[9/$Total] Insufficient funds ... FAIL"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($r.Content) -or ($r.Content -match "Insufficient funds")) {
    Write-Host "[9/$Total] Insufficient funds ... PASS"
} else {
    try {
        $err = $r.Content | ConvertFrom-Json
    } catch {
        Write-Host "Actual HTTP 422 body: $($r.Content)"
        Write-Error "[9/$Total] Insufficient funds ... FAIL"
        exit 1
    }
    $detail = $err.detail
    $ok = ($detail -eq "Insufficient funds")
    if (-not $ok -and ($detail -is [System.Array])) {
        foreach ($item in $detail) {
            if ("$item" -eq "Insufficient funds") { $ok = $true; break }
        }
    }
    if (-not $ok) {
        Write-Host "Actual HTTP 422 body: $($r.Content)"
        Write-Error "[9/$Total] Insufficient funds ... FAIL (expected detail 'Insufficient funds', got: $detail)"
        exit 1
    }
    Write-Host "[9/$Total] Insufficient funds ... PASS"
}

# --- [10/10] Final balance ---
$r = Invoke-SmokeRequest -Method GET -Path "/accounts/$accountId/balance"
if ($r.StatusCode -ne 200) {
    Write-Host "Actual HTTP $($r.StatusCode) body: $($r.Content)"
    Write-Error "[10/$Total] Final balance check ... FAIL"
    exit 1
}
$final = ($r.Content | ConvertFrom-Json).balance
Assert-DecimalEqual -Actual "$final" -Expected 1300 -Context "[10/$Total] Final balance check"
Write-Host "[10/$Total] Final balance check ... PASS"

Write-Host "All $Total checks passed"
