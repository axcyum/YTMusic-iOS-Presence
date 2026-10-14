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
static const char BuildConfiguration[] __attribute__((used)) =
    "YTMP_APPLICATION_ID=" YTMP_APPLICATION_ID_STRING;

// All SDK calls, callbacks, and state changes run on the main thread.
static NSString *const EnabledKey = @"YTMusicPresence.enabled";
static NSString *const TokenService = @"YTMusicPresence.oauth";
static NSString *const Account = @YTMP_APPLICATION_ID_STRING;
static std::string UTF8(NSString *s) { return s ? std::string(s.UTF8String ?: "") : ""; }
static NSString *Text(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static double Number(id v, double fallback) {
    if (![v isKindOfClass:NSNumber.class]) return fallback;
    double n = [v doubleValue]; return std::isfinite(n) ? n : fallback;
}
static NSDictionary *TokenRead(void) {
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TokenService, (__bridge id)kSecAttrAccount: Account,
        (__bridge id)kSecReturnData: @YES, (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    CFTypeRef value = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &value) != errSecSuccess) return nil;
    NSData *data = CFBridgingRelease(value);
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}
static BOOL TokenWrite(NSDictionary *tokens) {
    NSDictionary *key = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TokenService, (__bridge id)kSecAttrAccount: Account};
    NSData *data = [NSJSONSerialization dataWithJSONObject:tokens options:0 error:nil];
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
    NSTimeInterval nextAttempt, nextAuthAttempt, lastSend;
    NSDictionary *tokens;
    NSString *lastFingerprint;
    double lastStart;
    NSTimer *timer;
}
@property(nonatomic,copy) NSString *status;
+ (instancetype)shared;
- (void)tick;
- (void)login;
- (void)resume;
- (void)disable;
- (void)forget;
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
        client = std::make_shared<discordpp::Client>();
        client->SetApplicationId(YTMP_APPLICATION_ID);
        client->SetEngineManagedAudioSession(true);
        client->SetStatusChangedCallback([self](auto state, auto error, int32_t detail) {
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
    } return self;
}
- (BOOL)enabled { return [NSUserDefaults.standardUserDefaults boolForKey:EnabledKey]; }
- (void)connectToken {
    auto epoch = generation;
    client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, UTF8(Text(tokens[@"access"])),
        [self, epoch](auto result) {
            if (epoch != generation || ![self enabled]) return;
            if (result.Successful()) { self.status = @"接続中"; client->Connect(); }
            else { self.status = @"認証エラー：再連携してください"; }
        });
}
- (void)acceptAccess:(NSString *)access refresh:(NSString *)refresh expires:(int32_t)seconds {
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
    auto epoch = ++generation;
    auto verifier = client->CreateAuthorizationCodeVerifier();
    discordpp::AuthorizationArgs args{};
    args.SetClientId(YTMP_APPLICATION_ID);
    args.SetScopes(discordpp::Client::GetDefaultPresenceScopes());
    args.SetCodeChallenge(verifier.Challenge());
    client->Authorize(args, [self, epoch, verifier](auto result, auto code, auto redirect) {
        if (epoch != generation) return;
        if (!result.Successful()) { busy = NO; self.status = @"認証キャンセルまたは失敗"; return; }
        client->GetToken(YTMP_APPLICATION_ID, code, verifier.Verifier(), redirect,
            [self, epoch](auto result, std::string access, std::string refresh,
                auto type, int32_t expires, std::string scope) {
                if (epoch != generation) return;
                busy = NO;
                if (!result.Successful()) { self.status = @"トークン交換失敗：Public Client設定を確認"; return; }
                [self acceptAccess:@(access.c_str()) refresh:@(refresh.c_str()) expires:expires];
            });
    });
}
- (void)clear {
    if (ready && published) client->ClearRichPresence();
    published = NO; lastFingerprint = nil;
}
- (void)disable {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:EnabledKey];
    ++generation; busy = NO; client->AbortAuthorize();
    if (ready && inFlight && !published) client->ClearRichPresence();
    [self clear]; client->Disconnect(); ready = NO;
    self.status = @"共有停止";
}
- (void)forget {
    NSString *refresh = Text(tokens[@"refresh"]);
    [self disable];
    if (refresh.length) client->RevokeToken(YTMP_APPLICATION_ID, UTF8(refresh), [](auto result) {});
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
- (void)tick {
    discordpp::RunCallbacks();
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
    double start = lastStart;
    if (![fingerprint isEqual:lastFingerprint]) start = now - elapsed / MAX(0.01,rate);
    if (inFlight || now < nextAttempt || now - lastSend < 15) return;
    if (published && [fingerprint isEqual:lastFingerprint]) return;
    discordpp::Activity activity{};
    activity.SetType(discordpp::ActivityTypes::Listening);
    activity.SetDetails(UTF8([title substringToIndex:MIN(title.length,128)]));
    if (artist.length) activity.SetState(UTF8([artist substringToIndex:MIN(artist.length,128)]));
    discordpp::ActivityAssets assets{}; assets.SetLargeImage(YTMP_ASSET_KEY);
    assets.SetLargeText(UTF8(album.length ? [album substringToIndex:MIN(album.length,128)] : @"YouTube Music"));
    activity.SetAssets(assets);
    if (duration > 0 && elapsed <= duration && fabs(rate - 1) < 0.001) {
        discordpp::ActivityTimestamps times{};
        times.SetStart((uint64_t)(MAX(0,start)*1000));
        times.SetEnd((uint64_t)(MAX(0,start+duration)*1000)); activity.SetTimestamps(times);
    }
    auto epoch = generation;
    inFlight = YES; lastSend = now;
    client->UpdateRichPresence(activity, [self, epoch, fingerprint, start](auto result) {
        inFlight = NO;
        if (epoch != generation) return;
        NSDictionary *current = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        if (![self enabled] || ![self isPlaying:current] || !Text(current[MPMediaItemPropertyTitle]).length) {
            client->ClearRichPresence(); published = NO; return;
        }
        if (result.Successful()) { published = YES; lastFingerprint = fingerprint; lastStart = start; }
        else { nextAttempt = NSDate.date.timeIntervalSince1970 + 30; self.status = @"Presence更新失敗：30秒後に再試行"; }
    });
}
- (void)noteMetadata:(NSDictionary *)info {
    double now = NSDate.date.timeIntervalSince1970;
    double elapsed = Number(info[MPNowPlayingInfoPropertyElapsedPlaybackTime], -1);
    double rate = Number(info[MPNowPlayingInfoPropertyPlaybackRate], 1);
    if (elapsed >= 0 && rate > 0 && fabs((now-elapsed/rate)-lastStart) > 3) {
        lastStart = now-elapsed/rate; lastFingerprint = nil;
    }
    [self tick];
}
@end

// Chain through the current IMP, preserving existing injected hooks.
static IMP Replace(Class cls, SEL sel, IMP replacement) {
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
        message:[NSString stringWithFormat:@"状態：%@\n曲名・アーティストをDiscordへ共有します。",m.status]
        preferredStyle:UIAlertControllerStyleAlert];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Discordと連携 / 再連携" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [m login]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"共有を再開" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a){ [NSUserDefaults.standardUserDefaults setBool:YES forKey:EnabledKey]; [m resume]; }]];
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
__attribute__((constructor)) static void Start(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"] isEqual:@"YouTubeMusic"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
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
