# HLS Downloader for Windows

iOS版と同じ「URL入力 → 解析 → 候補選択 → 再生または保存」を、Windows向けの1カラム・カードUIで実装したWinUI 3アプリです。iOS版とAndroid版はリポジトリ内にそのまま残し、Windows固有コードはこの `windows` ディレクトリだけに分離しています。

## 主な機能

- 拡張子に依存しないHLS / MPD判定
- `video` / `source` / data属性 / inline script / 同一origin iframeの静的HTML解析
- WebView2でページを実際に操作する「再生解析（α）」
  - document-startでDOMとMutationObserverを監視
  - `fetch` / XHR / Performance Resource Timingを監視
  - EME要求と`encrypted`イベントを検出
  - host側のWebResourceRequested / WebResourceResponseReceivedでもm3u8 / MPDを捕捉
- サムネイル、検出元、保存可否を含む候補一覧
- 通常HLS、identity AES-128 / SAMPLE-AES、MPEG-TS / fMP4のローカル化とFFmpeg合成
- 実際のtrackをffprobeで確認し、映像ありはMP4、音声だけはPCM 16-bit WAVへ自動出力
- 進捗、取消、完成ファイルを開く・フォルダー表示・名前を付けて保存
- WVDをWindowsのユーザー単位データ保護で暗号化して保管・削除するUI
  - 取り込み時と復号読み出し時にWVD v2 / Chrome・Android / L3 / flags 0 / フィールド長を検証（最大256 KiB）
- URL queryとローカルpathを伏せ、秘密値を出力しないコピー・保存対応の診断ログ

## ビルド

要件:

- Windows 10 1809以降（開発時はWindows 10 SDK 19041以降を推奨）
- .NET SDK 8.0.301以降
- Visual Studio 2022/2026のC++ Desktop tools（Windows App SDKのnative bootstrapをリンクするため）
- FFmpegとffprobeを次のいずれかに配置
  - `PATH`
  - 環境変数 `HLS_DOWNLOADER_FFMPEG_DIR`
  - 配布物の `tools/ffmpeg`

```powershell
cd windows
dotnet restore HLSDownloader.sln -p:Platform=x64
dotnet build HLSDownloader.sln -c Release -p:Platform=x64 --no-restore
```

ARM64では `-p:Platform=ARM64` を指定します。UIはMicrosoft.WindowsAppSDK 2.4.0 stableを使うunpackaged WinUI 3アプリで、Windows App SDKはself-contained設定です。

## GitHub Actionsから取得

Actionsの `Build Windows portable app` を手動実行すると、artifact `HLSDownloader-Windows-win-x64` にportable ZIPとSHA-256ファイルが生成されます。build actionは時間のかかるtest actionを待たず、`Test Windows app` は別actionとして実行できます。

artifactをダウンロードし、必要なら `Get-FileHash <zip> -Algorithm SHA256` の結果を同梱SHA-256と照合してください。ZIPを通常の書き込み可能なフォルダーへ展開し、展開先直下の `HLSDownloader.Windows.exe` を起動します。ZIP内から直接起動せず、`worker` と `tools` を含む同梱ファイルの配置を変えないでください。

## 構成

- `src/HLSDownloader.Windows`: WinUI 3 UI、WebView2画面、ファイルpicker、WVD保管、Core/Media統合
- `src/HLSDownloader.WebProbe`: page script生成、nonce付きbridge payload検証、URL分類
- `src/HLSDownloader.Core`: URL解決、HTML/iframe解析、HLS解析、download plan、domain/network policy
- `src/HLSDownloader.Media`: segment/key/map取得、AES処理、FFmpeg/ffprobe、MP4/WAV検証
- `src/HLSDownloader.Worker`: foreground UIから独立できるjob台帳・worker起動・IPC
- `tests`: portable Core/Mediaの自動テスト

## 再生解析の安全境界

page scriptからnative bridgeへ送るのは、検出元、公開URL、frameのpage URL、MIME、タイトル、サムネイルURL、EME key-system名だけです。request/response本文、Cookie、Authorization、任意header値、ライセンス応答、init dataの内容はbridge payloadへ入れません。

native側では256-bit nonce、schema version、payload長、signal件数、http(s) scheme、userinfo不在を検証します。候補として必要な署名付きURLはメモリ上の候補に保持しますが、診断ログではqueryとfragmentを伏せます。検出URLとframe URLに適合するWebView2 Cookie（HttpOnlyを含む）はCookieManagerから取得し、domain/path/secure属性を検証したうえでforeground download用CookieContainerだけへコピーします。Cookie値はUI・ログ・job台帳・ファイルへ出力せず、アプリ終了時に破棄します。静的HTTP解析はprivate/local network宛てとHTTPSからHTTPへのdowngrade redirectを拒否します。

## Widevine / WVD

WebView2上のサービス提供playerによるWidevine再生は、サイト側実装とインストール済みEdge WebView2 Runtimeの対応範囲に依存します。保存可否と再生可否のdomain判定はCoreの共通policyへ集約し、許可host外の既知MPD requestとWidevine EME要求は再生解析画面で拒否します。

WVDは現在のWindowsユーザーに紐づけて暗号化保管できます。ただし、この時点のWindowsビルドにはWVDを使うWidevine L3 download providerは接続していません。したがって、WVDを読み込んでもWidevineの復号済みMP4/WAV保存を成功扱いにはせず、明示的な「provider未設定」エラーで停止します。通常HLSの保存にはWVDを使いません。

## portable UIの制約

Core、Media、WebProbeはUIから独立した.NET 8コードですが、WinUI 3 / WebView2 / Windows picker / Windowsユーザー単位データ保護はWindows固有です。完全な単一実行ファイルではなく、Windows App SDK self-containedファイル一式とWebView2 Runtimeが必要です。WebView2内のログイン状態やDRM再生能力は、配信サイト、Edge Runtime、端末ポリシーに左右されます。

WebView2内で検出した候補には、そのframeのpage URLをRefererとして引き継ぎ、適合Cookieをメモリ内だけで共有します。fetch / XHRはURLと公開Content-Typeを観測しますがresponse本文は読み取らないため、JSONやJavaScript本文の中にだけmanifest URLが現れ、network responseのURL/MIMEから判別できない配信は拾えない場合があります。Authorizationやサイト独自header、service worker内token、POST本文は取り込まないため、それらが必須のstreamは候補を検出できても保存に失敗する場合があります。

Cookieを使わない直接URLかつ、requested/effective/page URLのすべてにqueryを含まない通常HLSだけは、保存jobを別プロセスのWorkerへ引き渡すためUIを閉じても処理を継続できます。次回起動時は実行中jobへ再接続し、直近の完成ファイルも完成カードへ復元します。明示的な「取消」は再接続したworker jobにも送信しますが、ウィンドウを閉じただけではjobを取り消しません。job台帳がない、または実行待ちjobがない起動では、新しいWorkerを起動しません。Workerはjobとpipe利用がなくなってから60秒で終了します。署名tokenや認証状態をjob台帳へ残さないため、HTML/再生解析由来、Cookieあり、query付きの候補はforeground処理に限定します。OS終了、ユーザーログアウト、外部FFmpegの強制終了を越えて無条件に継続するものではありません。
