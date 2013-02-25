//
//  RNCachingURLProtocol.m
//
//  Created by Robert Napier on 1/10/12.
//  Copyright (c) 2012 Rob Napier.
//
//  This code is licensed under the MIT License:
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//

#import "RNCachingURLProtocol.h"
#import "Reachability.h"
#import "NSString+SHA.h"

// required to workaround http://openradar.appspot.com/11596316
@interface NSURLRequest (MutableCopyWorkaround)

- (id)mutableCopyWorkaround;

@end

@interface RNCachedData : NSObject <NSCoding>
@property(nonatomic, readwrite, strong) NSURLResponse *response;
@property(nonatomic, readwrite, strong) NSURLRequest *redirectRequest;
@property(nonatomic, readwrite, strong) NSString *mimeType;
@property(nonatomic, readwrite, strong) NSDate *lastModifiedDate;
@property(nonatomic, readwrite, strong) NSString *filePath;
@end

static NSString *RNCachingURLHeader = @"X-RNCache";
static NSString *RNCachingPlistFile = @"RNCache.plist";
static NSString *RNCachingFolderName = @"RNCaching";

@interface RNCachingURLProtocol () <NSURLConnectionDelegate, NSURLConnectionDataDelegate, NSStreamDelegate> {    //  iOS5-only
    NSOutputStream *_outputStream;
    NSInputStream *_inputStream;
}

@property(nonatomic, readwrite, strong) NSURLConnection *connection;
@property(nonatomic, readwrite, strong) NSURLResponse *response;
@property(nonatomic, readonly, assign) BOOL isURLInclude;

- (void)appendData:(NSData *)data;
@end

static NSMutableDictionary *_expireTime = nil;
static NSMutableArray *_includeHosts = nil;
static RNCacheListStore *_cacheListStore = nil;

@implementation RNCachingURLProtocol

+ (RNCacheListStore *)cacheListStore {
    @synchronized(self) {
        if (_cacheListStore == nil) {
            _cacheListStore = [[RNCacheListStore alloc] initWithPath:[self cachePathForKey:RNCachingPlistFile]];
        }
        return _cacheListStore;
    }
}

+ (NSMutableDictionary *)expireTime {
    if (_expireTime == nil) {
        _expireTime = [NSMutableDictionary dictionary];
        _expireTime[@"application/json"] = @(60 * 30); // 30 min
        _expireTime[@"text/html"] = @(60 * 30); // 30 min
        _expireTime[@"image/"] = @(60 * 60 * 24 * 30); // 30 day
        _expireTime[@"video/"] = @(60 * 60 * 24 * 30); // 30 day
        _expireTime[@"audio/"] = @(60 * 60 * 24 * 30); // 30 day
    }
    return _expireTime;
}

+ (NSMutableArray *)includeHostPatterns {
    if (_includeHosts == nil) {
        _includeHosts = [NSMutableArray array];
    }

    return _includeHosts;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // only handle http requests we haven't marked with our header.
    if ([[[request URL] scheme] isEqualToString:@"http"] &&
            ([request valueForHTTPHeaderField:RNCachingURLHeader] == nil)) {
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (void)removeCache {
    [[self cacheListStore] clear];
    NSString *offlineCachePath = [self RNCachingFolderPath];
    [[NSFileManager defaultManager] removeItemAtPath:offlineCachePath error:nil];
}

+ (void)removeCacheOlderThan:(NSDate *)date {
    NSArray *userInfo = nil;
    NSArray *keysToDelete = [[self cacheListStore] removeObjectsOlderThan:date userInfo:&userInfo];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSUInteger i = 0; i < [keysToDelete count]; i++) {
        [fileManager removeItemAtPath:userInfo[i][2] error:nil];
        [fileManager removeItemAtPath:keysToDelete[i] error:nil];
    }
}

+ (NSString *)RNCachingFolderPath {
    NSString *cachesPath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
    return [cachesPath stringByAppendingPathComponent:RNCachingFolderName];
}

+ (NSString *)cachePathForKey:(NSString *)key {
    NSString *offlineCachePath = [self RNCachingFolderPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:offlineCachePath withIntermediateDirectories:YES attributes:nil error:nil];
    return [offlineCachePath stringByAppendingPathComponent:key];
}

+ (NSString *)cacheDataPathForKey:(NSString *)key {
    NSString *offlineCachePath = [[self RNCachingFolderPath] stringByAppendingPathComponent:@"Data"];
    [[NSFileManager defaultManager] createDirectoryAtPath:offlineCachePath withIntermediateDirectories:YES attributes:nil error:nil];
    return [offlineCachePath stringByAppendingPathComponent:key];
}

+ (NSString *)cacheDataPathForRequest:(NSURLRequest *)aRequest {
    return [self cacheDataPathForURL:[aRequest URL]];
}

+ (NSData *)dataForURL:(NSString *)url {
    NSString *file = [self cachePathForKey:[url sha1]];
    RNCachedData *cache = [NSKeyedUnarchiver unarchiveObjectWithFile:file];
    if (cache) {
        return [NSData dataWithContentsOfFile:[cache filePath]];
    } else {
        return nil;
    }
}

+ (NSString *)cachePathForURL:(NSURL *)url {
    return [self cachePathForKey:[[url absoluteString] sha1]];
}

+ (NSString *)cacheDataPathForURL:(NSURL *)url {
    return [self cacheDataPathForKey:[[[url absoluteString] sha1] stringByAppendingPathExtension:[url pathExtension]]];
}

+ (NSString *)cachePathForRequest:(NSURLRequest *)aRequest {
    return [self cachePathForURL:[aRequest URL]];
}

- (NSOutputStream *)outputStream {
    if (!_outputStream) {
        NSString *dataPath = [[self class] cacheDataPathForRequest:[self request]];
        _outputStream = [NSOutputStream outputStreamToFileAtPath:dataPath append:NO];   // NO Resume broken transfer at this time
        [_outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }
    return _outputStream;
}

- (void)closeOutputStream:(NSOutputStream *)oStream {
    if (oStream) {
        [oStream close];
        [oStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        oStream.delegate = nil;
        oStream = nil;
    }
}

- (void)closeInputStream:(NSInputStream *)iStream {
    if (iStream) {
        [iStream close];
        [iStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        iStream.delegate = nil;
        iStream = nil;
    }
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {
        case NSStreamEventHasBytesAvailable: {
            uint8_t buf[1024];
            unsigned int len = 0;
            len = [(NSInputStream *)stream read:buf maxLength:1024];
            if (len) {
                NSData *data = [NSData dataWithBytes:(const void *)buf length:len];
                [[self client] URLProtocol:self didLoadData:data];
            } else {
                NSLog(@"no buffer!");
            }
            break;
        }
        case NSStreamEventEndEncountered: {
            [self closeInputStream:(NSInputStream *)stream];
            [[self client] URLProtocolDidFinishLoading:self];
            break;
        }
        default:
            break;
    }
}

- (void)startLoading {
    if ([self useCache]) {
        RNCachedData *cache = [NSKeyedUnarchiver unarchiveObjectWithFile:[[self class] cachePathForRequest:[self request]]];
        if (cache) {
            NSURLResponse *response = [cache response];
            NSURLRequest *redirectRequest = [cache redirectRequest];
            if (redirectRequest) {
                [[self client] URLProtocol:self wasRedirectedToRequest:redirectRequest redirectResponse:response];
            } else {
                [self closeInputStream:_inputStream];
                
                [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed]; // we handle caching ourselves.
                NSInputStream *iStream = [NSInputStream inputStreamWithFileAtPath:[[self class] cacheDataPathForRequest:[self request]]];
                // iStream is NSInputStream instance variable
                [iStream setDelegate:self];
                [iStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
                [iStream open];
            }
            return;
        }
    }

    NSMutableURLRequest *connectionRequest = [[self request] mutableCopyWorkaround];
    // we need to mark this request with our header so we know not to handle it in +[NSURLProtocol canInitWithRequest:].
    [connectionRequest setValue:@"" forHTTPHeaderField:RNCachingURLHeader];
    NSURLConnection *connection = [NSURLConnection connectionWithRequest:connectionRequest
                                                                delegate:self];
    [self setConnection:connection];
}

- (void)stopLoading {
    [[self connection] cancel];
}

// NSURLConnection delegates (generally we pass these on to our client)

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
// Thanks to Nick Dowell https://gist.github.com/1885821
    if (response != nil) {
        NSMutableURLRequest *redirectableRequest = [request mutableCopyWorkaround];
        // We need to remove our header so we know to handle this request and cache it.
        // There are 3 requests in flight: the outside request, which we handled, the internal request,
        // which we marked with our header, and the redirectableRequest, which we're modifying here.
        // The redirectable request will cause a new outside request from the NSURLProtocolClient, which
        // must not be marked with our header.
        [redirectableRequest setValue:nil forHTTPHeaderField:RNCachingURLHeader];

        if (_isURLInclude) {
            NSString *cachePath = [[self class] cachePathForRequest:[self request]];
            RNCachedData *cache = [RNCachedData new];
            [cache setResponse:response];
            [cache setFilePath:[[self class] cacheDataPathForRequest:[self request]]];
            [cache setRedirectRequest:redirectableRequest];
            [NSKeyedArchiver archiveRootObject:cache toFile:cachePath];
        }
        [[self client] URLProtocol:self wasRedirectedToRequest:redirectableRequest redirectResponse:response];
        return redirectableRequest;
    } else {
        return request;
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [[self client] URLProtocol:self didLoadData:data];
    if (_isURLInclude) {
        [self appendData:data];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [[self client] URLProtocol:self didFailWithError:error];
    if (_isURLInclude) {
        [self closeOutputStream:_outputStream];
    }
    [self setConnection:nil];
    [self setResponse:nil];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    [self setResponse:response];
    [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];  // We cache ourselves.
    if (_isURLInclude) {
        [[self outputStream] open];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [[self client] URLProtocolDidFinishLoading:self];

    if (_isURLInclude) {
        NSString *cachePath = [[self class] cachePathForRequest:[self request]];
        RNCachedData *cache = [RNCachedData new];
        [cache setResponse:[self response]];
        [cache setFilePath:[[self class] cacheDataPathForRequest:[self request]]];
        [[[self class] cacheListStore] setObject:@[[NSDate date], [self response].MIMEType, [cache filePath]] forKey:cachePath];
        
        [NSKeyedArchiver archiveRootObject:cache toFile:cachePath];
        
        [self closeOutputStream:_outputStream];
    }

    [self setConnection:nil];
    [self setResponse:nil];
}

- (BOOL)useCache {
    if (!([self isHostIncluded] && [[[self request] HTTPMethod] isEqualToString:@"GET"])) {
        return NO;
    }

    if ([[Reachability reachabilityWithHostName:[[[self request] URL] host]] currentReachabilityStatus] == NotReachable) {
        return YES;
    } else {
        return ![self isCacheExpired] && [self isCacheDataExists];
    }
}

+ (BOOL)isURLInclude:(NSString *)URLStr {
    NSError *error = NULL;
    NSArray *nonMutable = [NSArray arrayWithArray:[self includeHostPatterns]];
    for (NSString *pattern in nonMutable) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:&error];
        NSTextCheckingResult *result = [regex firstMatchInString:URLStr options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, URLStr.length)];
        if (result.numberOfRanges) {
            NSLog(@"[RNCachingURLProtocol] include: %@", URLStr);
            return YES;
        }
    }
    
    NSLog(@"[RNCachingURLProtocol] NOT include: %@", URLStr);
    return NO;
}

- (BOOL)isHostIncluded {
    NSString *string = [[[self request] URL] absoluteString];
    _isURLInclude = [RNCachingURLProtocol isURLInclude:string];
    return _isURLInclude;
}

- (NSArray *)cacheMeta {
    return [[[self class] cacheListStore] objectForKey:[[self class] cachePathForRequest:[self request]]];
}

- (BOOL)isCacheExpired {
    NSArray *meta = [self cacheMeta];
    if (meta == nil) {
        return YES;
    }

    NSDate *modifiedDate = meta[0];
    NSString *mimeType = meta[1];

    BOOL expired = YES;

    NSString *foundKey = nil;
    for (NSString *key in [[RNCachingURLProtocol expireTime] allKeys]) {
        if ([[key lowercaseString] rangeOfString:[mimeType lowercaseString] options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) {
            foundKey = key;
            break;
        }
    }
    NSNumber *time = [[RNCachingURLProtocol expireTime] valueForKey:foundKey];
    if (time) {
        NSTimeInterval delta = [[NSDate date] timeIntervalSinceDate:modifiedDate];

        expired = (delta > [time doubleValue]);
    }

    NSLog(@"[RNCachingURLProtocol] %@: %@", expired ? @"expired" : @"hit", [[[self request] URL] absoluteString]);
    return expired;
}

- (BOOL)isCacheDataExists {
    return [[NSFileManager defaultManager] fileExistsAtPath:[[self class] cacheDataPathForRequest:[self request]]];
}

- (void)appendData:(NSData *)newData {
    NSOutputStream *oStream = [self outputStream];
    if ([oStream hasSpaceAvailable]) {
        const uint8_t *dataBuffer = (uint8_t *) [newData bytes];
        [oStream write:&dataBuffer[0] maxLength:[newData length]];
    }
}

- (void)dealloc {
    [self closeInputStream:_inputStream];
    [self closeOutputStream:_outputStream];
}

@end

static NSString *const kFilePathKey = @"filePath";
static NSString *const kResponseKey = @"response";
static NSString *const kRedirectRequestKey = @"redirectRequest";
static NSString *const kMimeType = @"mimeType";
static NSString *const kLastModifiedDateKey = @"lastModifiedDateKey";

@implementation RNCachedData

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:[NSDate new] forKey:kLastModifiedDateKey];
    [aCoder encodeObject:[self filePath] forKey:kFilePathKey];
    [aCoder encodeObject:[self response].MIMEType forKey:kMimeType];
    [aCoder encodeObject:[self response] forKey:kResponseKey];
    [aCoder encodeObject:[self redirectRequest] forKey:kRedirectRequestKey];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self != nil) {
        [self setLastModifiedDate:[aDecoder decodeObjectForKey:kLastModifiedDateKey]];
        [self setFilePath:[aDecoder decodeObjectForKey:kFilePathKey]];
        [self setMimeType:[aDecoder decodeObjectForKey:kMimeType]];
        [self setResponse:[aDecoder decodeObjectForKey:kResponseKey]];
        [self setRedirectRequest:[aDecoder decodeObjectForKey:kRedirectRequestKey]];
    }

    return self;
}

@end

@implementation NSURLRequest (MutableCopyWorkaround)

- (id)mutableCopyWorkaround {
    NSMutableURLRequest *mutableURLRequest = [[NSMutableURLRequest alloc] initWithURL:[self URL]
                                                                          cachePolicy:[self cachePolicy]
                                                                      timeoutInterval:[self timeoutInterval]];
    [mutableURLRequest setHTTPMethod:[self HTTPMethod]];
    [mutableURLRequest setAllHTTPHeaderFields:[self allHTTPHeaderFields]];
    [mutableURLRequest setHTTPBody:[self HTTPBody]];
    [mutableURLRequest setHTTPShouldHandleCookies:[self HTTPShouldHandleCookies]];
    [mutableURLRequest setHTTPShouldUsePipelining:[self HTTPShouldUsePipelining]];
    return mutableURLRequest;
}

@end

#pragma mark - RNCacheListStore
@implementation RNCacheListStore {
    NSMutableDictionary *_dict;
    NSString *_path;
    dispatch_queue_t _queue;
}

- (id)initWithPath:(NSString *)path {
    if (self = [super init]) {
        _path = [path copy];

        NSDictionary* dict = [NSDictionary dictionaryWithContentsOfFile:_path];
        if (dict) {
            _dict = [[NSMutableDictionary alloc] initWithDictionary:dict];
        } else {
            _dict = [[NSMutableDictionary alloc] init];
        }

        _queue = dispatch_queue_create("cache.savelist.queue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)setObject:(id)object forKey:(id)key {
    dispatch_barrier_async(_queue, ^{
        _dict[key] = object;
    });

    [self performSelector:@selector(saveAfterDelay)];
}

- (id)objectForKey:(id)key {
    __block id obj;
    dispatch_sync(_queue, ^{
        obj = _dict[key];
    });
    return obj;
}

- (NSArray *)removeObjectsOlderThan:(NSDate *)date userInfo:(NSMutableArray **)userInfoPtr {
    __block NSSet *keysToDelete;
    dispatch_sync(_queue, ^{
        if (userInfoPtr) {
            *userInfoPtr = [NSMutableArray arrayWithCapacity:[_dict count]];
        }
        keysToDelete = [_dict keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop) {
            NSArray *userInfo = (NSArray *)obj;
            NSDate *d = userInfo[0];
            if ([d compare:date] == NSOrderedAscending) {
                if (userInfoPtr) {
                    [*userInfoPtr addObject:userInfo];
                }
                return YES;
            }
            return NO;
        }];
    });

    dispatch_barrier_async(_queue, ^{
        [_dict removeObjectsForKeys:[keysToDelete allObjects]];
    });

    [self performSelector:@selector(saveAfterDelay)];

    return [keysToDelete allObjects];
}

- (void)clear {
    dispatch_barrier_async(_queue, ^{
        [_dict removeAllObjects];
    });

    [self performSelector:@selector(saveAfterDelay)];
}

- (void)saveCacheDictionary {
    dispatch_barrier_async(_queue, ^{
        [_dict writeToFile:_path atomically:YES];
        NSLog(@"[RNCachingURLProtocol] cache list persisted.");
    });
}

- (void)saveAfterDelay {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveCacheDictionary) object:nil];
    [self performSelector:@selector(saveCacheDictionary) withObject:nil afterDelay:0.5];
}

@end
