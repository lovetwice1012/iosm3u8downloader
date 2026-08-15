# HLS Downloader for iOS

URLを1つ貼ると、公開VODのm3u8を解析し、選択した最高画質の全断片をダウンロードして単一MP4へまとめるSwiftUIアプリです。m3u8の直接URLに加え、HTMLや埋め込みプレイヤーから見つけた候補をサムネイル付きの一覧から選べます。

## 主な機能

- master/media playlistの自動判別
- `video` / `source`タグ、data属性、ページ内プレイヤー設定からm3u8候補を抽出
- `iframe` / `srcdoc`を最大3階層まで探索し、候補ごとの検出元Refererを維持
- WebKitでJavaScript実行後のDOM変更、`fetch` / XHR、resource timingを全frameから監視
- HTML入力では候補URL・検出元・サムネイルを一覧表示し、選択した候補だけを検証して保存
- playlistごとの実URL（リダイレクト後）を基準にした相対URL補完
- `segment.ts`、`../segment.ts`、`/segment.ts`、`//cdn.example/...`、絶対URL
- 最高帯域variantと既定audio renditionの自動選択
- MPEG-TS、fMP4 + `EXT-X-MAP`、`EXT-X-BYTERANGE`
- 映像・別音声をまたいだ最大6並列の断片ダウンロードと一時的な通信エラーの再試行
- HTTP 200のログインHTML・JSON等を断片として誤保存しない内容検査
- 署名queryなし候補がエラーページを返した場合の同一origin query付き候補への再試行
- identity `AES-128`（AES-CBC、鍵ローテーション、明示IV/sequence IV）
- MPEG-TSはFFmpegKit/FFmpegで再圧縮せずMP4へremuxし、fMP4等はAVFoundationで結合
- 断片単体を開けない場合のplaylist単位連結再試行
- 完成MP4の共有・「ファイル」への保存
- URLやCookieの秘密値を残さない、コピー・共有可能な診断ログ

## GitHub Actionsで未署名IPAを作る

Developer Program、証明書、Provisioning Profileはビルド時に不要です。

1. このフォルダをGitHubリポジトリへpushします。
2. GitHubの **Actions** → **Build unsigned iPhone IPA** → **Run workflow** を実行します。
3. 完了したrunのArtifactsから `HLSDownloader-unsigned-iphoneos` をダウンロードします。
4. ZIP内の `HLSDownloader-unsigned.ipa` を取り出します。

IPAビルドとSimulatorテストは別ワークフローです。**Build unsigned iPhone IPA** はテストの完了を待たず `iphoneos`/arm64を次の条件でビルドし、**Test iOS app** は単体テストだけを実行します。`main`/`master`へのpushとPRでは両方が並行し、手動実行では必要なワークフローをそれぞれ選びます。

```text
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
AD_HOC_CODE_SIGNING_ALLOWED=NO
```

IPA内は標準の `Payload/HLSDownloader.app` 構造です。アプリ本体と内包する動的frameworkの署名、`_CodeSignature`、`embedded.mobileprovision` がないことをCIで確認してからartifact化するため、後段の個人署名でBundle ID、署名、Provisioning Profileを付けられます。

未署名IPA自体は通常の非脱獄iPhoneへ直接インストールできません。利用する個人署名環境で再署名してからインストールしてください。本プロジェクトにはApp Groups、Push、iCloudなど個人署名を複雑にするentitlementを設定していません。

## 対応範囲

- `#EXT-X-ENDLIST` を含む終了済みVOD
- 認証なし、URL内の署名query、またはページ自身の読み込み中に得られるCookieで取得できるHTTP(S)
- H.264/HEVC + AACなど、MP4へ格納でき、端末が再生できるコーデック
- 選択した1つの映像variantと、それに対応する既定音声の全断片

次の形式は、壊れた出力を作らずエラーとして終了します。

- 終端のないlive/event playlist
- FairPlay、`SAMPLE-AES`、非identity key format
- Safari等のログインCookieを必要とするページ
- 再生ボタン等のユーザー操作後にだけURLを生成するページ
- Worker / Service Worker内だけでHLS URLを生成し、ページ側へURLを公開しないプレイヤー
- `#EXT-X-GAP` を含むplaylist
- `#EXT-X-DISCONTINUITY` を含むplaylist
- AVFoundationがMP4へ出力できないコーデック

ダウンロードとMP4化は現在foreground処理です。長い動画では完了までアプリを前面に置いてください。途中でキャンセルすると、そのジョブの一時断片と未完成MP4を削除します。

候補が不足する場合や取得に失敗した場合は、画面下部の「診断ログ」を更新してコピーまたは共有できます。静的HTML、iframe、WebKit動的監視、playlist検証、ダウンロード、MP4結合の各段階と件数・失敗分類を記録します。URLは実URLの代わりに実行中だけ有効な識別子と形状情報を残し、query値、Cookie、Referer、HTML本文、タイトルは記録しません。

## プライバシーと利用条件

- 署名queryや鍵URLを画面・ログへ出しません。
- 動的プレイヤー解析は非永続WebKitセッションで行い、その解析中に得たCookieは対象ジョブの通信だけに使用します。
- 公開ページからlocalhost・LANへのiframe、サムネイル、リダイレクトは自動追跡しません。
- queryの自動引き継ぎは、通常のRFC URL解決がHTTPエラーになった場合に使う「同一origin限定」の候補です。別CDNへtokenを転送しません。
- 個人利用でHTTPやLAN上のHLSも扱えるようATSを許可しています。HTTPSだけに限定する場合は `Info.plist` の `NSAllowsArbitraryLoads` を削除してください。
- 自分が保存する権利を持つコンテンツ、または明示的に許可されたコンテンツだけに使用してください。DRMの回避機能はありません。

## FFmpegとオープンソースライセンス

MPEG-TSをMP4へ詰め替えるため、FFmpegKit Extended / FFmpeg 8.1.2のLGPLビルドを動的frameworkとして使用します。映像・音声は `-c copy` でstream copyし、再エンコードしません。バイナリは `v0.10.5-ios` のURLとSHA-256をSwift Packageで固定しています。正確なsource、checksum、同梱ライブラリのライセンス本文は [`ThirdPartyNotices.txt`](HLSDownloader/Resources/ThirdPartyNotices.txt) に収録しています。

## プロジェクト構成

```text
HLSDownloader.xcodeproj
HLSDownloader/
  App/            SwiftUI entry point
  Features/       URL入力、進捗、共有UI
  Domain/         playlist/download models and errors
  HLS/            URL検出、playlist解析、download plan
  Networking/     HTTP retry、Range、並列segment取得
  Crypto/         CommonCrypto AES-128/CBC
  Media/          MPEG-TS remux + AVMutableComposition + MP4 export
  Persistence/    job cache and Exports folder
HLSDownloaderTests/
Vendor/HLSFFmpegBridge/  pinned binary package + C shim
.github/workflows/build-unsigned-ipa.yml
.github/workflows/test.yml
```

## Macで直接確認する場合

```bash
xcodebuild test \
  -project HLSDownloader.xcodeproj \
  -scheme HLSDownloader \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

iOS 17以降を対象にしています。
