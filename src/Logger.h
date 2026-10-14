#import <Foundation/Foundation.h>
void YTMPLog(NSString *event, NSDictionary *fields);
void YTMPRememberSecret(NSString *secret);
NSURL *YTMPLogFileURL(void);
void YTMPFlushLogs(void);
#ifdef YTMP_LOG_TESTING
void YTMPSetTestLogDirectory(NSURL *directory);
#endif
