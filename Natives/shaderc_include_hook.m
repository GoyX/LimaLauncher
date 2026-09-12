// shaderc_include_hook.m — Minecraft 26.3 `#include <minecraft:...>` 展开（dlsym 层挂载）
//
// 背景：26.3 renderpearl 把 GLSL 统一编译为 SPIR-V，全部管线 shader 使用
// `#include <minecraft:fog.glsl>` 系指令，通过 LWJGL 的
// shaderc_compile_options_set_include_callbacks 上行回调（libffi upcall →
// ShaderSource.getInclude）解析。仓库内置的 libshaderc.dylib 是预编译产物，
// 该入口在其 glue 层是 no-op：回调被丢弃、源码原样进 glslang →
// "ERROR: '#include' : required extension not requested" → 必需管线全部编译失败。
//
// 为什么不在 libshaderc.dylib 里改：本仓库不构建它（Natives/resources/Frameworks
// 下为预提交二进制，Makefile 无 shaderc 目标），无法在 shim 层收口。
//
// 挂载点：LWJGL 是 dlsym 取函数指针后直接调用（不走 __la_symbol_ptr，
// fishhook 拦不住），因此与 SDL3 兼容层一样在 main_hook.m 的 hooked_dlsym
// 拦截。调用者线程即 JVM 线程，libffi upcall 在此安全。
//
// 展开器本体在 shaderc_include.c（纯 C，递归文本展开 + #line 行号恢复，
// 深度 16 / 输出 64MiB 上限；resolver 缺失时保留原行，绝不静默吞错）。
//
// 判据日志：
//   [shaderc-hook] include_callbacks resolver=... (opt=...)
//   [shaderc-hook] compile #N #include expanded: A -> B bytes

#import "shaderc_include.h"

#import <dlfcn.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

// 宿主（Darwin）的 <dlfcn.h> 已定义 RTLD_DEFAULT；本地 gcc 语法校验环境下
// 兜底，值同为 ((void *)-2)。
#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void *)-2)
#endif

// main_hook.m 保存的原始 dlsym（fishhook 重绑定前）。必须用它解析真实实现，
// 否则会递归回 hooked_dlsym。
extern void *(*orig_dlsym)(void *handle, const char *name);

#pragma mark - 跨引擎编译总锁（对齐 Air a09e0201 + Task 37/2613e416）

// 设备实证（latestlog 2026-09-12 19:59，hs_err：libshaderc.dylib+0x155820
// TGlslangToSpvTraverser::visitAggregate+0x58，constArray 指针字段被 ASCII
// 覆盖 = freed-then-reused pool memory）：资源重载窗口内 shaderc 编译与
// MobileGlues 的 GLSL->ESSL 转换并发运行，两套内嵌 glslang 的进程级解析
// 状态（内建符号表/内存池）互相踩踏 —— 同款崩溃自 MG 2.0.1 起在 arm64
// 真机上反复出现。修复与 Air 一致：三把独立锁收敛为一把跨库总锁 ——
//   * 本层（shaderc 编译入口 + compiler/options 生命周期）全部持锁；
//   * MobileGlues 的 GLSLtoGLSLES_2 在转换全程通过协商拿到同一把锁
//     （glsl_for_es.cpp 侧 dlsym("ame_master_compile_lock")）；
//   * 锁序单向（MG g_conv_serial -> master；本层从不拿 g_conv_serial），
//     无环。递归锁允许未来可重入路径退化为串行而非死锁。
static pthread_mutex_t ame_master_lock_storage;

__attribute__((constructor))
static void ame_shaderc_hook_init(void) {
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&ame_master_lock_storage, &attr);
    pthread_mutexattr_destroy(&attr);
}

// 协商入口：MobileGlues 的 GLSLtoGLSLES_2 运行时 dlsym 本符号，与本层的
// 编译/生命周期共用同一把递归互斥锁。返回值恒非 NULL；MG 侧协商失败时
// 退回自身本地锁，不影响本层行为。visibility default 确保主二进制导出。
__attribute__((visibility("default")))
pthread_mutex_t *ame_master_compile_lock(void) {
    return &ame_master_lock_storage;
}

// 生命周期类入口（release/destroy）的锁助手：无竞争快速路径静默持锁；
// 必须等待在飞编译时打取证日志（下一轮日志可据此证实/排除 release-vs-
// compile 竞争 —— Air a09e0201 的验证字符串）。
static void ame_master_lock_logged(const char *who, void *arg) {
    if (pthread_mutex_trylock(&ame_master_lock_storage) == 0) return;
    fprintf(stderr,
            "[shaderc-hook] %s(%p) BLOCKED behind in-flight compile -- waiting "
            "(lifecycle serialized against pool UAF)\n", who, arg);
    pthread_mutex_lock(&ame_master_lock_storage);
}

#pragma mark - options → callbacks 映射表

// MC 对每个管线编译都会新建 options 并设置 resolver；同一时刻活跃数量远小于
// 此值。表满时复用最旧槽位（最坏情况退化为"找不到 resolver → 原样透传"，
// 与今日行为一致，不会变糟）。
#define AME_SHADERC_OPTS_MAX 64

typedef struct {
    void *options;
    void *resolver;
    void *releaser;
    void *user_data;
    int used;
} ame_shaderc_opt_t;

static ame_shaderc_opt_t g_opts[AME_SHADERC_OPTS_MAX];
static pthread_mutex_t g_opts_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_opts_cursor = 0;

// create=1 时若无空槽则抢占最旧槽位（地址复用防御：新槽一律先清零）
static ame_shaderc_opt_t *ame_shaderc_opt_slot(void *options, int create) {
    if (options == NULL) return NULL;
    ame_shaderc_opt_t *victim = NULL;
    for (int i = 0; i < AME_SHADERC_OPTS_MAX; i++) {
        ame_shaderc_opt_t *e = &g_opts[i];
        if (e->used && e->options == options) return e;
        if (!e->used && victim == NULL) victim = e;
    }
    if (!create) return NULL;
    if (victim == NULL) {
        victim = &g_opts[g_opts_cursor % AME_SHADERC_OPTS_MAX];
        g_opts_cursor++;
    }
    memset(victim, 0, sizeof *victim);
    victim->options = options;
    victim->used = 1;
    return victim;
}

static void ame_shaderc_opt_drop(void *options) {
    if (options == NULL) return;
    for (int i = 0; i < AME_SHADERC_OPTS_MAX; i++) {
        if (g_opts[i].used && g_opts[i].options == options) {
            memset(&g_opts[i], 0, sizeof g_opts[i]);
            return;
        }
    }
}

#pragma mark - 真实实现解析

// libshaderc.dylib 的句柄：首次命中 shaderc_* 查询时记下。必须用它解析真实
// 实现——若该库以 RTLD_LOCAL 加载（本仓库对 libmobileglues.dylib 就是如此），
// RTLD_DEFAULT 会解析不到，导致整条链路静默失效。
static void *g_shaderc_handle = NULL;

static void *ame_shaderc_real(const char *name) {
    if (orig_dlsym == NULL) return NULL;
    void *p = NULL;
    if (g_shaderc_handle != NULL) p = orig_dlsym(g_shaderc_handle, name);
    if (p == NULL) p = orig_dlsym(RTLD_DEFAULT, name); // 回退：全局符号表
    return p;
}

#pragma mark - 拦截：options 生命周期

// 不转发给 impl：include 语义已在本层收口，impl 收到的是展开后的干净源码。
// （与 Air Task 47 一致，真机验证通过。）
static void ame_shaderc_compile_options_set_include_callbacks(void *options,
                                                              void *resolver,
                                                              void *result_releaser,
                                                              void *user_data) {
    pthread_mutex_lock(&g_opts_lock);
    ame_shaderc_opt_t *e = ame_shaderc_opt_slot(options, 1);
    if (e != NULL) {
        e->resolver = resolver;
        e->releaser = result_releaser;
        e->user_data = user_data;
    }
    pthread_mutex_unlock(&g_opts_lock);
    fprintf(stderr, "[shaderc-hook] include_callbacks resolver=%p releaser=%p ud=%p (opt=%p)\n",
            resolver, result_releaser, user_data, options);
}

// MC 可能克隆 options：克隆体必须继承回调，否则展开器找不到 resolver。
// Task 36/Air a09e0201：clone 也并入总锁（impl 的 options 浅拷贝与在飞
// 编译共享 impl 私有状态）。
static void *ame_shaderc_compile_options_clone(void *options) {
    void *real = ame_shaderc_real("shaderc_compile_options_clone");
    if (real == NULL) return NULL;
    pthread_mutex_lock(&ame_master_lock_storage);
    void *copy = ((void *(*)(void *))real)(options);
    if (copy != NULL && copy != options) {
        pthread_mutex_lock(&g_opts_lock);
        ame_shaderc_opt_t *src = ame_shaderc_opt_slot(options, 0);
        if (src != NULL) {
            ame_shaderc_opt_t *dst = ame_shaderc_opt_slot(copy, 1);
            if (dst != NULL) {
                dst->resolver = src->resolver;
                dst->releaser = src->releaser;
                dst->user_data = src->user_data;
            }
        }
        pthread_mutex_unlock(&g_opts_lock);
    }
    pthread_mutex_unlock(&ame_master_lock_storage);
    return copy;
}

// 释放即清表：防止 options 地址被复用后命中过期回调。
// release 并入总锁（Air a09e0201 的 lifecycle 修复：options/compiler 结构
// 被在飞编译引用时释放 = 本次 pool UAF 家族的直接成因）。
// 锁序统一为 master -> g_opts_lock（与 clone 一致），杜绝死锁环。
static void ame_shaderc_compile_options_release(void *options) {
    ame_master_lock_logged("shaderc_compile_options_release", options);
    pthread_mutex_lock(&g_opts_lock);
    ame_shaderc_opt_drop(options);
    pthread_mutex_unlock(&g_opts_lock);
    void *real = ame_shaderc_real("shaderc_compile_options_release");
    if (real != NULL) ((void (*)(void *))real)(options);
    pthread_mutex_unlock(&ame_master_lock_storage);
}

#pragma mark - 拦截：编译入口

typedef void *(*ame_shaderc_compile_fn)(void *compiler, const char *source, size_t source_size,
                                        int kind, const char *input_file, const char *entry_point,
                                        void *options);

static void *ame_shaderc_compile_dispatch(const char *name, void *compiler, const char *source,
                                          size_t source_size, int kind, const char *input_file,
                                          const char *entry_point, void *options) {
    ame_shaderc_compile_fn real = (ame_shaderc_compile_fn)ame_shaderc_real(name);
    if (real == NULL) return NULL;

    char *expanded = NULL;
    size_t expanded_len = 0;
    int logged = 0;

    if (source != NULL && source_size > 0 &&
        ame_source_has_include(source, source_size)) {
        ame_include_resolver_fn resolver = NULL;
        ame_include_releaser_fn releaser = NULL;
        void *ud = NULL;
        pthread_mutex_lock(&g_opts_lock);
        ame_shaderc_opt_t *e = ame_shaderc_opt_slot(options, 0);
        if (e != NULL) {
            resolver = (ame_include_resolver_fn)e->resolver;
            releaser = (ame_include_releaser_fn)e->releaser;
            ud = e->user_data;
        }
        pthread_mutex_unlock(&g_opts_lock);

        if (resolver != NULL) {
            expanded = ame_include_expand(source, source_size, input_file, resolver, ud,
                                          releaser, ud, &expanded_len);
            if (expanded != NULL) {
                source = expanded;
                source_size = expanded_len;
                logged = 1;
            }
        } else {
            // 有 #include 却没登记回调：原样透传，impl 会给出可见诊断
            fprintf(stderr,
                    "[shaderc-hook] %s: source has #include but no resolver (opt=%p) -- "
                    "passing through\n", name, options);
        }
    }

    // 真实编译持总锁（Air Task 37：与 MG 转换、lifecycle 入口全串行）。
    // include 文本展开在锁外完成（纯文本处理 + 只读 resolver，缩短持锁时长；
    // 展开期间绝不请求 master，锁序 g_opts_lock 不升级，无死锁环）。
    pthread_mutex_lock(&ame_master_lock_storage);
    void *result = real(compiler, source, source_size, kind, input_file, entry_point, options);
    pthread_mutex_unlock(&ame_master_lock_storage);

    if (logged) {
        fprintf(stderr, "[shaderc-hook] %s #include expanded: %zu -> %zu bytes\n",
                name, expanded_len == 0 ? (size_t)0 : expanded_len, expanded_len);
    }
    if (expanded != NULL) free(expanded);
    return result;
}

static void *ame_shaderc_compile_into_spv(void *compiler, const char *source, size_t source_size,
                                          int kind, const char *input_file,
                                          const char *entry_point, void *options) {
    return ame_shaderc_compile_dispatch("shaderc_compile_into_spv", compiler, source, source_size,
                                        kind, input_file, entry_point, options);
}

static void *ame_shaderc_compile_into_spv_assembly(void *compiler, const char *source,
                                                   size_t source_size, int kind,
                                                   const char *input_file,
                                                   const char *entry_point, void *options) {
    return ame_shaderc_compile_dispatch("shaderc_compile_into_spv_assembly", compiler, source,
                                        source_size, kind, input_file, entry_point, options);
}

static void *ame_shaderc_compile_into_preprocessed_text(void *compiler, const char *source,
                                                        size_t source_size, int kind,
                                                        const char *input_file,
                                                        const char *entry_point, void *options) {
    return ame_shaderc_compile_dispatch("shaderc_compile_into_preprocessed_text", compiler, source,
                                        source_size, kind, input_file, entry_point, options);
}

#pragma mark - 拦截：compiler/options 生命周期（Air a09e0201）

// shaderc_compiler_release 在最后一个 compiler 上触发 glslang::FinalizeProcess
// （拆全局符号表 + 内存池）；与在飞编译并发 = 池被释放后复用 = visitAggregate
// 读到 ASCII 的 pool UAF（本次 hs_err 的直接机理）。initialize/release/
// options_initialize/add_macro_definition 全部并入总锁 —— lifecycle 与编译
// 彻底串行，资源重载的「旧管线 release 竞速新管线 compile」窗口归零。
static void *ame_shaderc_compiler_initialize(void) {
    void *real = ame_shaderc_real("shaderc_compiler_initialize");
    if (real == NULL) return NULL;
    pthread_mutex_lock(&ame_master_lock_storage);
    void *compiler = ((void *(*)(void))real)();
    pthread_mutex_unlock(&ame_master_lock_storage);
    return compiler;
}

static void ame_shaderc_compiler_release(void *compiler) {
    ame_master_lock_logged("shaderc_compiler_release", compiler);
    void *real = ame_shaderc_real("shaderc_compiler_release");
    if (real != NULL) ((void (*)(void *))real)(compiler);
    pthread_mutex_unlock(&ame_master_lock_storage);
}

static void *ame_shaderc_compile_options_initialize(void) {
    void *real = ame_shaderc_real("shaderc_compile_options_initialize");
    if (real == NULL) return NULL;
    pthread_mutex_lock(&ame_master_lock_storage);
    void *options = ((void *(*)(void))real)();
    pthread_mutex_unlock(&ame_master_lock_storage);
    return options;
}

// 真实签名 5 参、返回 void：shaderc_compile_options_add_macro_definition(
//   options, name, name_length, value, value_length)
// 上一版误声明为 3 参（漏掉两个 size_t 长度参数），调用点传 5 参 →
// clang "too many arguments to function call"，Build for ios 直接失败。
typedef void (*ame_shaderc_add_macro_fn)(void *options, const char *name, size_t name_length,
                                         const char *value, size_t value_length);

static void ame_shaderc_compile_options_add_macro_definition(void *options, const char *name,
                                                             size_t name_length, const char *value,
                                                             size_t value_length) {
    void *real = ame_shaderc_real("shaderc_compile_options_add_macro_definition");
    if (real == NULL) return;
    pthread_mutex_lock(&ame_master_lock_storage);
    ((ame_shaderc_add_macro_fn)real)(options, name, name_length, value, value_length);
    pthread_mutex_unlock(&ame_master_lock_storage);
}

#pragma mark - hooked_dlsym 入口

// 返回非 NULL 表示该符号已接管；供 main_hook.m 的 hooked_dlsym 调用。
void *ame_shaderc_hook_resolve(void *handle, const char *name) {
    if (name == NULL || strncmp(name, "shaderc_", 8) != 0) return NULL;
    if (g_shaderc_handle == NULL && handle != NULL) g_shaderc_handle = handle;
    if (strcmp(name, "shaderc_compile_options_set_include_callbacks") == 0) {
        return (void *)ame_shaderc_compile_options_set_include_callbacks;
    }
    if (strcmp(name, "shaderc_compile_options_clone") == 0) {
        return (void *)ame_shaderc_compile_options_clone;
    }
    if (strcmp(name, "shaderc_compile_options_release") == 0) {
        return (void *)ame_shaderc_compile_options_release;
    }
    // 编译入口：真实实现缺失时一律不接管（返回 NULL → LWJGL 看到与今日
    // 完全相同的结果），绝不返回无法工作的包装函数。
    if (strcmp(name, "shaderc_compile_into_spv") == 0) {
        return ame_shaderc_real(name) ? (void *)ame_shaderc_compile_into_spv : NULL;
    }
    if (strcmp(name, "shaderc_compile_into_spv_assembly") == 0) {
        return ame_shaderc_real(name) ? (void *)ame_shaderc_compile_into_spv_assembly : NULL;
    }
    if (strcmp(name, "shaderc_compile_into_preprocessed_text") == 0) {
        return ame_shaderc_real(name) ? (void *)ame_shaderc_compile_into_preprocessed_text : NULL;
    }
    // 生命周期入口（Air a09e0201）：并入总锁，lifecycle-vs-compile 串行。
    if (strcmp(name, "shaderc_compiler_initialize") == 0) {
        return ame_shaderc_real(name) ? (void *)ame_shaderc_compiler_initialize : NULL;
    }
    if (strcmp(name, "shaderc_compiler_release") == 0) {
        return ame_shaderc_real(name) ? (void *)ame_shaderc_compiler_release : NULL;
    }
    if (strcmp(name, "shaderc_compile_options_initialize") == 0) {
        return ame_shaderc_real(name) ? (void *)ame_shaderc_compile_options_initialize : NULL;
    }
    if (strcmp(name, "shaderc_compile_options_add_macro_definition") == 0) {
        return ame_shaderc_real(name) ? (void *)ame_shaderc_compile_options_add_macro_definition : NULL;
    }
    return NULL;
}
