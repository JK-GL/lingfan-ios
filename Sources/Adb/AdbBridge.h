#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 一条 ADB 命令的执行结果
@interface AdbResult : NSObject

/// 是否成功（C 层返回码 == 0）
@property (nonatomic, assign, readonly) BOOL success;

/// 命令输出（stdout + stderr 合流）
@property (nonatomic, copy, readonly) NSString *output;

- (instancetype)initWithSuccess:(BOOL)success output:(NSString *)output;

@end


/// libadb 的 Objective-C 封装
///
/// 底层是 adb-mobile 把官方 android-tools 编成的静态库 libadb-full.a。
/// 所有 ADB 子命令（pair / connect / install / shell / push / pull …）
/// 都通过 -runCommand: 走同一条通道，与桌面版 adb 行为逐字节一致。
@interface AdbBridge : NSObject

/// 单例。首次访问时完成 adb 运行时初始化。
@property (class, nonatomic, readonly) AdbBridge *shared;

/// adb server 监听端口，默认 15037（避开 5037，防止与其他进程冲突）
@property (nonatomic, copy, readonly) NSString *serverPort;

/// 是否已完成初始化
@property (nonatomic, assign, readonly) BOOL initialized;

/// 初始化 adb 运行时：设置 HOME、端口，并尝试拉起 in-process server。
/// 幂等，可重复调用。
- (void)initializeRuntimeIfNeeded;

/// 执行一条 adb 命令。
///
/// @param arguments 命令参数，不含 "adb" 前缀。
///                  例：@[@"connect", @"192.168.43.1:5557"]
///                      @[@"shell", @"getprop", @"ro.product.brand"]
/// @return 执行结果。底层失败时 success=NO，output 为错误信息。
- (AdbResult *)runCommand:(NSArray<NSString *> *)arguments;

/// 执行 adb 命令并把整行输出按 \n 拆成数组（自动去掉空行）
- (NSArray<NSString *> *)runCommandLines:(NSArray<NSString *> *)arguments
                                 success:(BOOL *)success;

@end

NS_ASSUME_NONNULL_END
