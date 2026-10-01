#Requires -Version 7.0
Set-StrictMode -Version Latest
# Modules do not inherit the caller's preference, and failed HTTP calls must stop the run.
$ErrorActionPreference = 'Stop'

$script:BaseUrl     = 'https://sapapps.wien.gv.at'
$script:AppUrl      = "$script:BaseUrl/sap/bc/ui5_ui5/sap/zleistungserfas/index.html"
$script:ODataUrl    = "$script:BaseUrl/sap/opu/odata/sap/Z_LEISTUNG_ERFS_FREIG_SRV"
$script:SapClient   = '100'
$script:CredTarget  = 'ELSAP'
$script:CsvCulture  = [cultureinfo]::GetCultureInfo('de-AT')
$script:CsvColumns  = 'Timestamp', 'Order', 'Item', 'Service', 'Project', 'Role', 'Period', 'Ordered', 'Open'

#region Credential store (Windows Credential Manager / macOS Keychain)

if ($IsWindows -and -not ('ElsapCredMan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ElsapCredMan {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredReadW(string target, uint type, uint flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWriteW(ref CREDENTIAL cred, uint flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr buffer);

    public static string[] Read(string target) {
        IntPtr p;
        if (!CredReadW(target, 1, 0, out p)) return null;
        try {
            var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            string pw = c.CredentialBlobSize > 0
                ? Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2) : "";
            return new[] { c.UserName, pw };
        } finally { CredFree(p); }
    }

    public static void Write(string target, string user, string password) {
        var bytes = Encoding.Unicode.GetBytes(password);
        var c = new CREDENTIAL {
            Type = 1, TargetName = target, UserName = user,
            Persist = 2, CredentialBlobSize = (uint)bytes.Length
        };
        c.CredentialBlob = Marshal.AllocHGlobal(bytes.Length);
        try {
            Marshal.Copy(bytes, 0, c.CredentialBlob, bytes.Length);
            if (!CredWriteW(ref c, 0))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.FreeHGlobal(c.CredentialBlob); }
    }
}
'@
}

function Get-ElsapCredential {
    <# Returns a PSCredential from the OS credential store, or $null if none is stored. #>
    if ($IsWindows) {
        $pair = [ElsapCredMan]::Read($script:CredTarget)
        if (-not $pair) { return $null }
        return [pscredential]::new($pair[0], (ConvertTo-SecureString $pair[1] -AsPlainText -Force))
    }
    if ($IsMacOS) {
        $attrs = & security find-generic-password -s $script:CredTarget 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $user = ($attrs | Select-String '"acct"<blob>="(.*)"').Matches[0].Groups[1].Value
        $pw = & security find-generic-password -s $script:CredTarget -w
        return [pscredential]::new($user, (ConvertTo-SecureString $pw -AsPlainText -Force))
    }
    throw "Unsupported platform."
}

function Set-ElsapCredential {
    param([Parameter(Mandatory)][pscredential]$Credential)
    $plain = $Credential.GetNetworkCredential().Password
    if ($IsWindows) {
        [ElsapCredMan]::Write($script:CredTarget, $Credential.UserName, $plain)
    } elseif ($IsMacOS) {
        # Note: `security` takes the password as an argument, so it is briefly visible in the process list.
        & security add-generic-password -U -s $script:CredTarget -a $Credential.UserName -w $plain | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not store credential in the Keychain." }
    } else {
        throw "Unsupported platform."
    }
}

#endregion

#region Notification

function Show-ElsapNotification {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message
    )
    if ($IsWindows) {
        # WinRT toasts are not available in PowerShell 7, so hand over to Windows PowerShell 5.1.
        $b64 = { param($s) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
        $script5 = @"
`$t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(& $b64 $Title)'))
`$m = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(& $b64 $Message)'))
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
`$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent('ToastText02')
`$nodes = `$xml.GetElementsByTagName('text')
[void]`$nodes.Item(0).AppendChild(`$xml.CreateTextNode(`$t))
[void]`$nodes.Item(1).AppendChild(`$xml.CreateTextNode(`$m))
`$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$appId).Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script5))
        & powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded
    } elseif ($IsMacOS) {
        & osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' -- $Title $Message
    }
}

#endregion

#region ELSAP access

function Get-HtmlForm {
    # PowerShell 7's Invoke-WebRequest has no .Forms property, so the first <form> is parsed by hand.
    param([Parameter(Mandatory)][string]$Html)
    $m = [regex]::Match($Html, '(?is)<form\b[^>]*action="([^"]*)"[^>]*>(.*?)</form>')
    if (-not $m.Success) { return $null }
    $fields = [ordered]@{}
    foreach ($tag in [regex]::Matches($m.Groups[2].Value, '(?is)<input\b[^>]*>')) {
        $name = [regex]::Match($tag.Value, 'name="([^"]*)"')
        if (-not $name.Success) { continue }
        $value = [regex]::Match($tag.Value, 'value="([^"]*)"')
        $fields[$name.Groups[1].Value] = [System.Net.WebUtility]::HtmlDecode($(if ($value.Success) { $value.Groups[1].Value } else { '' }))
    }
    [pscustomobject]@{ Action = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value); Fields = $fields }
}

function Connect-Elsap {
    <# Signs in through the ADFS SAML flow and returns a web session carrying the SAP cookies. #>
    param([Parameter(Mandatory)][pscredential]$Credential)
    $ProgressPreference = 'SilentlyContinue'

    # 1. The app answers with an auto-post form carrying the SAML request for ADFS.
    $page = Invoke-WebRequest $script:AppUrl -SessionVariable session -TimeoutSec 30
    $samlRequest = Get-HtmlForm $page.Content
    if (-not $samlRequest -or -not $samlRequest.Fields.Contains('SAMLRequest')) {
        throw "Unexpected response from ELSAP (no SAML request). Already signed in, or the page changed."
    }

    # 2. ADFS answers with its forms-login page.
    $adfs = Invoke-WebRequest $samlRequest.Action -Method Post -Body $samlRequest.Fields -WebSession $session -TimeoutSec 30
    $login = Get-HtmlForm $adfs.Content
    if (-not $login -or -not $login.Fields.Contains('UserName')) {
        throw "Unexpected ADFS page (no login form)."
    }
    $adfsUri = $adfs.BaseResponse.RequestMessage.RequestUri
    $loginUrl = [uri]::new($adfsUri, $login.Action).AbsoluteUri

    # 3. Submit credentials. A rejected login returns the login form again instead of a SAML response.
    $login.Fields['UserName'] = $Credential.UserName
    $login.Fields['Password'] = $Credential.GetNetworkCredential().Password
    $login.Fields['AuthMethod'] = 'FormsAuthentication'
    $answer = Invoke-WebRequest $loginUrl -Method Post -Body $login.Fields -WebSession $session -TimeoutSec 30
    $form = Get-HtmlForm $answer.Content
    if (-not $form -or -not $form.Fields.Contains('SAMLResponse')) {
        throw "ADFS rejected the login (wrong user name or password, or the password expired)."
    }

    # 4. Hand the assertion back to SAP. SAP answers with another auto-post form (to the app URL)
    #    before the session cookies are usable, so follow SAML auto-post forms until none is left.
    for ($hop = 0; $form -and $form.Fields.Contains('SAMLResponse'); $hop++) {
        if ($hop -ge 5) { throw "Too many SAML redirects." }
        $target = [uri]::new($answer.BaseResponse.RequestMessage.RequestUri, $form.Action).AbsoluteUri
        $answer = Invoke-WebRequest $target -Method Post -Body $form.Fields -WebSession $session -TimeoutSec 30
        $form = Get-HtmlForm $answer.Content
    }
    $session
}

function ConvertFrom-ODataDate {
    # ConvertFrom-Json in PowerShell 7 already turns "/Date(ms)/" into a DateTime.
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-dd') }
    $ms = [regex]::Match([string]$Value, '\d+').Value
    [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).UtcDateTime.ToString('yyyy-MM-dd')
}

function Get-ElsapTimeSheet {
    <# Returns the bookable time sheets with ordered and open hours. #>
    param([Parameter(Mandatory)]$Session)
    $ProgressPreference = 'SilentlyContinue'
    $uri = "$script:ODataUrl/LeistungsblattSet?`$format=json&sap-client=$script:SapClient"
    $response = Invoke-WebRequest $uri -WebSession $Session -Headers @{ Accept = 'application/json' } -TimeoutSec 60
    if (($response.Headers['Content-Type'] -join ' ') -notmatch 'json') {
        throw "ELSAP returned no JSON (session not accepted)."
    }
    $inv = [cultureinfo]::InvariantCulture
    ($response.Content | ConvertFrom-Json).d.results |
        Where-Object { -not $_.Elikz -and -not $_.Loekz -and -not $_.Erekz } |
        ForEach-Object {
            [pscustomobject]@{
                Order   = $_.Ebeln
                Item    = $_.Ebelp
                Service = $_.Leistnr
                Project = $_.Kurztext
                Role    = $_.LeistnrText
                Period  = ConvertFrom-ODataDate $_.LDatum
                Ordered = [decimal]::Parse($_.Pstd, $inv)
                Open    = [decimal]::Parse($_.Ostd, $inv)
            }
        } | Sort-Object Order, Item, Service
}

#endregion

#region Snapshot history and change detection

function Get-ElsapKey {
    param($Row)
    '{0}/{1}/{2}' -f $Row.Order, $Row.Item, $Row.Service
}

function Add-ElsapSnapshot {
    <# Appends one snapshot to the history CSV (; delimited, UTF-8 with BOM for Excel). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Timestamp, [object[]]$Rows)
    $out = foreach ($r in $Rows) {
        [pscustomobject][ordered]@{
            Timestamp = $Timestamp
            Order     = $r.Order
            Item      = $r.Item
            Service   = $r.Service
            Project   = $r.Project
            Role      = $r.Role
            Period    = $r.Period
            Ordered   = $r.Ordered.ToString('0.00', $script:CsvCulture)
            Open      = $r.Open.ToString('0.00', $script:CsvCulture)
        }
    }
    if (-not $out) { return }
    $lines = $out | ConvertTo-Csv -Delimiter ';' -NoTypeInformation
    if (Test-Path $Path) {
        Add-Content -Path $Path -Value ($lines | Select-Object -Skip 1) -Encoding utf8NoBOM
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
        Set-Content -Path $Path -Value $lines -Encoding utf8BOM
    }
}

function Get-ElsapSnapshot {
    <# Reads the rows written at the given timestamp (as stored in the state file). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Timestamp)
    if (-not (Test-Path $Path)) { return @() }
    Import-Csv -Path $Path -Delimiter ';' | Where-Object { $_.Timestamp -eq $Timestamp } | ForEach-Object {
        [pscustomobject]@{
            Order   = $_.Order
            Item    = $_.Item
            Service = $_.Service
            Project = $_.Project
            Role    = $_.Role
            Period  = $_.Period
            Ordered = [decimal]::Parse($_.Ordered, $script:CsvCulture)
            Open    = [decimal]::Parse($_.Open, $script:CsvCulture)
        }
    }
}

function Compare-ElsapSnapshot {
    <# Returns one change object per time sheet that appeared, disappeared or changed hours. #>
    param([object[]]$Previous = @(), [object[]]$Current = @())
    $prev = @{}; foreach ($r in $Previous) { $prev[(Get-ElsapKey $r)] = $r }
    $curr = @{}; foreach ($r in $Current)  { $curr[(Get-ElsapKey $r)] = $r }
    foreach ($key in ($curr.Keys + $prev.Keys | Sort-Object -Unique)) {
        $old = $prev[$key]; $new = $curr[$key]
        if (-not $old) {
            [pscustomobject]@{ Kind = 'new'; Key = $key; Row = $new; Old = $null }
        } elseif (-not $new) {
            [pscustomobject]@{ Kind = 'removed'; Key = $key; Row = $old; Old = $old }
        } elseif ($old.Ordered -ne $new.Ordered -or $old.Open -ne $new.Open) {
            [pscustomobject]@{ Kind = 'changed'; Key = $key; Row = $new; Old = $old }
        }
    }
}

function Get-ElsapChangeHistory {
    <# Replays the history CSV and returns every change between consecutive snapshots since a given time. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][datetime]$Since,
        [string]$Project,
        [string]$Role
    )
    if (-not (Test-Path $Path)) { return }
    $rows = Import-Csv -Path $Path -Delimiter ';'
    $stamps = @($rows.Timestamp | Sort-Object -Unique)
    $previous = @()
    foreach ($stamp in $stamps) {
        $current = @(Get-ElsapSnapshot -Path $Path -Timestamp $stamp)
        $time = [datetime]::ParseExact($stamp, 'yyyy-MM-dd HH:mm:ss', [cultureinfo]::InvariantCulture)
        # The first snapshot is the baseline; changes are only reported from the second one on.
        if ($previous.Count -gt 0 -or $stamp -ne $stamps[0]) {
            if ($time -ge $Since) {
                foreach ($c in Compare-ElsapSnapshot -Previous $previous -Current $current) {
                    if ($Project -and $c.Row.Project -notmatch $Project) { continue }
                    if ($Role -and $c.Row.Role -notmatch $Role) { continue }
                    $old = $c.Old; $new = if ($c.Kind -eq 'removed') { $null } else { $c.Row }
                    [pscustomobject]@{
                        Timestamp    = $time
                        Kind         = $c.Kind
                        Key          = $c.Key
                        Project      = $c.Row.Project
                        Role         = $c.Row.Role
                        OrderedOld   = if ($old) { $old.Ordered } else { $null }
                        OrderedNew   = if ($new) { $new.Ordered } else { $null }
                        OpenOld      = if ($old) { $old.Open } else { $null }
                        OpenNew      = if ($new) { $new.Open } else { $null }
                        OrderedDelta = if ($old -and $new) { $new.Ordered - $old.Ordered } else { $null }
                        OpenDelta    = if ($old -and $new) { $new.Open - $old.Open } else { $null }
                    }
                }
            }
        }
        $previous = $current
    }
}

function Format-ElsapChange {
    param([Parameter(Mandatory)]$Change)
    $de = [cultureinfo]::GetCultureInfo('de-DE')
    $f = { param($n) $n.ToString('N2', $de) }
    $name = '{0} [{1}]' -f ($Change.Row.Project -replace '^[A-Z]_', ''), $Change.Row.Role
    switch ($Change.Kind) {
        'new'     { "${name}: new, open $(& $f $Change.Row.Open) of $(& $f $Change.Row.Ordered)" }
        'removed' { "${name}: removed (no longer bookable)" }
        'changed' {
            $parts = @()
            if ($Change.Old.Open -ne $Change.Row.Open) { $parts += "open $(& $f $Change.Old.Open) -> $(& $f $Change.Row.Open)" }
            if ($Change.Old.Ordered -ne $Change.Row.Ordered) { $parts += "ordered $(& $f $Change.Old.Ordered) -> $(& $f $Change.Row.Ordered)" }
            "${name}: " + ($parts -join ', ')
        }
    }
}

#endregion

Export-ModuleMember -Function Get-ElsapCredential, Set-ElsapCredential, Show-ElsapNotification,
    Connect-Elsap, Get-ElsapTimeSheet, Add-ElsapSnapshot, Get-ElsapSnapshot,
    Compare-ElsapSnapshot, Get-ElsapChangeHistory, Format-ElsapChange
