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
#import <string.h>

// main_hook.m 保存的原始 dlsym（fishhook 重绑定前）。必须用它解析真实实现，
// 否则会递归回 hooked_dlsym。
extern void *(*orig_dlsym)(void *handle, const char *name);

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

static void *ame_shaderc_real(const char *name) {
    if (orig_dlsym == NULL) return NULL;
    // RTLD_DEFAULT：libshaderc.dylib 已加载，按全局符号表解析即可
    return orig_dlsym(RTLD_DEFAULT, name);
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

// MC 可能克隆 options：克隆体必须继承回调，否则展开器找不到 resolver
static void *ame_shaderc_compile_options_clone(void *options) {
    void *real = ame_shaderc_real("shaderc_compile_options_clone");
    if (real == NULL) return NULL;
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
    return copy;
}

// 释放即清表：防止 options 地址被复用后命中过期回调
static void ame_shaderc_compile_options_release(void *options) {
    pthread_mutex_lock(&g_opts_lock);
    ame_shaderc_opt_drop(options);
    pthread_mutex_unlock(&g_opts_lock);
    void *real = ame_shaderc_real("shaderc_compile_options_release");
    if (real != NULL) ((void (*)(void *))real)(options);
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

    void *result = real(compiler, source, source_size, kind, input_file, entry_point, options);

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

#pragma mark - hooked_dlsym 入口

// 返回非 NULL 表示该符号已接管；供 main_hook.m 的 hooked_dlsym 调用。
void *ame_shaderc_hook_resolve(void *handle, const char *name) {
    if (name == NULL) return NULL;
    if (strcmp(name, "shaderc_compile_options_set_include_callbacks") == 0) {
        return (void *)ame_shaderc_compile_options_set_include_callbacks;
    }
    if (strcmp(name, "shaderc_compile_options_clone") == 0) {
        return (void *)ame_shaderc_compile_options_clone;
    }
    if (strcmp(name, "shaderc_compile_options_release") == 0) {
        return (void *)ame_shaderc_compile_options_release;
    }
    if (strcmp(name, "shaderc_compile_into_spv") == 0) {
        return (void *)ame_shaderc_compile_into_spv;
    }
    if (strcmp(name, "shaderc_compile_into_spv_assembly") == 0) {
        return (void *)ame_shaderc_compile_into_spv_assembly;
    }
    if (strcmp(name, "shaderc_compile_into_preprocessed_text") == 0) {
        return (void *)ame_shaderc_compile_into_preprocessed_text;
    }
    return NULL;
}
