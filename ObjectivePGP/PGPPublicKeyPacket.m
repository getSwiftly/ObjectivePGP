//
//  OpenPGPPublicKey.m
//  ObjectivePGP
//
//  Created by Marcin Krzyzanowski on 04/05/14.
//  Copyright (c) 2014 Marcin Krzyżanowski. All rights reserved.
//

#import "PGPPublicKeyPacket.h"
#import "NSData+PGPUtils.h"
#import "PGPMPI.h"
#import "PGPPublicKeyRSA.h"
#import "PGPTypes.h"

#import <CommonCrypto/CommonCrypto.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@interface PGPPacket ()
@property (copy, readwrite) NSData *headerData;
@property (copy, readwrite) NSData *bodyData;
@end

@interface PGPPublicKeyPacket ()
@property (nonatomic, readwrite) PGPFingerprint *fingerprint;
@property (nonatomic, readwrite) PGPKeyID *keyID;
@property (nonatomic, readwrite) UInt16 V3validityPeriod;
@end

@implementation PGPPublicKeyPacket

- (PGPPacketTag)tag {
    return PGPPublicKeyPacketTag;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ %@", [super description], self.keyID];
}

- (NSUInteger)keySize {
    for (PGPMPI *mpi in self.publicMPIArray) {
        if ([mpi.identifier isEqualToString:@"N"]) {
            return (mpi.bigNum.bitsCount + 7) / 8; // ks
        }
    }
    return 0;
}

- (nullable PGPMPI *)publicMPI:(NSString *)identifier {
    for (PGPMPI *mpi in self.publicMPIArray) {
        if ([mpi.identifier isEqualToString:identifier]) {
            return mpi;
        }
    }

    return nil;
}

#pragma mark - KeyID and Fingerprint

/**
 *  12.2.  Key IDs and Fingerprints
 *
 *  @return keyID
 */
- (PGPKeyID *)keyID {
    if (!_keyID) {
        _keyID = [[PGPKeyID alloc] initWithFingerprint:self.fingerprint];
    }

    return _keyID;
}

/**
 *  12.2.  Key IDs and Fingerprints
 *  Calculate fingerprint
 *
 *  @return Fingerprint data
 */
- (PGPFingerprint *)fingerprint {
    if (!_fingerprint) {
        _fingerprint = [[PGPFingerprint alloc] initWithData:[self exportPublicPacketOldStyle]];
    }
    return _fingerprint;
}

#pragma mark - Parse data

/**
 *  5.5.2.  Public-Key Packet Formats
 *
 *  @param packetBody Packet body
 */
- (NSUInteger)parsePacketBody:(NSData *)packetBody error:(NSError *__autoreleasing *)error {
    NSUInteger position = [super parsePacketBody:packetBody error:error];

    // A one-octet version number (2,3,4).
    [packetBody getBytes:&_version range:(NSRange){position, 1}];
    position = position + 1;

    NSAssert(self.version >= 3, @"To old packet version");

    // A four-octet number denoting the time that the key was created.
    UInt32 timestamp = 0;
    [packetBody getBytes:&timestamp range:(NSRange){position, 4}];
    timestamp = CFSwapInt32BigToHost(timestamp);
    _createDate = [NSDate dateWithTimeIntervalSince1970:timestamp];
    position = position + 4;

    // V3 keys are deprecated; an implementation MUST NOT generate a V3 key, but MAY accept it.
    if (_version == 0x03) {
        //  A two-octet number denoting the time in days that this key is
        //  valid.  If this number is zero, then it does not expire.
        [packetBody getBytes:&_V3validityPeriod range:(NSRange){position, 2}];
        _V3validityPeriod = CFSwapInt16BigToHost(_V3validityPeriod);
        position = position + 2;
    }

    // A one-octet number denoting the public-key algorithm of this key.
    [packetBody getBytes:&_publicKeyAlgorithm range:(NSRange){position, 1}];
    position = position + 1;

    // A series of multiprecision integers comprising the key material.
    switch (self.publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmRSA:
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
        case PGPPublicKeyAlgorithmRSASignOnly: {
            // Algorithm-Specific Fields for RSA public keys:
            // MPI of RSA public modulus n;
            let mpiN = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"N" atPosition:position];
            position = position + mpiN.packetLength;

            // MPI of RSA public encryption exponent e.
            let mpiE = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"E" atPosition:position];
            position = position + mpiE.packetLength;

            self.publicMPIArray = @[mpiN, mpiE];
        } break;
        case PGPPublicKeyAlgorithmDSA:
        case PGPPublicKeyAlgorithmECDSA: {
            // - MPI of DSA prime p;
            let mpiP = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"P" atPosition:position];
            position = position + mpiP.packetLength;

            // - MPI of DSA group order q (q is a prime divisor of p-1);
            let mpiQ = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"Q" atPosition:position];
            position = position + mpiQ.packetLength;

            // - MPI of DSA group generator g;
            let mpiG = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"G" atPosition:position];
            position = position + mpiG.packetLength;

            // - MPI of DSA public-key value y (= g**x mod p where x is secret).
            let mpiY = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"Y" atPosition:position];
            position = position + mpiY.packetLength;

            self.publicMPIArray = @[mpiP, mpiQ, mpiG, mpiY];
        } break;
        case PGPPublicKeyAlgorithmElgamal:
        case PGPPublicKeyAlgorithmElgamalEncryptorSign: {
            // - MPI of Elgamal prime p;
            let mpiP = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"P" atPosition:position];
            position = position + mpiP.packetLength;

            // - MPI of Elgamal group generator g;
            let mpiG = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"G" atPosition:position];
            position = position + mpiG.packetLength;

            // - MPI of Elgamal public key value y (= g**x mod p where x is secret).
            let mpiY = [[PGPMPI alloc] initWithMPIData:packetBody identifier:@"Y" atPosition:position];
            position = position + mpiY.packetLength;

            self.publicMPIArray = @[mpiP, mpiG, mpiY];
        } break;
        default:
            @throw [NSException exceptionWithName:@"Unknown Algorithm" reason:@"Given algorithm is not supported" userInfo:nil];
            break;
    }

    return position;
}

/**
 *  Build new style public key data
 *
 *  @return public key data starting with version octet
 */
- (NSData *)buildPublicKeyBodyData:(BOOL)forceV4 {
    let data = [NSMutableData dataWithCapacity:128];
    [data appendBytes:&_version length:1];

    UInt32 timestamp = (UInt32)[self.createDate timeIntervalSince1970];
    UInt32 timestampBE = CFSwapInt32HostToBig(timestamp);
    [data appendBytes:&timestampBE length:4];

    if (!forceV4 && _version == 0x03) {
        // implementation MUST NOT generate a V3 key, but MAY accept it.
        // however it have to be generated here to calculate the very same fingerprint
        UInt16 V3ValidityPeriodBE = CFSwapInt16HostToBig(_V3validityPeriod);
        [data appendBytes:&V3ValidityPeriodBE length:2];
    }

    [data appendBytes:&_publicKeyAlgorithm length:1];

    // publicMPI is allways available, no need to decrypt
    for (PGPMPI *mpi in self.publicMPIArray) {
        let exportMPI = [mpi exportMPI];
        if (exportMPI) {
            [data appendData:exportMPI];
        }
    }
    return data;
}

// Old-style packet header for a key packet with two-octet length.
// Old but used by fingerprint and with signing
- (NSData *)exportPublicPacketOldStyle {
    let data = [NSMutableData data];

    let publicKeyData = [self buildPublicKeyBodyData:NO];

    NSUInteger length = publicKeyData.length;
    UInt8 upper = (UInt8)(length >> 8);
    UInt8 lower = length & 0xff;
    UInt8 headWithLength[3] = {0x99, upper, lower};
    [data appendBytes:&headWithLength length:3];
    [data appendData:publicKeyData];
    return data;
}

#pragma mark - PGPExportable

/**
 *  Packet data. Header with body data.
 *
 *  @param error error
 *
 *  @return data
 */
- (nullable NSData *)export:(NSError * __autoreleasing _Nullable *)error {
    let data = [NSMutableData data];

    let bodyData = [self buildPublicKeyBodyData:NO];
    let headerData = [self buildHeaderData:bodyData];
    [data appendData:headerData];
    [data appendData:bodyData];

    // it wont match, because input data is OLD world, and we export in NEW world format
    // NSAssert([headerData isEqualToData:self.headerData], @"Header not match");
    if ([self class] == [PGPPublicKeyPacket class]) {
        NSAssert([bodyData isEqualToData:self.bodyData], @"Body doesn't match");
    }

    return data;
}

#pragma mark - Encrypt & Decrypt

- (nullable NSData *)encryptData:(NSData *)data withPublicKeyAlgorithm:(PGPPublicKeyAlgorithm)publicKeyAlgorithm {
    switch (publicKeyAlgorithm) {
        case PGPPublicKeyAlgorithmRSA:
        case PGPPublicKeyAlgorithmRSAEncryptOnly:
        case PGPPublicKeyAlgorithmRSASignOnly: {
            // return ecnrypted m
            return [PGPPublicKeyRSA publicEncrypt:data withPublicKeyPacket:self];
        } break;
        default:
            // TODO: add algorithms
            [NSException raise:@"PGPNotSupported" format:@"Algorith not supported"];
            break;
    }
    return nil;
}

#pragma mark - NSCopying

- (id)copyWithZone:(nullable NSZone *)zone {
    PGPPublicKeyPacket *copy = (PGPPublicKeyPacket *)[super copyWithZone:zone];
    copy->_version = self.version;
    copy->_createDate = self.createDate;
    copy->_V3validityPeriod = self.V3validityPeriod;
    copy->_publicKeyAlgorithm = self.publicKeyAlgorithm;
    copy->_fingerprint = self.fingerprint;
    copy->_keyID = self.keyID;
    copy->_publicMPIArray = self.publicMPIArray;
    return copy;
}

@end

NS_ASSUME_NONNULL_END
