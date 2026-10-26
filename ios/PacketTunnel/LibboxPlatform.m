#import "LibboxPlatform.h"

static NSError *MBoxError(NSString *message) {
    return [NSError errorWithDomain:@"mbox" code:-1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation MBoxPlatformImpl

- (BOOL)openTun:(id<LibboxTunOptions>)options
         ret0_:(int32_t *)ret0_
          error:(NSError **)error {
    if (self.tunnelFd < 0) {
        if (error) *error = MBoxError(@"openTun: 还没有隧道 fd");
        return NO;
    }
    if (ret0_) *ret0_ = self.tunnelFd;
    if (self.logger) {
        self.logger([NSString stringWithFormat:@"openTun: 交出 fd=%d mtu=%d autoRoute=%d",
                     self.tunnelFd, [options getMTU], [options getAutoRoute] ? 1 : 0]);
    }
    return YES;
}

// iOS 上没有 protect()：靠 socketpair + 配置里的 default_interface 防自环
- (BOOL)autoDetectInterfaceControl:(int32_t)fd error:(NSError **)error { return YES; }

- (BOOL)usePlatformAutoDetectInterfaceControl { return NO; }
- (BOOL)underNetworkExtension { return YES; }
- (BOOL)includeAllNetworks { return NO; }
- (BOOL)usePlatformBridge { return NO; }
- (BOOL)usePlatformShell { return NO; }

- (void)clearDNSCache {}
- (LibboxWIFIState *)readWIFIState { return nil; }
- (id<LibboxLocalDNSTransport>)localDNSTransport { return nil; }
- (id<LibboxNetworkInterfaceIterator>)getInterfaces:(NSError **)error { return nil; }

- (BOOL)startDefaultInterfaceMonitor:(id<LibboxInterfaceUpdateListener>)listener
                               error:(NSError **)error { return NO; }
- (BOOL)closeDefaultInterfaceMonitor:(id<LibboxInterfaceUpdateListener>)listener
                               error:(NSError **)error { return NO; }
- (BOOL)startNeighborMonitor:(id<LibboxNeighborUpdateListener>)listener
                       error:(NSError **)error { return NO; }
- (BOOL)closeNeighborMonitor:(id<LibboxNeighborUpdateListener>)listener
                       error:(NSError **)error { return NO; }

- (BOOL)sendNotification:(LibboxNotification *)notification error:(NSError **)error { return NO; }
- (BOOL)cancelNotification:(NSString *)identifier
                    typeID:(int32_t)typeID
                     error:(NSError **)error { return NO; }

- (LibboxConnectionOwner *)findConnectionOwner:(int32_t)ipProtocol
                                 sourceAddress:(NSString *)sourceAddress
                                   sourcePort:(int32_t)sourcePort
                            destinationAddress:(NSString *)destinationAddress
                              destinationPort:(int32_t)destinationPort
                                        error:(NSError **)error { return nil; }

- (BOOL)checkPlatformShell:(NSError **)error { return NO; }

- (id<LibboxShellSession>)openShellSession:(LibboxPlatformUser *)user
                                  command:(NSString *)command
                                  environ:(id<LibboxStringIterator>)environ
                                     term:(NSString *)term
                                     rows:(int32_t)rows
                                     cols:(int32_t)cols
                                    error:(NSError **)error {
    if (error) *error = MBoxError(@"iOS: shell session not supported");
    return nil;
}

- (id<LibboxBridgeSession>)createBridge:(LibboxBridgeOptions *)options
                                 error:(NSError **)error {
    if (error) *error = MBoxError(@"iOS: bridge not supported");
    return nil;
}

- (LibboxPlatformUser *)lookupUser:(NSString *)username error:(NSError **)error { return nil; }

- (NSString *)lookupSFTPServer:(NSError **)error {
    if (error) *error = MBoxError(@"iOS: sftp not supported");
    return @"";
}

- (NSString *)readSystemSSHHostKey:(NSError **)error {
    if (error) *error = MBoxError(@"iOS: ssh host key not supported");
    return @"";
}

- (NSString *)tailscaleHostname { return @""; }

- (void)registerMyInterface:(NSString *)name {}

@end

@implementation MBoxServerHandlerImpl

- (BOOL)serviceReload:(NSError **)error {
    if (self.onReload) self.onReload();
    return YES;
}

- (BOOL)serviceStop:(NSError **)error {
    if (self.onStop) self.onStop();
    return YES;
}

- (LibboxSystemProxyStatus *)getSystemProxyStatus:(NSError **)error {
    LibboxSystemProxyStatus *status = [[LibboxSystemProxyStatus alloc] init];
    status.available = NO;
    status.enabled = NO;
    return status;
}

- (BOOL)setSystemProxyEnabled:(BOOL)enabled error:(NSError **)error { return YES; }

- (void)writeDebugMessage:(NSString *)message {
    if (message.length > 0 && self.logger) self.logger(message);
}

- (BOOL)connectSSHAgent:(int32_t *)ret0_ error:(NSError **)error { return NO; }

- (BOOL)triggerNativeCrash:(NSError **)error { return NO; }

@end

@implementation MBoxClientHandlerImpl

- (void)clearLogs {}
- (void)connected {}
- (void)disconnected:(NSString *)message {
    if (message.length > 0 && self.onLogLines) {
        self.onLogLines([NSString stringWithFormat:@"[app] 日志通道断开: %@\n", message]);
    }
}

- (void)initializeClashMode:(id<LibboxStringIterator>)modeList currentMode:(NSString *)currentMode {}
- (void)setDefaultLogLevel:(int32_t)level {}
- (void)updateClashMode:(NSString *)newMode {}
- (void)writeConnectionEvents:(LibboxConnectionEvents *)events {}
- (void)writeGroups:(id<LibboxOutboundGroupIterator>)message {}
- (void)writeOutbounds:(id<LibboxOutboundGroupItemIterator>)message {}
- (void)writeStatus:(LibboxStatusMessage *)message {}

- (void)writeLogs:(id<LibboxLogIterator>)messageList {
    if (!messageList || !self.onLogLines) return;
    NSMutableString *buf = [NSMutableString string];
    while ([messageList hasNext]) {
        LibboxLogEntry *entry = [messageList next];
        if (entry.message.length > 0) {
            [buf appendString:entry.message];
            [buf appendString:@"\n"];
        }
    }
    if (buf.length > 0) self.onLogLines(buf);
}

@end
