# ZarinVerifier-GUI.ps1 (Modified)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

# --------------------------------------------
# Decryption Helper
# --------------------------------------------
function Decrypt-TokenFile {
    param([string]$EncryptedContent, [string]$Password)
    
    $encryptedBytes = [Convert]::FromBase64String($EncryptedContent)
    
    $salt = $encryptedBytes[0..15]
    $iv = $encryptedBytes[16..31]
    $encrypted = $encryptedBytes[32..($encryptedBytes.Length - 1)]
    
    $key = (New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 1000)).GetBytes(32)
    
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV = $iv
    
    $decryptor = $aes.CreateDecryptor()
    $decrypted = $decryptor.TransformFinalBlock($encrypted, 0, $encrypted.Length)
    
    return [System.Text.Encoding]::UTF8.GetString($decrypted)
}

# --------------------------------------------
# Token file path helper
# --------------------------------------------
function Get-TokenFilePath {
    $encPath = $null
    
    if ($MyInvocation.MyCommand.Path -and (Test-Path $MyInvocation.MyCommand.Path)) {
        $encPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "tokens.enc"
    }
    if (-not $encPath -and $PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        $encPath = Join-Path $PSScriptRoot "tokens.enc"
    }
    if (-not $encPath) {
        try {
            if ($MyInvocation.InvocationName -and (Test-Path $MyInvocation.InvocationName)) {
                $encPath = Join-Path (Split-Path -Parent (Resolve-Path $MyInvocation.InvocationName)) "tokens.enc"
            }
        } catch {}
    }
    if (-not $encPath) {
        $encPath = Join-Path (Get-Location) "tokens.enc"
    }
    
    if (Test-Path $encPath) {
        return $encPath
    }
    
    if ($MyInvocation.MyCommand.Path -and (Test-Path $MyInvocation.MyCommand.Path)) {
        return (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "tokens.json")
    }
    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) {
        return (Join-Path $PSScriptRoot "tokens.json")
    }
    try {
        if ($MyInvocation.InvocationName -and (Test-Path $MyInvocation.InvocationName)) {
            return (Join-Path (Split-Path -Parent (Resolve-Path $MyInvocation.InvocationName)) "tokens.json")
        }
    } catch {}
    return (Join-Path (Get-Location) "tokens.json")
}

# --------------------------------------------
# Zarinpal URL
# --------------------------------------------
$ZP_URL = $env:ZARINPAL_GRAPHQL_URL
if ([string]::IsNullOrWhiteSpace($ZP_URL)) {
    $ZP_URL = "https://next.zarinpal.com/api/v4/graphql/"
}

# --------------------------------------------
# Load tokens
# --------------------------------------------
function Load-ZarinTokens {
    $file = Get-TokenFilePath
    if (-not (Test-Path $file)) {
        throw "Token file not found."
    }
    
    $raw = Get-Content $file -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Token file is empty."
    }
    
    $obj = $null
    if ($file -like "*.enc") {
        try {
            $decrypted = Decrypt-TokenFile $raw '@paeezan1405'
            $obj = $decrypted | ConvertFrom-Json
        }
        catch {
            throw "Failed to decrypt token file: $_"
        }
    }
    else {
        $obj = $raw | ConvertFrom-Json
    }
    
    if (-not $obj.zarin_tokens) {
        throw "No 'zarin_tokens' section found."
    }
    
    $global:PreloadedTerminals = $obj.terminals
    
    if ($obj.zarin_tokens -is [hashtable]) {
        return $obj.zarin_tokens
    }
    
    $hash = @{}
    foreach ($p in $obj.zarin_tokens.PSObject.Properties) {
        $hash[$p.Name] = $p.Value
    }
    return $hash
}

$global:ZARIN_TOKENS = Load-ZarinTokens
$global:ZP_SELECTED_KEY = "default"

if (-not $ZARIN_TOKENS.ContainsKey($ZP_SELECTED_KEY)) {
    $global:ZP_SELECTED_KEY = ($ZARIN_TOKENS.Keys | Select-Object -First 1)
}

$global:ZP_TOKEN = $ZARIN_TOKENS[$global:ZP_SELECTED_KEY]

# --------------------------------------------
# GraphQL Queries
# --------------------------------------------
$TERMINALS_QUERY = @'
query{
  Terminals {
    id
    status
    domain
    name
    created_at
    updated_at
  }
}
'@

$SESSIONS_QUERY = @'
query Sessions($terminal_id: ID, $reference_id: String, $id: ID, $card_pan: String,
               $description: String, $mobile: CellNumber, $email: String, $rrn: String) {
  Session(terminal_id: $terminal_id, reference_id: $reference_id, id: $id,
          card_pan: $card_pan, description: $description, mobile: $mobile,
          email: $email, rrn: $rrn) {
    session_tries {
      id
      payer_ip
      init_time
      verify_time
      status
      rrn
      card_pan
      created_at
    }
    id
    status
    amount
    description
    created_at
    authority
  }
}
'@

# --------------------------------------------
# GraphQL Call
# --------------------------------------------
function Invoke-ZarinpalGraphQL {
    param([string]$Query,[hashtable]$Variables)

    $payload = @{
        query     = $Query
        variables = $Variables
    } | ConvertTo-Json -Depth 10

    $headers = @{
        Authorization = "Bearer $global:ZP_TOKEN"
        Accept        = "application/json"
        "Content-Type"= "application/json"
    }

    $response = Invoke-RestMethod -Uri $ZP_URL -Method POST -Headers $headers -Body $payload -TimeoutSec 30
    $global:LastRawResponse = $response | ConvertTo-Json -Depth 10

    if ($response.errors) {
        throw ($response.errors | ConvertTo-Json -Depth 5)
    }

    return $response.data
}

# --------------------------------------------
# Helpers
# --------------------------------------------
function Convert-ISO-ToDates {
    param([string]$iso)
    if ([string]::IsNullOrWhiteSpace($iso)) {
        return @{ Jalali="N/A"; Gregorian="N/A" }
    }

    try { $utc = [DateTime]::Parse($iso).ToUniversalTime() }
    catch { return @{ Jalali="N/A"; Gregorian=$iso } }

    $local = $utc + (New-TimeSpan -Hours 3 -Minutes 30)
    $pc = New-Object System.Globalization.PersianCalendar

    return @{
        Jalali = "{0}/{1:00}/{2:00} {3:00}:{4:00}:{5:00}" -f `
            $pc.GetYear($local),$pc.GetMonth($local),$pc.GetDayOfMonth($local),
            $pc.GetHour($local),$pc.GetMinute($local),$pc.GetSecond($local)
        Gregorian = $local.ToString("yyyy/MM/dd HH:mm:ss")
    }
}

function Get-BestTry {
    param($tries)
    if (!$tries) { return $null }
    $sorted = $tries | Sort-Object created_at -Descending
    foreach ($t in $sorted) { if ($t.status -in @("VERIFIED","PAID")) { return $t } }
    foreach ($t in $sorted) { if ($t.status -in @("REFUNDED","TRASH")) { return $t } }
    return $sorted[0]
}

function Format-SessionCard {
    param($session)

    $dates = Convert-ISO-ToDates $session.created_at
    $best  = Get-BestTry $session.session_tries

    $out = @(
        "================================================",
        "Session ID  : $($session.id)",
        "Status      : $($session.status)",
        "Amount      : $($session.amount)",
        "Description : $($session.description)",
        "Authority   : $($session.authority)",
        "Created(G)  : $($dates.Gregorian)",
        "Created(J)  : $($dates.Jalali)"
    )

    if ($best) {
        $bd = Convert-ISO-ToDates $best.created_at
        $out += "", "---- Best Try ----",
            "Try ID     : $($best.id)",
            "Status     : $($best.status)",
            "RRN        : $($best.rrn)",
            "Card PAN   : $($best.card_pan)",
            "Payer IP   : $($best.payer_ip)",
            "Init Time  : $($best.init_time)",
            "Verify Time: $($best.verify_time)",
            "Try(G)     : $($bd.Gregorian)",
            "Try(J)     : $($bd.Jalali)"
    }
    return ($out -join "`r`n")
}

function Load-Terminals {
    if ($global:PreloadedTerminals -and $global:PreloadedTerminals.$global:ZP_SELECTED_KEY) {
        return $global:PreloadedTerminals.$global:ZP_SELECTED_KEY | Sort-Object name
    }
    
    (Invoke-ZarinpalGraphQL $TERMINALS_QUERY @{}).Terminals | Sort-Object name
}

# --------------------------------------------
# UI
# --------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Zarin Purchase Verifier"
$form.Size = "620,700"
$form.StartPosition = "CenterScreen"
$form.BackColor = "#1e1e1e"
$form.ForeColor = "White"
$form.Font = New-Object System.Drawing.Font("Segoe UI",9)

$lblAcct = New-Object System.Windows.Forms.Label
$lblAcct.Text = "Zarinpal Account"
$lblAcct.Location = "20,20"
$form.Controls.Add($lblAcct)

$cmbToken = New-Object System.Windows.Forms.ComboBox
$cmbToken.Location = "120,15"
$cmbToken.Width = 420
$cmbToken.DropDownStyle = "DropDownList"
$form.Controls.Add($cmbToken)

foreach ($k in $ZARIN_TOKENS.Keys) { [void]$cmbToken.Items.Add($k) }
$cmbToken.SelectedItem = $global:ZP_SELECTED_KEY

$lblGame = New-Object System.Windows.Forms.Label
$lblGame.Text = "Terminal"
$lblGame.Location = "20,55"
$form.Controls.Add($lblGame)

$cmbGame = New-Object System.Windows.Forms.ComboBox
$cmbGame.Location = "120,50"
$cmbGame.Width = 420
$cmbGame.DropDownStyle = "DropDownList"
$form.Controls.Add($cmbGame)

$labels = @("Card PAN","Email","Description")
$y = 90
foreach ($l in $labels) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $l
    $lbl.Location = "20,$y"
    $form.Controls.Add($lbl)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = "120,$($y-5)"
    $txt.Width = 420
    Set-Variable "txt$($l.Replace(' ',''))" $txt -Scope Global
    $form.Controls.Add($txt)
    $y += 35
}

$btnVerify = New-Object System.Windows.Forms.Button
$btnVerify.Text = "Search Sessions"
$btnVerify.Location = "120,200"
$form.Controls.Add($btnVerify)

$txtResult = New-Object System.Windows.Forms.TextBox
$txtResult.Location = "20,245"
$txtResult.Size = "560,200"
$txtResult.Multiline = $true
$txtResult.ScrollBars = "Vertical"
$txtResult.BackColor = "#252526"
$txtResult.ForeColor = "White"
$txtResult.Font = New-Object System.Drawing.Font("Consolas",9)
$form.Controls.Add($txtResult)

$txtRaw = New-Object System.Windows.Forms.TextBox
$txtRaw.Location = "20,460"
$txtRaw.Size = "560,180"
$txtRaw.Multiline = $true
$txtRaw.ScrollBars = "Vertical"
$txtRaw.BackColor = "#c69a0e"
$txtRaw.ForeColor = "White"
$txtRaw.Font = New-Object System.Drawing.Font("Consolas",9)
$form.Controls.Add($txtRaw)

# --------------------------------------------
# Events
# --------------------------------------------
$cmbToken.Add_SelectedIndexChanged({
    $global:ZP_SELECTED_KEY = $cmbToken.SelectedItem
    $global:ZP_TOKEN = $ZARIN_TOKENS[$global:ZP_SELECTED_KEY]
    $cmbGame.Items.Clear()
    $global:Terminals = Load-Terminals
    foreach ($t in $global:Terminals) {
        $display = $t.name
        if ($t.domain) { $display += " [$($t.domain)]" }
        [void]$cmbGame.Items.Add($display)
    }
    if ($cmbGame.Items.Count) { $cmbGame.SelectedIndex = 0 }
})

$form.Add_Shown({
    $global:Terminals = Load-Terminals
    foreach ($t in $global:Terminals) {
        $display = $t.name
        if ($t.domain) { $display += " [$($t.domain)]" }
        [void]$cmbGame.Items.Add($display)
    }
    if ($cmbGame.Items.Count) { $cmbGame.SelectedIndex = 0 }
})

$btnVerify.Add_Click({
    $t = $global:Terminals[$cmbGame.SelectedIndex]
    $vars = @{ terminal_id="$($t.id)" }
    if ($txtCardPAN.Text) { $vars.card_pan = $txtCardPAN.Text }
    if ($txtEmail.Text)   { $vars.email = $txtEmail.Text }
    if ($txtDescription.Text) { $vars.description = $txtDescription.Text }

    try {
        $data = Invoke-ZarinpalGraphQL $SESSIONS_QUERY $vars
        $out = $data.Session | Sort-Object created_at -Descending | ForEach-Object {
            Format-SessionCard $_
        }
        $txtResult.Text = ($out -join "`r`n`r`n")
        $txtRaw.Text = $global:LastRawResponse
    }
    catch {
        $txtResult.Text = "Error:`r`n$_"
        $txtRaw.Text = ""
    }
})

[void]$form.ShowDialog()
