# HLS Downloader for Windows

iOS版と同じ「URL入力 → 解析 → 候補選択 → 再生または保存」を、Windows向けの1カラム・カードUIで実装したWinUI 3アプリです。iOS版とAndroid版はリポジトリ内にそのまま残し、Windows固有コードはこの `windows` ディレクトリだけに分離しています。

## 主な機能

- 拡張子に依存しないHLS / MPD判定
- `video` / `source` / data属性 / inline script / 同一origin iframeの静的HTML解析
- WebView2でページを実際に操作する「再生解析（α）」
  - document-startでDOMとMutationObserverを監視
  - `fetch` / XHR / Performance Resource Timingを監視
  - EME要求と`encrypted`イベントを検出
  - host側の全WebResource context、redirect先、response MIMEでもm3u8 / MPDを捕捉
  - Content-Lengthが512 KiB以下の拡張子なしtext/XML/octet-stream応答だけ、先頭32 KiBを最大64応答・2並列・3秒で確認
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

native側では256-bit nonce、schema version、payload長、signal件数、http(s) scheme、userinfo不在を検証します。候補として必要な署名付きURLはメモリ上の候補に保持しますが、診断ログではqueryとfragmentを伏せます。検出URLとframe URLに適合するWebView2 Cookie（HttpOnlyを含む）はCookieManagerから取得し、domain/path/secure/SameSite属性を検証します。Cookie snapshotは候補ごとにメモリ内だけで最大5分保持し、選択時に一度だけforeground download用CookieContainerへ反映して処理後に消去します。Cookie値はUI・ログ・job台帳・ファイルへ出力しません。静的HTTP解析はprivate/local network宛てとHTTPSからHTTPへのdowngrade redirectを拒否します。

高度解析はアプリ内WebView2のnative resource eventで完結し、WindowsのVPN・system proxy・証明書storeを変更しません。HTTPSのCA MITMや自己署名証明書のinstallも行いません。非復号のloopback CONNECT proxyではhost以外の取得情報が増えず、DRMやcertificate pinningとの互換性を落とすためです。

再生解析ブラウザーのCookie、localStorage、IndexedDBなどは、`LocalApplicationData/HLSDownloader.Windows/WebView2Profile` の専用profileへ保持します。すべての再生解析windowが同じ明示的なWebView2 environmentを共有するため、サイトとWebView2 Runtimeが定める有効期限内では、アプリ更新や再起動後もログイン状態を再利用できます。session cookieを永続cookieへ変更するものではありません。portable EXEの隣へ暗黙profileを作るfallbackや、通常のEdge profileとの共有は行いません。profile pathやCookie値は診断ログへ出力しません。

## Widevine / WVD

WebView2上のサービス提供playerによるWidevine再生は、サイト側実装とインストール済みEdge WebView2 Runtimeの対応範囲に依存します。保存可否と再生可否のdomain判定はCoreの共通policyへ集約しています。再生解析画面では、許可hostから成功応答したMPDを同一frameで確認し、かつ実際にEMEを呼ぶplayer frame自体も許可hostである場合だけWidevine EMEを許可します。外部ページ内の許可host iframeは対象ですが、別hostのframeが許可MPDだけを読む構成はfail-closedで拒否します。

license endpointは、`MediaKeySession.generateRequest`の開始・成功から`update`成功までの30秒以内にnative WebView2が確認した2xx `POST`から自動関連付けします。同じ再生解析windowで許可MPDとPOST URIがそれぞれ1件に確定した場合だけ採用し、複数候補は拒否します。MPDにLaurlがあれば観測URIとの一致が必須で、Laurlが0件の場合だけ観測URIをhintとして使います。hintとlicense scopeのCookieはメモリ内だけで5分保持し、最初の保存試行で消費します。query値、Cookie値、request/response header、challenge/license bytesはbridge・診断ログ・job台帳へ出力しません。

WVDは現在のWindowsユーザーに紐づけて暗号化保管し、許可hostのWidevine L3 VODにだけ使用します。providerはstatic single-period MPD、Widevine ContentProtection/PSSH、CENC/CBCS、映像・音声representation、SegmentTemplate/Timeline/List、raw binary offline licenseに対応し、実trackに映像があればMP4、音声だけならPCM 16-bit WAVへ保存します。requested/effective manifest、license、全segmentと最終公開直前で共通のexact HTTPS host policyを再確認し、license redirect、key rotation、PIFF、dynamic/multi-period MPD、期限・更新・出力制約を持つlicenseはfail-closedで拒否します。通常HLSの保存にはWVDを使いません。

実FFmpeg CENC fixtureでは映像→MP4と音声のみ→WAVを確認しています。CBCS経路はparser・fMP4検証・FFmpeg引数まで実装していますが、この開発環境のFFmpegでは暗号化CBCS fixtureを生成できないため実暗号E2Eは未確認です。保存時は観測したPOSTを再送せず、WVD providerが生成したraw binary `SignedMessage`を新しく送信します。再生時POSTのbody/headerは意図的に取得しないため、実配信側がJSON/form wrapper、Authorization、独自header、privacy-mode service certificateを要求する場合は保存できません。

## portable UIの制約

Core、Media、WebProbeはUIから独立した.NET 8コードですが、WinUI 3 / WebView2 / Windows picker / Windowsユーザー単位データ保護はWindows固有です。完全な単一実行ファイルではなく、Windows App SDK self-containedファイル一式とWebView2 Runtimeが必要です。WebView2内のログイン状態やDRM再生能力は、配信サイト、Edge Runtime、端末ポリシーに左右されます。

WebView2内で検出した候補には、そのframeのpage URLをRefererとして引き継ぎ、適合Cookieをメモリ内だけで共有します。fetch / XHRはURLと公開Content-Typeを観測しますがresponse本文は読み取らないため、JSONやJavaScript本文の中にだけmanifest URLが現れ、network responseのURL/MIMEから判別できない配信は拾えない場合があります。Authorizationやサイト独自header、service worker内token、POST本文は取り込まないため、それらが必須のstreamは候補を検出できても保存に失敗する場合があります。

Cookieを使わない直接URLかつ、requested/effective/page URLのすべてにqueryを含まない通常HLSだけは、保存jobを別プロセスのWorkerへ引き渡すためUIを閉じても処理を継続できます。次回起動時は実行中jobへ再接続し、直近の完成ファイルも完成カードへ復元します。明示的な「取消」は再接続したworker jobにも送信しますが、ウィンドウを閉じただけではjobを取り消しません。job台帳がない、または実行待ちjobがない起動では、新しいWorkerを起動しません。Workerはjobとpipe利用がなくなってから60秒で終了します。署名tokenや認証状態をjob台帳へ残さないため、HTML/再生解析由来、Cookieあり、query付きの候補はforeground処理に限定します。OS終了、ユーザーログアウト、外部FFmpegの強制終了を越えて無条件に継続するものではありません。
