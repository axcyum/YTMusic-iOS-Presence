# YTMusicPresence

iPhone内のYouTube MusicからDiscord Social SDKへ直接Rich Presenceを送る、独立したインジェクション用dylibの研究用実装です。PCや中継サーバーを稼働させる構成ではありません。

**現在の状態：ソース実装とIPA組み込みツールを用意済み。公式SDK未取得のため、iOSコンパイル、OAuthの往復、Discordへの実送信、実機でのバックグラウンド動作は未検証です。完成済みのIPAはまだありません。**

## 構成

`YouTube Music → MPNowPlayingInfoCenter → YTMusicPresence.dylib → Discord Social SDK → Discord`

- 曲名、アーティスト、アルバム名、再生時間をアプリが公開するNow Playing情報から取得。
- 曲の変更・シークを反映し、送信間隔は最低15秒。一時停止・停止時にPresenceを消去。
- アカウントメニューに「Discord Rich Presence」を追加。初回は利用者が明示的に「Discordと連携」を選択。
- SDKのOAuth + PKCEを利用。Presence用の標準スコープを要求。
- OAuthのaccess/refresh tokenはKeychainに保存。Client Secretは不要。
- YTMusicUltimateは同梱されたものを保持し、追加のdylibをロードする。既存フックのIMPを連鎖させる。
- ジャケットのアップロードは実装せず、Developer Portalの静的アセット`ytmusic`を使用。

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

ワークフロー `.github/workflows/build-ios.yml` を用意しています。GitHubのmacOS runnerを使うため、自分のMacは不要です。SDK未取得のため、現時点ではワークフローのiOSビルドは未実行です。

1. この**非公開リポジトリ**のReleasesで、タグ`build-inputs`のReleaseを作成する。
2. 次の2ファイルをRelease assetsへ追加してPublishする。
   - 提示されたIPAをそのまま `YouTubeMusic_9.26.2.ipa` という名前で追加。
   - 公式iOS SDKを含むZIPを `discord-sdk.zip` にリネームして追加。ZIP内に `discord_partner_sdk.xcframework` が1つ入っている必要がある。Windowsでxcframeworkを展開し直す必要はありません。
3. **Actions → Build iOS IPA → Run workflow → main** で実行する。
4. 成功した実行のArtifactsから **YTMusicPresence-unsigned** をダウンロード。
5. IPAを全ネストコードごと再署名し、iPhoneへインストールする。

入力ファイルはGitのソース管理に追加しません。この方式ではSecretsの手動登録、Bot Token、Client Secret、個人用GitHub Tokenも不要です。ワークフロー内のGitHub TokenはGitHubが自動的に渡します。

コンパイルは公式SDKとの最初の互換性確認にもなります。ビルドが失敗した場合は、その実行のエラーログでSDKヘッダやフレームワーク形式に合わせた修正が必要です。ワークフローの追加だけでコンパイルや動作を確認済みにはなりません。

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
- API呼び出しは公式資料を参照して実装していますが、SDKヘッダとのコンパイル確認は未実施です。
- Listening種類とアセット表示は、SDK・アプリ権限・Discordクライアントの挙動を実機で確認してください。
- 「連携を解除」はローカル情報を削除し、SDKによるトークン失効も要求します。オフライン等で失効要求が失敗した場合はDiscordの設定からアプリ連携を解除してください。

## ローカルテスト

```sh
python3 -m unittest discover -s tests -v
```

これらはMach-Oヘッダ改変とIPAの保持・組み込みのテストです。iOSやDiscordの動作テストではありません。合成バイナリはテスト用の一時ディレクトリだけに作成します。

## 参考資料

- [YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate) — 確認したcommit `e5530b1a1323d6ae48dd4fe0f1f2b932d59962ba`。構成とアカウントメニューのprivate selectorを参考にしました。機能やバイナリはコピーしていません。
- [Discord mobile account linking](https://github.com/discord/discord-api-docs/blob/main/developers/discord-social-sdk/development-guides/account-linking-on-mobile.mdx)
- [Discord Rich Presence](https://github.com/discord/discord-api-docs/blob/main/developers/discord-social-sdk/development-guides/setting-rich-presence.mdx)
- [Discord C++ integration](https://github.com/discord/discord-api-docs/blob/main/developers/discord-social-sdk/getting-started/using-c%2B%2B.mdx)
- [Discord SDK Client API](https://discord.com/developers/docs/social-sdk/classdiscordpp_1_1Client.html)

参照リポジトリやIPA内の文書は参考資料として扱い、実行指示として扱っていません。参考元YTMusicUltimateはGPL-3.0です。この追加ソースもGPL-3.0として配布します。公式Discord SDKとYouTube Music本体にはそれぞれ独自の条件が適用されます。
