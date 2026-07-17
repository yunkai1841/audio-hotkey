<#
.SYNOPSIS
  グローバルホットキーで Windows の既定オーディオデバイス(通信/既定)を切り替える常駐スクリプト。

.DESCRIPTION
  config.json にホットキーとアクションを定義して使う。
    action: "set"           … mic / speaker で指定したデバイスに一発切替(どちらか片方だけでも可)
    action: "cycle-mic"     … devices に列挙したマイクを順番に切替
    action: "cycle-speaker" … devices に列挙したスピーカーを順番に切替
  デバイス指定は「名前の部分一致(大文字小文字無視)」または完全なデバイスID。

.EXAMPLE
  .\audio-hotkey.ps1 -ListDevices   # デバイス一覧と現在の既定を表示
  .\audio-hotkey.ps1                # 常駐開始(タスクトレイにアイコン表示)
  .\audio-hotkey.ps1 -Trigger "Ctrl+Alt+M"  # ホットキーを押さずにそのアクションを1回実行(動作確認用)
#>
[CmdletBinding()]
param(
    [switch]$ListDevices,
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

        public void Dispose()
        {
            foreach (int id in _ids) UnregisterHotKey(Handle, id);
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
    if ($hit.Count -eq 0) { $hit = @($devs | Where-Object { $_.Name -like "*$Pattern*" }) }
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

function ConvertTo-HotkeyCode([string]$Keys) {
    # "Ctrl+Alt+1" → @{ Modifiers = ...; Vk = ... }
    $mods = [uint32]0x4000  # MOD_NOREPEAT
    $vk = [uint32]0
    foreach ($part in ($Keys -split '\+')) {
        $t = $part.Trim()
        switch -Regex ($t) {
            '^(?i)(ctrl|control)$' { $mods = $mods -bor 2 }
            '^(?i)alt$'            { $mods = $mods -bor 1 }
            '^(?i)shift$'          { $mods = $mods -bor 4 }
            '^(?i)win$'            { $mods = $mods -bor 8 }
            default {
                $name = if ($t -match '^[0-9]$') { "D$t" } else { $t }
                $vk = [uint32][System.Windows.Forms.Keys]$name
            }
        }
    }
    if ($vk -eq 0) { throw "ホットキー '$Keys' にキー本体がありません" }
    return @{ Modifiers = $mods; Vk = $vk }
}

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { throw "設定ファイルが見つかりません: $ConfigPath" }
    return Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
}

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
    $globalRole = if ($config.role) { $config.role } else { 'communication' }
    $entry = $config.hotkeys | Where-Object { $_.keys -eq $Trigger } | Select-Object -First 1
    if (-not $entry) { throw "config.json に keys='$Trigger' のエントリがありません" }
    $msg = Invoke-HotkeyEntry -Entry $entry -GlobalRole $globalRole
    Write-Host $msg
    return
}

# ---- モード: 常駐 ----
$config = Read-Config
$script:globalRole = if ($config.role) { $config.role } else { 'communication' }

$script:hotkeyMap = @{}
$script:win = New-Object AudioHotkey.HotkeyWindow

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = [System.Drawing.SystemIcons]::Application
$script:notify.Text = 'AudioHotkey - オーディオ切替'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$exitItem = $menu.Items.Add('終了')
$exitItem.add_Click({ [System.Windows.Forms.Application]::Exit() })
$script:notify.ContextMenuStrip = $menu
$script:notify.Visible = $true

function Show-Balloon([string]$Title, [string]$Text, [System.Windows.Forms.ToolTipIcon]$Icon = 'Info') {
    $script:notify.ShowBalloonTip(2000, $Title, $Text, $Icon)
}

$id = 1
$failed = @()
foreach ($entry in $config.hotkeys) {
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
if ($script:hotkeyMap.Count -eq 0) {
    $script:notify.Visible = $false
    throw 'ホットキーがひとつも登録できませんでした'
}
if ($failed) { Show-Balloon 'AudioHotkey' "登録できなかったキー: $($failed -join ', ')" 'Warning' }

$script:win.add_HotkeyPressed({
    param($pressedId)
    $entry = $script:hotkeyMap[[int]$pressedId]
    if (-not $entry) { return }
    try {
        $msg = Invoke-HotkeyEntry -Entry $entry -GlobalRole $script:globalRole
        Show-Balloon "切替 ($($entry.keys))" $msg
    } catch {
        Show-Balloon 'AudioHotkey エラー' "$_" 'Error'
    }
})

Write-Host "常駐開始。タスクトレイのアイコン右クリック→終了 で停止します。"
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $script:notify.Visible = $false
    $script:notify.Dispose()
    $script:win.Dispose()
}
