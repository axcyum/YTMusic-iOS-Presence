#import "Artwork.h"
#import "Logger.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <cstring>

// Do not retain the application's player or use unrestricted KVC. Only invoke
// verified object-returning, no-argument selectors from its playback model.
static __weak id CurrentPlayer;
static id ObjectValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!object) return nil;
    if (![object respondsToSelector:selector]) {
        // Only use explicitly named, object-typed ivars as a compatibility path.
        Ivar ivar = class_getInstanceVariable([object class],[[@"_" stringByAppendingString:name] UTF8String]);
        if (ivar && ivar_getTypeEncoding(ivar)[0]=='@') return object_getIvar(object,ivar);
        return nil;
    }
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2) return nil;
    const char *type = signature.methodReturnType;
    while (*type && strchr("rnNoORV",*type)) ++type;
    if (*type != '@') return nil;
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
static NSString *VideoCover(NSString *videoID) {
    if (videoID.length != 11) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    if ([videoID rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg",videoID];
}
NSString *YTMPResolveIdentifier(id value) {
    if ([value isKindOfClass:NSURL.class]) value=[value absoluteString];
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *direct=VideoCover(value); if (direct) return direct;
    NSURLComponents *url=[NSURLComponents componentsWithString:value];
    if (![url.scheme.lowercaseString isEqual:@"https"] || url.user.length || url.password.length) return nil;
    NSString *host=url.host.lowercaseString;
    if ([host isEqual:@"youtu.be"]) return VideoCover(url.path.lastPathComponent);
    if (![@[@"youtube.com",@"www.youtube.com",@"music.youtube.com",@"m.youtube.com"] containsObject:host]) return nil;
    for (NSURLQueryItem *item in url.queryItems) if ([item.name isEqual:@"v"]) return VideoCover(item.value);
    return nil;
}
static id DetailsForPlayer(id player) {
    id response = ObjectValue(player,@"playerResponse");
    id data = ObjectValue(response,@"playerData");
    id details = ObjectValue(data,@"videoDetails");
    if (!details) details=ObjectValue(response,@"videoDetails");
    if (!details) details=ObjectValue(player,@"videoDetails");
    return details;
}
static NSString *DetailsCover(id details) {
    id thumbnails = ObjectValue(ObjectValue(details,@"thumbnail"),@"thumbnailsArray");
    if ([thumbnails isKindOfClass:NSArray.class]) {
        for (id thumb in [thumbnails reverseObjectEnumerator]) {
            NSString *url=YTMPValidateCoverURL(ObjectValue(thumb,@"URL"));
            if (!url) url=YTMPValidateCoverURL(ObjectValue(thumb,@"url"));
            if (url) return url;
        }
    }
    NSString *url=VideoCover(StringValue(details,@"videoId"));
    if (!url) url=VideoCover(StringValue(details,@"videoID"));
    return url;
}
NSString *YTMPResolveCover(id player, NSString *nowPlayingTitle) {
    if (!nowPlayingTitle.length) return nil;
    id details=DetailsForPlayer(player);
    NSString *title = StringValue(details,@"title");
    // Track changes can reach Now Playing and playerResponse in different orders.
    // Wait for agreement rather than attaching the preceding song's artwork.
    if (!title.length || ![Normalized(title) isEqual:Normalized(nowPlayingTitle)]) return nil;
    NSString *cover=DetailsCover(details); if (cover) return cover;
    // A public, standard thumbnail is available even if the native array is empty.
    NSString *videoID = StringValue(player,@"currentVideoID");
    if (!videoID.length) videoID = StringValue(player,@"contentVideoID");
    return VideoCover(videoID);
}
static NSMutableArray *Snapshots(void) {
    static NSMutableArray *items; static dispatch_once_t once;
    dispatch_once(&once,^{items=[NSMutableArray new];}); return items;
}
void YTMPObserveVideoDetails(id details) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{YTMPObserveVideoDetails(details);}); return; }
    NSString *title=StringValue(details,@"title"), *author=StringValue(details,@"author");
    NSString *url=DetailsCover(details); if (!title.length || !url.length) return;
    for (NSDictionary *old in [Snapshots() copy]) {
        if ([old[@"title"] isEqual:Normalized(title)] && [old[@"author"] isEqual:Normalized(author)]) {
            if ([old[@"url"] isEqual:url]) return;
            [Snapshots() removeObject:old];
        }
    }
    [Snapshots() addObject:@{@"title":Normalized(title),@"author":Normalized(author),@"url":url}];
    if (Snapshots().count>24) [Snapshots() removeObjectAtIndex:0];
    YTMPLog(@"artwork_metadata_captured",@{@"title":title,@"author":author,@"url":url});
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
NSString *YTMPCoverURL(NSString *title, NSString *artist, id identifier) {
    // A current Now Playing video ID is more direct than retained player state.
    NSString *url=YTMPResolveIdentifier(identifier);
    if (url) return url;
    url=YTMPResolveCover(CurrentPlayer,title); if (url) return url;
    NSMutableArray *matches=[NSMutableArray new];
    for (NSDictionary *item in [Snapshots() reverseObjectEnumerator]) {
        if (![item[@"title"] isEqual:Normalized(title)]) continue;
        [matches addObject:item];
        if (artist.length && [item[@"author"] isEqual:Normalized(artist)]) return item[@"url"];
    }
    // Missing uploader metadata is acceptable only for an unambiguous title.
    if (matches.count==1 && ![matches[0][@"author"] length]) return matches[0][@"url"];
    id response=ObjectValue(CurrentPlayer,@"playerResponse");
    id data=ObjectValue(response,@"playerData");
    id details=DetailsForPlayer(CurrentPlayer);
    id thumbs=ObjectValue(ObjectValue(details,@"thumbnail"),@"thumbnailsArray");
    NSDictionary *diagnostic=@{@"player":NSStringFromClass([CurrentPlayer class]) ?: @"",
        @"response":NSStringFromClass([response class]) ?: @"",@"data":NSStringFromClass([data class]) ?: @"",
        @"details":NSStringFromClass([details class]) ?: @"",@"model_title":StringValue(details,@"title"),
        @"now_title":title ?: @"",@"thumbnail_count":@([thumbs isKindOfClass:NSArray.class] ? [thumbs count] : 0),
        @"snapshot_count":@(Snapshots().count),@"identifier_present":@(identifier != nil)};
    static NSDictionary *previous;
    if (![diagnostic isEqual:previous]) { YTMPLog(@"artwork_missing_details",diagnostic); previous=diagnostic; }
    return nil;
}
