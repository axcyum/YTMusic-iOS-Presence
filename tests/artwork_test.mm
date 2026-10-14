#import <Foundation/Foundation.h>
#import "../src/Artwork.h"
#import "../src/Logger.h"
#include <cassert>

@interface Model : NSObject
@property(nonatomic,strong) id playerResponse, playerData, videoDetails, thumbnail, thumbnailsArray;
@property(nonatomic,copy) NSString *title, *currentVideoID, *URL, *author;
@end
@implementation Model
@end

static Model *Player(NSString *title,NSArray *urls) {
    Model *player = [Model new], *response = [Model new], *data = [Model new];
    Model *details = [Model new], *thumbnail = [Model new];
    player.playerResponse=response; response.playerData=data; data.videoDetails=details;
    details.title=title; details.thumbnail=thumbnail; player.currentVideoID=@"abcdefghijk";
    NSMutableArray *items=[NSMutableArray new];
    for (NSString *url in urls) { Model *thumb=[Model new]; thumb.URL=url; [items addObject:thumb]; }
    thumbnail.thumbnailsArray=items; return player;
}
int main(void) {
    @autoreleasepool {
        NSURL *logDir=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        YTMPSetTestLogDirectory(logDir);
        assert([YTMPValidateCoverURL(@"https://lh3.googleusercontent.com/album=w544-h544") length]);
        assert([YTMPValidateCoverURL([NSURL URLWithString:@"https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"]) length]);
        for (NSString *url in @[@"http://i.ytimg.com/cover.jpg",@"https://ytimg.com.evil.example/cover.jpg",
            @"https://127.0.0.1/cover.jpg",@"file:///tmp/art.png",@"https://user:pass@i.ytimg.com/cover.jpg",
            @"https://i.ytimg.com:444/cover.jpg",@"https://i.ytimg.com/a.jpg#fragment"]) {
            assert(!YTMPValidateCoverURL(url));
        }
        assert(!YTMPValidateCoverURL(@42));
        Model *player=Player(@"Song",@[@"https://i.ytimg.com/small.jpg",@"https://lh3.googleusercontent.com/large.jpg"]);
        assert([YTMPResolveCover(player,@"Song") isEqual:@"https://lh3.googleusercontent.com/large.jpg"]);
        // Now Playing moved ahead of the model: no stale artwork or ID fallback.
        assert(!YTMPResolveCover(player,@"Different song"));
        Model *noThumbs=Player(@"Song",@[]);
        assert([YTMPResolveCover(noThumbs,@"Song") isEqual:@"https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"]);
        noThumbs.currentVideoID=@"../../private"; assert(!YTMPResolveCover(noThumbs,@"Song"));
        assert(!YTMPResolveCover(nil,@"Song"));
        assert(!YTMPResolveCover([NSObject new],@"Song"));
        assert([YTMPResolveCover(Player(@"Cafe\u0301",@[@"https://i.ytimg.com/a.jpg"]),@"Café") length]);
        Model *next=Player(@"Next",@[@"https://i.ytimg.com/next.jpg"]);
        assert([YTMPResolveCover(next,@"Next") isEqual:@"https://i.ytimg.com/next.jpg"]);
        Model *directPlayer=[Model new], *directResponse=[Model new];
        directPlayer.playerResponse=directResponse;
        directResponse.videoDetails=((Model *)((Model *)((Model *)next.playerResponse).playerData).videoDetails);
        assert([YTMPResolveCover(directPlayer,@"Next") isEqual:@"https://i.ytimg.com/next.jpg"]);
        assert([YTMPResolveIdentifier(@"https://music.youtube.com/watch?v=abcdefghijk") isEqual:@"https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"]);
        assert(!YTMPResolveIdentifier(@"https://evil.example/watch?v=abcdefghijk"));
        assert(!YTMPResolveIdentifier(@"https://youtube.com/watch?v=invalid"));
        Model *cached=(Model *)directResponse.videoDetails; cached.author=@"Artist";
        YTMPObserveVideoDetails(cached);
        // Metadata can be captured even when there is no live player controller.
        assert([YTMPCoverURL(@"Next",@"Artist",nil) isEqual:@"https://i.ytimg.com/next.jpg"]);
        assert(!YTMPCoverURL(@"Next",@"Other Artist",nil));
        assert(!YTMPCoverURL(@"Unknown",@"Artist",nil));
        YTMPFlushLogs();
        [NSFileManager.defaultManager removeItemAtURL:logDir error:NULL];
        puts("Artwork tests passed: URL validation, native thumbnail selection, track mismatch, ID fallback, Unicode.");
    } return 0;
}
