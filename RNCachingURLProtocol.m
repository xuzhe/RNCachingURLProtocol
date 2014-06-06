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


#define WORKAROUND_MUTABLE_COPY_LEAK  FALSE

#if WORKAROUND_MUTABLE_COPY_LEAK
// required to workaround http://openradar.appspot.com/11596316
@interface NSURLRequest (MutableCopyWorkaround)

- (id)mutableCopyWorkaround;

@end
#endif

@interface RNCachedData : NSObject <NSCoding>
@property(nonatomic, readwrite, strong) NSURLResponse *response;
@property(nonatomic, readwrite, strong) NSURLRequest *redirectRequest;
@property(nonatomic, readwrite, strong) NSString *mimeType;
@property(nonatomic, readwrite, strong) NSDate *lastModifiedDate;
@property(nonatomic, readwrite, strong) NSString *filePath;
@end

static NSString *const RNCachingURLHeader = @"X-RNCache";
static NSString *const RNCachingPlistFile = @"RNCache.plist";
static NSString *const RNCachingFolderName = @"RNCaching";
static BOOL __includeAllURLs = NO;
static BOOL __alwaysUseCache = NO;
static NSString *__customizedUserAgentPlugin = nil;

@interface RNCachingURLProtocol () <NSURLConnectionDelegate, NSURLConnectionDataDelegate, NSStreamDelegate> {    //  iOS5-only
    NSOutputStream *_outputStream;
    NSInputStream *_inputStream;
}

@property(nonatomic, readwrite, strong) NSURLConnection *connection;
@property(nonatomic, readwrite, strong) NSURLResponse *response;
@property(nonatomic, readonly, assign) BOOL isURLInclude;

- (void)appendData:(NSData *)data;
@end

static NSDictionary *_expireTime = nil;
static NSArray *_includeHosts = nil;
static NSArray *_hostsBlackList = nil;
static NSArray *_fileTypeBlackList = nil;
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

+ (NSString *)appVersion {
    static NSString *appVersion = nil;
    if (!appVersion) {
        appVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    }
    return appVersion;
}

+ (NSString *)appBuildVersion {
    static NSString *appBuildVersion = nil;
    if (!appBuildVersion) {
        appBuildVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:(NSString *)kCFBundleVersionKey];
    }
	return appBuildVersion;
}

+ (NSString *)appName {
    static NSString *appName = nil;
    if (!appName) {
        appName = [[[NSBundle mainBundle] localizedInfoDictionary] objectForKey:@"CFBundleDisplayName"];
        if (!appName) {
            appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleDisplayName"];
        }
    }
    return appName;
}

+ (NSString *)customizedUserAgent:(NSString *)originalUserAgent {
    static NSString *customizedUserAgent = nil;
    if (__customizedUserAgentPlugin) {
        customizedUserAgent = __customizedUserAgentPlugin;
    } else if (!customizedUserAgent) {
        customizedUserAgent = [NSString stringWithFormat:@"%@/%@(%@)",
                               [[[self appName] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""],
                               [self appVersion], [self appBuildVersion]];
    }
    NSString *temp = (originalUserAgent ? [originalUserAgent stringByAppendingFormat:@" %@", customizedUserAgent] : customizedUserAgent);
    return (temp ? temp : @"");
}

+ (void)setCustmizedUserAgentPlugin:(NSString *)plugin {
    __customizedUserAgentPlugin = plugin;
}

+ (void)setExpireTime:(NSDictionary *)expireTime {
    _expireTime = expireTime;
}

+ (NSDictionary *)expireTime {
    if (_expireTime == nil) {
        _expireTime = @{
#ifdef IN_HOUSE
         @"application/json" : @(60.0 * 5) // 5 min
        ,@"text/html" : @(60.0 * 5) // 5 min
        ,@"text/css" : @(60.0 * 5) // 5 min
        ,@"image/" : @(60.0 * 10) // 10 min
        ,@"video/" : @(60.0 * 10) // 10 min
        ,@"audio/" : @(60.0 * 10) // 10 min
#else
         @"application/json" : @(60.0 * 30) // 30 min
        ,@"text/html" : @(60.0 * 30) // 30 min
        ,@"text/css" : @(60.0 * 30) // 30 min
        ,@"image/" : @(60.0 * 60 * 24 * 14) // 14 day
        ,@"video/" : @(60.0 * 60 * 24 * 14) // 14 day
        ,@"audio/" : @(60.0 * 60 * 24 * 14) // 14 day
#endif
        };
    }
    return _expireTime;
}

+ (NSArray *)includeHosts {
    return _includeHosts;
}

+ (void)setIncludeHosts:(NSArray *)hosts {
    if ([_includeHosts isEqual:hosts]) {
        return;
    }
    _includeHosts = hosts;
}

+ (NSArray *)fileTypeBlackList {
    return _fileTypeBlackList;
}

+ (void)setFileTypeBlackList:(NSArray *)blacklist {
    if ([_fileTypeBlackList isEqual:blacklist]) {
        return;
    }
    _fileTypeBlackList = blacklist;
}

+ (NSArray *)hostsBlackList {
    return _hostsBlackList;
}

+ (void)setHostsBlackList:(NSArray *)blacklist {
    if ([_hostsBlackList isEqual:blacklist]) {
        return;
    }
    _hostsBlackList = blacklist;
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
    NSString *cachePath = [[url absoluteString] sha1];
    if ([[url pathExtension] length] > 0) {
        cachePath = [cachePath stringByAppendingPathExtension:[url pathExtension]];
    }
    return [self cacheDataPathForKey:cachePath];
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
            NSInteger len = 0;
            len = [(NSInputStream *)stream read:buf maxLength:1024];
            if (len > 0) {
                NSData *data = [NSData dataWithBytes:(const void *)buf length:len];
                [[self client] URLProtocol:self didLoadData:data];
//            } else {
//                NSLog(@"no buffer!");
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
                _inputStream = [NSInputStream inputStreamWithFileAtPath:[[self class] cacheDataPathForRequest:[self request]]];
                // iStream is NSInputStream instance variable
                [_inputStream setDelegate:self];
                [_inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
                [_inputStream open];
            }
            return;
        }
    }
    
    NSMutableURLRequest *connectionRequest =
#if WORKAROUND_MUTABLE_COPY_LEAK
    [[self request] mutableCopyWorkaround];
#else
    [[self request] mutableCopy];
#endif
    
    // we need to mark this request with our header so we know not to handle it in +[NSURLProtocol canInitWithRequest:].
    [connectionRequest setValue:@"" forHTTPHeaderField:RNCachingURLHeader];
    
    static NSString *userAgentKey = @"User-Agent";
    [connectionRequest setValue:[RNCachingURLProtocol customizedUserAgent:[connectionRequest valueForHTTPHeaderField:userAgentKey]] forHTTPHeaderField:userAgentKey];
    
    NSURLConnection *connection = [NSURLConnection connectionWithRequest:connectionRequest
                                                                delegate:self];
    self.connection = connection;
}

- (void)stopLoading {
    [[self connection] cancel];
}

// NSURLConnection delegates (generally we pass these on to our client)

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
// Thanks to Nick Dowell https://gist.github.com/1885821
    if (response != nil) {
        NSMutableURLRequest *redirectableRequest =
#if WORKAROUND_MUTABLE_COPY_LEAK
        [request mutableCopyWorkaround];
#else
        [request mutableCopy];
#endif
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
            [[[self class] cacheListStore] setObject:@[[NSDate date], [self response].MIMEType, [cache filePath]] forKey:cachePath];
            
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

    if (_isURLInclude &&
        ([[self response] isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)[self response] statusCode] == 200)) {
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
    if (__alwaysUseCache) {
        return YES;
    }
    if ([[Reachability reachabilityWithHostname:[[[self request] URL] host]] currentReachabilityStatus] == NotReachable) {
        return YES;
    } else {
        return ![self isCacheExpired] && [self isCacheDataExists];
    }
}

+ (void)setIncludeAllURLs:(BOOL)includeAllURLs {
    __includeAllURLs = includeAllURLs;
}

+ (void)setAlwaysUseCache:(BOOL)alwaysUseCache {
    __alwaysUseCache = alwaysUseCache;
}

+ (BOOL)isURLInclude:(NSString *)URLStr inArray:(NSArray *)array {
    NSError *error = NULL;
    for (NSString *pattern in array) {
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

+ (BOOL)isURLInclude:(NSString *)URLStr {
    if (__includeAllURLs) {
        return YES;
    }
    return [self isURLInclude:URLStr inArray:[self includeHosts]];
}

+ (BOOL)isFileTypeInBlackList:(NSString *)fileType {
    return NO;
}

+ (BOOL)isURLInBlackList:(NSString *)URLStr {
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
    NSDictionary *expireTime = [RNCachingURLProtocol expireTime];
    NSString *foundKey = nil;
    for (NSString *key in [expireTime allKeys]) {
        if ([mimeType rangeOfString:key options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) {
            foundKey = key;
            break;
        }
    }
    if (!foundKey) {
        foundKey = kAllMIMETypesKey;
    }
    NSNumber *time = [expireTime valueForKey:foundKey];
    if (time) {
        NSTimeInterval delta = [[NSDate date] timeIntervalSinceDate:modifiedDate];
        expired = (delta > [time doubleValue]);
    }
    
    NSLog(@"[%@] %@: %@", [[self class] description], expired ? @"expired" : @"hit", [[[self request] URL] absoluteString]);
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

#if WORKAROUND_MUTABLE_COPY_LEAK
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
#endif

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
    [self performSelector:@selector(saveCacheDictionary) withObject:nil afterDelay:1.0];
}

#if NEEDS_DISPATCH_RETAIN_RELEASE
- (void)dealloc {
    dispatch_release(_queue);
}
#endif

@end
