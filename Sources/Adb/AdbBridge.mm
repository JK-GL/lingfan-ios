#import "AdbBridge.h"

// 注意：这里刻意不 #include "adb_public.h"。
//
// 原因有两个：
// 1. 它在声明 C 函数时没有 extern "C" 保护，在 .mm 里会被按 C++ 规则
//    做名字修饰，链接时报 Undefined symbols（实测已复现）。
// 2. 它里面的 adb_set_home / adb_set_server_port / adb_enable_trace 是
//    static inline，只能在头文件所在翻译单元展开。
//
// 所以这里用 extern "C" 显式声明自己需要的 3 个真正导出符号，
// setenv 那几行在 ObjC 里直接自己写，等价且更可控。

#include <stdlib.h>

extern "C" {
/// 执行一条 adb 命令，输出写入 output_buffer（realloc 分配，调用方负责 free）
int adb_commandline_porting(char **output_buffer,
                            size_t *output_buffer_size,
                            int argc,
                            const char **argv);

/// 初始化 adb trace 子系统
void adb_trace_init_porting(char **argv);
}

// libadb 在 C 层会调用这个弱符号上报连接状态变化。
__attribute__((weak)) void adb_connect_status_updated(const char *serial, const char *status);

// ---------------------------------------------------------------------------

@implementation AdbResult

- (instancetype)initWithSuccess:(BOOL)success output:(NSString *)output {
    if ((self = [super init])) {
        _success = success;
        _output = [output copy] ?: @"";
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<AdbResult success=%d output=%@>",
            self.success, self.output];
}

@end

// ---------------------------------------------------------------------------

@interface AdbBridge ()
@property (nonatomic, copy, readwrite) NSString *serverPort;
@property (nonatomic, assign, readwrite) BOOL initialized;
/// libadb 的 C 接口不是线程安全的，所有调用必须串行化。
/// 用 NSRecursiveLock 而非 os_unfair_lock：后者作为 ivar 时
/// 结构体地址可能随对象移动而变化，属未定义行为。
@property (nonatomic, strong) NSRecursiveLock *lock;
@end

@implementation AdbBridge

+ (AdbBridge *)shared {
    static AdbBridge *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[AdbBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _serverPort = @"15037";
        _initialized = NO;
        _lock = [[NSRecursiveLock alloc] init];
        _lock.name = @"com.lingfan.adb.bridge";
    }
    return self;
}

- (void)initializeRuntimeIfNeeded {
    [self.lock lock];
    @try {
        if (self.initialized) {
            return;
        }

        // 证书与私钥落盘：libadb 会在 HOME 下写 .android/adbkey
        NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *home = documents.firstObject;
        if (home.length == 0) {
            NSLog(@"[AdbBridge] 取不到 Documents 目录，初始化失败");
            return;
        }

        NSString *androidDir = [home stringByAppendingPathComponent:@".android"];
        [[NSFileManager defaultManager] createDirectoryAtPath:androidDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];

        // 等价于 adb_public.h 里的 static inline adb_set_home / adb_set_server_port
        setenv("HOME", home.UTF8String, 1);
        setenv("ANDROID_ADB_SERVER_PORT", self.serverPort.UTF8String, 1);

        const char *traceArgv[] = { "adb" };
        adb_trace_init_porting((char **)traceArgv);

        self.initialized = YES;
        NSLog(@"[AdbBridge] 初始化完成 home=%@ port=%@", home, self.serverPort);
    } @finally {
        [self.lock unlock];
    }
}

- (AdbResult *)runCommand:(NSArray<NSString *> *)arguments {
    if (arguments.count == 0) {
        return [[AdbResult alloc] initWithSuccess:NO output:@"命令为空"];
    }

    [self initializeRuntimeIfNeeded];

    AdbResult *result = nil;
    [self.lock lock];
    @try {
        int argc = (int)arguments.count;
        const char **argv = (const char **)calloc((size_t)argc, sizeof(char *));
        if (argv == NULL) {
            result = [[AdbResult alloc] initWithSuccess:NO output:@"内存分配失败"];
        } else {
            for (int i = 0; i < argc; i++) {
                argv[i] = [arguments[(NSUInteger)i] UTF8String];
            }

            // 每次调用必须是全新 buffer：
            // capture_printf 用 realloc 追加写入，复用会串上一次输出；
            // 不复用又不 free 会内存泄漏。
            char *output = NULL;
            size_t outputSize = 0;

            int ret = adb_commandline_porting(&output, &outputSize, argc, argv);

            NSString *text = @"";
            if (output != NULL && outputSize > 0) {
                text = [NSString stringWithUTF8String:output] ?: @"";
            }
            if (output != NULL) {
                free(output);
            }
            free(argv);

            result = [[AdbResult alloc] initWithSuccess:(ret == 0) output:text];
        }
    } @finally {
        [self.lock unlock];
    }
    return result;
}

- (NSArray<NSString *> *)runCommandLines:(NSArray<NSString *> *)arguments
                                 success:(BOOL *)success {
    AdbResult *r = [self runCommand:arguments];
    if (success != NULL) {
        *success = r.success;
    }

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [r.output enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) {
            [lines addObject:trimmed];
        }
    }];
    return lines;
}

@end
