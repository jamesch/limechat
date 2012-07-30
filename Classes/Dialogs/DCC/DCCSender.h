// LimeChat is copyrighted free software by Satoshi Nakagawa <psychs AT limechat DOT net>.
// You can redistribute it and/or modify it under the terms of the GPL version 2 (see the file GPL.txt).

#import <Foundation/Foundation.h>
#import "DCCFileTransferCell.h"
#import "TCPServer.h"


@interface DCCSender : NSObject
{
    __weak id delegate;
    int uid;
    NSString* peerNick;
    int port;
    NSString* fileName;
    NSString* fullFileName;
    long long size;
    long long processedSize;
    DCCFileTransferStatus status;
    NSString* error;
    NSImage* icon;
    NSProgressIndicator* progressBar;

    TCPServer* sock;
    TCPClient* client;
    NSFileHandle* file;
    NSMutableArray* speedRecords;
    double currentRecord;
}

@property (nonatomic, weak) id delegate;
@property (nonatomic) int uid;
@property (nonatomic, strong) NSString* peerNick;
@property (nonatomic, readonly) int port;
@property (nonatomic, readonly) NSString* fileName;
@property (nonatomic, strong) NSString* fullFileName;
@property (nonatomic, readonly) long long size;
@property (nonatomic, readonly) long long processedSize;
@property (nonatomic, readonly) DCCFileTransferStatus status;
@property (nonatomic, readonly) NSString* error;
@property (nonatomic, readonly) NSImage* icon;
@property (nonatomic, strong) NSProgressIndicator* progressBar;
@property (nonatomic, readonly) double speed;

- (BOOL)open;
- (void)close;
- (void)onTimer;
- (void)setAddressError;

@end


@interface NSObject (DCCSenderDelegate)
- (void)dccSenderOnListen:(DCCSender*)sender;
- (void)dccSenderOnConnect:(DCCSender*)sender;
- (void)dccSenderOnClose:(DCCSender*)sender;
- (void)dccSenderOnError:(DCCSender*)sender;
- (void)dccSenderOnComplete:(DCCSender*)sender;
@end
