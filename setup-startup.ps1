# スタートアップに AudioHotkey のショートカットを作成/削除する
param([switch]$Remove)

$lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'AudioHotkey.lnk'
$scriptPath = Join-Path $PSScriptRoot 'audio-hotkey.ps1'

if ($Remove) {
    if (Test-Path $lnkPath) {
        Remove-Item $lnkPath
        Write-Host "削除しました: $lnkPath"
    } else {
        Write-Host 'ショートカットはありません'
    }
    return
}

$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.Description = 'AudioHotkey - オーディオデバイス切替'
$lnk.Save()
Write-Host "作成しました: $lnkPath"
Write-Host '次回サインイン時から自動起動します。今すぐ開始するには audio-hotkey.ps1 を実行してください。'
