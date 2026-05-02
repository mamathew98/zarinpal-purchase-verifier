# AdminApp.ps1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security

# --------------------------------------------
# Load ps2exe (global or local)
# --------------------------------------------
if (-not (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue)) {

    $BasePath = if ($PSScriptRoot) {
        $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    }

    $LocalPs2Exe = Join-Path $BasePath "ps2exe\ps2exe.psd1"

    if (Test-Path $LocalPs2Exe) {
        Import-Module $LocalPs2Exe -Force
    }
}

$ZarinIcon = "icons\zarinpal.ico"

# --------------------------------------------
# Encryption Helper
# --------------------------------------------
function Encrypt-TokenFile {
    param([string]$JsonContent, [string]$Password)
    
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonContent)
    $salt = [byte[]](1..16)
    $key = (New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 1000)).GetBytes(32)
    
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.GenerateIV()
    
    $encryptor = $aes.CreateEncryptor()
    $encrypted = $encryptor.TransformFinalBlock($bytes, 0, $bytes.Length)
    
    $result = $salt + $aes.IV + $encrypted
    return [Convert]::ToBase64String($result)
}

# --------------------------------------------
# Load/Save tokens
# --------------------------------------------
function Get-TokenFilePath {
    $scriptPath = if ($PSScriptRoot) {
        $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    }
    return (Join-Path $scriptPath "tokens.json")
}


function Load-AllTokens {
    $file = Get-TokenFilePath
    if (-not (Test-Path $file)) {
        throw "tokens.json not found"
    }
    $obj = Get-Content $file -Raw | ConvertFrom-Json
    return $obj.zarin_tokens
}

function Save-AllTokens {
    param($TokensObject)
    
    $file = Get-TokenFilePath
    $data = @{
        zarin_tokens = $TokensObject
    }
    $data | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding UTF8
}

# --------------------------------------------
# GraphQL
# --------------------------------------------
$ZP_URL = "https://next.zarinpal.com/api/v4/graphql/"
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

function Invoke-ZarinpalGraphQL {
    param([string]$Token, [string]$Query, [hashtable]$Variables)
    
    $payload = @{
        query = $Query
        variables = $Variables
    } | ConvertTo-Json -Depth 10
    
    $headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/json"
        "Content-Type" = "application/json"
    }
    
    $response = Invoke-RestMethod -Uri $ZP_URL -Method POST -Headers $headers -Body $payload -TimeoutSec 30
    if ($response.errors) {
        throw ($response.errors | ConvertTo-Json -Depth 5)
    }
    return $response.data
}

function Load-Terminals {
    param([string]$Token)
    return (Invoke-ZarinpalGraphQL $Token $TERMINALS_QUERY @{}).Terminals | Sort-Object name
}

# --------------------------------------------
# Token Management Functions
# --------------------------------------------
function Refresh-TokenList {
    $lstTokens.Items.Clear()
    foreach ($key in $global:AllTokens.PSObject.Properties.Name) {
        [void]$lstTokens.Items.Add($key)
    }
}

function Show-TokenDialog {
    param([string]$Mode, [string]$TokenKey = "", [string]$TokenValue = "")
    
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($Mode -eq "Add") { "Add New Token" } elseif ($Mode -eq "Edit") { "Edit Token" } else { "View Token" }
    $dlg.Size = "500,250"
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = "#1e1e1e"
    $dlg.ForeColor = "White"
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    
    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = "Token Name:"
    $lblKey.Location = "20,20"
    $lblKey.Size = "100,20"
    $dlg.Controls.Add($lblKey)
    
    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Location = "120,18"
    $txtKey.Size = "340,20"
    $txtKey.Text = $TokenKey
    $txtKey.ReadOnly = ($Mode -eq "Edit" -or $Mode -eq "View")
    $dlg.Controls.Add($txtKey)
    
    $lblValue = New-Object System.Windows.Forms.Label
    $lblValue.Text = "Token Value:"
    $lblValue.Location = "20,55"
    $lblValue.Size = "100,20"
    $dlg.Controls.Add($lblValue)
    
    $txtValue = New-Object System.Windows.Forms.TextBox
    $txtValue.Location = "120,53"
    $txtValue.Size = "340,80"
    $txtValue.Multiline = $true
    $txtValue.ScrollBars = "Vertical"
    $txtValue.Text = $TokenValue
    $txtValue.ReadOnly = ($Mode -eq "View")
    $txtValue.BackColor = "#252526"
    $txtValue.ForeColor = "White"
    $dlg.Controls.Add($txtValue)
    
    if ($Mode -ne "View") {
        $btnSave = New-Object System.Windows.Forms.Button
        $btnSave.Text = "Save"
        $btnSave.Location = "280,150"
        $btnSave.Size = "80,30"
        $btnSave.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Controls.Add($btnSave)
        $dlg.AcceptButton = $btnSave
    }
    
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = if ($Mode -eq "View") { "Close" } else { "Cancel" }
    $btnCancel.Location = "380,150"
    $btnCancel.Size = "80,30"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)
    $dlg.CancelButton = $btnCancel
    
    $result = $dlg.ShowDialog()
    
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return @{
            Key = $txtKey.Text.Trim()
            Value = $txtValue.Text.Trim()
        }
    }
    
    return $null
}

# --------------------------------------------
# UI
# --------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Zarin Admin - Token & Terminal Manager"
$form.Size = "900,700"
$form.StartPosition = "CenterScreen"
$form.BackColor = "#1e1e1e"
$form.ForeColor = "White"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$lblTokens = New-Object System.Windows.Forms.Label
$lblTokens.Text = "Available Tokens:"
$lblTokens.Location = "20,20"
$lblTokens.Size = "200,20"
$form.Controls.Add($lblTokens)

$lstTokens = New-Object System.Windows.Forms.CheckedListBox
$lstTokens.Location = "20,45"
$lstTokens.Size = "400,200"
$lstTokens.BackColor = "#252526"
$lstTokens.ForeColor = "White"
$lstTokens.CheckOnClick = $true
$form.Controls.Add($lstTokens)

$btnAddToken = New-Object System.Windows.Forms.Button
$btnAddToken.Text = "Add"
$btnAddToken.Location = "440,45"
$btnAddToken.Size = "80,30"
$form.Controls.Add($btnAddToken)

$btnViewToken = New-Object System.Windows.Forms.Button
$btnViewToken.Text = "View"
$btnViewToken.Location = "440,85"
$btnViewToken.Size = "80,30"
$form.Controls.Add($btnViewToken)

$btnEditToken = New-Object System.Windows.Forms.Button
$btnEditToken.Text = "Edit"
$btnEditToken.Location = "440,125"
$btnEditToken.Size = "80,30"
$form.Controls.Add($btnEditToken)

$btnDeleteToken = New-Object System.Windows.Forms.Button
$btnDeleteToken.Text = "Delete"
$btnDeleteToken.Location = "440,165"
$btnDeleteToken.Size = "80,30"
$form.Controls.Add($btnDeleteToken)

$btnLoadTerminals = New-Object System.Windows.Forms.Button
$btnLoadTerminals.Text = "Load Terminals"
$btnLoadTerminals.Location = "440,215"
$btnLoadTerminals.Size = "120,30"
$form.Controls.Add($btnLoadTerminals)

$lblTerminals = New-Object System.Windows.Forms.Label
$lblTerminals.Text = "Terminals (check to include):"
$lblTerminals.Location = "20,260"
$lblTerminals.Size = "300,20"
$form.Controls.Add($lblTerminals)

$lstTerminals = New-Object System.Windows.Forms.CheckedListBox
$lstTerminals.Location = "20,285"
$lstTerminals.Size = "840,250"
$lstTerminals.BackColor = "#252526"
$lstTerminals.ForeColor = "White"
$lstTerminals.CheckOnClick = $true
$form.Controls.Add($lstTerminals)

$btnBuild = New-Object System.Windows.Forms.Button
$btnBuild.Text = "Build Distribution"
$btnBuild.Location = "20,550"
$btnBuild.Size = "150,40"
$btnBuild.BackColor = "#0e639c"
$btnBuild.ForeColor = "White"
$form.Controls.Add($btnBuild)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = "20,600"
$txtLog.Size = "840,50"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BackColor = "#252526"
$txtLog.ForeColor = "White"
$txtLog.ReadOnly = $true
$form.Controls.Add($txtLog)

# --------------------------------------------
# Data
# --------------------------------------------
$global:AllTokens = @{}
$global:TerminalsByToken = @{}

# --------------------------------------------
# Events
# --------------------------------------------
$form.Add_Shown({
    try {
        $global:AllTokens = Load-AllTokens
        Refresh-TokenList
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error loading tokens: $_", "Error")
    }
})

$btnAddToken.Add_Click({
    $result = Show-TokenDialog -Mode "Add"
    if ($result) {
        if ([string]::IsNullOrWhiteSpace($result.Key) -or [string]::IsNullOrWhiteSpace($result.Value)) {
            [System.Windows.Forms.MessageBox]::Show("Token name and value cannot be empty", "Error")
            return
        }
        
        if ($global:AllTokens.PSObject.Properties.Name -contains $result.Key) {
            [System.Windows.Forms.MessageBox]::Show("Token name already exists", "Error")
            return
        }
        
        $global:AllTokens | Add-Member -MemberType NoteProperty -Name $result.Key -Value $result.Value
        Save-AllTokens $global:AllTokens
        Refresh-TokenList
        $txtLog.AppendText("Token '$($result.Key)' added successfully.`r`n")
    }
})

$btnViewToken.Add_Click({
    if ($lstTokens.SelectedIndex -eq -1) {
        [System.Windows.Forms.MessageBox]::Show("Please select a token to view", "Error")
        return
    }
    
    $tokenKey = $lstTokens.SelectedItem
    $tokenValue = $global:AllTokens.$tokenKey
    Show-TokenDialog -Mode "View" -TokenKey $tokenKey -TokenValue $tokenValue
})

$btnEditToken.Add_Click({
    if ($lstTokens.SelectedIndex -eq -1) {
        [System.Windows.Forms.MessageBox]::Show("Please select a token to edit", "Error")
        return
    }
    
    $tokenKey = $lstTokens.SelectedItem
    $tokenValue = $global:AllTokens.$tokenKey
    
    $result = Show-TokenDialog -Mode "Edit" -TokenKey $tokenKey -TokenValue $tokenValue
    if ($result) {
        if ([string]::IsNullOrWhiteSpace($result.Value)) {
            [System.Windows.Forms.MessageBox]::Show("Token value cannot be empty", "Error")
            return
        }
        
        $global:AllTokens.$tokenKey = $result.Value
        Save-AllTokens $global:AllTokens
        $txtLog.AppendText("Token '$tokenKey' updated successfully.`r`n")
    }
})

$btnDeleteToken.Add_Click({
    if ($lstTokens.SelectedIndex -eq -1) {
        [System.Windows.Forms.MessageBox]::Show("Please select a token to delete", "Error")
        return
    }
    
    $tokenKey = $lstTokens.SelectedItem
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Are you sure you want to delete token '$tokenKey'?",
        "Confirm Delete",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        $global:AllTokens.PSObject.Properties.Remove($tokenKey)
        Save-AllTokens $global:AllTokens
        Refresh-TokenList
        $txtLog.AppendText("Token '$tokenKey' deleted successfully.`r`n")
    }
})

$btnLoadTerminals.Add_Click({
    $lstTerminals.Items.Clear()
    $global:TerminalsByToken = @{}
    
    foreach ($idx in 0..($lstTokens.Items.Count - 1)) {
        if ($lstTokens.GetItemChecked($idx)) {
            $tokenKey = $lstTokens.Items[$idx]
            $token = $global:AllTokens.$tokenKey
            
            try {
                $terminals = Load-Terminals $token
                $global:TerminalsByToken[$tokenKey] = $terminals
                
                foreach ($t in $terminals) {
                    $display = "[$tokenKey] $($t.name)"
                    if ($t.domain) { $display += " [$($t.domain)]" }
                    [void]$lstTerminals.Items.Add($display)
                }
            }
            catch {
                $txtLog.AppendText("Error loading terminals for ${tokenKey}: $_`r`n")
            }
        }
    }
    
    $txtLog.AppendText("Loaded terminals for selected tokens.`r`n")
})

$btnBuild.Add_Click({
    $selectedTokens = @{}
    $selectedTerminals = @{}
    
    foreach ($idx in 0..($lstTokens.Items.Count - 1)) {
        if ($lstTokens.GetItemChecked($idx)) {
            $tokenKey = $lstTokens.Items[$idx]
            $selectedTokens[$tokenKey] = $global:AllTokens.$tokenKey
            $selectedTerminals[$tokenKey] = @()
        }
    }
    
    if ($selectedTokens.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Select at least one token", "Error")
        return
    }
    
    foreach ($idx in 0..($lstTerminals.Items.Count - 1)) {
        if ($lstTerminals.GetItemChecked($idx)) {
            $item = $lstTerminals.Items[$idx]
            if ($item -match '^\[([^\]]+)\]') {
                $tokenKey = $matches[1]
                $terminals = $global:TerminalsByToken[$tokenKey]
                $terminalName = $item -replace '^\[[^\]]+\]\s*', '' -replace '\s*\[.*\]$', ''
                $terminalUrl = ''
                if ($item -match '\[([^\]]+)\]$') {
                    $terminalUrl = $matches[1]
                }
                
                $terminal = $terminals | Where-Object { $_.name -eq $terminalName -and $_.domain -eq $terminalUrl } | Select-Object -First 1

                if ($terminal) {
                    $selectedTerminals[$tokenKey] += $terminal
                }
            }
        }
    }
    
    $hasTerminals = $false
    foreach ($key in $selectedTerminals.Keys) {
        if ($selectedTerminals[$key].Count -gt 0) {
            $hasTerminals = $true
            break
        }
    }
    
    if (-not $hasTerminals) {
        [System.Windows.Forms.MessageBox]::Show("Select at least one terminal", "Error")
        return
    }
    
    try {
        $scriptPath = if ($PSScriptRoot) {
            $PSScriptRoot
        } elseif ($MyInvocation.MyCommand.Path) {
            Split-Path -Parent $MyInvocation.MyCommand.Path
        } else {
            Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        }

        $buildFolder = Join-Path $scriptPath "Build"
        if (Test-Path $buildFolder) {
            Remove-Item $buildFolder -Recurse -Force
        }
        New-Item -ItemType Directory -Path $buildFolder | Out-Null
        
        $filteredData = @{
            zarin_tokens = @{}
            terminals    = @{}
        }
        
        foreach ($tokenKey in $selectedTokens.Keys) {
            $filteredData.zarin_tokens[$tokenKey] = $selectedTokens[$tokenKey]
            $filteredData.terminals[$tokenKey] = $selectedTerminals[$tokenKey]
        }
        
        $jsonContent = $filteredData | ConvertTo-Json -Depth 10
        $encrypted = Encrypt-TokenFile $jsonContent '@paeezan1405'
        
        $encryptedFile = Join-Path $buildFolder "tokens.enc"
        Set-Content -Path $encryptedFile -Value $encrypted -Encoding UTF8
        
        $originalScript = Join-Path $scriptPath "ZarinVerifier-GUI.ps1"
        $verifierScript = Join-Path $buildFolder "ZarinVerifier-GUI.ps1"
        Copy-Item $originalScript $verifierScript
        
        $txtLog.AppendText("Build created in: $buildFolder`r`n")
        $txtLog.AppendText("Building EXE...`r`n")
        
        Try-BuildExe $buildFolder $verifierScript "ZarinVerifier.exe" -IconFile $ZarinIcon
        
        Remove-Item $verifierScript -Force
        
        $txtLog.AppendText("Build complete!`r`n")
        [System.Windows.Forms.MessageBox]::Show("Build created successfully in: $buildFolder", "Success")
    }
    catch {
        $txtLog.AppendText("Build error: $_`r`n")
        [System.Windows.Forms.MessageBox]::Show("Build failed: $_", "Error")
    }
})


function Try-BuildExe {
    param(
        [string]$BuildFolder,
        [string]$ScriptFile,
        [string]$ExeName,
        [string]$IconFile
    )
    
    try {
        if (Get-Command Invoke-ps2exe -ErrorAction SilentlyContinue) {

            if ($IconFile -and (Test-Path $IconFile)) {
                Invoke-ps2exe -inputFile $ScriptFile -outputFile "$BuildFolder\$ExeName" -NoConsole -iconFile $IconFile
            }
            else {
                Invoke-ps2exe -inputFile $ScriptFile -outputFile "$BuildFolder\$ExeName" -NoConsole
            }

            $txtLog.AppendText("EXE built successfully.`r`n")
        }
        else {
            $txtLog.AppendText("ps2exe not found (local or global) - skipping EXE build.`r`n")
        }
    }
    catch {
        $txtLog.AppendText("EXE build error: $_`r`n")
    }
}

[void]$form.ShowDialog()
