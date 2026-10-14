#import <Foundation/Foundation.h>
void YTMPObservePlayer(id player);
NSString *YTMPCoverURL(NSString *nowPlayingTitle, NSString *artist, id contentIdentifier);
void YTMPObserveVideoDetails(id details);
NSString *YTMPResolveIdentifier(id value);
// Pure resolver used by both the runtime tracker and native regression tests.
NSString *YTMPResolveCover(id player, NSString *nowPlayingTitle);
NSString *YTMPValidateCoverURL(id value);
