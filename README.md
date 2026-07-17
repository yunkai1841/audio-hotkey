# AudioHotkey

グローバルホットキーで Windows の既定オーディオデバイス(既定の通信デバイス等)を切り替える PowerShell スクリプト。外部ツール・追加インストール不要。

## 使い方

```powershell
# 1. デバイス一覧と現在の既定を確認(config.json に書く名前を決める)
powershell -NoProfile -ExecutionPolicy Bypass -File .\audio-hotkey.ps1 -ListDevices

# 2. config.sample.json を config.json にコピーして編集
#    (config.json は .gitignore 対象。各自の環境用)
copy config.sample.json config.json

# 3. 常駐開始(タスクトレイにアイコンが出る。右クリック→終了 で停止)
powershell -NoProfile -ExecutionPolicy Bypass -File .\audio-hotkey.ps1

# ホットキーを押さずにアクションを試す(デバッグ用)
powershell -NoProfile -ExecutionPolicy Bypass -File .\audio-hotkey.ps1 -Trigger "Ctrl+Alt+1"
```

切替に成功するとタスクトレイからバルーン通知が出ます。

## config.json

```json
{
  "role": "communication",
  "hotkeys": [
    { "keys": "Ctrl+Alt+1", "action": "set", "mic": "UGREEN USB MIC", "speaker": "Realtek" },
    { "keys": "Ctrl+Alt+2", "action": "set", "mic": "G435", "speaker": "G435" },
    { "keys": "Ctrl+Shift+Alt+M", "action": "cycle-mic", "devices": ["UGREEN USB MIC", "G435"] },
    { "keys": "Ctrl+Alt+S", "action": "cycle-speaker", "devices": ["Realtek", "G435"] }
  ]
}
```

### role — どの「既定」を切り替えるか

| 値 | 効果 |
|---|---|
| `"communication"` | 既定の通信デバイスのみ(Discord/Teams 等の通話用) |
| `"default"` | 既定のデバイスのみ(通常の音楽・システム音) |
| `"both"` | 両方まとめて切替 |

トップレベルの `role` が全体のデフォルト。各ホットキーに `"role": "both"` のように書けば個別に上書きできます。

### hotkeys の各エントリ

- `keys` — `Ctrl` / `Alt` / `Shift` / `Win` + キーを `+` でつなぐ。キー名は `A`〜`Z`、`0`〜`9`、`F1`〜`F24`、`NumPad0` など([.NET の Keys 列挙体](https://learn.microsoft.com/dotnet/api/system.windows.forms.keys)の名前)。
- `action`
  - `"set"` — `mic` / `speaker` で指定したデバイスに切替。片方だけの指定も可。
  - `"cycle-mic"` / `"cycle-speaker"` — `devices` の配列を上から順にサイクル。現在の既定が配列に無ければ先頭に切替。未接続のデバイスは自動でスキップ。
- デバイス指定は **名前の部分一致**(大文字小文字無視)。曖昧な場合は `-ListDevices` に出る ID をそのまま書けば確実。

## PC 起動時に自動開始する

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-startup.ps1
```

スタートアップフォルダにショートカットを作ります。外すときは `-Remove` を付けて実行。

## 注意

- ホットキー登録に失敗した場合(他アプリと競合)は起動時に警告が出ます。別のキーに変えてください。
- デバイス切替には非公開の COM インターフェース(IPolicyConfig)を使っています。SoundSwitch 等の定番ツールと同じ方式で、Windows 10/11 で動作します。
