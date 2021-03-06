//
//  PGPUserID.m
//  ObjectivePGP
//
//  Created by Marcin Krzyzanowski on 05/05/14.
//  Copyright (c) 2014 Marcin Krzyżanowski. All rights reserved.
//

#import "PGPUserIDPacket.h"
#import "PGPMacros.h"

@interface PGPPacket ()
@property (nonatomic, copy, readwrite) NSData *headerData;
@property (nonatomic, copy, readwrite) NSData *bodyData;
@end

@implementation PGPUserIDPacket

- (PGPPacketTag)tag {
    return PGPUserIDPacketTag;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ %@", [super description], self.userID];
}

- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError *__autoreleasing *)error {
    NSUInteger position = [super parsePacketBody:packetBody error:error];

    _userID = [[NSString alloc] initWithData:packetBody encoding:NSUTF8StringEncoding];
    position = position + packetBody.length;

    return position;
}

- (nullable NSData *)export:(NSError *__autoreleasing *)error {
    let data = [NSMutableData data];
    let bodyData = [self.userID dataUsingEncoding:NSUTF8StringEncoding];
    let headerData = [self buildHeaderData:bodyData];
    [data appendData:headerData];
    [data appendData:bodyData];
    return data;
}

@end
