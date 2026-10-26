//
//  LibboxPlatform.h
//  sing-box（libbox）在 iOS 网络扩展里的平台接口实现。
//
// 为什么用 Objective-C 而不是 Swift：gomobile 生成的框架里，
// `LibboxPlatformInterface` 既有同名 @protocol 又有同名 @class，Swift 侧
// 无法干净地区分（会报 Multiple inheritance），且部分方法被 Swift 自动
// 重命名（writeConnectionEvents → write(_:) 等）。ObjC 里 @protocol 的
// 语义是明确的，方法名与头文件逐字对应，不会出现 override/rename 歧义。
//

#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import <Libbox/Libbox.h>

NS_ASSUME_NONNULL_BEGIN

/// 平台接口实现：内核要建 TUN 时把 `tunnelFd` 交回去。
@interface MBoxPlatformImpl : NSObject <LibboxPlatformInterface>

/// 隧道 fd（socketpair 用户态桥的一端），由扩展在启动前设置。
@property (nonatomic, assign) int32_t tunnelFd;

/// 诊断日志回调（由扩展注入，避免 ObjC 侧直接依赖 Swift 的 TunnelDiag）。
@property (nonatomic, copy, nullable) void (^logger)(NSString *message);

@end

/// CommandServerHandler：内核启停 / 系统代理状态回调。
@interface MBoxServerHandlerImpl : NSObject <LibboxCommandServerHandler>

@property (nonatomic, copy, nullable) void (^onStop)(void);
@property (nonatomic, copy, nullable) void (^onReload)(void);
@property (nonatomic, copy, nullable) void (^logger)(NSString *message);

@end

/// CommandClientHandler：订阅内核日志（CommandLog）。
@interface MBoxClientHandlerImpl : NSObject <LibboxCommandClientHandler>

/// 收到内核日志行（已按行拼接好，直接写共享日志文件）
@property (nonatomic, copy, nullable) void (^onLogLines)(NSString *lines);

@end

NS_ASSUME_NONNULL_END
