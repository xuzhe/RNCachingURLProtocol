//
//  NSString+SHA.m
//  Modernzine
//
//  Created by Rakuraku Jyo on 11/30/11.
//  Copyright (c) 2011 XUZHE.COM. All rights reserved.
//


#import <CommonCrypto/CommonDigest.h>
#import "NSString+SHA.h"


@implementation NSString (SHA)

+ (NSString *)sha256:(NSString *)input {
    const char *str = [input cStringUsingEncoding:NSUTF8StringEncoding];
    NSData *data = [NSData dataWithBytes:str length:input.length];

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];

    CC_SHA256(data.bytes, data.length, digest);

    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];

    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }

    return output;
}

- (NSString *)sha256 {
    return [NSString sha256:self];
}

+ (NSString *)sha1:(NSString *)input {
    const char *str = [input cStringUsingEncoding:NSUTF8StringEncoding];
    NSData *data = [NSData dataWithBytes:str length:input.length];
    
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1(data.bytes, data.length, digest);
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return output;
}

- (NSString *)sha1 {
    return [NSString sha1:self];
}

@end