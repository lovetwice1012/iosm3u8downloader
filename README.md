# HLS Downloader for iOS

URLを1つ貼ると、公開VODのm3u8を解析し、選択した最高画質の全断片をダウンロードして単一MP4へまとめるSwiftUIアプリです。m3u8の直接URLに加え、HTML内にm3u8 URLが記載されたページも探索します。

## 主な機能

- master/media playlistの自動判別
- playlistごとの実URL（リダイレクト後）を基準にした相対URL補完
- `segment.ts`、`../segment.ts`、`/segment.ts`、`//cdn.example/...`、絶対URL
- 最高帯域variantと既定audio renditionの自動選択
- MPEG-TS、fMP4 + `EXT-X-MAP`、`EXT-X-BYTERANGE`
- 最大4並列の断片ダウンロードと一時的な通信エラーの再試行
- HTTP 200のログインHTML・JSON等を断片として誤保存しない内容検査
- 署名queryなし候補がエラーページを返した場合の同一origin query付き候補への再試行
- identity `AES-128`（AES-CBC、鍵ローテーション、明示IV/sequence IV）
- AVFoundationによるMP4作成と、断片単体を開けない場合のplaylist単位連結再試行
- 完成MP4の共有・「ファイル」への保存

## GitHub Actionsで未署名IPAを作る

Developer Program、証明書、Provisioning Profileはビルド時に不要です。

1. このフォルダをGitHubリポジトリへpushします。
2. GitHubの **Actions** → **Build unsigned iPhone IPA** → **Run workflow** を実行します。
3. 完了したrunのArtifactsから `HLSDownloader-unsigned-iphoneos` をダウンロードします。
4. ZIP内の `HLSDownloader-unsigned.ipa` を取り出します。

ワークフローは先にSimulatorで単体テストを実行し、その後 `iphoneos`/arm64を次の条件でビルドします。

```text
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
AD_HOC_CODE_SIGNING_ALLOWED=NO
```

IPA内は標準の `Payload/HLSDownloader.app` 構造です。`_CodeSignature` と `embedded.mobileprovision` がないことをCIで確認してからartifact化するため、後段の個人署名でBundle ID、署名、Provisioning Profileを付けられます。

未署名IPA自体は通常の非脱獄iPhoneへ直接インストールできません。利用する個人署名環境で再署名してからインストールしてください。本プロジェクトにはApp Groups、Push、iCloudなど個人署名を複雑にするentitlementを設定していません。

## 対応範囲

- `#EXT-X-ENDLIST` を含む終了済みVOD
- 認証なし、またはURL内の署名queryだけで取得できるHTTP(S)
- H.264/HEVC + AACなど、端末のAVFoundationが読み込み・MP4出力できるコーデック
- 選択した1つの映像variantと、それに対応する既定音声の全断片

次の形式は、壊れた出力を作らずエラーとして終了します。

- 終端のないlive/event playlist
- FairPlay、`SAMPLE-AES`、非identity key format
- Safari等のログインCookieを必要とするページ
- `#EXT-X-GAP` を含むplaylist
- `#EXT-X-DISCONTINUITY` を含むplaylist
- AVFoundationがMP4へ出力できないコーデック

ダウンロードとMP4化は現在foreground処理です。長い動画では完了までアプリを前面に置いてください。途中でキャンセルすると、そのジョブの一時断片と未完成MP4を削除します。

## プライバシーと利用条件

- 署名queryや鍵URLを画面・ログへ出しません。
- queryの自動引き継ぎは、通常のRFC URL解決がHTTPエラーになった場合に使う「同一origin限定」の候補です。別CDNへtokenを転送しません。
- 個人利用でHTTPやLAN上のHLSも扱えるようATSを許可しています。HTTPSだけに限定する場合は `Info.plist` の `NSAllowsArbitraryLoads` を削除してください。
- 自分が保存する権利を持つコンテンツ、または明示的に許可されたコンテンツだけに使用してください。DRMの回避機能はありません。

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
  Media/          AVMutableComposition + MP4 export
  Persistence/    job cache and Exports folder
HLSDownloaderTests/
.github/workflows/build-unsigned-ipa.yml
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
