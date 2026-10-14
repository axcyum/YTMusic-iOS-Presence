#import <Foundation/Foundation.h>
#import "../src/Artwork.h"
#include <cassert>

@interface Model : NSObject
@property(nonatomic,strong) id playerResponse, playerData, videoDetails, thumbnail, thumbnailsArray;
@property(nonatomic,copy) NSString *title, *currentVideoID, *URL;
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
        puts("Artwork tests passed: URL validation, native thumbnail selection, track mismatch, ID fallback, Unicode.");
    } return 0;
}
