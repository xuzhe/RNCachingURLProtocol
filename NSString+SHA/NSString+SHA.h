//
//  NSString+SHA.h
//  Modernzine
//
//  Created by Rakuraku Jyo on 11/30/11.
//  Copyright (c) 2011 XUZHE.COM. All rights reserved.
//


#import <Foundation/Foundation.h>

@interface NSString (SHA)

+ (NSString *)sha256:(NSString *)input;
- (NSString *)sha256;

+ (NSString *)sha1:(NSString *)input;
- (NSString *)sha1;

@end