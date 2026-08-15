# HLS Downloader for iOS

URLを1つ貼ると、公開VODのm3u8を解析し、選択した最高画質の全断片をダウンロードして、映像を含む配信はMP4、音声のみの配信はPCM WAVへまとめるSwiftUIアプリです。m3u8の直接URLに加え、HTMLや埋め込みプレイヤーから見つけた候補をサムネイル付きの一覧から選べます。

## 主な機能

- master/media playlistの自動判別
- `video` / `source`タグ、data属性、ページ内プレイヤー設定からm3u8候補を抽出
- `iframe` / `srcdoc`を最大3階層まで探索し、候補ごとの検出元Refererを維持
- WebKitでJavaScript実行後のDOM変更、`fetch` / XHR、resource timingを全frameから監視
- **再生通信を解析（α）**: アプリ内ブラウザで実際に動画を再生し、その操作後に発生したDOM・`fetch` / XHR・resource timing・navigationからHLS/MPD候補を追加。Widevine EME試行とライセンス要求候補も同一frame内で関連付け
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
- 完成MP4/WAVの共有・「ファイル」への保存
- URLやCookieの秘密値を残さない、コピー・共有可能な診断ログ
- MPEG-DASH/MPDの`ContentProtection`、Widevine system ID、PSSH、CENC/CBCSの検出（アルファ）
- Widevine L3 WVD v2の構造検証と、端末限定Keychainへの保存

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
- 映像trackを含まないHLS/DASH音声の16-bit PCM WAV保存
- identity `SAMPLE-AES`（許可host上のVOD。FairPlay key formatは対象外）

### Widevineアルファ基盤

Widevineの許可hostは `HLSDownloader/DRM/WidevineDownloadPolicy.swift` のSetだけで管理し、すべての判定を `isDownloadableWidevineDomain(_:)` へ集約しています。現在はHTTPSの `widevine.sprink.cloud` 完全一致hostのみです。HTTP、userinfo付きURL、サブドメインや部分一致は許可しません。manifestとlicense endpointの両方に同じ判定を適用し、WVDのclient identificationを許可外hostへ送信しません。その他のWidevineは候補化せず、再生・保存とも行いません。DRMなしHLSにはこのドメイン制限を適用しません。

WVDファイルはアプリUIから読み込み、magic/version/AndroidまたはChrome device type/L3/flags/lengthを検証した後、`AfterFirstUnlockThisDeviceOnly` のKeychain itemとして保存します。処理開始時にはclient certificateのRSA公開鍵とWVD秘密鍵の一致も確認します。WVD本体、private key、client identification、content key、license headerはリポジトリや診断ログへ出力しません。

Widevineはm3u8/MPDの直リンクだけを前提にせず、「再生ページを開いて解析」からページ内の再生操作を監視します。MPD、`requestMediaKeySystemAccess("com.widevine.alpha")`、`MediaKeySession`のmessage、および直後の`fetch` / XHRを観測し、frame tokenとevent順序でmanifest候補へ結び付けます。候補へ保持するのはlicense URL、method、Content-Type、header**名**、body種別・サイズだけで、Authorization等のheader値、challenge、license応答本文は保持しません。

iOS標準のAVFoundation／WKWebViewがネイティブ対応するDRMはFairPlayで、Widevine CDMは内蔵されていません。このリポジトリのWidevine L3処理はWVDを使う独自ソフトウェア経路であり、iOS標準のWidevine再生機能ではありません。WKWebViewでEMEが拒否されたページでは、MPDとWidevine試行は検出できても、license要求が発生しない場合があります。fetch/XHRは送信直前に観測するため、画面では「通信完了」ではなく「license要求候補」として表示します。Worker / Service Worker内だけで完結する通信も対象外です。

mainの実行providerは、WVD v2/L3からoffline license challengeを生成し、MPDで選択した映像・音声representationのsegmentを上限付きで取得して、CENC/CBCSの復号を行います。映像を含む場合はMP4へ結合し、音声trackだけの場合は16-bit PCM WAVへ変換します。静的VODの単一Period、`SegmentTemplate` / `SegmentTimeline` / `SegmentList`、映像・音声それぞれ1つのKIDに対応します。ライセンスはoffline保存と再生を明示的に許可し、期限・renewal・output protectionなど、復号済みファイルで強制できない制約を持たない場合だけ受理します。

license要求はraw binaryを標準経路とし、応答はraw SignedMessage、厳格なbase64、または既知の単一JSON fieldだけを受理します。Authorization等のheader値、独自署名、privacy mode、独自JSON/form wrapperが必要なサービスは、運営者仕様に合わせたtransport設定が別途必要です。複数Period、dynamic MPD、KID rotation、`SegmentBase`、Worker内だけで完結する通信は現在の対象外です。復号キーを渡すFFmpeg処理は全セッションを直列化し、stdoutへのログ転送を止め、終了時にFFmpegKitのsession historyを消去します。復号途中・保存途中の平文ファイルは最初のbyteを書き込む前からData Protectionを設定し、前回の強制終了で残った専用一時ファイルを次回起動時に削除します。

次の形式は、壊れた出力を作らずエラーとして終了します。

- 終端のないlive/event playlist
- FairPlay key format、`SAMPLE-AES-CTR`、非identity key format
- main/audio rendition間で暗号方式が異なるSAMPLE-AES構成
- Safari等、別アプリのログインCookieだけを必要とするページ（αブラウザ内でログインできるページは、その非永続セッションのCookieを選択後のダウンロードへ引き継ぎます）
- Worker / Service Worker内だけでHLS URLを生成し、ページ側へURLを公開しないプレイヤー
- `#EXT-X-GAP` を含むplaylist
- `#EXT-X-DISCONTINUITY` を含むplaylist
- AVFoundationがMP4へ出力できないコーデック

再生通信の解析用ブラウザはforeground専用です。解析中にアプリをbackgroundへ移すと、その時点までの候補とCookieを確定して解析を終了します。候補を選んだ後のダウンロードとMP4/WAV生成は、iOS 26以降ではジョブごとの一意なidentifierでContinued Processing Taskを動的に登録・要求し、システムが受理した場合はbackgroundでも継続します。個人再署名でBundle IDが変更されてbackground task identifierが一致しない場合、またはiOS 17〜25では、`beginBackgroundTask`による短時間の完了猶予へ自動的にフォールバックします。システムのリソース制約、Live Activityからの取消、Appスイッチャーでの強制終了では中断されます。途中でキャンセルすると、そのジョブの一時断片と未完成ファイルを削除します。

候補が不足する場合や取得に失敗した場合は、画面下部の「診断ログ」を更新してコピーまたは共有できます。静的HTML、iframe、WebKit動的監視、playlist検証、ダウンロード、MP4/WAV生成の各段階と件数・失敗分類を記録します。URLは実URLの代わりに実行中だけ有効な識別子と形状情報を残し、query値、Cookie、Referer、HTML本文、タイトルは記録しません。

## プライバシーと利用条件

- 署名queryや鍵URLを画面・ログへ出しません。
- 動的プレイヤー解析は非永続WebKitセッションで行い、その解析中に得たCookieは対象ジョブの通信だけに使用します。
- αブラウザの候補表示ではURLのhost、pathの深さ、拡張子だけを示し、path・query内の署名値そのものは表示しません。
- 公開ページからlocalhost・LANへのiframe、サムネイル、リダイレクトは自動追跡しません。
- queryの自動引き継ぎは、通常のRFC URL解決がHTTPエラーになった場合に使う「同一origin限定」の候補です。別CDNへtokenを転送しません。
- 個人利用でHTTPやLAN上のHLSも扱えるようATSを許可しています。HTTPSだけに限定する場合は `Info.plist` の `NSAllowsArbitraryLoads` を削除してください。
- Widevine L3の復号・平文MP4保存機能を含みます。自分が保存する権利を持つコンテンツ、または配信運営者・権利者から明示的に許可されたコンテンツだけに使用してください。本実装はGoogle公式Widevine CDMまたは認定robustness実装の代替ではありません。

### ローカルVPN / 独自CAについて

ローカルVPN targetはこの個人署名向けIPAには含めていません。`NEPacketTunnelProvider`にはProvisioning Profileで許可されたNetwork Extension entitlementが必要で、無料のPersonal Team署名では有効化できないためです。端末へ独自ルートCAを導入して「完全な信頼」を有効化し、MITM proxyへ通信を通せば、証明書pinningのない通常TLSは技術的には復号できます。ただし、CAの導入だけでは通信はproxyへ流れず、pinning・独自TLS・QUIC等では失敗します。端末全体の通信を扱うVPN/MITMを、動作しない状態や秘密鍵管理が不十分な状態で同梱することはしていません。

iOS 17以降のWebKitには、特定の`WKWebsiteDataStore`だけをHTTP CONNECT proxyへ通すAPIがあります。将来の高度解析を追加する場合は、端末全体のVPNではなくαブラウザ限定の明示的なdebug modeとして分離する方針です。

## FFmpegとオープンソースライセンス

MPEG-TSのMP4化、identity SAMPLE-AESの復号、音声のみ配信のPCM WAV化に、FFmpegKit Extended / FFmpeg 8.1.2のLGPLビルドを動的frameworkとして使用します。映像を含むMP4は原則 `-c copy` でstream copyし、WAVだけは `pcm_s16le` へ変換します。バイナリは `v0.10.5-ios` のURLとSHA-256をSwift Packageで固定しています。正確なsource、checksum、同梱ライブラリのライセンス本文は [`ThirdPartyNotices.txt`](HLSDownloader/Resources/ThirdPartyNotices.txt) に収録しています。

## プロジェクト構成

```text
HLSDownloader.xcodeproj
HLSDownloader/
  App/            SwiftUI entry point
  Features/       URL入力、進捗、共有UI
  Domain/         playlist/download models and errors
  HLS/            URL検出、playlist解析、download plan
  DASH/           MPD、ContentProtection、PSSH解析
  DRM/            Widevine許可hostの共通ポリシー
  Widevine/       WVD検証、Keychain、処理provider境界
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
