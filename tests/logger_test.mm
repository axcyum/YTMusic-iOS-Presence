#import <Foundation/Foundation.h>
#import "../src/Logger.h"
#include <cassert>

int main(void) {
    @autoreleasepool {
        NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        YTMPSetTestLogDirectory(dir);
        YTMPRememberSecret(@"known-secret-credential-12345");
        YTMPLog(@"diagnostic",@{@"message":@"bearer known-secret-credential-12345",
            @"nested":@{@"access_token":@"unseen-private-token",@"error_code":@50035},
            @"url":@"discord-app:/callback?code=unknown-auth-code&state=unknown-state",
            @"error":@"timestamps.end invalid",@"unicode":@"再生失敗🎵"});
        dispatch_apply(32,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t i){
            YTMPLog(@"concurrent",@{@"index":@(i)});
        });
        YTMPFlushLogs();
        NSString *contents = [NSString stringWithContentsOfURL:YTMPLogFileURL() encoding:NSUTF8StringEncoding error:NULL];
        assert(contents != nil);
        assert(![contents containsString:@"known-secret-credential-12345"]);
        assert(![contents containsString:@"unseen-private-token"]);
        assert(![contents containsString:@"unknown-auth-code"]);
        assert(![contents containsString:@"unknown-state"]);
        NSArray *lines = [contents componentsSeparatedByString:@"\n"];
        assert(lines.count == 34);
        for (NSString *line in lines) {
            if (!line.length) continue;
            NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            assert(entry[@"event"] && entry[@"timestamp"]);
        }
        assert([contents containsString:@"timestamps.end invalid"]);
        assert([contents containsString:@"50035"]);
        NSString *large = [@"x" stringByPaddingToLength:16000 withString:@"x" startingAtIndex:0];
        for (int i=0; i<160; ++i) YTMPLog(@"rotation",@{@"text":large});
        YTMPFlushLogs();
        NSURL *old = [dir URLByAppendingPathComponent:@"presence.previous.jsonl"];
        assert([NSFileManager.defaultManager fileExistsAtPath:old.path]);
        for (NSURL *file in @[YTMPLogFileURL(),old]) {
            NSNumber *size = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:NULL][NSFileSize];
            assert(size.unsignedLongLongValue <= 1024*1024);
        }
        [NSFileManager.defaultManager removeItemAtURL:dir error:NULL];
        puts("Logger tests passed: credential redaction, JSONL, concurrent writes, Unicode, rotation.");
    }
    return 0;
}
