// Created by Satoshi Nakagawa.
// You can redistribute it and/or modify it under the Ruby's license or the GPL2.

#import "IRCClient.h"
#import "IRC.h"
#import "IRCWorld.h"
#import "IRCMessage.h"
#import "Preferences.h"
#import "NSStringHelper.h"
#import "NSDataHelper.h"
#import "WhoisDialog.h"


#define MAX_JOIN_CHANNELS	10
#define MAX_BODY_LEN		480
#define TIME_BUFFER_SIZE	256


@interface IRCClient (Private)
- (void)sendLine:(NSString*)str;
- (void)send:(NSString*)str, ...;

- (void)setKeywordState:(id)target;
- (void)setNewTalkState:(id)target;
- (void)setUnreadState:(id)target;

- (void)receivePrivmsgAndNotice:(IRCMessage*)message;
- (void)receiveJoin:(IRCMessage*)message;
- (void)receivePart:(IRCMessage*)message;
- (void)receiveKick:(IRCMessage*)message;
- (void)receiveQuit:(IRCMessage*)message;
- (void)receiveKill:(IRCMessage*)message;
- (void)receiveNick:(IRCMessage*)message;
- (void)receiveMode:(IRCMessage*)message;
- (void)receiveTopic:(IRCMessage*)message;
- (void)receiveInvite:(IRCMessage*)message;
- (void)receiveError:(IRCMessage*)message;
- (void)receivePing:(IRCMessage*)message;
- (void)receiveNumericReply:(IRCMessage*)message;

- (void)receiveInit:(IRCMessage*)message;
- (void)receiveText:(IRCMessage*)m command:(NSString*)cmd text:(NSString*)text identified:(BOOL)identified;
- (void)receiveErrorNumericReply:(IRCMessage*)message;
- (void)receiveNickCollision:(IRCMessage*)message;
- (void)receiveCTCPQuery:(IRCMessage*)message text:(NSString*)text;
- (void)receiveCTCPReply:(IRCMessage*)message text:(NSString*)text;

- (void)changeStateOff;
- (BOOL)printBoth:(id)chan type:(LogLineType)type text:(NSString*)text;
- (BOOL)printBoth:(id)chan type:(LogLineType)type nick:(NSString*)nick text:(NSString*)text identified:(BOOL)identified;
- (void)printConsole:(id)chan type:(LogLineType)type text:(NSString*)text;
- (void)printConsole:(id)chan type:(LogLineType)type nick:(NSString*)nick text:(NSString*)text identified:(BOOL)identified;
- (BOOL)printChannel:(IRCChannel*)channel type:(LogLineType)type text:(NSString*)text;
- (BOOL)printChannel:(IRCChannel*)channel type:(LogLineType)type nick:(NSString*)nick text:(NSString*)text identified:(BOOL)identified;
- (void)printSystem:(id)channel text:(NSString*)text;
- (void)printSystemBoth:(id)channel text:(NSString*)text;
- (void)printReply:(IRCMessage*)m;
- (void)printUnknownReply:(IRCMessage*)m;
- (void)printErrorReply:(IRCMessage*)m;
- (void)printError:(NSString*)error;

- (WhoisDialog*)createWhoisDialogWithNick:(NSString*)nick username:(NSString*)username address:(NSString*)address realname:(NSString*)realname;
- (WhoisDialog*)findWhoisDialog:(NSString*)nick;
@end


@implementation IRCClient

@synthesize world;

@synthesize config;
@synthesize channels;
@synthesize isupport;
@synthesize connecting;
@synthesize connected;
@synthesize reconnecting;
@synthesize loggedIn;

@synthesize isKeyword;
@synthesize isUnread;

@synthesize myNick;
@synthesize myAddress;

@synthesize lastSelectedChannel;

@synthesize propertyDialog;

- (id)init
{
	if (self = [super init]) {
		tryingNick = -1;
		channels = [NSMutableArray new];
		isupport = [IRCISupportInfo new];
		myMode = [IRCUserMode new];
		whoisDialogs = [NSMutableArray new];
	}
	return self;
}

- (void)dealloc
{
	[config release];
	[channels release];
	[isupport release];
	[myMode release];
	[conn close];
	[conn autorelease];
	[inputNick release];
	[sentNick release];
	[myNick release];
	[serverHostname release];
	[joinMyAddress release];
	[myAddress release];
	[lastSelectedChannel release];
	[whoisDialogs release];
	[propertyDialog release];
	[super dealloc];
}

#pragma mark -
#pragma mark Init

- (void)setup:(IRCClientConfig*)seed
{
	[config autorelease];
	config = [seed mutableCopy];
}

- (void)updateConfig:(IRCClientConfig*)seed
{
	[config autorelease];
	config = [seed mutableCopy];
	
	NSArray* chans = config.channels;
	
	NSMutableArray* ary = [NSMutableArray array];
	
	for (IRCChannelConfig* i in chans) {
		IRCChannel* c = [self findChannel:i.name];
		if (c) {
			[c updateConfig:i];
			[ary addObject:c];
			[channels removeObjectIdenticalTo:c];
		}
		else {
			c = [world createChannel:i client:self reload:NO adjust:NO];
			[ary addObject:c];
		}
	}
	
	for (IRCChannel* c in channels) {
		if (c.isChannel) {
			[self partChannel:c];
		}
		else {
			[ary addObject:c];
		}
	}
	
	[channels removeAllObjects];
	[channels addObjectsFromArray:ary];
	
	[config.channels removeAllObjects];

	[world reloadTree];
	[world adjustSelection];
}

- (IRCClientConfig*)storedConfig
{
	IRCClientConfig* u = [[config mutableCopy] autorelease];
	u.uid = uid;
	[u.channels removeAllObjects];
	
	for (IRCChannel* c in channels) {
		if (c.isChannel) {
			[u.channels addObject:[[c.config mutableCopy] autorelease]];
		}
	}
	
	return u;
}

- (NSMutableDictionary*)dictionaryValue
{
	NSMutableDictionary* dic = [config dictionaryValue];
	
	NSMutableArray* ary = [NSMutableArray array];
	for (IRCChannel* c in channels) {
		if (c.isChannel) {
			[ary addObject:[c dictionaryValue]];
		}
	}
	
	[dic setObject:ary forKey:@"channels"];
	return dic;
}

#pragma mark -
#pragma mark Properties

- (NSString*)name
{
	return config.name;
}

- (BOOL)isNewTalk
{
	return NO;
}

#pragma mark -
#pragma mark Utilities

- (void)autoConnect:(int)delay
{
	connectDelay = delay;
	[self connect];
}

- (void)onTimer
{
}

- (void)terminate
{
	[self quit];
	[self closeDialogs];
	for (IRCChannel* c in channels) {
		[c terminate];
	}
	[self disconnect];
}

- (void)closeDialogs
{
	for (WhoisDialog* d in whoisDialogs) {
		[d close];
	}
	[whoisDialogs removeAllObjects];
}

- (void)reloadTree
{
	[world reloadTree];
}

#pragma mark -
#pragma mark Commands

- (void)connect
{
	if (conn) {
		[conn close];
		[conn autorelease];
		conn = nil;
	}
	
	[self printSystemBoth:nil text:@"Connecting…"];
	
	connecting = YES;
	reconnectEnabled = YES;
	reconnectTime = 30;
	retryEnabled = YES;
	retryTime = 30;
	
	NSString* host = config.host;
	if (host) {
		int n = [host findCharacter:' '];
		if (n >= 0) {
			host = [host substringToIndex:n];
		}
	}
	
	conn = [IRCConnection new];
	conn.delegate = self;
	conn.host = host;
	conn.port = config.port;
	conn.useSSL = config.useSSL;
	conn.encoding = config.encoding;
	
	switch (config.proxyType) {
		case PROXY_SOCKS_SYSTEM:
			conn.useSystemSocks = YES;
		case PROXY_SOCKS4:
		case PROXY_SOCKS5:
			conn.useSocks = YES;
			conn.socksVersion = config.proxyType;
			conn.proxyHost = config.proxyHost;
			conn.proxyPort = config.proxyPort;
			conn.proxyUser = config.proxyUser;
			conn.proxyPassword = config.proxyPassword;
			break;
	}
	
	[conn open];
}

- (void)disconnect
{
	if (conn) {
		[conn close];
		[conn autorelease];
		conn = nil;
	}
	
	[self changeStateOff];
}

- (void)quit
{
	if (!loggedIn) {
		[self disconnect];
		return;
	}
	
	quitting = YES;
	reconnectEnabled = NO;
	[conn clearSendQueue];
	[self send:QUIT, config.leavingComment, nil];
}

- (void)cancelReconnect
{
}

- (void)changeNick:(NSString*)newNick
{
	if (!connected) return;
	
	[inputNick autorelease];
	[sentNick autorelease];
	inputNick = [newNick retain];
	sentNick = [sentNick retain];
	
	[self send:NICK, newNick, nil];
}

- (void)joinChannel:(IRCChannel*)channel
{
	if (!loggedIn) return;
	if (channel.isActive) return;
	
	NSString* password = channel.config.password;
	if (!password.length) password = nil;
	
	[self send:JOIN, channel.name, password, nil];
}

- (void)partChannel:(IRCChannel*)channel
{
	if (!loggedIn) return;
	if (!channel.isActive) return;
	
	NSString* comment = config.leavingComment;
	if (!comment.length) comment = nil;
	
	[self send:PART, channel.name, comment, nil];
}

- (void)sendWhois:(NSString*)nick
{
	if (!loggedIn) return;
	
	[self send:WHOIS, nick, nick, nil];
}

- (void)changeOp:(IRCChannel*)channel users:(NSArray*)inputUsers mode:(char)mode value:(BOOL)value
{
	if (!loggedIn || !channel || !channel.isActive || !channel.isChannel || !channel.hasOp) return;
	
	NSMutableArray* users = [NSMutableArray array];
	
	for (IRCUser* user in inputUsers) {
		IRCUser* m = [channel findMember:user.nick];
		if (m) {
			if (value != [m hasMode:mode]) {
				[users addObject:m];
			}
		}
	}
	
	int max = isupport.modesCount;
	while (users.count) {
		NSArray* ary = [users subarrayWithRange:NSMakeRange(0, MIN(max, users.count))];
		
		NSMutableString* s = [NSMutableString string];
		[s appendFormat:@"%@ %@ %c", MODE, channel.name, value ? '+' : '-'];
		
		for (int i=ary.count-1; i>=0; --i) {
			[s appendFormat:@"%c", mode];
		}
		
		for (IRCUser* m in ary) {
			[s appendString:@" "];
			[s appendString:m.nick];
		}
		
		[self sendLine:s];
		
		[users removeObjectsInRange:NSMakeRange(0, ary.count)];
	}
}

- (void)kick:(IRCChannel*)channel target:(NSString*)nick
{
	[self send:KICK, channel.name, nick, nil];
}

- (void)quickJoin:(NSArray*)chans
{
	NSMutableString* target = [NSMutableString string];
	NSMutableString* pass = [NSMutableString string];
	
	for (IRCChannel* c in chans) {
		NSMutableString* prevTarget = [[target mutableCopy] autorelease];
		NSMutableString* prevPass = [[pass mutableCopy] autorelease];
		
		if (!target.isEmpty) [target appendString:@","];
		[target appendString:c.name];
		if (!c.password.isEmpty) {
			if (!pass.isEmpty) [pass appendString:@","];
			[pass appendString:c.password];
		}
		
		NSData* targetData = [target dataUsingEncoding:conn.encoding];
		NSData* passData = [pass dataUsingEncoding:conn.encoding];
		
		if (targetData.length + passData.length > MAX_BODY_LEN) {
			if (!prevTarget.isEmpty) {
				if (prevPass.isEmpty) {
					[self send:JOIN, prevTarget, nil];
				}
				else {
					[self send:JOIN, prevTarget, prevPass, nil];
				}
				[target setString:c.name];
				[pass setString:c.password];
			}
			else {
				if (c.password.isEmpty) {
					[self send:JOIN, c.name, nil];
				}
				else {
					[self send:JOIN, c.name, c.password, nil];
				}
				[target setString:@""];
				[pass setString:@""];
			}
		}
	}
	
	if (!target.isEmpty) {
		if (pass.isEmpty) {
			[self send:JOIN, target, nil];
		}
		else {
			[self send:JOIN, target, pass, nil];
		}
	}
}

- (void)joinChannels:(NSArray*)chans
{
	NSMutableArray* ary = [NSMutableArray array];
	BOOL pass = YES;
	
	for (IRCChannel* c in chans) {
		BOOL hasPass = !c.password.isEmpty;
		
		if (pass) {
			pass = hasPass;
			[ary addObject:c];
		}
		else {
			if (hasPass) {
				[self quickJoin:ary];
				[ary removeAllObjects];
				pass = hasPass;
			}
			[ary addObject:c];
		}
		
		if (ary.count >= MAX_JOIN_CHANNELS) {
			[self quickJoin:ary];
			[ary removeAllObjects];
			pass = YES;
		}
	}
	
	if (ary.count > 0) {
		[self quickJoin:ary];
	}
}

#pragma mark -
#pragma mark Sending Text

- (BOOL)sendText:(NSString*)s command:(NSString*)command
{
	if (!connected) return NO;
	
	id sel = world.selected;
	if (!sel) return NO;
	if ([sel isClient]) {
		// server
		if ([s hasPrefix:@"/"]) {
			s = [s substringFromIndex:1];
		}
		[self sendLine:s];
	}
	else {
		// channel
		if ([s hasPrefix:@"/"]) {
			// command
			s = [s substringFromIndex:1];
			[self sendLine:s];
		}
		else {
			// normal text
			[self send:command, [sel name], s, nil];
			[self printBoth:sel type:LINE_TYPE_PRIVMSG nick:myNick text:s identified:YES];
		}
	}
	
	return YES;
}

- (void)sendLine:(NSString*)str
{
	[conn sendLine:str];
	
	LOG(@">>> %@", str);
}

- (void)send:(NSString*)str, ...
{
	NSMutableArray* ary = [NSMutableArray array];
	
	id obj;
	va_list args;
	va_start(args, str);
	while (obj = va_arg(args, id)) {
		[ary addObject:obj];
	}
	va_end(args);
	
	NSMutableString* s = [NSMutableString stringWithString:str];
	
	int count = ary.count;
	for (int i=0; i<count; i++) {
		NSString* e = [ary objectAtIndex:i];
		[s appendString:@" "];
		if (i == count-1 && (e.length == 0 || [e hasPrefix:@":"] || [e contains:@" "])) {
			[s appendString:@":"];
		}
		[s appendString:e];
	}
	
	[self sendLine:s];
}

#pragma mark -
#pragma mark Find Channel

- (IRCChannel*)findChannel:(NSString*)name
{
	for (IRCChannel* c in channels) {
		if ([c.name isEqualNoCase:name]) {
			return c;
		}
	}
	return nil;
}

- (int)indexOfTalkChannel
{
	int i = 0;
	for (IRCChannel* e in channels) {
		if (e.isTalk) return i;
		++i;
	}
	return -1;
}

#pragma mark -
#pragma mark Window Title

- (void)updateClientTitle
{
	[world updateClientTitle:self];
}

- (void)updateChannelTitle:(IRCChannel*)c
{
	[world updateChannelTitle:c];
}

#pragma mark -
#pragma mark Channel States

- (void)setKeywordState:(id)t
{
	if ([NSApp isActive] && world.selected == t) return;
	if ([t isKeyword]) return;
	[t setIsKeyword:YES];
	[self reloadTree];
	if (![NSApp isActive]) [NSApp requestUserAttention:NSInformationalRequest];
	[world updateIcon];
}

- (void)setNewTalkState:(id)t
{
	if ([NSApp isActive] && world.selected == t) return;
	if ([t isNewTalk]) return;
	[t setIsNewTalk:YES];
	[self reloadTree];
	if (![NSApp isActive]) [NSApp requestUserAttention:NSInformationalRequest];
	[world updateIcon];
}

- (void)setUnreadState:(id)t
{
	if ([NSApp isActive] && world.selected == t) return;
	if ([t isUnread]) return;
	[t setIsUnread:YES];
	[self reloadTree];
	[world updateIcon];
}

#pragma mark -
#pragma mark Print

- (NSString*)now
{
	NSString* format = @"%H:%M";
	if ([Preferences themeOverrideTimestampFormat]) {
		format = [Preferences themeTimestampFormat];
	}
	
	time_t global = time(NULL);
	struct tm* local = localtime(&global);
	char buf[TIME_BUFFER_SIZE+1];
	strftime(buf, TIME_BUFFER_SIZE, [format UTF8String], local);
	buf[TIME_BUFFER_SIZE] = 0;
	NSString* result = [[[NSString alloc] initWithBytes:buf length:strlen(buf) encoding:NSUTF8StringEncoding] autorelease];
	return result;
}

- (BOOL)needPrintConsole:(id)chan
{
	if (!chan) chan = self;
	
	IRCChannel* channel = nil;
	if (![chan isKindOfClass:[NSString class]]) {
		channel = chan;
	}
	
	if (!channel.isClient && !channel.config.logToConsole) {
		return NO;
	}
	return channel != world.selected || !channel.log.viewingBottom;
}

- (BOOL)printBoth:(id)chan type:(LogLineType)type text:(NSString*)text
{
	return [self printBoth:chan type:type nick:nil text:text identified:NO];
}

- (BOOL)printBoth:(id)chan type:(LogLineType)type nick:(NSString*)nick text:(NSString*)text identified:(BOOL)identified
{
	BOOL result = [self printChannel:chan type:type nick:nick text:text identified:identified];
	if ([self needPrintConsole:chan]) {
		[self printConsole:chan type:type nick:nick text:text identified:identified];
	}
	return result;
}

- (void)printConsole:(id)chan type:(LogLineType)type text:(NSString*)text
{
	[self printConsole:chan type:type nick:nil text:text identified:NO];
}

- (void)printConsole:(id)chan type:(LogLineType)type nick:(NSString*)nick text:(NSString*)text identified:(BOOL)identified
{
	NSString* time = [self now];
	IRCChannel* channel = nil;
	NSString* channelName = nil;
	NSString* place = nil;
	NSString* nickStr = nil;
	LogLineType memberType = MEMBER_TYPE_NORMAL;
	int colorNumber = 0;
	id clickContext = nil;
	NSArray* keywords = nil;
	NSArray* excludeWords = nil;

	if (time.length) {
		time = [time stringByAppendingString:@" "];
	}
	
	if ([chan isKindOfClass:[IRCChannel class]]) {
		channel = chan;
		channelName = channel.name;
	}
	else if ([chan isKindOfClass:[NSString class]]) {
		channelName = chan;
	}
	
	if (channelName && [channelName isChannelName]) {
		place = [NSString stringWithFormat:@"<%@> ", channelName];
	}
	else {
		place = [NSString stringWithFormat:@"<%@> ", config.name];
	}
	
	if (nick.length > 0) {
		if (type == LINE_TYPE_ACTION) {
			nickStr = [NSString stringWithFormat:@"%@ "];
		}
		else {
			nickStr = [NSString stringWithFormat:@"%@: ", nick];
		}
	}
	
	if (nick && [nick isEqualToString:myNick]) {
		memberType = MEMBER_TYPE_MYSELF;
	}
	
	if (nick && channel) {
		IRCUser* user = [channel findMember:nick];
		if (user) {
			colorNumber = user.colorNumber;
		}
	}
	
	if (channel) {
		clickContext = [NSString stringWithFormat:@"channel %d %d", uid, channel.uid];
	}
	else {
		clickContext = [NSString stringWithFormat:@"client %d", uid];
	}
	
	if (type == LINE_TYPE_PRIVMSG || type == LINE_TYPE_ACTION) {
		if (memberType != MEMBER_TYPE_MYSELF) {
			keywords = [Preferences keywords];
			excludeWords = [Preferences excludeWords];
			
			if ([Preferences keywordCurrentNick]) {
				NSMutableArray* ary = [[keywords mutableCopy] autorelease];
				[ary insertObject:myNick atIndex:0];
				keywords = ary;
			}
		}
	}
	
	LogLine* c = [[LogLine new] autorelease];
	c.time = time;
	c.place = place;
	c.nick = nickStr;
	c.body = text;
	c.lineType = type;
	c.memberType = memberType;
	c.nickInfo = nick;
	c.clickInfo = clickContext;
	c.identified = identified;
	c.nickColorNumber = colorNumber;
	c.keywords = keywords;
	c.excludeWords = excludeWords;

	[world.consoleLog print:c];
}

- (BOOL)printChannel:(id)chan type:(LogLineType)type text:(NSString*)text
{
	return [self printChannel:chan type:type nick:nil text:text identified:NO];
}

- (BOOL)printChannel:(id)chan type:(LogLineType)type nick:(NSString*)nick text:(NSString*)text identified:(BOOL)identified
{
	NSString* time = [self now];
	NSString* channelName = nil;
	IRCChannel* channel = nil;
	NSString* place = nil;
	NSString* nickStr = nil;
	LogLineType memberType = MEMBER_TYPE_NORMAL;
	int colorNumber = 0;
	NSArray* keywords = nil;
	NSArray* excludeWords = nil;

	if (time.length) {
		time = [time stringByAppendingString:@" "];
	}
	
	if ([chan isKindOfClass:[IRCChannel class]]) {
		channel = chan;
		channelName = channel.name;
	}
	else if ([chan isKindOfClass:[NSString class]]) {
		channelName = chan;
		place = [NSString stringWithFormat:@"<%@> ", channelName];
	}
	
	if (nick.length > 0) {
		if (type == LINE_TYPE_ACTION) {
			nickStr = [NSString stringWithFormat:@"%@ ", nick];
		}
		else {
			nickStr = [NSString stringWithFormat:@"%@: ", nick];
		}
	}
	
	if (nick && [nick isEqualToString:myNick]) {
		memberType = MEMBER_TYPE_MYSELF;
	}
	
	if (nick && channel) {
		IRCUser* user = [channel findMember:nick];
		if (user) {
			colorNumber = user.colorNumber;
		}
	}
	
	if (type == LINE_TYPE_PRIVMSG || type == LINE_TYPE_ACTION) {
		if (memberType != MEMBER_TYPE_MYSELF) {
			keywords = [Preferences keywords];
			excludeWords = [Preferences excludeWords];
			
			if ([Preferences keywordCurrentNick]) {
				NSMutableArray* ary = [[keywords mutableCopy] autorelease];
				[ary insertObject:myNick atIndex:0];
				keywords = ary;
			}
		}
	}
	
	LogLine* c = [[LogLine new] autorelease];
	c.time = time;
	c.place = place;
	c.nick = nickStr;
	c.body = text;
	c.lineType = type;
	c.memberType = memberType;
	c.nickInfo = nick;
	c.clickInfo = nil;
	c.identified = identified;
	c.nickColorNumber = colorNumber;
	c.keywords = keywords;
	c.excludeWords = excludeWords;
	
	if (channel) {
		return [channel print:c];
	}
	else {
		return [log print:c];
	}
}

- (void)printSystem:(id)channel text:(NSString*)text
{
	[self printChannel:channel type:LINE_TYPE_SYSTEM text:text];
}

- (void)printSystemBoth:(id)channel text:(NSString*)text
{
	[self printBoth:channel type:LINE_TYPE_SYSTEM text:text];
}

- (void)printReply:(IRCMessage*)m
{
	NSString* text = [m sequence:1];
	[self printBoth:nil type:LINE_TYPE_REPLY text:text];
}

- (void)printUnknownReply:(IRCMessage*)m
{
	NSString* text = [NSString stringWithFormat:@"Reply(%d): %@", m.numericReply, [m sequence:1]];
	[self printBoth:nil type:LINE_TYPE_REPLY text:text];
}

- (void)printErrorReply:(IRCMessage*)m
{
	NSString* text = [NSString stringWithFormat:@"Error(%d): %@", m.numericReply, [m sequence:1]];
	[self printBoth:nil type:LINE_TYPE_ERROR_REPLY text:text];
}

- (void)printError:(NSString*)error
{
	[self printBoth:nil type:LINE_TYPE_ERROR text:error];
}

#pragma mark -
#pragma mark IRCTreeItem

- (BOOL)isClient
{
	return YES;
}

- (BOOL)isActive
{
	return loggedIn;
}

- (IRCClient*)client
{
	return self;
}

- (void)resetState
{
}

- (int)numberOfChildren
{
	return channels.count;
}

- (id)childAtIndex:(int)index
{
	return [channels objectAtIndex:index];
}

- (NSString*)label
{
	return config.name;
}

#pragma mark -
#pragma mark WhoisDialog

- (WhoisDialog*)createWhoisDialogWithNick:(NSString*)nick username:(NSString*)username address:(NSString*)address realname:(NSString*)realname
{
	WhoisDialog* d = [self findWhoisDialog:nick];
	if (d) {
		[d show];
		return d;
	}
	
	d = [[WhoisDialog new] autorelease];
	d.delegate = self;
	[whoisDialogs addObject:d];
	[d startWithNick:nick username:username address:address realname:realname];
	return d;
}

- (WhoisDialog*)findWhoisDialog:(NSString*)nick
{
	for (WhoisDialog* d in whoisDialogs) {
		if ([nick isEqualNoCase:d.nick]) {
			return d;
		}
	}
	return nil;
}

- (void)whoisDialogOnTalk:(WhoisDialog*)sender
{
	IRCChannel* c = [world createTalk:sender.nick client:self];
	if (c) {
		[world select:c];
	}
}

- (void)whoisDialogOnUpdate:(WhoisDialog*)sender
{
	[self sendWhois:sender.nick];
}

- (void)whoisDialogOnJoin:(WhoisDialog*)sender channel:(NSString*)channel
{
	[self send:JOIN, channel, nil];
}

- (void)whoisDialogWillClose:(WhoisDialog*)sender
{
	[[sender retain] autorelease];
	[whoisDialogs removeObjectIdenticalTo:sender];
}

#pragma mark -
#pragma mark Protocol Handlers

- (void)receivePrivmsgAndNotice:(IRCMessage*)m
{
	NSString* text = [m paramAt:1];
	
	BOOL identified = NO;
	if (identifyCTCP && ([text hasPrefix:@"+\x01"] || [text hasPrefix:@"-\x01"])) {
		identified = [text hasPrefix:@"+"];
		text = [text substringFromIndex:1];
	}
	else if (identifyMsg && ([text hasPrefix:@"+"] || [text hasPrefix:@"-"])) {
		identified = [text hasPrefix:@"+"];
		text = [text substringFromIndex:1];
	}
	
	if ([text hasPrefix:@"\x01"]) {
		//
		// CTCP
		//
		text = [text substringFromIndex:1];
		int n = [text findString:@"\x01"];
		if (n >= 0) {
			text = [text substringToIndex:n];
		}
		
		if ([m.command isEqualToString:PRIVMSG]) {
			if ([[text uppercaseString] hasPrefix:@"ACTION "]) {
				text = [text substringFromIndex:7];
				[self receiveText:m command:ACTION text:text identified:identified];
			}
			else {
				[self receiveCTCPQuery:m text:text];
			}
		}
		else {
			[self receiveCTCPReply:m text:text];
		}
	}
	else {
		[self receiveText:m command:m.command text:text identified:identified];
	}
}

- (void)receiveText:(IRCMessage*)m command:(NSString*)cmd text:(NSString*)text identified:(BOOL)identified
{
	NSString* nick = m.sender.nick;
	NSString* target = [m paramAt:0];
	
	LogLineType type = LINE_TYPE_PRIVMSG;
	if ([cmd isEqualToString:NOTICE]) {
		type = LINE_TYPE_NOTICE;
	}
	else if ([cmd isEqualToString:ACTION]) {
		type = LINE_TYPE_ACTION;
	}
	
	if ([target hasPrefix:@"@"]) {
		target = [target substringFromIndex:1];
	}
	
	if (target.isChannelName) {
		// channel
		IRCChannel* c = [self findChannel:target];
		BOOL keyword = [self printBoth:(c ?: (id)target) type:type nick:nick text:text identified:identified];

		if (type == LINE_TYPE_NOTICE) {
			;
		}
		else {
			id t = c ?: (id)self;
			[self setUnreadState:t];
			if (keyword) [self setKeywordState:t];
		}
	}
	else if ([target isEqualNoCase:myNick]) {
		if (!nick.length || [nick contains:@"."]) {
			// system
			[self printBoth:nil type:type text:text];
		}
		else {
			// talk
			IRCChannel* c = [self findChannel:nick];
			BOOL newTalk = NO;
			if (!c && type != LINE_TYPE_NOTICE) {
				c = [world createTalk:nick client:self];
				newTalk = YES;
			}
			
			BOOL keyword = [self printBoth:(c ?: (id)target) type:type nick:nick text:text identified:identified];
			
			if (type == LINE_TYPE_NOTICE) {
				;
			}
			else {
				id t = c ?: (id)self;
				[self setUnreadState:t];
				if (keyword) [self setKeywordState:t];
				if (newTalk) [self setNewTalkState:t];
			}
		}
	}
	else {
		// system
		[self printBoth:nil type:type nick:nick text:text identified:identified];
	}
}

- (void)receiveCTCPQuery:(IRCMessage*)m text:(NSString*)text
{
	LOG(@"CTCP Query %@", text);
}

- (void)receiveCTCPReply:(IRCMessage*)m text:(NSString*)text
{
	LOG(@"CTCP Reply %@", text);
}

- (void)receiveJoin:(IRCMessage*)m
{
	NSString* nick = m.sender.nick;
	NSString* chname = [m paramAt:0];
	
	BOOL myself = [nick isEqualNoCase:myNick];

	// work around for ircd 2.9.5
	BOOL njoin = NO;
	if ([chname hasSuffix:@"\x07o"]) {
		njoin = YES;
		chname = [chname substringToIndex:chname.length - 2];
	}
	
	IRCChannel* c = [self findChannel:chname];
	
	if (myself) {
		if (!c) {
			IRCChannelConfig* seed = [[IRCChannelConfig new] autorelease];
			seed.name = chname;
			c = [world createChannel:seed client:self reload:YES adjust:YES];
			[world save];
		}
		[c activate];
		[self reloadTree];
		[self printSystem:c text:@"You have joined the channel"];
		
		if (!joinMyAddress) {
			joinMyAddress = [m.sender.address retain];
			// @@@ resolve my address
		}
	}
	
	if (c) {
		IRCUser* u = [[IRCUser new] autorelease];
		u.nick = nick;
		u.username = m.sender.user;
		u.address = m.sender.address;
		u.o = njoin;
		[c addMember:u];
		[self updateChannelTitle:c];
	}
	
	if ([Preferences showJoinLeave]) {
		NSString* text = [NSString stringWithFormat:@"%@ has joined (%@@%@)", nick, m.sender.user, m.sender.address];
		[self printBoth:(c ?: (id)chname) type:LINE_TYPE_JOIN text:text];
	}
	
	//@@@ check auto op
	
	// add user to talk
	c = [self findChannel:nick];
	if (c) {
		IRCUser* u = [[IRCUser new] autorelease];
		u.nick = nick;
		u.username = m.sender.user;
		u.address = m.sender.address;
		[c addMember:u];
	}
}

- (void)receivePart:(IRCMessage*)m
{
	NSString* nick = m.sender.nick;
	NSString* chname = [m paramAt:0];
	NSString* comment = [m paramAt:1];
	
	BOOL myself = NO;
	
	IRCChannel* c = [self findChannel:chname];
	if (c) {
		if ([nick isEqualNoCase:myNick]) {
			myself = YES;
			[c deactivate];
			[self reloadTree];
		}
		[c removeMember:nick];
		[self updateChannelTitle:c];
		// @@@ check rejoin
	}
	
	if ([Preferences showJoinLeave]) {
		NSString* text = [NSString stringWithFormat:@"%@ has left (%@)", nick, comment];
		[self printBoth:(c ?: (id)chname) type:LINE_TYPE_PART text:text];
	}
	
	if (myself) {
		[self printSystem:c text:@"You have left the channel"];
	}
}

- (void)receiveKick:(IRCMessage*)m
{
	NSString* nick = m.sender.nick;
	NSString* chname = [m paramAt:0];
	NSString* target = [m paramAt:1];
	NSString* comment = [m paramAt:1];
	
	IRCChannel* c = [self findChannel:chname];
	if (c) {
		BOOL myself = [target isEqualNoCase:myNick];
		if (myself) {
			[c deactivate];
			[self reloadTree];
			[self printSystemBoth:c text:@"You have been kicked out from the channel"];
			
			// notify event and sound
		}
		
		[c removeMember:target];
		[self updateChannelTitle:c];
		// @@@ check rejoin
	}
	
	NSString* text = [NSString stringWithFormat:@"%@ has kicked %@ (%@)", nick, target, comment];
	[self printBoth:(c ?: (id)chname) type:LINE_TYPE_KICK text:text];
}

- (void)receiveQuit:(IRCMessage*)m
{
	NSString* nick = m.sender.nick;
	NSString* comment = [m paramAt:0];
	
	NSString* text = [NSString stringWithFormat:@"%@ has left IRC (%@)", nick, comment];
	
	for (IRCChannel* c in channels) {
		if ([c findMember:nick]) {
			if ([Preferences showJoinLeave]) {
				[self printChannel:c type:LINE_TYPE_QUIT text:text];
			}
			[c removeMember:nick];
			[self updateChannelTitle:c];
			// @@@ check rejoin
		}
	}
	
	if ([Preferences showJoinLeave]) {
		[self printConsole:nil type:LINE_TYPE_QUIT text:text];
	}
}

- (void)receiveKill:(IRCMessage*)m
{
	NSString* sender = m.sender.nick;
	if (!sender || !sender.length) {
		sender = m.sender.raw;
	}
	NSString* target = [m paramAt:0];
	NSString* comment = [m paramAt:1];
	
	NSString* text = [NSString stringWithFormat:@"%@ has forced %@ to leave IRC (%@)", sender, target, comment];
	
	for (IRCChannel* c in channels) {
		if ([c findMember:target]) {
			[self printChannel:c type:LINE_TYPE_KILL text:text];
			[c removeMember:target];
			[self updateChannelTitle:c];
			// @@@ check rejoin
		}
	}
	
	if ([Preferences showJoinLeave]) {
		[self printConsole:nil type:LINE_TYPE_KILL text:text];
	}
}

- (void)receiveNick:(IRCMessage*)m
{
	NSString* nick = m.sender.nick;
	NSString* toNick = [m paramAt:0];
	
	if ([nick isEqualNoCase:myNick]) {
		// changed my nick
		[myNick release];
		myNick = [toNick retain];
		[self updateClientTitle];
		
		NSString* text = [NSString stringWithFormat:@"You are now known as %@", toNick];
		[self printChannel:nil type:LINE_TYPE_NICK text:text];
	}
	
	for (IRCChannel* c in channels) {
		if ([c findMember:nick]) {
			// rename channel member
			NSString* text = [NSString stringWithFormat:@"%@ is now known as %@", nick, toNick];
			[self printChannel:c type:LINE_TYPE_NICK text:text];
			[c renameMember:nick to:toNick];
		}
	}
	
	IRCChannel* c = [self findChannel:nick];
	if (c) {
		IRCChannel* t = [self findChannel:toNick];
		if (t) {
			// there is a channel already for a nick
			// just remove it
			[world destroyChannel:t];
		}
		
		// rename talk
		c.name = toNick;
		[self reloadTree];
		[self updateChannelTitle:c];
	}
	
	// @@@ rename nick on whois dialogs
	
	// @@@ rename nick in dcc
	
	NSString* text = [NSString stringWithFormat:@"%@ is now known as %@", nick, toNick];
	[self printConsole:nil type:LINE_TYPE_NICK text:text];
}

- (void)receiveMode:(IRCMessage*)m
{
	NSString* nick = m.sender.nick;
	NSString* target = [m paramAt:0];
	NSString* modeStr = [m sequence:1];
	
	if ([target isChannelName]) {
		// channel
		IRCChannel* c = [self findChannel:target];
		if (c) {
			BOOL prevA = c.mode.a;
			NSArray* info = [c.mode update:modeStr];
			
			if (c.mode.a != prevA) {
				if (c.mode.a) {
					IRCUser* me = [c findMember:myNick];
					[[me retain] autorelease];
					[c addMember:me];
				}
				else {
					c.whoInit = NO;
					[self send:WHO, c.name, nil];
				}
			}
			
			for (IRCModeInfo* h in info) {
				if (!h.op) continue;
				
				unsigned char mode = h.mode;
				BOOL plus = h.plus;
				NSString* t = h.param;
				
				BOOL myself = NO;
				
				if ((mode == 'q' || mode == 'a' || mode == 'o') && [myNick isEqualNoCase:t]) {
					// mode change for myself
					IRCUser* m = [c findMember:myNick];
					if (m) {
						myself = YES;
						BOOL prev = m.isOp;
						[c changeMember:myNick mode:mode value:plus];
						c.hasOp = m.isOp;
						if (!prev && c.hasOp && c.whoInit) {
							// @@@ check all auto op
						}
					}
				}
				
				if (!myself) {
					[c changeMember:t mode:mode value:plus];
				}
			}
			
			[self updateChannelTitle:c];
		}
		
		NSString* text = [NSString stringWithFormat:@"%@ has changed mode: %@", nick, modeStr];
		[self printBoth:(c ?: (id)target) type:LINE_TYPE_MODE text:text];
	}
	else {
		// user mode
		// @@@ update my mode
		NSString* text = [NSString stringWithFormat:@"%@ has changed mode: %@", nick, modeStr];
		[self printBoth:nil type:LINE_TYPE_MODE text:text];
		[self updateClientTitle];
	}
}

- (void)receiveTopic:(IRCMessage*)m
{
	NSString* nick = m.sender.nick;
	NSString* chname = [m paramAt:0];
	NSString* topic = [m paramAt:1];
	
	IRCChannel* c = [self findChannel:chname];
	if (c) {
		c.topic = topic;
		[self updateChannelTitle:c];
	}
	
	NSString* text = [NSString stringWithFormat:@"%@ has set topic: %@", nick, topic];
	[self printBoth:(c ?: (id)chname) type:LINE_TYPE_TOPIC text:text];
}

- (void)receiveInvite:(IRCMessage*)m
{
	NSString* nick = m.sender.nick;
	NSString* chname = [m paramAt:1];
	
	NSString* text = [NSString stringWithFormat:@"%@ has invited you to %@", nick, chname];
	[self printBoth:self type:LINE_TYPE_INVITE text:text];
}

- (void)receiveError:(IRCMessage*)m
{
	[self printError:m.sequence];
}

- (void)receivePing:(IRCMessage*)m
{
	[self send:PONG, [m sequence:0], nil];
}

- (void)receiveInit:(IRCMessage*)m
{
	if (loggedIn) return;
	
	[world expandClient:self];
	
	loggedIn = YES;
	tryingNick = -1;
	
	[serverHostname release];
	serverHostname = [m.sender.raw retain];
	[myNick release];
	myNick = [[m paramAt:0] retain];
	inWhois = NO;
	
	[self printSystem:self text:@"Logged in"];
	
	if (config.nickPassword.length > 0) {
		[self send:PRIVMSG, @"NickServ", [NSString stringWithFormat:@"IDENTIFY %@", config.nickPassword], nil];
	}
	
	for (NSString* s in config.loginCommands) {
		//@@@
	}
	
	for (IRCChannel* c in channels) {
		if (c.isTalk) {
			[c activate];
			
			IRCUser* m;
			m = [[IRCUser new] autorelease];
			m.nick = myNick;
			[c addMember:m];
			
			m = [[IRCUser new] autorelease];
			m.nick = c.name;
			[c addMember:m];
		}
	}
	
	[self updateClientTitle];
	[self reloadTree];
	
	NSMutableArray* ary = [NSMutableArray array];
	for (IRCChannel* c in channels) {
		if (c.isChannel && c.config.autoJoin) {
			[ary addObject:c];
		}
	}
	
	[self joinChannels:ary];
}

- (void)receiveErrorNumericReply:(IRCMessage*)m
{
	[self printErrorReply:m];
}

- (void)receiveNickCollision:(IRCMessage*)m
{
}

- (void)receiveNumericReply:(IRCMessage*)m
{
	int n = m.numericReply;
	if (400 <= n && n < 600 && n != 403 && n != 422) {
		[self receiveErrorNumericReply:m];
		return;
	}
	
	switch (n) {
		case 1:
		case 376:
		case 422:
			[self receiveInit:m];
			[self printReply:m];
			break;
		case 5:		// RPL_ISUPPORT
			[isupport update:[m sequence:1]];
			[self printReply:m];
			break;
		case 221:	// RPL_UMODEIS
		{
			NSString* modeStr = [m paramAt:1];
			
			modeStr = [modeStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			if ([modeStr isEqualToString:@"+"]) return;
			
			[myMode clear];
			[myMode update:modeStr];
			[self updateClientTitle];
			
			NSString* text = [NSString stringWithFormat:@"Mode: %@", modeStr];
			[self printBoth:nil type:LINE_TYPE_REPLY text:text];
			break;
		}
		case 290:	// RPL_CAPAB on freenode
		{
			NSString* kind = [m paramAt:1];
			kind = [kind lowercaseString];
			
			if ([kind isEqualToString:@"identify-msg"]) {
				identifyMsg = YES;
			}
			else if ([kind isEqualToString:@"identify-ctcp"]) {
				identifyCTCP = YES;
			}
			
			[self printReply:m];
			break;
		}
		//case 301:	// RPL_AWAY
		case 311:	// RPL_WHOISUSER
		{
			NSString* nick = [m paramAt:1];
			NSString* username = [m paramAt:2];
			NSString* address = [m paramAt:3];
			NSString* realname = [m paramAt:5];
			
			inWhois = YES;
			
			WhoisDialog* d = [self createWhoisDialogWithNick:nick username:username address:address realname:realname];
			if (!d) {
				NSString* text = [NSString stringWithFormat:@"%@ is %@ (%@@%@)", nick, realname, username, address];
				[self printBoth:nil type:LINE_TYPE_REPLY text:text];
			}
			break;
		}
		case 312:	// RPL_WHOISSERVER
		{
			NSString* nick = [m paramAt:1];
			NSString* server = [m paramAt:2];
			NSString* serverInfo = [m paramAt:3];
			
			if (inWhois) {
				WhoisDialog* d = [self findWhoisDialog:nick];
				if (d) {
					[d setServer:server serverInfo:serverInfo];
					return;
				}
			}
			
			NSString* text = [NSString stringWithFormat:@"%@ is on %@ (%@)", nick, server, serverInfo];
			[self printBoth:nil type:LINE_TYPE_REPLY text:text];
			break;
		}
		case 313:	// RPL_WHOISOPERATOR
		{
			NSString* nick = [m paramAt:1];
			
			if (inWhois) {
				WhoisDialog* d = [self findWhoisDialog:nick];
				if (d) {
					[d setIsOperator:YES];
					return;
				}
			}
			
			NSString* text = [NSString stringWithFormat:@"%@ is an IRC operator", nick];
			[self printBoth:nil type:LINE_TYPE_REPLY text:text];
			break;
		}
		case 317:	// RPL_WHOISIDLE
		{
			NSString* nick = [m paramAt:1];
			NSString* idleStr = [m paramAt:2];
			NSString* signOnStr = [m paramAt:3];
			
			NSString* idle = @"";
			NSString* signOn = @"";
			
			long long sec = [idleStr longLongValue];
			if (sec > 0) {
				long long min = sec / 60;
				sec %= 60;
				long long hour = min / 60;
				min %= 60;
				idle = [NSString stringWithFormat:@"%qi:%02qi:%02qi", hour, min, sec];
			}
			
			long long signOnTime = [signOnStr longLongValue];
			if (signOnTime > 0) {
				static NSDateFormatter* format = nil;
				if (!format) {
					format = [NSDateFormatter new];
					[format setDateStyle:NSDateFormatterMediumStyle];
					[format setTimeStyle:NSDateFormatterShortStyle];
					//[format setDateFormat:@"yyyy/MM/dd HH:mm"];
				}
				NSDate* date = [NSDate dateWithTimeIntervalSince1970:signOnTime];
				signOn = [format stringFromDate:date];
			}
			
			if (inWhois) {
				WhoisDialog* d = [self findWhoisDialog:nick];
				if (d) {
					[d setIdle:idle signOn:signOn];
					return;
				}
			}
			
			NSString* text;
			text = [NSString stringWithFormat:@"%@ is %@ idle", nick, idle];
			[self printBoth:nil type:LINE_TYPE_REPLY text:text];
			text = [NSString stringWithFormat:@"%@ logged in at %@", nick, signOn];
			[self printBoth:nil type:LINE_TYPE_REPLY text:text];
			break;
		}
		case 319:	// RPL_WHOISCHANNELS
		{
			NSString* nick = [m paramAt:1];
			NSString* trail = [m paramAt:2];
			
			trail = [trail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			NSArray* channelNames = [trail componentsSeparatedByString:@" "];
			
			if (inWhois) {
				WhoisDialog* d = [self findWhoisDialog:nick];
				if (d) {
					[d setChannels:channelNames];
					return;
				}
			}
			
			NSString* text = [NSString stringWithFormat:@"%@ is in %@", nick, trail];
			[self printBoth:nil type:LINE_TYPE_REPLY text:text];
			break;
		}
		//case 318:	// RPL_ENDOFWHOIS
		case 324:	// RPL_CHANNELMODEIS
		{
			NSString* chname = [m paramAt:1];
			NSString* modeStr = [m sequence:2];
			
			modeStr = [modeStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
			if ([modeStr isEqualToString:@"+"]) return;
			
			IRCChannel* c = [self findChannel:chname];
			if (c && c.isActive) {
				BOOL prevA = c.mode.a;
				[c.mode clear];
				[c.mode update:modeStr];
				
				if (c.mode.a != prevA) {
					if (c.mode.a) {
						IRCUser* me = [c findMember:myNick];
						[[me retain] autorelease];
						[c clearMembers];
						[c addMember:me];
					}
					else {
						c.whoInit = NO;
						[self send:WHO, c.name, nil];
					}
				}
				
				c.modeInit = YES;
				[self updateChannelTitle:c];
			}
			
			NSString* text = [NSString stringWithFormat:@"Mode: %@", modeStr];
			[self printBoth:(c ?: (id)chname) type:LINE_TYPE_REPLY text:text];
			break;
		}
		//case 329:	// hemp ? channel creation time
		//case 331:	// RPL_NOTOPIC
		//case 332:	// RPL_TOPIC
		//case 333:	// RPL_TOPIC_WHO_TIME
		case 353:	// RPL_NAMREPLY
		{
			NSString* chname = [m paramAt:2];
			NSString* trail = [m paramAt:3];
			
			IRCChannel* c = [self findChannel:chname];
			if (c && c.isActive && !c.namesInit) {
				NSArray* ary = [trail componentsSeparatedByString:@" "];
				for (NSString* nick in ary) {
					if (!nick.length) continue;
					UniChar u = [nick characterAtIndex:0];
					char op = ' ';
					if (u == '@' || u == '~' || u == '&' || u == '%' || u == '+') {
						op = u;
						nick = [nick substringFromIndex:1];
					}
					
					IRCUser* m = [[IRCUser new] autorelease];
					m.nick = nick;
					m.q = op == '~';
					m.a = op == '&';
					m.o = op == '@' || m.q;
					m.h = op == '%';
					m.v = op == '+';
					m.isMyself = [nick isEqualNoCase:myNick];
					[c addMember:m reload:NO];
					if ([myNick isEqualNoCase:nick]) {
						c.hasOp = (m.q || m.a | m.o);
					}
				}
				[c reloadMemberList];
				[self updateChannelTitle:c];
			}
			else {
				[self printBoth:c ?: (id)chname type:LINE_TYPE_REPLY text:[NSString stringWithFormat:@"Names: %@", trail]];
			}
			break;
		}
		case 366:	// RPL_ENDOFNAMES
		{
			NSString* chname = [m paramAt:1];
			
			IRCChannel* c = [self findChannel:chname];
			if (c && c.isActive && !c.namesInit) {
				c.namesInit = YES;
				
				if ([c numberOfMembers] <= 1 && c.hasOp) {
					// set mode if creator
					NSString* m = c.config.mode;
					if (m.length) {
						[self send:MODE, chname, m, nil];
					}
					c.modeInit = YES;
				}
				else {
					// query mode
					[self send:MODE, chname, nil];
				}
				
				if ([c numberOfMembers] <= 1 && [chname isModeChannelName]) {
					NSString* topic = c.storedTopic;
					if (!topic.length) {
						topic = c.config.topic;
					}
					if (topic.length) {
						[self send:TOPIC, chname, topic, nil];
					}
				}
				
				if ([c numberOfMembers] > 1) {
					// @@@add to who queue
				}
				else {
					c.whoInit = YES;
				}
				
				[self updateChannelTitle:c];
			}
			break;
		}
		//case 352:	// RPL_WHOREPLY
		//case 315:	// RPL_ENDOFWHO
		//case 322:	// RPL_LIST
		//case 323:	// RPL_LISTEND
		default:
			[self printUnknownReply:m];
			break;
	}
}

#pragma mark -
#pragma mark IRCConnection Delegate

- (void)changeStateOff
{
	BOOL prevConnected = connected;
	
	[conn autorelease];
	conn = nil;
	
	connecting = connected = loggedIn = quitting = NO;
	[myNick release];
	myNick = @"";
	[sentNick release];
	sentNick = @"";
	
	tryingNick = -1;
	[joinMyAddress release];
	joinMyAddress = nil;
	
	inWhois = NO;
	identifyMsg = NO;
	identifyCTCP = NO;
	
	for (IRCChannel* c in channels) {
		if (c.isActive) {
			[c deactivate];
			[self printSystem:c text:@"Disconnected"];
		}
	}
	
	[self printSystemBoth:nil text:@"Disconnected"];
	
	[self updateClientTitle];
	[self reloadTree];
	
	if (prevConnected) {
		// notifyEvent
		//[SoundPlayer play:]
	}
}

- (void)ircConnectionDidConnect:(IRCConnection*)sender
{
	[self printSystemBoth:nil text:@"Connected"];
	
	connecting = loggedIn = NO;
	connected = reconnectEnabled = YES;
	encoding = config.encoding;
	
	[inputNick autorelease];
	[sentNick autorelease];
	[myNick autorelease];
	inputNick = [config.nick retain];
	sentNick = [config.nick retain];
	myNick = [config.nick retain];
	
	[isupport reset];
	[myMode clear];
	
	int modeParam = config.invisibleMode ? 8 : 0;
	NSString* user = config.username ?: config.nick;
	NSString* realName = config.realName ?: config.nick;
	
	if (config.password.length) [self send:PASS, config.password, nil];
	[self send:NICK, sentNick, nil];
	[self send:USER, user, [NSString stringWithFormat:@"%d", modeParam], @"*", realName, nil];
	
	[self updateClientTitle];
}

- (void)ircConnectionDidDisconnect:(IRCConnection*)sender
{
	[self changeStateOff];
}

- (void)ircConnectionDidError:(NSString*)error
{
	[self printError:error];
}

- (void)ircConnectionDidReceive:(NSData*)data
{
	NSStringEncoding enc = encoding;
	if (encoding == NSUTF8StringEncoding && config.fallbackEncoding != NSUTF8StringEncoding && ![data isValidUTF8]) {
		enc = config.fallbackEncoding;
	}
	
	NSString* s = [[[NSString alloc] initWithData:data encoding:enc] autorelease];
	if (!s) {
		s = [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] autorelease];
		if (!s) return;
	}
	
	IRCMessage* m = [[[IRCMessage alloc] initWithLine:s] autorelease];
	NSString* cmd = m.command;
	
	if (m.numericReply > 0) [self receiveNumericReply:m];
	else if ([cmd isEqualToString:PRIVMSG] || [cmd isEqualToString:NOTICE]) [self receivePrivmsgAndNotice:m];
	else if ([cmd isEqualToString:JOIN]) [self receiveJoin:m];
	else if ([cmd isEqualToString:PART]) [self receivePart:m];
	else if ([cmd isEqualToString:KICK]) [self receiveKick:m];
	else if ([cmd isEqualToString:QUIT]) [self receiveQuit:m];
	else if ([cmd isEqualToString:KILL]) [self receiveKill:m];
	else if ([cmd isEqualToString:NICK]) [self receiveNick:m];
	else if ([cmd isEqualToString:MODE]) [self receiveMode:m];
	else if ([cmd isEqualToString:TOPIC]) [self receiveTopic:m];
	else if ([cmd isEqualToString:INVITE]) [self receiveInvite:m];
	else if ([cmd isEqualToString:ERROR]) [self receiveError:m];
	else if ([cmd isEqualToString:PING]) [self receivePing:m];
}

- (void)ircConnectionWillSend:(NSString*)line
{
}

@end
