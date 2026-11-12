<#
.SYNOPSIS
  グローバルホットキーで Windows の既定オーディオデバイス(通信/既定)を切り替える常駐スクリプト。

.DESCRIPTION
  ホットキーとアクションは config.json に保存される。タスクトレイのアイコン → 「設定...」の
  設定画面でキー割り当てを編集できる(config.json を直接書いてもよい)。
    action: "set"           … mic / speaker で指定したデバイスに一発切替(どちらか片方だけでも可)
    action: "cycle-mic"     … devices に列挙したマイクを順番に切替
    action: "cycle-speaker" … devices に列挙したスピーカーを順番に切替
  デバイス指定は「名前の部分一致(大文字小文字無視)」または完全なデバイスID。

.EXAMPLE
  .\audio-hotkey.ps1 -ListDevices   # デバイス一覧と現在の既定を表示
  .\audio-hotkey.ps1                # 常駐開始(タスクトレイにアイコン表示)
  .\audio-hotkey.ps1 -Settings      # 常駐せずに設定画面だけ開く
  .\audio-hotkey.ps1 -Trigger "Ctrl+Alt+M"  # ホットキーを押さずにそのアクションを1回実行(動作確認用)
#>
[CmdletBinding()]
param(
    [switch]$ListDevices,
    [switch]$Settings,
    [string]$Trigger,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- CoreAudio / IPolicyConfig / ホットキー用ウィンドウ (C#) ----
if (-not ([System.Management.Automation.PSTypeName]'AudioHotkey.Audio').Type) {
    $cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AudioHotkey
{
    public enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    public enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr p;
        [FieldOffset(16)] public IntPtr p2;
    }

    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int cProps);
        [PreserveSig] int GetAt(int iProp, out PropertyKey pkey);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant pv);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant pv);
        [PreserveSig] int Commit();
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, out IntPtr iface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IPropertyStore propertyStore);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorCom { }

    // 非公開COMだが SoundSwitch 等が長年使っている実績あるインターフェース
    [Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string dev, out IntPtr fmt);
        [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string dev, int bDefault, out IntPtr fmt);
        [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string dev);
        [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string dev, IntPtr endpointFmt, IntPtr mixFmt);
        [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string dev, int bDefault, IntPtr defPeriod, IntPtr minPeriod);
        [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string dev, IntPtr period);
        [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string dev, IntPtr mode);
        [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string dev, IntPtr mode);
        [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string dev, int bFxStore, IntPtr key, IntPtr pv);
        [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string dev, int bFxStore, IntPtr key, IntPtr pv);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string dev, ERole role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string dev, int visible);
    }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    public class PolicyConfigClientCom { }

    public class DeviceInfo
    {
        public string Id;
        public string Name;
        public override string ToString() { return Name; }
    }

    public static class Audio
    {
        static PropertyKey PKEY_Device_FriendlyName = new PropertyKey
        {
            fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
            pid = 14
        };

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant pv);

        public static List<DeviceInfo> List(EDataFlow flow)
        {
            var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDeviceCollection col;
            Check(en.EnumAudioEndpoints(flow, 1 /* DEVICE_STATE_ACTIVE */, out col));
            int n;
            Check(col.GetCount(out n));
            var list = new List<DeviceInfo>();
            for (int i = 0; i < n; i++)
            {
                IMMDevice d;
                Check(col.Item(i, out d));
                string id;
                Check(d.GetId(out id));
                IPropertyStore ps;
                Check(d.OpenPropertyStore(0 /* STGM_READ */, out ps));
                PropVariant pv;
                Check(ps.GetValue(ref PKEY_Device_FriendlyName, out pv));
                string name = (pv.vt == 31 /* VT_LPWSTR */) ? Marshal.PtrToStringUni(pv.p) : "(unknown)";
                PropVariantClear(ref pv);
                list.Add(new DeviceInfo { Id = id, Name = name });
            }
            return list;
        }

        public static string GetDefault(EDataFlow flow, ERole role)
        {
            var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDevice d;
            int hr = en.GetDefaultAudioEndpoint(flow, role, out d);
            if (hr != 0) return null; // デバイスが1つもない場合など
            string id;
            Check(d.GetId(out id));
            return id;
        }

        public static void SetDefault(string id, ERole role)
        {
            var pc = (IPolicyConfig)new PolicyConfigClientCom();
            Check(pc.SetDefaultEndpoint(id, role));
        }

        static void Check(int hr)
        {
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        }
    }

    public class HotkeyWindow : System.Windows.Forms.NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)]
        static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")]
        static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        readonly List<int> _ids = new List<int>();
        public event Action<int> HotkeyPressed;

        public HotkeyWindow()
        {
            CreateHandle(new System.Windows.Forms.CreateParams());
        }

        public bool Register(int id, uint modifiers, uint vk)
        {
            bool ok = RegisterHotKey(Handle, id, modifiers, vk);
            if (ok) _ids.Add(id);
            return ok;
        }

        protected override void WndProc(ref System.Windows.Forms.Message m)
        {
            if (m.Msg == 0x0312 /* WM_HOTKEY */ && HotkeyPressed != null)
                HotkeyPressed((int)m.WParam);
            base.WndProc(ref m);
        }

        public void UnregisterAll()
        {
            foreach (int id in _ids) UnregisterHotKey(Handle, id);
            _ids.Clear();
        }

        public void Dispose()
        {
            UnregisterAll();
            DestroyHandle();
        }
    }
}
'@
    Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Windows.Forms'
}

# ---- ヘルパー ----

function Get-Roles([string]$roleName) {
    switch ($roleName) {
        'default'       { @([AudioHotkey.ERole]::eConsole, [AudioHotkey.ERole]::eMultimedia) }
        'both'          { @([AudioHotkey.ERole]::eConsole, [AudioHotkey.ERole]::eMultimedia, [AudioHotkey.ERole]::eCommunications) }
        default         { @([AudioHotkey.ERole]::eCommunications) }  # 'communication'
    }
}

function Resolve-Device {
    param([AudioHotkey.EDataFlow]$Flow, [string]$Pattern)
    $devs = [AudioHotkey.Audio]::List($Flow)
    $hit = @($devs | Where-Object { $_.Id -eq $Pattern })
    if ($hit.Count -eq 0) {
        # -like だとデバイス名の [ ] がワイルドカード扱いになるので IndexOf で部分一致
        $hit = @($devs | Where-Object { $_.Name.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    if ($hit.Count -eq 0) { return $null }
    if ($hit.Count -gt 1) {
        Write-Warning "パターン '$Pattern' に複数のデバイスが一致: $($hit.Name -join ' / ') → 先頭を使用"
    }
    return $hit[0]
}

function Set-DefaultDevice {
    param([AudioHotkey.DeviceInfo]$Device, $Roles)
    foreach ($r in $Roles) { [AudioHotkey.Audio]::SetDefault($Device.Id, $r) }
}

function Invoke-CycleAction {
    param([AudioHotkey.EDataFlow]$Flow, [string[]]$Patterns, $Roles)
    $resolved = @()
    foreach ($p in $Patterns) {
        $d = Resolve-Device -Flow $Flow -Pattern $p
        if ($d) { $resolved += $d } else { Write-Warning "サイクル対象 '$p' が見つかりません(未接続?) → スキップ" }
    }
    if ($resolved.Count -eq 0) { throw "サイクル対象のデバイスがひとつも見つかりません" }

    # 現在の既定(通信ロールを優先して判定)を探して「次」を選ぶ
    $queryRole = if ($Roles -contains [AudioHotkey.ERole]::eCommunications) { [AudioHotkey.ERole]::eCommunications } else { [AudioHotkey.ERole]::eConsole }
    $currentId = [AudioHotkey.Audio]::GetDefault($Flow, $queryRole)
    $idx = -1
    for ($i = 0; $i -lt $resolved.Count; $i++) {
        if ($resolved[$i].Id -eq $currentId) { $idx = $i; break }
    }
    $next = $resolved[($idx + 1) % $resolved.Count]
    Set-DefaultDevice -Device $next -Roles $Roles
    return $next
}

function Invoke-HotkeyEntry {
    param($Entry, [string]$GlobalRole)
    $roleName = if ($Entry.role) { $Entry.role } else { $GlobalRole }
    $roles = Get-Roles $roleName
    $messages = @()

    switch ($Entry.action) {
        'set' {
            if ($Entry.mic) {
                $d = Resolve-Device -Flow ([AudioHotkey.EDataFlow]::eCapture) -Pattern $Entry.mic
                if (-not $d) { throw "マイク '$($Entry.mic)' が見つかりません" }
                Set-DefaultDevice -Device $d -Roles $roles
                $messages += "マイク: $($d.Name)"
            }
            if ($Entry.speaker) {
                $d = Resolve-Device -Flow ([AudioHotkey.EDataFlow]::eRender) -Pattern $Entry.speaker
                if (-not $d) { throw "スピーカー '$($Entry.speaker)' が見つかりません" }
                Set-DefaultDevice -Device $d -Roles $roles
                $messages += "スピーカー: $($d.Name)"
            }
        }
        'cycle-mic' {
            $d = Invoke-CycleAction -Flow ([AudioHotkey.EDataFlow]::eCapture) -Patterns $Entry.devices -Roles $roles
            $messages += "マイク → $($d.Name)"
        }
        'cycle-speaker' {
            $d = Invoke-CycleAction -Flow ([AudioHotkey.EDataFlow]::eRender) -Patterns $Entry.devices -Roles $roles
            $messages += "スピーカー → $($d.Name)"
        }
        default { throw "不明な action: $($Entry.action)" }
    }
    return ($messages -join "`n")
}

# ---- ホットキー文字列 ----

function Get-HotkeyParts([string]$Keys) {
    # "Ctrl+Alt+1" → @{ Ctrl; Alt; Shift; Win; Key = 'D1' }
    $p = @{ Ctrl = $false; Alt = $false; Shift = $false; Win = $false; Key = '' }
    foreach ($part in ($Keys -split '\+')) {
        $t = $part.Trim()
        if (-not $t) { continue }
        switch -Regex ($t) {
            '^(ctrl|control)$' { $p.Ctrl = $true; break }
            '^alt$'            { $p.Alt = $true; break }
            '^shift$'          { $p.Shift = $true; break }
            '^win$'            { $p.Win = $true; break }
            default {
                $name = if ($t -match '^[0-9]$') { "D$t" } else { $t }
                # キャストだと小文字("m")を解決できないので大文字小文字無視で Parse
                $p.Key = [Enum]::Parse([System.Windows.Forms.Keys], $name, $true).ToString()
            }
        }
    }
    return $p
}

function Format-Hotkey($Parts) {
    if (-not $Parts.Key) { return '' }
    $out = @()
    if ($Parts.Ctrl)  { $out += 'Ctrl' }
    if ($Parts.Alt)   { $out += 'Alt' }
    if ($Parts.Shift) { $out += 'Shift' }
    if ($Parts.Win)   { $out += 'Win' }
    $out += ($Parts.Key -replace '^D([0-9])$', '$1')
    return ($out -join '+')
}

function ConvertTo-HotkeyCode([string]$Keys) {
    $p = Get-HotkeyParts $Keys
    if (-not $p.Key) { throw "ホットキー '$Keys' にキー本体がありません" }
    $mods = [uint32]0x4000  # MOD_NOREPEAT
    if ($p.Alt)   { $mods = $mods -bor 1 }
    if ($p.Ctrl)  { $mods = $mods -bor 2 }
    if ($p.Shift) { $mods = $mods -bor 4 }
    if ($p.Win)   { $mods = $mods -bor 8 }
    return @{ Modifiers = $mods; Vk = [uint32][System.Windows.Forms.Keys]$p.Key }
}

function Get-NormalizedHotkey([string]$Keys) {
    try { return (Format-Hotkey (Get-HotkeyParts $Keys)) } catch { return $Keys }
}

# ---- 設定ファイル ----

$script:RoleChoices = @(
    @{ V = 'communication'; L = '既定の通信デバイス (通話用)' },
    @{ V = 'default';       L = '既定のデバイス (音楽・システム音)' },
    @{ V = 'both';          L = '両方' }
)
$script:ActionChoices = @(
    @{ V = 'set';           L = '指定したデバイスに切替' },
    @{ V = 'cycle-mic';     L = 'マイクを順番に切替' },
    @{ V = 'cycle-speaker'; L = 'スピーカーを順番に切替' }
)

function Get-ChoiceIndex($Choices, [string]$Value) {
    for ($i = 0; $i -lt $Choices.Count; $i++) { if ($Choices[$i].V -eq $Value) { return $i } }
    return 0
}

function New-Entry {
    [pscustomobject]@{ keys = ''; action = 'set'; mic = ''; speaker = ''; devices = @(); role = '' }
}

function Copy-Entry($e) {
    [pscustomobject]@{
        keys    = Get-NormalizedHotkey ([string]$e.keys)
        action  = [string]$e.action
        mic     = [string]$e.mic
        speaker = [string]$e.speaker
        devices = @($e.devices | Where-Object { $_ } | ForEach-Object { [string]$_ })
        role    = [string]$e.role
    }
}

function Read-Config {
    # config.json が無ければ空の設定を返す(初回起動 → 設定画面で作る)
    $role = 'communication'
    $entries = @()
    if (Test-Path $ConfigPath) {
        $raw = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
        if ($raw.role) { $role = [string]$raw.role }
        $entries = @($raw.hotkeys | Where-Object { $_ } | ForEach-Object { Copy-Entry $_ })
    }
    return [pscustomobject]@{ role = $role; hotkeys = $entries }
}

function ConvertTo-JsonText([string]$s) {
    $s = $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $s + '"'
}

function Save-Config($Config) {
    $lines = @()
    foreach ($e in $Config.hotkeys) {
        $f = @(('"keys": ' + (ConvertTo-JsonText $e.keys)), ('"action": ' + (ConvertTo-JsonText $e.action)))
        if ($e.action -eq 'set') {
            if ($e.mic)     { $f += '"mic": ' + (ConvertTo-JsonText $e.mic) }
            if ($e.speaker) { $f += '"speaker": ' + (ConvertTo-JsonText $e.speaker) }
        } else {
            $f += '"devices": [' + ((@($e.devices) | ForEach-Object { ConvertTo-JsonText $_ }) -join ', ') + ']'
        }
        if ($e.role) { $f += '"role": ' + (ConvertTo-JsonText $e.role) }
        $lines += '    { ' + ($f -join ', ') + ' }'
    }
    $nl = "`r`n"
    $text = '{' + $nl + '  "role": ' + (ConvertTo-JsonText $Config.role) + ',' + $nl +
            '  "hotkeys": [' + $nl + ($lines -join (',' + $nl)) + $nl + '  ]' + $nl + '}' + $nl
    [System.IO.File]::WriteAllText($ConfigPath, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ActionLabel([string]$Action) {
    foreach ($c in $script:ActionChoices) { if ($c.V -eq $Action) { return $c.L } }
    return $Action
}

function Get-EntrySummary($e) {
    if ($e.action -eq 'set') {
        $p = @()
        if ($e.mic)     { $p += "マイク: $($e.mic)" }
        if ($e.speaker) { $p += "スピーカー: $($e.speaker)" }
        return ($p -join ' / ')
    }
    return (@($e.devices) -join ' → ')
}

# ---- 設定画面 ----

$script:UiFont = New-Object System.Drawing.Font('Yu Gothic UI', 9)
# 修飾キーなしでも割り当てを許すキー
$script:SoloKeyPattern = '^(F\d+|Pause|Scroll|Media.*|Browser.*|Launch.*|Volume.*)$'

function New-Ctl {
    param([string]$Type, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text)
    $c = New-Object "System.Windows.Forms.$Type"
    $c.SetBounds($X, $Y, $W, $H)
    if ($Text) { $c.Text = $Text }
    return $c
}

function New-DialogForm([string]$Title, [int]$W, [int]$H) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.Font = $script:UiFont
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.ClientSize = New-Object System.Drawing.Size($W, $H)
    return $f
}

function Show-EntryDialog {
    # 1件分の編集ダイアログ。OK なら新しいエントリ、キャンセルなら $null
    param($Entry, [string[]]$UsedKeys)

    $edMicNames = @([AudioHotkey.Audio]::List([AudioHotkey.EDataFlow]::eCapture) | ForEach-Object { $_.Name })
    $edSpkNames = @([AudioHotkey.Audio]::List([AudioHotkey.EDataFlow]::eRender) | ForEach-Object { $_.Name })
    $ed = @{ Result = $null; Parts = $null }
    try { $ed.Parts = Get-HotkeyParts $Entry.keys } catch { $ed.Parts = Get-HotkeyParts '' }

    $edForm = New-DialogForm 'ホットキーの割り当て' 460 395
    $edForm.StartPosition = 'CenterParent'
    $edForm.ShowInTaskbar = $false

    # --- ホットキー入力 ---
    $edForm.Controls.Add((New-Ctl Label 15 18 90 20 'ホットキー'))
    $edTxt = New-Ctl TextBox 110 15 200 23
    $edTxt.ReadOnly = $true
    $edTxt.BackColor = [System.Drawing.SystemColors]::Window
    $edTxt.ShortcutsEnabled = $false
    $edTxt.ImeMode = 'Disable'
    $edTxt.TextAlign = 'Center'
    $edWin = New-Ctl CheckBox 320 16 55 22 'Win'
    $edWin.Checked = $ed.Parts.Win
    $edClear = New-Ctl Button 380 14 65 25 'クリア'
    $edHintDefault = '入力欄をクリックして、割り当てたいキーの組み合わせを押してください'
    $edHint = New-Ctl Label 110 43 340 20 $edHintDefault
    $edHint.ForeColor = [System.Drawing.SystemColors]::GrayText
    $edForm.Controls.AddRange(@($edTxt, $edWin, $edClear, $edHint))

    $edRefresh = {
        $edTxt.Text = Format-Hotkey $ed.Parts
        $edHint.Text = $edHintDefault
        $edHint.ForeColor = [System.Drawing.SystemColors]::GrayText
    }
    & $edRefresh

    $edTxt.add_PreviewKeyDown({
        # Tab / Enter / Esc 単体はダイアログ操作に残し、それ以外は入力として受け取る
        $plain = ($_.Modifiers -eq [System.Windows.Forms.Keys]::None) -and -not $edWin.Checked
        if (-not ($plain -and (@('Tab', 'Return', 'Escape') -contains $_.KeyCode.ToString()))) { $_.IsInputKey = $true }
    })
    $edTxt.add_KeyDown({
        $_.SuppressKeyPress = $true
        $_.Handled = $true
        $name = $_.KeyCode.ToString()
        if (@('ControlKey', 'ShiftKey', 'Menu', 'LWin', 'RWin', 'None', 'ProcessKey') -contains $name) { return }
        $hasMod = $_.Control -or $_.Alt -or $_.Shift -or $edWin.Checked
        if (-not $hasMod -and (@('Back', 'Delete') -contains $name)) {
            $ed.Parts.Key = ''
            & $edRefresh
            return
        }
        if (-not $hasMod -and $name -notmatch $script:SoloKeyPattern) {
            $edHint.Text = 'Ctrl / Alt / Shift / Win のいずれかと組み合わせてください'
            $edHint.ForeColor = [System.Drawing.Color]::Firebrick
            return
        }
        $ed.Parts.Ctrl = $_.Control
        $ed.Parts.Alt = $_.Alt
        $ed.Parts.Shift = $_.Shift
        $ed.Parts.Win = $edWin.Checked
        $ed.Parts.Key = $name
        & $edRefresh
    })
    $edWin.add_CheckedChanged({ $ed.Parts.Win = $edWin.Checked; & $edRefresh })
    $edClear.add_Click({ $ed.Parts.Key = ''; & $edRefresh; $edTxt.Focus() })

    # --- 動作 ---
    $edForm.Controls.Add((New-Ctl Label 15 78 90 20 '動作'))
    $edAction = New-Ctl ComboBox 110 75 335 23
    $edAction.DropDownStyle = 'DropDownList'
    foreach ($c in $script:ActionChoices) { [void]$edAction.Items.Add($c.L) }
    $edForm.Controls.Add($edAction)

    # --- 動作 = set 用 ---
    $edSetPanel = New-Ctl Panel 0 110 460 185
    $edSetPanel.Controls.Add((New-Ctl Label 15 8 90 20 'マイク'))
    $edMic = New-Ctl ComboBox 110 5 335 23
    $edMic.Items.AddRange([object[]]$edMicNames)
    $edMic.Text = $Entry.mic
    $edSetPanel.Controls.Add((New-Ctl Label 15 43 90 20 'スピーカー'))
    $edSpk = New-Ctl ComboBox 110 40 335 23
    $edSpk.Items.AddRange([object[]]$edSpkNames)
    $edSpk.Text = $Entry.speaker
    $edSetHint = New-Ctl Label 110 72 340 40 "空欄にした方は変更しません。`n名前の一部だけを手入力しても一致します。"
    $edSetHint.ForeColor = [System.Drawing.SystemColors]::GrayText
    $edSetPanel.Controls.AddRange(@($edMic, $edSpk, $edSetHint))

    # --- 動作 = cycle 用 ---
    $edCyclePanel = New-Ctl Panel 0 110 460 185
    $edCyclePanel.Controls.Add((New-Ctl Label 15 8 90 20 '切替の順番'))
    $edList = New-Ctl ListBox 110 5 250 110
    $edList.IntegralHeight = $false
    foreach ($d in @($Entry.devices)) { if ($d) { [void]$edList.Items.Add([string]$d) } }
    $edUp = New-Ctl Button 370 5 75 26 '↑ 上へ'
    $edDown = New-Ctl Button 370 35 75 26 '↓ 下へ'
    $edDel = New-Ctl Button 370 65 75 26 '削除'
    $edAddBox = New-Ctl ComboBox 110 122 250 23
    $edAdd = New-Ctl Button 370 121 75 26 '追加'
    $edCycleHint = New-Ctl Label 110 152 340 30 '押すたびに上から順に切り替わります。未接続のものは飛ばします。'
    $edCycleHint.ForeColor = [System.Drawing.SystemColors]::GrayText
    $edCyclePanel.Controls.AddRange(@($edList, $edUp, $edDown, $edDel, $edAddBox, $edAdd, $edCycleHint))
    $edForm.Controls.AddRange(@($edSetPanel, $edCyclePanel))

    $edMove = {
        param([int]$Delta)
        $i = $edList.SelectedIndex
        $j = $i + $Delta
        if ($i -lt 0 -or $j -lt 0 -or $j -ge $edList.Items.Count) { return }
        $v = $edList.Items[$i]
        $edList.Items.RemoveAt($i)
        $edList.Items.Insert($j, $v)
        $edList.SelectedIndex = $j
    }
    $edUp.add_Click({ & $edMove -1 })
    $edDown.add_Click({ & $edMove 1 })
    $edDel.add_Click({
        $i = $edList.SelectedIndex
        if ($i -ge 0) {
            $edList.Items.RemoveAt($i)
            if ($edList.Items.Count) { $edList.SelectedIndex = [Math]::Min($i, $edList.Items.Count - 1) }
        }
    })
    $edAdd.add_Click({
        $t = $edAddBox.Text.Trim()
        if ($t -and -not $edList.Items.Contains($t)) {
            [void]$edList.Items.Add($t)
            $edList.SelectedIndex = $edList.Items.Count - 1
        }
        $edAddBox.Text = ''
    })

    $edAction.add_SelectedIndexChanged({
        $a = $script:ActionChoices[$edAction.SelectedIndex].V
        $edSetPanel.Visible = ($a -eq 'set')
        $edCyclePanel.Visible = ($a -ne 'set')
        $edAddBox.Items.Clear()
        if ($a -eq 'cycle-mic') { $edAddBox.Items.AddRange([object[]]$edMicNames) }
        if ($a -eq 'cycle-speaker') { $edAddBox.Items.AddRange([object[]]$edSpkNames) }
    })
    $edAction.SelectedIndex = Get-ChoiceIndex $script:ActionChoices $Entry.action

    # --- 切替対象(role) ---
    $edForm.Controls.Add((New-Ctl Label 15 308 90 20 '切替対象'))
    $edRole = New-Ctl ComboBox 110 305 335 23
    $edRole.DropDownStyle = 'DropDownList'
    [void]$edRole.Items.Add('全体の設定に従う')
    foreach ($c in $script:RoleChoices) { [void]$edRole.Items.Add($c.L) }
    $edRole.SelectedIndex = if ($Entry.role) { (Get-ChoiceIndex $script:RoleChoices $Entry.role) + 1 } else { 0 }
    $edForm.Controls.Add($edRole)

    # --- OK / キャンセル ---
    $edOk = New-Ctl Button 265 355 85 28 'OK'
    $edCancel = New-Ctl Button 360 355 85 28 'キャンセル'
    $edCancel.DialogResult = 'Cancel'
    $edForm.Controls.AddRange(@($edOk, $edCancel))
    $edForm.AcceptButton = $edOk
    $edForm.CancelButton = $edCancel

    $edOk.add_Click({
        $keys = Format-Hotkey $ed.Parts
        $action = $script:ActionChoices[$edAction.SelectedIndex].V
        $mic = $edMic.Text.Trim()
        $spk = $edSpk.Text.Trim()
        $err = $null
        if (-not $keys) { $err = 'ホットキーを入力してください。' }
        elseif ($UsedKeys -contains $keys) { $err = "$keys はすでに別の割り当てで使われています。" }
        elseif ($action -eq 'set' -and -not $mic -and -not $spk) { $err = 'マイクかスピーカーの少なくとも一方を指定してください。' }
        elseif ($action -ne 'set' -and $edList.Items.Count -lt 1) { $err = '切り替えるデバイスを1つ以上追加してください。' }
        if ($err) {
            [void][System.Windows.Forms.MessageBox]::Show($edForm, $err, 'AudioHotkey', 'OK', 'Warning')
            return
        }
        $n = New-Entry
        $n.keys = $keys
        $n.action = $action
        if ($action -eq 'set') { $n.mic = $mic; $n.speaker = $spk }
        else { $n.devices = @($edList.Items | ForEach-Object { [string]$_ }) }
        if ($edRole.SelectedIndex -gt 0) { $n.role = $script:RoleChoices[$edRole.SelectedIndex - 1].V }
        $ed.Result = $n
        $edForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })

    $edForm.add_Shown({ $edTxt.Focus() })
    [void]$edForm.ShowDialog()
    $edForm.Dispose()
    return $ed.Result
}

function Update-SettingsList($ListView, $Items, [int]$Select) {
    $ListView.BeginUpdate()
    $ListView.Items.Clear()
    foreach ($e in $Items) {
        $it = New-Object System.Windows.Forms.ListViewItem([string]$e.keys)
        [void]$it.SubItems.Add((Get-ActionLabel $e.action))
        [void]$it.SubItems.Add((Get-EntrySummary $e))
        [void]$ListView.Items.Add($it)
    }
    if ($Select -ge 0 -and $Select -lt $ListView.Items.Count) {
        $ListView.Items[$Select].Selected = $true
        $ListView.Items[$Select].Focused = $true
    }
    $ListView.EndUpdate()
}

function Show-SettingsDialog {
    # 設定画面。保存なら新しい設定オブジェクト、キャンセルなら $null
    param($Config)

    $st = @{ Items = New-Object System.Collections.ArrayList }
    foreach ($e in $Config.hotkeys) { [void]$st.Items.Add((Copy-Entry $e)) }

    $stForm = New-DialogForm 'AudioHotkey 設定' 640 400
    $stForm.StartPosition = 'CenterScreen'
    $stForm.Icon = Get-AppIcon

    $stForm.Controls.Add((New-Ctl Label 15 18 150 20 '切り替える対象 (全体)'))
    $stRole = New-Ctl ComboBox 170 15 260 23
    $stRole.DropDownStyle = 'DropDownList'
    foreach ($c in $script:RoleChoices) { [void]$stRole.Items.Add($c.L) }
    $stRole.SelectedIndex = Get-ChoiceIndex $script:RoleChoices $Config.role
    $stForm.Controls.Add($stRole)

    $stList = New-Ctl ListView 15 50 515 290
    $stList.View = 'Details'
    $stList.FullRowSelect = $true
    $stList.MultiSelect = $false
    $stList.HideSelection = $false
    $stList.HeaderStyle = 'Nonclickable'
    [void]$stList.Columns.Add('ホットキー', 130)
    [void]$stList.Columns.Add('動作', 140)
    [void]$stList.Columns.Add('デバイス', 240)
    $stForm.Controls.Add($stList)

    $stAdd  = New-Ctl Button 540 50 85 28 '追加...'
    $stEdit = New-Ctl Button 540 83 85 28 '編集...'
    $stDel  = New-Ctl Button 540 116 85 28 '削除'
    $stUp   = New-Ctl Button 540 159 85 28 '↑ 上へ'
    $stDown = New-Ctl Button 540 192 85 28 '↓ 下へ'
    $stTest = New-Ctl Button 540 312 85 28 '今すぐ実行'
    $stHint = New-Ctl Label 15 350 400 40 "行をダブルクリックで編集できます。`n設定画面を開いている間、ホットキーは一時停止します。"
    $stHint.ForeColor = [System.Drawing.SystemColors]::GrayText
    $stSave = New-Ctl Button 445 358 85 28 '保存'
    $stCancel = New-Ctl Button 540 358 85 28 'キャンセル'
    $stSave.DialogResult = 'OK'
    $stCancel.DialogResult = 'Cancel'
    $stForm.Controls.AddRange(@($stAdd, $stEdit, $stDel, $stUp, $stDown, $stTest, $stHint, $stSave, $stCancel))
    $stForm.AcceptButton = $stSave
    $stForm.CancelButton = $stCancel

    $stSelected = { if ($stList.SelectedIndices.Count) { $stList.SelectedIndices[0] } else { -1 } }
    $stSync = {
        $on = ((& $stSelected) -ge 0)
        foreach ($b in @($stEdit, $stDel, $stUp, $stDown, $stTest)) { $b.Enabled = $on }
    }
    $stOtherKeys = {
        param([int]$Except)
        $keys = @()
        for ($i = 0; $i -lt $st.Items.Count; $i++) { if ($i -ne $Except) { $keys += [string]$st.Items[$i].keys } }
        return , $keys
    }
    $stEditAt = {
        $i = & $stSelected
        if ($i -lt 0) { return }
        $r = Show-EntryDialog -Entry $st.Items[$i] -UsedKeys (& $stOtherKeys $i)
        if ($r) { $st.Items[$i] = $r; Update-SettingsList $stList $st.Items $i }
    }
    $stMove = {
        param([int]$Delta)
        $i = & $stSelected
        $j = $i + $Delta
        if ($i -lt 0 -or $j -lt 0 -or $j -ge $st.Items.Count) { return }
        $v = $st.Items[$i]
        $st.Items.RemoveAt($i)
        $st.Items.Insert($j, $v)
        Update-SettingsList $stList $st.Items $j
    }

    $stList.add_SelectedIndexChanged({ & $stSync })
    $stList.add_DoubleClick({ & $stEditAt })
    $stEdit.add_Click({ & $stEditAt })
    $stAdd.add_Click({
        $r = Show-EntryDialog -Entry (New-Entry) -UsedKeys (& $stOtherKeys -1)
        if ($r) { [void]$st.Items.Add($r); Update-SettingsList $stList $st.Items ($st.Items.Count - 1) }
    })
    $stDel.add_Click({
        $i = & $stSelected
        if ($i -lt 0) { return }
        $st.Items.RemoveAt($i)
        Update-SettingsList $stList $st.Items ([Math]::Min($i, $st.Items.Count - 1))
        & $stSync
    })
    $stUp.add_Click({ & $stMove -1 })
    $stDown.add_Click({ & $stMove 1 })
    $stTest.add_Click({
        $i = & $stSelected
        if ($i -lt 0) { return }
        try {
            $msg = Invoke-HotkeyEntry -Entry $st.Items[$i] -GlobalRole $script:RoleChoices[$stRole.SelectedIndex].V
            [void][System.Windows.Forms.MessageBox]::Show($stForm, "切り替えました。`n`n$msg", 'AudioHotkey', 'OK', 'Information')
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($stForm, "$_", 'AudioHotkey', 'OK', 'Error')
        }
    })

    Update-SettingsList $stList $st.Items 0
    & $stSync
    $stForm.add_Shown({ $stForm.Activate() })
    $result = $stForm.ShowDialog()
    $stForm.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return [pscustomobject]@{
        role    = $script:RoleChoices[$stRole.SelectedIndex].V
        hotkeys = @($st.Items.ToArray())
    }
}

function Get-AppIcon {
    if (-not $script:appIcon) {
        try {
            $script:appIcon = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $env:SystemRoot 'System32\SndVol.exe'))
        } catch {
            $script:appIcon = [System.Drawing.SystemIcons]::Application
        }
    }
    return $script:appIcon
}

# ---- スタートアップ登録 ----

function Get-StartupLinkPath { Join-Path ([Environment]::GetFolderPath('Startup')) 'AudioHotkey.lnk' }

function Set-StartupEnabled([bool]$Enable) {
    $lnkPath = Get-StartupLinkPath
    if (-not $Enable) {
        if (Test-Path $lnkPath) { Remove-Item $lnkPath }
        return
    }
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.Description = 'AudioHotkey - オーディオデバイス切替'
    $lnk.Save()
}

# ドットソース(. .\audio-hotkey.ps1)された場合は関数定義だけで終わる
if ($MyInvocation.InvocationName -eq '.') { return }

[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- モード: デバイス一覧 ----
if ($ListDevices) {
    foreach ($set in @(
        @{ Label = 'スピーカー / 出力'; Flow = [AudioHotkey.EDataFlow]::eRender },
        @{ Label = 'マイク / 入力';     Flow = [AudioHotkey.EDataFlow]::eCapture }
    )) {
        $defComm = [AudioHotkey.Audio]::GetDefault($set.Flow, [AudioHotkey.ERole]::eCommunications)
        $defCons = [AudioHotkey.Audio]::GetDefault($set.Flow, [AudioHotkey.ERole]::eConsole)
        Write-Host "`n=== $($set.Label) ===" -ForegroundColor Cyan
        foreach ($d in [AudioHotkey.Audio]::List($set.Flow)) {
            $marks = @()
            if ($d.Id -eq $defCons) { $marks += '既定' }
            if ($d.Id -eq $defComm) { $marks += '通信' }
            $mark = if ($marks) { '[' + ($marks -join '/') + '] ' } else { '' }
            Write-Host ("  {0}{1}" -f $mark, $d.Name)
            Write-Host ("      ID: {0}" -f $d.Id) -ForegroundColor DarkGray
        }
    }
    Write-Host "`nconfig.json には名前の一部(部分一致)か ID をそのまま書けます。" -ForegroundColor Yellow
    return
}

# ---- モード: 単発実行(動作確認用) ----
if ($Trigger) {
    $config = Read-Config
    $want = Get-NormalizedHotkey $Trigger
    $entry = $config.hotkeys | Where-Object { $_.keys -eq $want } | Select-Object -First 1
    if (-not $entry) { throw "config.json に keys='$Trigger' のエントリがありません" }
    Write-Host (Invoke-HotkeyEntry -Entry $entry -GlobalRole $config.role)
    return
}

# ---- モード: 設定画面だけ開く ----
if ($Settings) {
    $new = Show-SettingsDialog (Read-Config)
    if ($new) {
        Save-Config $new
        Write-Host "保存しました: $ConfigPath"
        Write-Host '常駐中の AudioHotkey には、トレイメニューの「設定を再読み込み」で反映できます。'
    }
    return
}

# ---- モード: 常駐 ----
$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\AudioHotkey', [ref]$createdNew)
if (-not $createdNew) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "AudioHotkey はすでに起動しています。`nタスクトレイのアイコンから設定を開けます。", 'AudioHotkey', 'OK', 'Information')
    return
}

$script:config = $null
$script:hotkeyMap = @{}
$script:settingsOpen = $false
$script:win = New-Object AudioHotkey.HotkeyWindow

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = Get-AppIcon
$script:notify.Text = 'AudioHotkey - オーディオ切替'
$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:notify.ContextMenuStrip = $script:menu
$script:notify.Visible = $true

function Show-Balloon([string]$Title, [string]$Text, [System.Windows.Forms.ToolTipIcon]$Icon = 'Info') {
    $script:notify.ShowBalloonTip(2000, $Title, $Text, $Icon)
}

function Invoke-EntryWithBalloon($Entry) {
    try {
        $msg = Invoke-HotkeyEntry -Entry $Entry -GlobalRole $script:config.role
        Show-Balloon "切替 ($($Entry.keys))" $msg
    } catch {
        Show-Balloon 'AudioHotkey エラー' "$_" 'Error'
    }
}

function Register-ConfiguredHotkeys {
    # config.json を読み直してホットキーを登録し直す。登録できなかったキーの一覧を返す
    $script:win.UnregisterAll()
    $script:hotkeyMap = @{}
    $script:config = Read-Config
    $failed = @()
    $id = 1
    foreach ($entry in $script:config.hotkeys) {
        try {
            $code = ConvertTo-HotkeyCode $entry.keys
            if ($script:win.Register($id, $code.Modifiers, $code.Vk)) {
                $script:hotkeyMap[$id] = $entry
                Write-Host "登録: $($entry.keys) → $($entry.action)"
            } else {
                $failed += $entry.keys
                Write-Warning "登録失敗(他アプリと競合?): $($entry.keys)"
            }
        } catch {
            $failed += $entry.keys
            Write-Warning "登録失敗: $($entry.keys) - $_"
        }
        $id++
    }
    return , $failed
}

function Update-Hotkeys {
    try {
        $failed = Register-ConfiguredHotkeys
        if ($failed.Count) {
            Show-Balloon 'AudioHotkey' "登録できなかったキー(他アプリと競合?): $($failed -join ', ')" 'Warning'
        }
    } catch {
        Show-Balloon 'AudioHotkey エラー' "設定を読み込めません: $_" 'Error'
    }
}

function Open-Settings {
    if ($script:settingsOpen) { return }
    $script:settingsOpen = $true
    try {
        # キー入力を受け取れるよう、開いている間はホットキーを外す
        $script:win.UnregisterAll()
        $new = Show-SettingsDialog (Read-Config)
        if ($new) { Save-Config $new }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("設定画面を開けません: $_", 'AudioHotkey', 'OK', 'Error')
    } finally {
        $script:settingsOpen = $false
        Update-Hotkeys
    }
}

$script:menu.add_Opening({
    $_.Cancel = $false  # 項目ゼロの状態で開くと既定でキャンセルされるため
    $items = $script:menu.Items
    $items.Clear()
    if ($script:config) {
        foreach ($entry in $script:config.hotkeys) {
            $mi = $items.Add("$(Get-EntrySummary $entry)")
            $mi.ShortcutKeyDisplayString = $entry.keys
            $mi.Tag = $entry
            $mi.add_Click({ Invoke-EntryWithBalloon $this.Tag })
        }
        if ($script:config.hotkeys.Count) { [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
    }
    $mi = $items.Add('設定...')
    $mi.Font = New-Object System.Drawing.Font($mi.Font, [System.Drawing.FontStyle]::Bold)
    $mi.add_Click({ Open-Settings })
    $mi = $items.Add('設定を再読み込み')
    $mi.add_Click({ Update-Hotkeys })
    $mi = $items.Add('Windows 起動時に自動で開始')
    $mi.Checked = (Test-Path (Get-StartupLinkPath))
    $mi.add_Click({
        try { Set-StartupEnabled (-not (Test-Path (Get-StartupLinkPath))) }
        catch { Show-Balloon 'AudioHotkey エラー' "$_" 'Error' }
    })
    [void]$items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mi = $items.Add('終了')
    $mi.add_Click({ [System.Windows.Forms.Application]::Exit() })
})
$script:notify.add_DoubleClick({ Open-Settings })

$script:win.add_HotkeyPressed({
    param($pressedId)
    $entry = $script:hotkeyMap[[int]$pressedId]
    if ($entry) { Invoke-EntryWithBalloon $entry }
})

try {
    if (Test-Path $ConfigPath) {
        Update-Hotkeys
    } else {
        # 初回起動: 設定画面から始める
        $script:config = Read-Config
        Open-Settings
    }
    Write-Host '常駐開始。タスクトレイのアイコンを右クリック → 設定 / 終了。'
    [System.Windows.Forms.Application]::Run()
} finally {
    $script:notify.Visible = $false
    $script:notify.Dispose()
    $script:win.Dispose()
    $script:mutex.ReleaseMutex()
}
