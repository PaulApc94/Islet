//
//  IsletBridge.m
//
//  Tiny helper that streams the system "Now Playing" state as JSON lines on
//  stdout and accepts transport commands on stdin.
//
//  Why a separate dylib? Since macOS 15.4 the private MediaRemote framework
//  only answers processes that Apple trusts. /usr/bin/perl is one of them, so
//  the app launches perl, which loads this library and calls
//  `islet_bridge_run`. The app itself never links MediaRemote.
//
//  Protocol (one JSON object per line):
//    { "playing": Bool, "pid": Int, "title": String, "artist": String,
//      "album": String, "duration": Double, "elapsed": Double,
//      "timestamp": Double (unix seconds), "rate": Double,
//      "artworkId": String, "artwork": String (base64, only when it changed) }
//    { "empty": true }   when nothing is playing
//
//  Commands (one per line on stdin):
//    toggle | play | pause | next | previous | seek <seconds> | refresh
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*MRGetNowPlayingInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(uint32_t, CFDictionaryRef);
typedef void (*MRSetElapsedTimeFn)(double);

static MRGetNowPlayingInfoFn sGetInfo;
static MRGetIsPlayingFn sGetIsPlaying;
static MRGetPIDFn sGetPID;
static MRRegisterFn sRegister;
static MRSendCommandFn sSendCommand;
static MRSetElapsedTimeFn sSetElapsedTime;

static NSString *sLastArtworkId = nil;
static uint64_t sGeneration = 0;

enum {
    kCommandPlay = 0,
    kCommandPause = 1,
    kCommandToggle = 2,
    kCommandNext = 4,
    kCommandPrevious = 5,
};

static void emit(NSDictionary *payload) {
    // NSJSONSerialization raises instead of returning an error for values it
    // cannot encode. A dropped update is harmless; a crashed bridge is not.
    if (![NSJSONSerialization isValidJSONObject:payload]) return;
    NSData *json = nil;
    @try {
        json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    } @catch (NSException *exception) {
        return;
    }
    if (json == nil) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

/// FNV-1a over a sample of the data: cheap and good enough to tell covers apart.
static NSString *artworkIdentifier(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger step = MAX((NSUInteger)1, length / 4096);
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < length; i += step) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%llx-%lu", hash, (unsigned long)length];
}

/// Live streams report an infinite duration (and some players NaN positions),
/// which JSON cannot carry: such a value is treated as absent.
static NSNumber *finiteNumber(id value) {
    if (![value isKindOfClass:[NSNumber class]]) return nil;
    return isfinite([value doubleValue]) ? value : nil;
}

static void publish(NSDictionary *info, BOOL playing, int pid) {
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    if (![title isKindOfClass:[NSString class]] || title.length == 0) {
        sLastArtworkId = nil;
        emit(@{ @"empty": @YES });
        return;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"playing"] = @(playing);
    out[@"pid"] = @(pid);
    out[@"title"] = title;

    NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    NSString *album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
    if ([artist isKindOfClass:[NSString class]]) out[@"artist"] = artist;
    if ([album isKindOfClass:[NSString class]]) out[@"album"] = album;

    NSNumber *duration = finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
    NSNumber *elapsed = finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
    NSNumber *rate = finiteNumber(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
    NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if (duration) out[@"duration"] = duration;
    if (elapsed) out[@"elapsed"] = elapsed;
    if (rate) out[@"rate"] = rate;
    if ([timestamp isKindOfClass:[NSDate class]] && isfinite(timestamp.timeIntervalSince1970)) {
        out[@"timestamp"] = @(timestamp.timeIntervalSince1970);
    }

    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0) {
        NSString *identifier = artworkIdentifier(artwork);
        out[@"artworkId"] = identifier;
        if (![identifier isEqualToString:sLastArtworkId]) {
            out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            sLastArtworkId = identifier;
        }
    } else {
        out[@"artworkId"] = @"";
    }

    emit(out);
}

static void refresh(void) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    sGetInfo(queue, ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = cfInfo ? [(__bridge NSDictionary *)cfInfo copy] : @{};
        sGetIsPlaying(queue, ^(Boolean playing) {
            sGetPID(queue, ^(int pid) {
                publish(info, playing, pid);
            });
        });
    });
}

/// Coalesces bursts of notifications (a track change fires three or four).
static void scheduleRefresh(double delay) {
    uint64_t generation = ++sGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == sGeneration) refresh();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceCharacterSet]];
    NSString *name = parts.firstObject;
    if (name.length == 0) return;

    if ([name isEqualToString:@"toggle"]) sSendCommand(kCommandToggle, NULL);
    else if ([name isEqualToString:@"play"]) sSendCommand(kCommandPlay, NULL);
    else if ([name isEqualToString:@"pause"]) sSendCommand(kCommandPause, NULL);
    else if ([name isEqualToString:@"next"]) sSendCommand(kCommandNext, NULL);
    else if ([name isEqualToString:@"previous"]) sSendCommand(kCommandPrevious, NULL);
    else if ([name isEqualToString:@"seek"] && parts.count > 1 && sSetElapsedTime) {
        sSetElapsedTime(parts[1].doubleValue);
    } else if (![name isEqualToString:@"refresh"]) {
        return;
    }
    scheduleRefresh(0.15);
}

static void watchStdin(void) {
    static NSMutableData *buffer;
    static dispatch_source_t source;
    buffer = [NSMutableData data];
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0,
                                    dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        char chunk[1024];
        ssize_t count = read(STDIN_FILENO, chunk, sizeof(chunk));
        if (count <= 0) {
            // The app went away: do not linger as an orphan.
            exit(0);
        }
        [buffer appendBytes:chunk length:(NSUInteger)count];
        NSData *newlineData = [NSData dataWithBytes:"\n" length:1];
        while (YES) {
            NSRange newline = [buffer rangeOfData:newlineData
                                          options:0
                                            range:NSMakeRange(0, buffer.length)];
            if (newline.location == NSNotFound) break;
            NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, newline.location)];
            [buffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (line) handleCommand(line);
        }
    });
    dispatch_resume(source);
}

__attribute__((visibility("default")))
void islet_bridge_run(void) {
    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (handle == NULL) {
            fprintf(stderr, "islet-bridge: MediaRemote unavailable\n");
            exit(2);
        }
        sGetInfo = (MRGetNowPlayingInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        sGetIsPlaying = (MRGetIsPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        sGetPID = (MRGetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        sRegister = (MRRegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        sSendCommand = (MRSendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
        sSetElapsedTime = (MRSetElapsedTimeFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
        if (!sGetInfo || !sGetIsPlaying || !sGetPID || !sRegister || !sSendCommand) {
            fprintf(stderr, "islet-bridge: MediaRemote symbols missing\n");
            exit(3);
        }

        NSArray<NSString *> *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                scheduleRefresh(0.04);
            }];
        }
        sRegister(dispatch_get_main_queue());

        watchStdin();
        refresh();
        CFRunLoopRun();
    }
}
