# YTMusicPresence

iPhone内のYouTube MusicからDiscord Social SDKへ直接Rich Presenceを送る、独立したインジェクション用dylibの研究用実装です。PCや中継サーバーを稼働させる構成ではありません。

**現在の状態：公式Discord Social SDK 1.10.19337でiOS arm64のコンパイルと未署名IPA生成を確認済みです。診断ログ付きv2では利用者からPresence更新の改善報告を受けています。v3の実機ログでは画像取得が失敗し、画像なしのPresence送信は成功していました。v4で画像の取得経路を追加しています。インストール前に全ネストコードの再署名が必要です。**

サムネイル取得修正版のビルド：[Actions run 38561712731](https://github.com/axcyum/YTMusicPresence/actions/runs/38561712731)。入力は提供されたYouTube Music 9.26.2 IPAと公式SDKのrelease用iOS xcframeworkです。

## 構成

`YouTube Music → MPNowPlayingInfoCenter → YTMusicPresence.dylib → Discord Social SDK → Discord`

- 曲名、アーティスト、アルバム名、再生時間をアプリが公開するNow Playing情報から取得。
- 曲の変更・シークを反映し、送信間隔は最低15秒。一時停止・停止時にPresenceを消去。
- アカウントメニューに「Discord Rich Presence」を追加。初回は利用者が明示的に「Discordと連携」を選択。
- SDKのOAuth + PKCEを利用。Presence用の標準スコープを要求。
- OAuthのaccess/refresh tokenはKeychainに保存。Client Secretは不要。
- YTMusicUltimateは同梱されたものを保持し、追加のdylibをロードする。既存フックのIMPを連鎖させる。
- 曲のサムネイルURLを取得できた場合、外部画像URLとして送信します。静的アセットの送信は標準では無効です。

## 曲ごとのサムネイル

公式Social SDKは外部画像URLを `ActivityAssets::SetLargeImage` に指定できます。Developer Portalへ曲ごとに画像を登録する必要はなく、この機能のための追加OAuthスコープは要求しません。

YouTube Musicの `YTPlayerViewController → playerResponse → playerData → videoDetails → thumbnail → thumbnailsArray` からサムネイルURLを取得します。Now Playingの曲名とモデルの曲名が一致した時だけ使用し、曲変更時に前の画像を誤って送ることを避けます。画像一覧が空なら、確認した動画IDから標準YouTubeサムネイルの公開URLを作ります。既知のYouTube/Google画像ホストのHTTPS URLのみを使用します。ローカル画像のアップロードは行いません。

v4では、`playerResponse.videoDetails`という別構造にも対応し、曲のデータを読み込む`YTIVideoDetails`/`YTIPlayerResponse`のsetterから画像情報を取得する経路を追加しました。保持するのは直近24件の曲名・作者・画像URLのスナップショットで、プレイヤー自体は保持しません。キャッシュは曲名と作者が一致した時に使用します。Now Playingに動画IDまたはYouTubeのwatch URLが提供された場合は、そこからもサムネイルを解決します。

画像が取得できない時は`artwork_missing_details`へ、各モデルのクラス名、モデル内とNow Playingの曲名、画像一覧の件数、動画識別子の有無を記録します。動画データ取得フックの設置結果は`artwork_model_hooks`へ記録します。提供ログから確定できるのは「v3は画像URLを取得できず、画像を送信していなかった」という点で、欠落していた具体的なモデルの段階はv4の実機ログで確認します。

設定メニューの「サムネイルを非表示 / 表示」で切り替えられます。画像が原因で送信内容を拒否された場合は画像なしで再試行し、曲情報の共有を維持します。「共有を再開」で画像送信も再試行します。画像URLの取得結果・送信・画像なしへのフォールバックはDocumentsの診断ログへ記録します。

`config.json`の`use_cover`は初期表示設定です。`use_assets`は別設定で、trueにすると動的サムネイルが取得できない場合に登録済みの静的キー`ytmusic`を使用します。初期値はfalseのため静的画像の登録は任意です。

今回のURL取得処理はアプリのprivate再生モデルに依存します。取得処理のネイティブテストとiOSコンパイルはActionsで検証し、実機での画像表示は更新後に確認が必要です。

## 診断ログと送信失敗への対応

アプリ内の `Documents/YTMusicPresence/presence.jsonl` に、起動、認証・トークン更新の成否、SDK接続状態、Presence送信内容・結果をJSON Lines形式で保存します。失敗時はSDKのerror type、HTTP status、Discord error code、HTTP response bodyを記録します。OAuthトークン、認証コード、PKCE verifierは伏せ字にします。

設定メニューの **診断ログを共有** からログファイルを書き出せます。Filesアプリや対応するファイル共有ツールからDocumentsへアクセスするためのInfo.plist設定も追加しています。ファイルサイズが1 MiBを超える前に `presence.previous.jsonl` へローテーションし、直近2ファイルを保持します。曲名・アーティストは診断のためログに含まれます。

更新失敗の原因は、以前の版が詳細を記録していなかったためまだ確定できていません。今回の変更では次を実施します。

- 未登録の画像キーに依存しない送信内容へ変更。
- Unicodeの文字を途中で切らず、文字列をUTF-8で128 bytes以内に調整。
- 再生時刻をメタデータ取得時点に固定し、再試行待機時間による時刻のずれを抑制。
- HTTP 400やDiscord code 50035で画像を含む送信内容が拒否され、時刻情報のエラーと判断できない場合は画像を外して再試行。時刻情報が原因の場合は画像を維持して時刻情報を外す。それでも拒否された場合はPlayingの互換表示で再試行し、再度HTTP 400なら自動再試行を停止。
- HTTP 401/403は送信形式を変更せず停止し、状態表示とログに詳細を残す。HTTP 429はRetryAfter以上の待機時間を取る。
- 成功時は「共有中」へ表示を更新。「共有を再開」で停止した再試行を再開できる。

ログは今後の起動から記録されます。以前のIPAで発生した失敗のログを遡って取得することはできません。実機で同じ失敗が続く場合は、メニューの「診断ログを共有」で取得したファイルが原因特定に必要です。

Application ID：`1559887091171852310`。`config.json`を変更して別のアプリIDでビルドできます。

## Discordで必要な設定

1. [Developer Portal](https://discord.com/developers/applications)で上記アプリを開く。
2. 左側の **Discord Social SDK → Getting Started** で初期設定を完了し、Social SDKを有効にする。公式の現行ガイドではDeveloper Teamに所属したアプリを使用します。既存アプリの所属とアクセス権も確認してください。
3. OAuth2ページの **Public Client** を有効にする。これは「URLジェネレーター」のスコープ一覧にあるチェック項目ではありません。OAuth2ページの設定領域を確認してください。項目が見つからなければ、Social SDKの初期設定とTeam所属を確認する。非表示の原因は画面全体やアプリ設定を確認しないと断定できません。
4. Redirect URIに **`discord-1559887091171852310:/authorize/callback`** を追加。
5. Discord Social SDKのDownloadsで、iOSを含む公式C++ SDKを取得する。`discord_partner_sdk.xcframework`が必要。アプリにSocial SDKの利用権限が付いていることも確認する。
6. Rich PresenceのArt Assetsへ`ytmusic`というキーでアイコンを登録する。
7. Discord側のアクティビティ共有・アプリ連携を有効にする。

OAuth2 URLジェネレーターで`rpc`や`rpc.activities.write`を選択・招待URLを作成する作業は、この実装では不要です。認証用のスコープとPKCEはSDK呼び出しが指定します。

SDKは公式配布物を利用してください。このリポジトリには含めません。iOSでは未認証RPCは使えないため、SDKによるOAuth認証を使います。SDKのiOS対応だけで、この第三者アプリへの注入構成やListening表示が保証されるものではありません。実機での検証が必要です。

## GitHub Actionsでビルドする場合

ワークフロー `.github/workflows/build-ios.yml` を用意しています。GitHubのmacOS runnerを使うため、自分のMacは不要です。公式SDK 1.10.19337でビルドとIPA生成を確認済みです。

1. この**非公開リポジトリ**のReleasesで、タグ`build-inputs`のReleaseを作成する。
2. 次の2ファイルをRelease assetsへ追加してPublishする。
   - 提示されたIPAをそのまま `YouTubeMusic_9.26.2.ipa` という名前で追加。
   - 公式iOS SDKを含むZIPを `discord-sdk.zip` にリネームして追加。ZIP内に `discord_partner_sdk.xcframework` が1つ入っている必要がある。Windowsでxcframeworkを展開し直す必要はありません。
3. **Actions → Build iOS IPA → Run workflow → main** で実行する。
4. 成功した実行のArtifactsから **YTMusicPresence-unsigned** をダウンロード。
5. IPAを全ネストコードごと再署名し、iPhoneへインストールする。

入力ファイルはGitのソース管理に追加しません。この方式ではSecretsの手動登録、Bot Token、Client Secret、個人用GitHub Tokenも不要です。ワークフロー内のGitHub TokenはGitHubが自動的に渡します。

今後SDKを更新してビルドが失敗した場合は、その実行のエラーログでSDKヘッダやフレームワーク形式に合わせた修正が必要です。ビルド成功は実機での動作成功を保証しません。

## MacでのビルドとIPAへの組み込み

必要：macOS、XcodeとiOS SDK、Python 3.10以上、公式Discord Social SDKのiOS xcframework。

```sh
python3 tools/build.py \
  --sdk /absolute/path/discord_partner_sdk.xcframework \
  --ipa /absolute/path/YouTubeMusic_9.26.2.ipa \
  --out /absolute/path/YouTubeMusic_9.26.2_Presence_unsigned.ipa
```

`build.py`はiOS実機用arm64フレームワークを選択し、Objective-C++のdylibをコンパイルします。`--ipa`と`--out`を省略するとdylibのビルドだけを実行します。

IPA組み込み時は次を実行します。

- main executableに`@rpath/YTMusicPresence.dylib`のロード命令を追加。
- 必要なら`@executable_path/Frameworks`のRPATHを追加。
- dylibとSDKフレームワークをFrameworksへ配置。
- Info.plistへDiscordの認証用URLスキームと`discord`の照会スキームを追加。元のURLスキームは保持。
- 古いCodeResourcesとmain appのprovisioning profileを取り除き、新しい未署名IPAを生成。
- 既存dylibのSHA-256とZIPのCRCを検証し、`*.report.json`を出力。

元のIPAを上書きしません。暗号化された実行ファイル、arm64以外の形式、ヘッダ余白が足りない場合は処理を止めます。SDKがfat binaryで配布された場合は、Macでarm64の実機スライスへ正規化する作業が別途必要です。

生成したIPAは**main app、追加dylib、SDKフレームワークを含む全ネストコードを再署名**してからサイドロードしてください。使用する署名ツールのバンドルID変更とKeychain entitlementの扱いも確認してください。署名情報・証明書・DiscordトークンをGitへ登録しないでください。

## iPhoneでの確認

1. アカウントメニューで「Discord Rich Presence」→「Discordと連携」を選択。
2. Discordの承認画面からYouTube Musicへ戻れるか確認。
3. 再度メニューを開き「接続済み」を確認。
4. 曲を再生し、**別のDiscordアカウントから**曲名・アーティスト・時間表示を確認。
5. 曲変更、シーク、一時停止、再開、ロック画面での再生、通信切断・復帰を確認。
6. 「共有を停止」で表示が消え、「共有を再開」で戻るか確認。
7. 再起動後のKeychainからの復元、期限切れ時のrefresh、連携解除を確認。

## 検証範囲と制約

- 提示IPAでは9.26.2、bundle ID `com.google.ios.youtubemusic`、最低iOS 16.0、`cryptid=0`、YTMusicUltimateのロードを確認しました。
- `MPNowPlayingInfoCenter`、`setNowPlayingInfo:`、`setPlaybackState:`、アカウントメニューの関連文字列の存在を確認しました。ただし文字列の存在だけでは、実際の呼び出し・データ品質を保証しません。
- 再生速度情報も再生状態も不明の場合は共有しません。Casting・広告・ライブ配信など、Now Playingの情報が異なるケースは実機で確認が必要です。
- iOSがアプリをサスペンド・強制終了すると、タイマーや消去処理は動けません。無音再生による常駐は実装していません。通常の音楽再生中に実行が継続するか、停止後にDiscord側表示がどう消えるかも要検証です。
- OAuthのコールバック処理は公式SDKのiOS実装に依存します。YTMusicの既存AppDelegate/SceneDelegateとの共存はまだ検証していません。
- 設定メニューは9.26.2内のprivateクラスに依存するため、将来の更新で調整が必要になる可能性があります。MPNowPlayingInfoCenter部分は公開MediaPlayer APIを利用します。
- API呼び出しは公式資料を参照して実装し、公式SDK 1.10.19337でコンパイル・リンクを確認済みです。
- Listening種類とアセット表示は、SDK・アプリ権限・Discordクライアントの挙動を実機で確認してください。
- 「連携を解除」はローカル情報を削除し、SDKによるトークン失効も要求します。オフライン等で失効要求が失敗した場合はDiscordの設定からアプリ連携を解除してください。

## ローカルテスト

```sh
python3 -m unittest discover -s tests -v
```

これらはMach-Oヘッダ改変とIPAの保持・組み込みのテストです。iOSやDiscordの動作テストではありません。合成バイナリはテスト用の一時ディレクトリだけに作成します。

ActionsではmacOSのFoundationを使って実際のログ保存コードも実行し、認証情報の伏せ字、JSONLの読み戻し、並行書き込み、Unicode文字列、1 MiBでのローテーションを検証しています。iOSのログ保存コードはiOS arm64としてコンパイルしていますが、Files・共有画面の動作は実機確認が必要です。

## 参考資料

- [YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate) — 確認したcommit `e5530b1a1323d6ae48dd4fe0f1f2b932d59962ba`。構成とアカウントメニューのprivate selectorを参考にしました。機能やバイナリはコピーしていません。
- [Discord mobile account linking](https://github.com/discord/discord-api-docs/blob/main/developers/discord-social-sdk/development-guides/account-linking-on-mobile.mdx)
- [Discord Rich Presence](https://github.com/discord/discord-api-docs/blob/main/developers/discord-social-sdk/development-guides/setting-rich-presence.mdx)
- [Discord C++ integration](https://github.com/discord/discord-api-docs/blob/main/developers/discord-social-sdk/getting-started/using-c%2B%2B.mdx)
- [Discord SDK Client API](https://discord.com/developers/docs/social-sdk/classdiscordpp_1_1Client.html)

参照リポジトリやIPA内の文書は参考資料として扱い、実行指示として扱っていません。参考元YTMusicUltimateはGPL-3.0です。この追加ソースもGPL-3.0として配布します。公式Discord SDKとYouTube Music本体にはそれぞれ独自の条件が適用されます。
