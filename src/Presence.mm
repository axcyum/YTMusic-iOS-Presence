#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <cmath>
#include <memory>
#define DISCORDPP_IMPLEMENTATION
#include <discord_partner_sdk/discordpp.h>
#include "Config.h"
#import "Logger.h"
#import "Artwork.h"
static const char BuildConfiguration[] __attribute__((used)) =
    "YTMP_APPLICATION_ID=" YTMP_APPLICATION_ID_STRING;

// All SDK calls, callbacks, and state changes run on the main thread.
static NSString *const EnabledKey = @"YTMusicPresence.enabled";
static NSString *const CoverKey = @"YTMusicPresence.cover";
static NSString *const TokenService = @"YTMusicPresence.oauth";
static NSString *const Account = @YTMP_APPLICATION_ID_STRING;
static std::string UTF8(NSString *s) { return s ? std::string(s.UTF8String ?: "") : ""; }
static NSString *Text(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static double Number(id v, double fallback) {
    if (![v isKindOfClass:NSNumber.class]) return fallback;
    double n = [v doubleValue]; return std::isfinite(n) ? n : fallback;
}
static NSString *PresenceText(NSString *s) {
    s = [[s componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
    s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!s.length) return @"";
    NSMutableString *out = [NSMutableString new];
    [s enumerateSubstringsInRange:NSMakeRange(0,s.length) options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(NSString *part,NSRange range,NSRange enclosing,BOOL *stop){
            if ([out lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+[part lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>128) *stop=YES;
            else [out appendString:part];
        }];
    if (out.length == 1) [out appendString:@" "];
    return out;
}
static void LogResult(NSString *event, const discordpp::ClientResult &r) {
    NSString *body = @(r.ResponseBody().c_str());
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    id response = data.length ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL] : @"";
    YTMPLog(event,@{@"success":@(r.Successful()),@"error_type":@((int)r.Type()),
        @"http_status":@((int)r.Status()),@"error_code":@(r.ErrorCode()),
        @"error":@(r.Error().c_str()),@"response":response ?: body,
        @"retryable":@(r.Retryable()),@"retry_after":@(r.RetryAfter())});
}
static NSDictionary *TokenRead(void) {
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TokenService, (__bridge id)kSecAttrAccount: Account,
        (__bridge id)kSecReturnData: @YES, (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    CFTypeRef value = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &value) != errSecSuccess) return nil;
    NSData *data = CFBridgingRelease(value);
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}
static BOOL TokenWrite(NSDictionary *tokens) {
    NSDictionary *key = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TokenService, (__bridge id)kSecAttrAccount: Account};
    NSData *data = [NSJSONSerialization dataWithJSONObject:tokens options:0 error:NULL];
    if (!data) return NO;
    NSDictionary *attrs = @{(__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus result = SecItemUpdate((__bridge CFDictionaryRef)key, (__bridge CFDictionaryRef)attrs);
    if (result == errSecItemNotFound) {
        NSMutableDictionary *item = [key mutableCopy]; [item addEntriesFromDictionary:attrs];
        result = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return result == errSecSuccess;
}
static void TokenDelete(void) {
    NSDictionary *key = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TokenService, (__bridge id)kSecAttrAccount: Account};
    SecItemDelete((__bridge CFDictionaryRef)key);
}

@interface YTMPManager : NSObject {
    std::shared_ptr<discordpp::Client> client;
    BOOL ready, busy, published, inFlight;
    NSUInteger generation;
    NSUInteger metadataRevision;
    int payloadMode;
    BOOL blockedPayload, ticking;
    BOOL omitArtwork;
    NSTimeInterval nextAttempt, nextAuthAttempt, lastSend;
    NSDictionary *tokens;
    NSString *lastFingerprint;
    double lastStart;
    double sampleStart;
    NSString *sampleFingerprint;
    NSString *cachedCover, *coverTitle;
    NSTimeInterval lastCoverCheck;
    NSTimer *timer;
}
@property(nonatomic,copy) NSString *status;
+ (instancetype)shared;
- (void)tick;
- (void)login;
- (void)resume;
- (void)disable;
- (void)forget;
- (void)retryPresence;
- (BOOL)coverEnabled;
- (void)toggleCover;
- (void)refresh;
- (void)connectToken;
- (BOOL)enabled;
- (BOOL)isPlaying:(NSDictionary *)info;
- (void)clear;
- (void)background;
- (void)noteMetadata:(NSDictionary *)info;
- (void)acceptAccess:(NSString *)access refresh:(NSString *)refresh expires:(int32_t)seconds;
@end

@implementation YTMPManager
+ (instancetype)shared {
    static YTMPManager *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [YTMPManager new]; }); return m;
}
- (instancetype)init {
    if ((self = [super init])) {
        self.status = @"未連携"; tokens = TokenRead();
        YTMPRememberSecret(Text(tokens[@"access"])); YTMPRememberSecret(Text(tokens[@"refresh"]));
        YTMPLog(@"startup",@{@"build":@"cover-v4",@"app_id":Account,
            @"bundle_id":NSBundle.mainBundle.bundleIdentifier ?: @"",@"saved_token":@(tokens != nil)});
        client = std::make_shared<discordpp::Client>();
        client->SetApplicationId(YTMP_APPLICATION_ID);
        client->SetEngineManagedAudioSession(true);
        client->AddLogCallback([](auto message,auto severity){
            YTMPLog(@"sdk_warning",@{@"severity":@((int)severity),@"message":@(message.c_str())});
        },discordpp::LoggingSeverity::Warning);
        client->SetStatusChangedCallback([self](auto state, auto error, int32_t detail) {
            YTMPLog(@"connection",@{@"state":@(discordpp::Client::StatusToString(state).c_str()),
                @"error":@(discordpp::Client::ErrorToString(error).c_str()),@"detail":@(detail)});
            ready = state == discordpp::Client::Status::Ready;
            self.status = ready ? @"接続済み" : @"接続待ち";
            if (!ready) { published = NO; lastFingerprint = nil; }
            if (error != discordpp::Client::Error::None) {
                self.status = @"接続エラー：設定と通信を確認";
                nextAuthAttempt = NSDate.date.timeIntervalSince1970 + 30;
            }
        });
        client->SetTokenExpirationCallback([self]() { [self refresh]; });
        timer = [NSTimer timerWithTimeInterval:0.1 target:self selector:@selector(tick)
            userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resume)
            name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [self resume];
        YTMPLog(@"log_ready",@{@"path":@"Documents/YTMusicPresence/presence.jsonl"});
    } return self;
}
- (BOOL)enabled { return [NSUserDefaults.standardUserDefaults boolForKey:EnabledKey]; }
- (void)connectToken {
    auto epoch = generation;
    client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, UTF8(Text(tokens[@"access"])),
        [self, epoch](auto result) {
            LogResult(@"update_token",result);
            if (epoch != generation || ![self enabled]) return;
            if (result.Successful()) { self.status = @"接続中"; client->Connect(); }
            else { self.status = @"認証エラー：再連携してください"; }
        });
}
- (void)acceptAccess:(NSString *)access refresh:(NSString *)refresh expires:(int32_t)seconds {
    YTMPRememberSecret(access); YTMPRememberSecret(refresh);
    tokens = @{ @"access":access, @"refresh":refresh,
        @"expiry":@(NSDate.date.timeIntervalSince1970 + MAX(0, seconds)) };
    self.status = TokenWrite(tokens) ? @"認証済み" : @"認証済み（保存失敗、次回は再連携）";
    [self connectToken];
}
- (void)refresh {
    if (busy || ![self enabled] || !Text(tokens[@"refresh"]).length) return;
    busy = YES; auto epoch = generation;
    client->RefreshToken(YTMP_APPLICATION_ID, UTF8(Text(tokens[@"refresh"])),
        [self, epoch](auto result, std::string access, std::string refresh,
            auto type, int32_t expires, std::string scope) {
            YTMPRememberSecret(@(access.c_str())); YTMPRememberSecret(@(refresh.c_str()));
            LogResult(@"refresh_token",result);
            if (epoch != generation) return;
            busy = NO;
            if (!result.Successful()) {
                self.status = @"認証更新失敗：再連携または通信を確認";
                nextAuthAttempt = NSDate.date.timeIntervalSince1970 + 60; return;
            }
            [self acceptAccess:@(access.c_str()) refresh:@(refresh.c_str()) expires:expires];
        });
}
- (void)resume {
    if (![self enabled] || busy) return;
    if (NSDate.date.timeIntervalSince1970 < nextAuthAttempt) return;
    if (!Text(tokens[@"access"]).length) { self.status = @"Discordと連携してください"; return; }
    if (Number(tokens[@"expiry"], 0) < NSDate.date.timeIntervalSince1970 + 120) [self refresh];
    else if (!ready) { nextAuthAttempt = NSDate.date.timeIntervalSince1970 + 30; [self connectToken]; }
}
- (void)login {
    if (busy) return;
    // Explicit user action only; never trigger OAuth when the app launches.
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:EnabledKey];
    busy = YES; self.status = @"Discordの認証を待っています";
    blockedPayload = NO; payloadMode = 0; omitArtwork = NO; nextAttempt = 0;
    auto epoch = ++generation;
    inFlight = NO;
    auto verifier = client->CreateAuthorizationCodeVerifier();
    YTMPRememberSecret(@(verifier.Verifier().c_str()));
    YTMPLog(@"authorize_start",@{@"scopes":@(discordpp::Client::GetDefaultPresenceScopes().c_str())});
    discordpp::AuthorizationArgs args{};
    args.SetClientId(YTMP_APPLICATION_ID);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(verifier.Challenge());
    client->Authorize(args, [self, epoch, verifier](auto result, auto code, auto redirect) {
        YTMPRememberSecret(@(code.c_str())); LogResult(@"authorize",result);
        if (epoch != generation) return;
        if (!result.Successful()) { busy = NO; self.status = @"認証キャンセルまたは失敗"; return; }
        client->GetToken(YTMP_APPLICATION_ID, code, verifier.Verifier(), redirect,
            [self, epoch](auto result, std::string access, std::string refresh,
                auto type, int32_t expires, std::string scope) {
                YTMPRememberSecret(@(access.c_str())); YTMPRememberSecret(@(refresh.c_str()));
                LogResult(@"get_token",result);
                if (epoch != generation) return;
                busy = NO;
                if (!result.Successful()) { self.status = @"トークン交換失敗：Public Client設定を確認"; return; }
                [self acceptAccess:@(access.c_str()) refresh:@(refresh.c_str()) expires:expires];
            });
    });
}
- (void)clear {
    if (ready && published) { client->ClearRichPresence(); YTMPLog(@"presence_clear",@{}); }
    published = NO; lastFingerprint = nil;
}
- (void)disable {
    YTMPLog(@"sharing_disabled",@{});
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:EnabledKey];
    ++generation; busy = NO; client->AbortAuthorize();
    if (ready && inFlight && !published) client->ClearRichPresence();
    [self clear]; client->Disconnect(); ready = NO;
    inFlight = NO;
    self.status = @"共有停止";
}
- (void)forget {
    NSString *refresh = Text(tokens[@"refresh"]);
    [self disable];
    if (refresh.length) client->RevokeToken(YTMP_APPLICATION_ID, UTF8(refresh), [](auto result) { LogResult(@"revoke_token",result); });
    TokenDelete(); tokens = nil; self.status = @"連携解除（保存情報を削除）";
}
- (BOOL)isPlaying:(NSDictionary *)info {
    MPNowPlayingPlaybackState state = MPNowPlayingInfoCenter.defaultCenter.playbackState;
    if (state == MPNowPlayingPlaybackStatePaused || state == MPNowPlayingPlaybackStateStopped ||
        state == MPNowPlayingPlaybackStateInterrupted) return NO;
    double rate = Number(info[MPNowPlayingInfoPropertyPlaybackRate], -1);
    return rate >= 0 ? rate > 0 : state == MPNowPlayingPlaybackStatePlaying;
}
- (void)background {
    if (![self isPlaying:MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo]) [self clear];
}
- (void)retryPresence {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:EnabledKey];
    blockedPayload = NO; payloadMode = 0; omitArtwork = NO; nextAttempt = 0; nextAuthAttempt = 0;
    lastFingerprint = nil; self.status = @"再試行中";
    YTMPLog(@"manual_retry",@{}); [self resume]; [self tick];
}
- (BOOL)coverEnabled {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:CoverKey];
    return value ? [value boolValue] : YTMP_USE_COVER;
}
- (void)toggleCover {
    [NSUserDefaults.standardUserDefaults setBool:![self coverEnabled] forKey:CoverKey];
    omitArtwork = NO; cachedCover = nil; coverTitle = nil; lastCoverCheck = 0;
    lastFingerprint = nil;
    YTMPLog(@"cover_setting",@{@"enabled":@([self coverEnabled])}); [self tick];
}
- (void)tick {
    if (ticking) return;
    ticking = YES;
    discordpp::RunCallbacks();
    ticking = NO;
    if (![self enabled]) return;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!busy && Text(tokens[@"access"]).length && Number(tokens[@"expiry"], 0) < now + 120 && now >= nextAuthAttempt) {
        nextAuthAttempt = now + 60; [self refresh];
    }
    if (!ready) { if (!busy && now >= nextAuthAttempt) [self resume]; return; }
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    NSString *title = Text(info[MPMediaItemPropertyTitle]);
    if (!title.length || ![self isPlaying:info]) { [self clear]; return; }
    NSString *artist = Text(info[MPMediaItemPropertyArtist]);
    NSString *album = Text(info[MPMediaItemPropertyAlbumTitle]);
    double duration = MAX(0, Number(info[MPMediaItemPropertyPlaybackDuration], 0));
    double elapsed = MAX(0, Number(info[MPNowPlayingInfoPropertyElapsedPlaybackTime], 0));
    double rate = Number(info[MPNowPlayingInfoPropertyPlaybackRate], 1);
    NSString *fingerprint = [NSString stringWithFormat:@"%@\n%@\n%@\n%.1f\n%.2f",title,artist,album,duration,rate];
    // elapsed returned by MPNowPlayingInfoCenter may be a fixed snapshot. Correct
    // seek timing in noteMetadata below rather than recomputing every timer tick.
    if (![fingerprint isEqual:sampleFingerprint]) {
        sampleStart = now-elapsed/MAX(0.01,rate); sampleFingerprint = fingerprint;
    }
    double start = sampleStart;
    if (inFlight || blockedPayload || now < nextAttempt || now - lastSend < 15) return;
    if ([self coverEnabled] && !omitArtwork && (now-lastCoverCheck >= 1 || ![title isEqual:coverTitle])) {
        NSString *url = YTMPCoverURL(title,artist,info[MPNowPlayingInfoPropertyExternalContentIdentifier]);
        if (![url ?: @"" isEqual:cachedCover ?: @""] || ![title isEqual:coverTitle]) {
            YTMPLog(@"artwork_lookup",@{@"title":title,@"url":url ?: @"",@"found":@(url.length>0)});
        }
        cachedCover = url; coverTitle = title; lastCoverCheck = now;
    }
    NSString *image = ([self coverEnabled] && !omitArtwork) ? cachedCover : nil;
    if (!image.length && !omitArtwork && YTMP_USE_ASSETS) image = @YTMP_ASSET_KEY;
    // Keep the timeline identity independent from image changes.
    fingerprint = [fingerprint stringByAppendingFormat:@"\n%@",image ?: @""];
    if (published && [fingerprint isEqual:lastFingerprint]) return;
    discordpp::Activity activity{};
    activity.SetType(payloadMode < 2 ? discordpp::ActivityTypes::Listening : discordpp::ActivityTypes::Playing);
    activity.SetDetails(UTF8(PresenceText(title)));
    if (PresenceText(artist).length) activity.SetState(UTF8(PresenceText(artist)));
    if (image.length) {
        discordpp::ActivityAssets assets{}; assets.SetLargeImage(UTF8(image));
        assets.SetLargeText(UTF8(PresenceText(album.length ? album : @"YouTube Music"))); activity.SetAssets(assets);
    }
    BOOL withTimes = payloadMode == 0 && duration > 0 && elapsed <= duration && fabs(rate-1)<0.001;
    if (withTimes) {
        discordpp::ActivityTimestamps times{};
        times.SetStart((uint64_t)(MAX(0,start)*1000));
        times.SetEnd((uint64_t)(MAX(0,start+duration)*1000)); activity.SetTimestamps(times);
    }
    auto epoch = generation;
    auto revision = metadataRevision;
    YTMPLog(@"presence_send",@{@"mode":@(payloadMode),@"details":PresenceText(title),
        @"state":PresenceText(artist),@"duration":@(duration),@"elapsed":@(elapsed),
        @"rate":@(rate),@"timestamps":@(withTimes),@"assets":@(image.length>0),@"image":image ?: @""});
    inFlight = YES; lastSend = now;
    client->UpdateRichPresence(activity, [self, epoch, revision, fingerprint, start, image](auto result) {
        LogResult(@"presence_result",result);
        if (epoch != generation) return;
        inFlight = NO;
        NSDictionary *current = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        if (![self enabled] || ![self isPlaying:current] || !Text(current[MPMediaItemPropertyTitle]).length) {
            client->ClearRichPresence(); published = NO; return;
        }
        if (result.Successful()) {
            published = YES; self.status = payloadMode == 2 ? @"共有中（互換表示）" : @"共有中";
            if (revision == metadataRevision) { lastFingerprint = fingerprint; lastStart = start; }
        } else {
            int http = (int)result.Status();
            // Only degrade payload on validation errors, never on auth/network failures.
            NSString *body = @(result.ResponseBody().c_str());
            BOOL invalidPayload = http == 400 || result.ErrorCode() == 50035;
            BOOL mentionsTime = [body.lowercaseString containsString:@"timestamps"];
            if (invalidPayload && image.length && !mentionsTime && !omitArtwork) {
                omitArtwork = YES; lastFingerprint = nil;
                nextAttempt = NSDate.date.timeIntervalSince1970 + 15;
                self.status = @"画像なしで再試行";
                YTMPLog(@"artwork_fallback",@{@"image":image,@"reason":@"payload_validation"});
            } else if (invalidPayload && payloadMode < 2) {
                ++payloadMode; nextAttempt = NSDate.date.timeIntervalSince1970 + 15;
                self.status = @"送信内容を簡略化して再試行";
                YTMPLog(@"payload_fallback",@{@"mode":@(payloadMode)});
            } else if (http == 401 || http == 403 || http == 400) {
                blockedPayload = YES;
                self.status = [NSString stringWithFormat:@"更新失敗 HTTP %d / code %d：ログを確認",http,result.ErrorCode()];
            } else {
                double delay = http == 429 ? MAX(30,Number(@(result.RetryAfter()),30)) : 30;
                nextAttempt = NSDate.date.timeIntervalSince1970 + delay;
                self.status = [NSString stringWithFormat:@"更新失敗 HTTP %d / code %d：再試行待ち",http,result.ErrorCode()];
            }
        }
    });
}
- (void)noteMetadata:(NSDictionary *)info {
    ++metadataRevision;
    double now = NSDate.date.timeIntervalSince1970;
    double elapsed = Number(info[MPNowPlayingInfoPropertyElapsedPlaybackTime], -1);
    double rate = Number(info[MPNowPlayingInfoPropertyPlaybackRate], 1);
    double duration = MAX(0,Number(info[MPMediaItemPropertyPlaybackDuration],0));
    NSString *fingerprint = [NSString stringWithFormat:@"%@\n%@\n%@\n%.1f\n%.2f",
        Text(info[MPMediaItemPropertyTitle]),Text(info[MPMediaItemPropertyArtist]),
        Text(info[MPMediaItemPropertyAlbumTitle]),duration,rate];
    if (elapsed >= 0 && rate > 0 && (![fingerprint isEqual:sampleFingerprint] || fabs((now-elapsed/rate)-sampleStart)>3)) {
        sampleStart = now-elapsed/rate; sampleFingerprint = fingerprint; lastFingerprint = nil;
        YTMPLog(@"timeline_update",@{@"elapsed":@(elapsed),@"duration":@(duration),@"rate":@(rate)});
    }
    [self tick];
}
@end

// Chain through the current IMP, preserving existing injected hooks.
static IMP Replace(Class cls, SEL sel, IMP replacement) {
    if (cls) [cls instancesRespondToSelector:sel]; // Resolve lazy protobuf accessors.
    Method m = class_getInstanceMethod(cls,sel); if (!m) return NULL;
    IMP old = method_getImplementation(m);
    if (!class_addMethod(cls,sel,replacement,method_getTypeEncoding(m)))
        class_replaceMethod(cls,sel,replacement,method_getTypeEncoding(m));
    return old;
}
static void (*OriginalInfo)(id,SEL,NSDictionary *);
static void InfoHook(id self,SEL sel,NSDictionary *info) {
    OriginalInfo(self,sel,info);
    NSDictionary *copy = [info copy];
    dispatch_async(dispatch_get_main_queue(), ^{ [[YTMPManager shared] noteMetadata:copy]; });
}
static void (*OriginalState)(id,SEL,MPNowPlayingPlaybackState);
static void StateHook(id self,SEL sel,MPNowPlayingPlaybackState state) {
    OriginalState(self,sel,state);
    dispatch_async(dispatch_get_main_queue(), ^{ [[YTMPManager shared] tick]; });
}
static UIViewController *TopController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            UIViewController *vc = window.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            return vc;
        }
    } return nil;
}
static void PresentSettings(void) {
    YTMPManager *m = [YTMPManager shared];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Discord Rich Presence"
        message:[NSString stringWithFormat:@"状態：%@\nログ：Documents/YTMusicPresence/presence.jsonl",m.status]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController *weakSheet = sheet;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Discordと連携 / 再連携" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [m login]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"共有を再開" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [m retryPresence]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:[m coverEnabled] ? @"サムネイルを非表示" : @"サムネイルを表示"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [m toggleCover]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"診断ログを共有" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){
            YTMPLog(@"log_export",@{}); YTMPFlushLogs();
            NSMutableArray *files = [NSMutableArray arrayWithObject:YTMPLogFileURL()];
            NSURL *previous = [[YTMPLogFileURL() URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"presence.previous.jsonl"];
            if ([NSFileManager.defaultManager fileExistsAtPath:previous.path]) [files addObject:previous];
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
            UIViewController *vc = weakSheet.presentingViewController;
            if (!vc) return;
            share.popoverPresentationController.sourceView = vc.view;
            share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds),CGRectGetMidY(vc.view.bounds),1,1);
            [vc dismissViewControllerAnimated:YES completion:^{
                [vc presentViewController:share animated:YES completion:nil];
            }];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"共有を停止" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [m disable]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"連携を解除" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *a){ [m forget]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [TopController() presentViewController:sheet animated:YES completion:nil];
}
static void (*OriginalMenu)(id,SEL,id,id);
static void MenuHook(id self,SEL sel,id upper,id lower) {
    Class cls = NSClassFromString(@"YTMAccountButton");
    SEL init = NSSelectorFromString(@"initWithTitle:identifier:icon:actionBlock:");
    if (!cls || ![cls instancesRespondToSelector:init] ||
        (lower && ![lower isKindOfClass:NSArray.class])) { OriginalMenu(self,sel,upper,lower); return; }
    id button = ((id(*)(id,SEL,id,id,id,id))objc_msgSend)([cls alloc],init,
        @"Discord Rich Presence",@"ytmpresence",[UIImage systemImageNamed:@"music.note"],
        ^(BOOL done){ dispatch_async(dispatch_get_main_queue(), ^{ PresentSettings(); }); });
    NSMutableArray *buttons = lower ? [lower mutableCopy] : [NSMutableArray new];
    if (button) [buttons addObject:button]; OriginalMenu(self,sel,upper,buttons);
}
static void (*OriginalPlayerLoad)(id,SEL);
static void PlayerLoadHook(id self,SEL sel) {
    OriginalPlayerLoad(self,sel); YTMPObservePlayer(self);
}
static void (*OriginalPlayerTime)(id,SEL,id,id);
static void PlayerTimeHook(id self,SEL sel,id video,id time) {
    OriginalPlayerTime(self,sel,video,time); YTMPObservePlayer(self);
}
static void (*OriginalMutatedTime)(id,SEL,id,id);
static void MutatedTimeHook(id self,SEL sel,id video,id time) {
    OriginalMutatedTime(self,sel,video,time); YTMPObservePlayer(self);
}
static void (*OriginalDetailsThumbnail)(id,SEL,id);
static void DetailsThumbnailHook(id self,SEL sel,id value) {
    OriginalDetailsThumbnail(self,sel,value);
    dispatch_async(dispatch_get_main_queue(),^{YTMPObserveVideoDetails(self);});
}
static void (*OriginalDetailsTitle)(id,SEL,id);
static void DetailsTitleHook(id self,SEL sel,id value) {
    OriginalDetailsTitle(self,sel,value);
    dispatch_async(dispatch_get_main_queue(),^{YTMPObserveVideoDetails(self);});
}
static void (*OriginalResponseDetails)(id,SEL,id);
static void ResponseDetailsHook(id self,SEL sel,id value) {
    OriginalResponseDetails(self,sel,value);
    dispatch_async(dispatch_get_main_queue(),^{YTMPObserveVideoDetails(value);});
}
__attribute__((constructor)) static void Start(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"] isEqual:@"YouTubeMusic"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            Class playerClass = NSClassFromString(@"YTPlayerViewController");
            OriginalPlayerLoad = (decltype(OriginalPlayerLoad))Replace(playerClass,@selector(viewDidLoad),(IMP)PlayerLoadHook);
            OriginalPlayerTime = (decltype(OriginalPlayerTime))Replace(playerClass,NSSelectorFromString(@"singleVideo:currentVideoTimeDidChange:"),(IMP)PlayerTimeHook);
            OriginalMutatedTime = (decltype(OriginalMutatedTime))Replace(playerClass,NSSelectorFromString(@"potentiallyMutatedSingleVideo:currentVideoTimeDidChange:"),(IMP)MutatedTimeHook);
            YTMPLog(@"artwork_hooks",@{@"viewDidLoad":@(OriginalPlayerLoad != NULL),
                @"timeChanged":@(OriginalPlayerTime != NULL),@"mutatedTimeChanged":@(OriginalMutatedTime != NULL)});
            Class detailsClass=NSClassFromString(@"YTIVideoDetails");
            OriginalDetailsThumbnail=(decltype(OriginalDetailsThumbnail))Replace(detailsClass,NSSelectorFromString(@"setThumbnail:"),(IMP)DetailsThumbnailHook);
            OriginalDetailsTitle=(decltype(OriginalDetailsTitle))Replace(detailsClass,NSSelectorFromString(@"setTitle:"),(IMP)DetailsTitleHook);
            OriginalResponseDetails=(decltype(OriginalResponseDetails))Replace(NSClassFromString(@"YTIPlayerResponse"),NSSelectorFromString(@"setVideoDetails:"),(IMP)ResponseDetailsHook);
            YTMPLog(@"artwork_model_hooks",@{@"thumbnail":@(OriginalDetailsThumbnail != NULL),
                @"title":@(OriginalDetailsTitle != NULL),@"videoDetails":@(OriginalResponseDetails != NULL)});
            OriginalInfo = (decltype(OriginalInfo))Replace(MPNowPlayingInfoCenter.class,
                @selector(setNowPlayingInfo:),(IMP)InfoHook);
            OriginalState = (decltype(OriginalState))Replace(MPNowPlayingInfoCenter.class,
                @selector(setPlaybackState:),(IMP)StateHook);
            OriginalMenu = (decltype(OriginalMenu))Replace(NSClassFromString(@"YTMAvatarAccountView"),
                NSSelectorFromString(@"setAccountMenuUpperButtons:lowerButtons:"),(IMP)MenuHook);
            [YTMPManager shared];
        });
    }
}
