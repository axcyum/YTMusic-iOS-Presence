#import "Logger.h"
#import <TargetConditionals.h>

static dispatch_queue_t LogQueue(void) {
    static dispatch_queue_t q; static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("YTMusicPresence.log",DISPATCH_QUEUE_SERIAL); });
    return q;
}
static NSMutableSet *Secrets(void) {
    static NSMutableSet *values; static dispatch_once_t once;
    dispatch_once(&once, ^{ values = [NSMutableSet new]; }); return values;
}
static NSURL *TestDirectory;
static NSURL *Directory(void) {
    if (TestDirectory) return TestDirectory;
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:@"YTMusicPresence" isDirectory:YES];
}
NSURL *YTMPLogFileURL(void) { return [Directory() URLByAppendingPathComponent:@"presence.jsonl"]; }
void YTMPRememberSecret(NSString *secret) {
    if (secret.length < 4) return;
    dispatch_sync(LogQueue(), ^{ [Secrets() addObject:secret]; });
}
static id Redact(id value) {
    if ([value isKindOfClass:NSString.class]) {
        NSString *s = value;
        // Longest first prevents a shorter credential from masking part of another.
        NSArray *secrets = [Secrets().allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b){
            return a.length > b.length ? NSOrderedAscending : (a.length < b.length ? NSOrderedDescending : NSOrderedSame);
        }];
        for (NSString *secret in secrets) s = [s stringByReplacingOccurrencesOfString:secret withString:@"[REDACTED]"];
        NSArray *patterns = @[
            @"(?i)(Bearer\\s+)[A-Za-z0-9._~+/=-]+",
            @"(?i)((?:access_token|refresh_token|client_secret|code_verifier|authorization|token)[\\\"'\\s]*[:=][\\\"'\\s]*)[^\\\"'\\s&,}]+",
            @"(?i)([?&](?:code|state)=)[^&\\s]+",
            @"[A-Za-z0-9_-]{15,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{15,}"
        ];
        for (NSString *pattern in patterns) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
            s = [regex stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0,s.length) withTemplate:@"[REDACTED]"];
        }
        return s.length > 16384 ? [[s substringToIndex:16384] stringByAppendingString:@"[TRUNCATED]"] : s;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *clean = [NSMutableDictionary new];
        for (id key in value) {
            NSString *name = [[key description] lowercaseString];
            BOOL sensitive = [@[@"access",@"refresh",@"access_token",@"refresh_token",@"token",@"client_secret",@"code_verifier",@"authorization"] containsObject:name];
            if ([name isEqual:@"code"] && [value[key] isKindOfClass:NSString.class]) sensitive = YES;
            clean[[key description]] = sensitive ? @"[REDACTED]" : Redact(value[key]);
        } return clean;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *clean = [NSMutableArray new]; for (id v in value) [clean addObject:Redact(v)]; return clean;
    }
    return value ?: NSNull.null;
}
void YTMPLog(NSString *event, NSDictionary *fields) {
    NSDictionary *snapshot = [fields copy] ?: @{};
    NSDate *time = NSDate.date;
    dispatch_async(LogQueue(), ^{
        @autoreleasepool {
            static NSISO8601DateFormatter *formatter;
            if (!formatter) formatter = [NSISO8601DateFormatter new];
            NSMutableDictionary *entry = [Redact(snapshot) mutableCopy];
            entry[@"event"] = event; entry[@"timestamp"] = [formatter stringFromDate:time];
            NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
            if (!json) return;
            NSMutableData *line = [json mutableCopy]; [line appendBytes:"\n" length:1];
            NSFileManager *fm = NSFileManager.defaultManager;
            NSURL *file = YTMPLogFileURL();
            [fm createDirectoryAtURL:Directory() withIntermediateDirectories:YES attributes:nil error:NULL];
            NSNumber *size = [fm attributesOfItemAtPath:file.path error:NULL][NSFileSize];
            if (size.unsignedLongLongValue + line.length > 1024*1024) {
                NSURL *old = [Directory() URLByAppendingPathComponent:@"presence.previous.jsonl"];
                [fm removeItemAtURL:old error:NULL]; [fm moveItemAtURL:file toURL:old error:NULL];
            }
            if (![fm fileExistsAtPath:file.path]) {
                NSMutableDictionary *attrs = [NSMutableDictionary new];
#if TARGET_OS_IPHONE
                attrs[NSFileProtectionKey] = NSFileProtectionCompleteUntilFirstUserAuthentication;
#endif
                [fm createFileAtPath:file.path contents:nil attributes:attrs];
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:file.path];
            @try { [handle seekToEndOfFile]; [handle writeData:line]; [handle closeFile]; }
            @catch (NSException *exception) { [handle closeFile]; }
        }
    });
}
void YTMPFlushLogs(void) { dispatch_sync(LogQueue(), ^{}); }
#ifdef YTMP_LOG_TESTING
void YTMPSetTestLogDirectory(NSURL *directory) { TestDirectory = directory; }
#endif
