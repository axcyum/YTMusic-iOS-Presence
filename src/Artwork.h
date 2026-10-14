#import <Foundation/Foundation.h>
void YTMPObservePlayer(id player);
NSString *YTMPCoverURL(NSString *nowPlayingTitle);
// Pure resolver used by both the runtime tracker and native regression tests.
NSString *YTMPResolveCover(id player, NSString *nowPlayingTitle);
NSString *YTMPValidateCoverURL(id value);
