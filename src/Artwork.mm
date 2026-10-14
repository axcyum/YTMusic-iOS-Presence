#import "Artwork.h"
#import "Logger.h"
#import <objc/message.h>

// Do not retain the application's player or use unrestricted KVC. Only invoke
// verified object-returning, no-argument selectors from its playback model.
static __weak id CurrentPlayer;
static id ObjectValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    @try { return ((id(*)(id,SEL))objc_msgSend)(object,selector); }
    @catch (NSException *exception) { return nil; }
}
static NSString *StringValue(id object, NSString *name) {
    id value = ObjectValue(object,name);
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static NSString *Normalized(NSString *s) {
    return [[s precomposedStringWithCanonicalMapping] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
NSString *YTMPValidateCoverURL(id value) {
    if ([value isKindOfClass:NSURL.class]) value = [value absoluteString];
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length]>1024) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    NSString *host = parts.host.lowercaseString;
    if (![parts.scheme.lowercaseString isEqual:@"https"] || parts.user.length || parts.password.length ||
        (parts.port && parts.port.integerValue != 443)) return nil;
    BOOL allowed = NO;
    for (NSString *domain in @[@"ytimg.com",@"googleusercontent.com",@"ggpht.com"]) {
        if ([host isEqual:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) allowed = YES;
    }
    if (!allowed || !parts.path.length || parts.fragment.length) return nil;
    return parts.URL.absoluteString;
}
NSString *YTMPResolveCover(id player, NSString *nowPlayingTitle) {
    if (!nowPlayingTitle.length) return nil;
    id response = ObjectValue(player,@"playerResponse");
    id data = ObjectValue(response,@"playerData");
    id details = ObjectValue(data,@"videoDetails");
    NSString *title = StringValue(details,@"title");
    // Track changes can reach Now Playing and playerResponse in different orders.
    // Wait for agreement rather than attaching the preceding song's artwork.
    if (!title.length || ![Normalized(title) isEqual:Normalized(nowPlayingTitle)]) return nil;
    id thumbnails = ObjectValue(ObjectValue(details,@"thumbnail"),@"thumbnailsArray");
    if ([thumbnails isKindOfClass:NSArray.class]) {
        // YouTube's thumbnail array is ordered from smaller to larger images.
        for (id thumb in [thumbnails reverseObjectEnumerator]) {
            NSString *url = YTMPValidateCoverURL(ObjectValue(thumb,@"URL"));
            if (!url) url = YTMPValidateCoverURL(ObjectValue(thumb,@"url"));
            if (url) return url;
        }
    }
    // A public, standard thumbnail is available even if the native array is empty.
    NSString *videoID = StringValue(player,@"currentVideoID");
    if (!videoID.length) videoID = StringValue(player,@"contentVideoID");
    if (videoID.length != 11) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    if ([videoID rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg",videoID];
}
void YTMPObservePlayer(id player) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ YTMPObservePlayer(player); }); return;
    }
    if (CurrentPlayer != player) {
        CurrentPlayer = player;
        YTMPLog(@"artwork_player_observed",@{@"class":NSStringFromClass([player class]) ?: @""});
    }
}
NSString *YTMPCoverURL(NSString *title) {
    return YTMPResolveCover(CurrentPlayer,title);
}
