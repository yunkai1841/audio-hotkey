# AudioHotkey

グローバルホットキーで Windows の既定オーディオデバイス(既定の通信デバイス等)を切り替える PowerShell スクリプト。外部ツール・追加インストール不要。

## 使い方

```powershell
# 常駐開始(タスクトレイにスピーカーのアイコンが出る)
# config.json がまだ無い初回は、設定画面が自動で開きます
powershell -NoProfile -ExecutionPolicy Bypass -File .\audio-hotkey.ps1

# 常駐せずに設定画面だけ開く
powershell -NoProfile -ExecutionPolicy Bypass -File .\audio-hotkey.ps1 -Settings

# デバイス一覧と現在の既定を表示
powershell -NoProfile -ExecutionPolicy Bypass -File .\audio-hotkey.ps1 -ListDevices

# ホットキーを押さずにアクションを試す(デバッグ用)
powershell -NoProfile -ExecutionPolicy Bypass -File .\audio-hotkey.ps1 -Trigger "Ctrl+Alt+1"
```

切替に成功するとタスクトレイからバルーン通知が出ます。

## タスクトレイのメニュー

アイコンを右クリック(ダブルクリックで設定画面を直接開く):

- **割り当て済みのアクション一覧** — クリックでその場で実行
- **設定...** — 設定画面を開く
- **設定を再読み込み** — config.json を手で編集したあとの反映用
- **Windows 起動時に自動で開始** — スタートアップ登録の ON/OFF
- **終了**

## 設定画面

- 「追加...」「編集...」で割り当てダイアログを開き、**ホットキー欄をクリックして割り当てたいキーの組み合わせをそのまま押す**と登録されます。Win キーを含めたい場合は横の「Win」にチェック。
- 通常のキーは Ctrl / Alt / Shift / Win のいずれかとの組み合わせが必要です(F1〜F24 やメディアキーは単体でも可)。
- マイク / スピーカーは接続中のデバイスから選択。名前の一部だけを手入力しても構いません。
- 「今すぐ実行」で、選択中の割り当てをその場で試せます。
- 「保存」で config.json に書き出し、ホットキーを即座に登録し直します。他アプリと競合して登録できなかったキーは通知されます。
- 設定画面を開いている間は、キー入力を受け取るためホットキーが一時停止します。

## config.json

設定画面が読み書きするファイルです(.gitignore 対象)。手で編集しても構いません。サンプルは `config.sample.json`。

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

スタートアップフォルダにショートカットを作ります。外すときは `-Remove` を付けて実行。トレイメニューの「Windows 起動時に自動で開始」でも同じことができます。

## 注意

- ホットキー登録に失敗した場合(他アプリと競合)は起動時に警告が出ます。別のキーに変えてください。
- デバイス切替には非公開の COM インターフェース(IPolicyConfig)を使っています。SoundSwitch 等の定番ツールと同じ方式で、Windows 10/11 で動作します。
