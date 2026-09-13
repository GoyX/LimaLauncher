#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <string.h>
#include <stdatomic.h>
#include <unistd.h>
#include <time.h>
#include "bridge_tbl.h"
#include "environ.h"
#include "gl_bridge.h"
#include "utils.h"

// MobileGlues 运行时使用的 EGL：打包在 App Frameworks 下的 libEGL.framework。
// 与 Natives/external/MobileGlues/src/main/cpp/external/libEGL.framework 对应。
// 已核对：该镜像导出 dlsym_EGL() 需要的全部 18 个 egl* 符号。
#define AME_EGL_FRAMEWORK_PATH "libEGL.framework/libEGL"

// 由 Natives/SurfaceViewController.m 提供，用于修正 SDL3 嵌入导致的 OpenGL 后端黑屏。
// 详见下方 gl_init_context() 中的说明。GLFW 路径（1.21.1 等）下两者均为空操作。
extern BOOL Amethyst_RestoreGameSurfaceVisibility(void);
extern CALayer *Amethyst_SDL3RenderLayer(void);

// SDL3（MC 26.3+）路径下：GL 拥有呈现层（CAMetalLayer），且 MC 以「点」回报
// 窗口尺寸 / 设置 viewport（iPhone X 上 812x375）。由 gl_init_context() 在建
// EGL surface 之前置位；SurfaceViewController.updateSavedResolution 查询它来
// 决定 CAMetalLayer 是否对齐 1x。GLFW 路径（1.21.1，MC 用像素）与 Vulkan
// 路径（MoltenVK 自管 swapchain）恒为 NO，行为完全不变。
static BOOL g_ame_sdl3_points_surface = NO;
BOOL Amethyst_SDL3SurfaceWantsPoints(void) {
    // Air Task 60（664f58a3）定案：本函数代表的「1x 点数对齐」（Task 50）已退役，
    // 恒返回 NO 让 1x 分支全部走不通。
    //
    // 1x 钉扎（contentsScale=1.0、drawableSize=bounds 点数）把 EGL surface 压到
    // 812x375，CoreAnimation 线性放大 3x 到物理屏 -> 全屏模糊；更糟的是它与
    // sdl3_hook 的 resize nudge / Task61 像素口径每帧拉锯（日志实证：
    // "auto resize nudge: viewport 812x375 -> 2436x1125" 与 1x align 互推）。
    // Air 原文结论：「别走 1x 弯路」，直接按物理像素统一：
    //     drawableSize  = windowWidth x windowHeight（像素）
    //     contentsScale = screenScale x resolutionScale（宿主原生值，不覆盖）
    // MC 侧窗口尺寸改由 Task61 三路统一收敛到像素（SDL_GetWindowSize /
    // SDL_GetWindowSizeInPixels / 窗口尺寸事件），surface==viewport==物理像素。
    // GLFW 路径与 Vulkan 路径本来恒为 NO，行为完全不变。
    return NO;
}

static EGLDisplay g_EglDisplay;
static egl_library handle;

static void* load_egl_symbol(void *dl_handle, const char *symbol) {
    dlerror();
    void *addr = dlsym(dl_handle, symbol);
    const char *error = dlerror();
    if (!addr || error) {
        NSLog(@"EGLBridge: failed to resolve %s: %s", symbol, error ?: "symbol not found");
    }
    return addr;
}

// ============================================================================
// Task 36（对齐 Air bec59b40，本轮为逐字重移植）：MobileGlues 前端 EGL 生命周期路由
//
// 问题（Air 设备实测 latestlog e28e4c3 + 本仓库架构同构）：MobileGlues 的
// EGL 符号全部从 libEGL.framework（raw ANGLE）解析 —— 上下文创建/MakeCurrent
// 完全绕过了 MobileGlues 的前端 EGL。MGContext 虚拟上下文记录（MG 前端
// egl/context.cpp）只能由**前端** eglCreateContext 创建、由**前端**
// eglMakeCurrent 绑定（g_current_ctx + mg_framebuffer_bind_context +
// gl_state 重指向）。被绕过时 mg_context_make_current 走「handle is not
// tracked」分支 —— g_current_ctx 恒为 NULL，FBO 转译 / 状态机 / 每上下文
// 子系统全部退化到进程级回退实例。渲染照常发生（Air 实测 fps=57~58、
// 485 次 eglSwapBuffers 全成功、零 GL 错误），但 MC 26.3 RenderPearl 的
// 合成画面进不了默认帧缓冲 —— eglSwapBuffers 以满帧率呈现从未被画过的黑帧。
//
// 修复（Air 原文结构）：六个生命周期入口（eglBindAPI / eglCreateContext /
// eglDestroyContext / eglMakeCurrent / eglSwapBuffers / eglSwapInterval）
// 改经 libmobileglues.dylib 的前端 EGL；基础设施（display / config /
// surface / GetProcAddress）留在 raw ANGLE —— 前端对它们本就是透传，且
// MG 后端句柄（load_libs 的 __APPLE__ 分支）绑定的正是同一份
// libEGL.framework / libGLESv2.framework，两侧指向同一个 ANGLE 实例，
// display/config 句柄天然互通。
//
// 引导（与 Air 逐字同构）：在首个前端调用之前，用 raw ANGLE 建一个 16x16
// pbuffer + 临时 ES3 上下文 → eglMakeCurrent → 调 mg_init_gles() → 释放
// 临时资源 → 再把生命周期指针切换到前端。mg_init_gles 的核心价值是让
// caps 检测（set_hardware / set_es_version 经 glGetString 等真实查询）
// 发生在"有当前上下文"的正确环境里 —— 静态构造（proc_init）运行时进程里
// 没有任何当前上下文，彼时测得的 caps 不可靠。本仓库 vendored 的
// MG 2.0.1-dev 原本没有该入口，已在本仓库源码（MobileGlues-cpp/main.cpp）
// 按 fork 2.0.16 同名语义补齐（幂等、一次性）。
//
// 时序约束（Air 原文）：前端函数内部的 LOAD_EGL 静态指针是首次调用时
// 一次性初始化的，后端句柄 `egl` 由 load_libs 的 __APPLE__ 分支绑定
// （静态构造时已执行）；引导确保首个前端调用发生在句柄绑定之后。
// 引导失败则保持旧行为（全 raw ANGLE），不引入新风险。
//
// 切换时机（与 Air 相同）：gl_init_context 里 eglChooseConfig 之后、
// eglBindAPI / eglCreateContext 之前。
// ============================================================================
static void *ame_mg_handle = NULL;        // libmobileglues.dylib（前端 EGL/GL）
static void *ame_mg_angle_handle = NULL;  // libEGL.framework（raw ANGLE 垫片）
static BOOL  ame_mgFrontendActive = NO;   // 生命周期函数已切到前端
static BOOL  ame_mgBootstrapTried = NO;   // 引导只尝试一次

typedef void (*ame_mg_init_gles_t)(void);
static ame_mg_init_gles_t ame_mg_init_gles = NULL;

// 引导专用 raw ANGLE 指针（不进 handle 表：仅 bootstrap + 取证使用）
typedef EGLSurface (*ame_fn_create_pbuffer)(EGLDisplay, EGLConfig, const EGLint *);
typedef EGLBoolean (*ame_fn_egl_query_surface)(EGLDisplay, EGLSurface, EGLint, EGLint *);
static ame_fn_create_pbuffer       ame_raw_create_pbuffer = NULL;
static ame_fn_egl_query_surface    ame_raw_query_surface = NULL;
static PFNEGLCREATECONTEXTPROC     ame_raw_create_context = NULL;
static PFNEGLMAKECURRENTPROC       ame_raw_make_current = NULL;
static PFNEGLDESTROYCONTEXTPROC    ame_raw_destroy_context = NULL;
static PFNEGLDESTROYSURFACEPROC    ame_raw_destroy_surface = NULL;

// 只应在 gl_init_context（eglChooseConfig 之后、eglBindAPI/eglCreateContext 之前）
// 调用一次。返回 YES 表示生命周期 EGL 已切换到 MobileGlues 前端。
static BOOL ame_mgBootstrap(EGLDisplay dpy, EGLConfig config) {
    if (ame_mgBootstrapTried) return ame_mgFrontendActive;
    ame_mgBootstrapTried = YES;

    if (ame_mg_handle == NULL || ame_mg_init_gles == NULL) {
        NSLog(@"[MG-Bridge] bootstrap skipped: frontend image or mg_init_gles unavailable "
              @"-- EGL stays on raw ANGLE (legacy behavior)");
        return NO;
    }
    if (ame_raw_create_pbuffer == NULL || ame_raw_create_context == NULL ||
        ame_raw_make_current == NULL || ame_raw_destroy_context == NULL ||
        ame_raw_destroy_surface == NULL) {
        NSLog(@"[MG-Bridge] bootstrap skipped: raw ANGLE pointers incomplete -- EGL stays on raw ANGLE");
        return NO;
    }

    // 1) 临时 pbuffer + ES3 上下文（raw ANGLE）：唯一目的是让 mg_init_gles() 的
    //    caps 查询（glGetString 等）发生在"有当前上下文"的正确环境里。
    const EGLint pbAttribs[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
    EGLSurface pb = ame_raw_create_pbuffer(dpy, config, pbAttribs);
    const EGLint tmpCtxAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext tmpCtx = (pb != EGL_NO_SURFACE)
        ? ame_raw_create_context(dpy, config, EGL_NO_CONTEXT, tmpCtxAttribs)
        : EGL_NO_CONTEXT;

    BOOL ok = NO;
    if (pb != EGL_NO_SURFACE && tmpCtx != EGL_NO_CONTEXT &&
        ame_raw_make_current(dpy, pb, pb, tmpCtx)) {
        // 2) 绑定 gles/egl 后端句柄 + 真实 caps 检测（MobileGlues 内部幂等）
        ame_mg_init_gles();
        ok = YES;
        NSLog(@"[MG-Bridge] bootstrap: mg_init_gles complete under throwaway ES context "
              @"(GLES/ANGLE handles bound, caps detected)");
    } else {
        NSLog(@"[MG-Bridge] bootstrap FAILED (pbuffer=%p ctx=%p, eglError=0x%x) "
              @"-- EGL stays on raw ANGLE (legacy behavior)",
              (void *)pb, (void *)tmpCtx,
              (unsigned int)(uintptr_t)handle.eglGetError());
    }

    // 3) 无论成败都释放临时资源（MobileGlues 从未见过它们，无残留状态）
    if (pb != EGL_NO_SURFACE || tmpCtx != EGL_NO_CONTEXT) {
        ame_raw_make_current(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (tmpCtx != EGL_NO_CONTEXT) ame_raw_destroy_context(dpy, tmpCtx);
        if (pb != EGL_NO_SURFACE) ame_raw_destroy_surface(dpy, pb);
    }
    if (!ok) return NO;

    // 4) 把生命周期 EGL 切换到 MobileGlues 前端（此后 eglCreateContext 会建立
    //    MGContext 记录、eglMakeCurrent 会绑定 g_current_ctx 与每上下文子系统，
    //    eglSwapBuffers 走 presentSurface）。任一符号缺失则单独回退 raw。
    void *fn = NULL;
    #define AME_MG_SWAP(field, name)                                                  \
        do {                                                                          \
            fn = dlsym(ame_mg_handle, name);                                          \
            if (fn != NULL) { handle.field = fn; }                                    \
            else NSLog(@"[MG-Bridge] frontend " name " missing -- raw ANGLE retained"); \
        } while (0)
    AME_MG_SWAP(eglBindAPI,        "eglBindAPI");
    AME_MG_SWAP(eglCreateContext,  "eglCreateContext");
    AME_MG_SWAP(eglDestroyContext, "eglDestroyContext");
    AME_MG_SWAP(eglMakeCurrent,    "eglMakeCurrent");
    AME_MG_SWAP(eglSwapBuffers,    "eglSwapBuffers");
    AME_MG_SWAP(eglSwapInterval,   "eglSwapInterval");
    #undef AME_MG_SWAP

    ame_mgFrontendActive = YES;
    NSLog(@"[MG-Bridge] EGL lifecycle routed through MobileGlues frontend "
          @"(MGContext tracking + presentSurface active)");
    return YES;
}

static bool dlsym_EGL() {
    // EGL 符号来源：
    //   - Mithril / MobileGL：自带完整 EGL 实现，必须从自身 dylib 解析。
    //     若复用 ANGLE 的 EGL，会创建 ANGLE 的 Metal 上下文而不是渲染器自己的
    //     surface，且 eglChooseConfig 在这些渲染器请求的属性组合下可能返回 0
    //     个配置，触发 gl_init_context 里的 assert(bundle->config) 崩溃。
    //   - MobileGlues：生命周期函数经其前端 EGL（Task 36，见上方大段注释），
    //     其余基础设施函数仍从 ANGLE 解析（前端本来就是透传，且必须在
    //     mg_init_gles 引导完成前避免触发前端内部的 LOAD_EGL 一次性初始化）。
    //   - 其余渲染器（gl4es / ANGLE / LTW）：全部从 ANGLE 解析。
    const char *renderer = getenv("AMETHYST_RENDERER");
    //
    // MobileGlues 的 EGL 必须取自它自己链接的那份 EGL，而不是 ANGLE。
    //
    // MobileGlues 的 external/ 目录里带的正是 libEGL.framework / libGLESv2.framework
    // 两个 .tbd，即它在运行时使用内置 libEGL.framework 的 egl* 入口点；其 GL 层
    // （glGetString 等）也建立在这份 EGL 的 current context 之上。
    //
    // 而此处原先一律回落到 libtinygl4angle.dylib —— 那是 ANGLE 的**另一份副本**
    // （两份都导出 egl* 且都带 ANGLE 扩展，但彼此是独立镜像，各自维护 current
    // context 状态）。于是 br_init_context 用 tinygl4angle 的 eglMakeCurrent 建立
    // 主上下文后，MobileGlues 侧查自己的 EGL 仍看不到任何 current context：
    // glGetString(GL_VERSION) 返回 NULL，LWJGL 3.4.1 随即在 GL.java:456 抛出
    // "There is no OpenGL context current in the current thread."。
    //
    // 这与 MobileGL / Mithril 的情况完全同构（两者早已因同样原因从自身解析 EGL），
    // 差别只是 MobileGlues 的 EGL 在独立的 framework 中，不在它自己的 dylib 里。
    //
    // 仅影响 MobileGlues：其余渲染器取值顺序与改动前逐字相同。
    // 逃生开关：AMETHYST_MOBILEGLUES_EGL_ANGLE=1 可恢复为从 ANGLE 解析。
    //
    // 注意：这里解析的只是**基础设施** EGL（display/config/surface）。
    // 六个生命周期入口在 gl_init_context 里由 ame_mgBootstrap() 经
    // mg_init_gles 引导后进一步切换到 libmobileglues.dylib 的前端
    // （Task 36）—— 见该函数上方的完整说明。
    const char *forceAngleEgl = getenv("AMETHYST_MOBILEGLUES_EGL_ANGLE");
    BOOL mobileGluesOwnEgl = renderer &&
                             strcmp(renderer, RENDERER_NAME_MOBILEGLUES) == 0 &&
                             !(forceAngleEgl && forceAngleEgl[0] == '1');
    const char *eglLibrary;
    if (isSelfEglRenderer(renderer)) {
        eglLibrary = renderer;                    // Mithril / MobileGL：自身 EGL
    } else if (mobileGluesOwnEgl) {
        eglLibrary = AME_EGL_FRAMEWORK_PATH;      // MobileGlues：内置的 libEGL.framework
    } else {
        eglLibrary = RENDERER_NAME_MTL_ANGLE;     // gl4es / ANGLE / LTW / zink：ANGLE
    }
    NSString *eglPath = [NSString stringWithFormat:@"@rpath/%s", eglLibrary ?: ""];
    //
    // MobileGL 以 RTLD_LOCAL 载入（参照 MojoLauncher mojoexec_acq_egl_handle() 的
    // RTLD_LOCAL | RTLD_NOW）：
    //
    // libMobileGL.dylib 镜像内静态链接了一份 glslang。以 RTLD_GLOBAL 载入时，其中
    // 大量 N_WEAK_DEF 符号会被提升进全局符号空间；随后 LWJGL 加载 libshaderc.dylib
    // 时，dyld 把 shaderc 那份 glslang 合并到 MobileGL 这份上，二者共用线程局部的
    // AST 内存池 —— MobileGL 销毁自己的 TShader 时会连带回收 shaderc 仍在使用的
    // AST 节点，TGlslangToSpvTraverser::visitAggregate 随即解引用到已释放内存
    // （SIGSEGV；26.3 上崩溃地址固定在 +0x155820，多次复现完全一致）。
    //
    // EGL 符号一律通过本函数持有的 dl_handle 显式 dlsym 解析（load_egl_symbol 用
    // dlsym(dl_handle, ...) 而非 RTLD_DEFAULT），因此 RTLD_LOCAL 不影响解析。
    //
    // ANGLE 作为多个渲染器共享的 EGL host 仍保持 RTLD_GLOBAL，行为不变。
    // 逃生开关：AMETHYST_MOBILEGL_RTLD_GLOBAL=1 可恢复旧行为，无需重新构建。
    // MobileGlues（26.2/26.3 + LWJGL 3.4.1）同样必须 RTLD_LOCAL：
    //
    // libtinygl4angle.dylib 由 gl4es 的 tinygl4angle.c 构建，镜像内带有 GL 入口点
    // （glGetString / glGetError / glGetIntegerv 等）。以 RTLD_GLOBAL 载入时这些
    // 入口点进入全局符号空间，并在 iOS flat namespace 下抢占
    // libGLESv2.framework / libmobileglues.dylib 提供的同名符号。
    //
    // LWJGL 3.4.1 的 GL.createCapabilities() 会 dlsym 解析 glGetError /
    // glGetString / glGetIntegerv。若命中 tinygl4angle 这份没有 GL 上下文的副本，
    // glGetString(GL_VERSION) 返回 NULL、glGetError() 返回非零，于是
    // GL.java:456 抛出 "There is no OpenGL context current in the current thread."。
    //
    // 反证：MobileGlues 自身的 glGetError() 恒返回 GL_NO_ERROR，
    // glGetString(GL_VERSION) 恒返回非空（由全局 GLVersion 拼装），
    // 因此只要 LWJGL 解析到的是 MobileGlues 的入口点，该异常在逻辑上不可能发生。
    //
    // 改为 RTLD_LOCAL 后全局空间只剩 MobileGlues 自己以 RTLD_GLOBAL 载入的
    // libGLESv2.framework，LWJGL 解析到的即为渲染器真实入口点。
    // 逃生开关：AMETHYST_ANGLE_RTLD_GLOBAL=1 可恢复旧行为，无需重新构建。
    const char *forceGlobal = getenv("AMETHYST_MOBILEGL_RTLD_GLOBAL");
    bool isMobileGlues = renderer && !strcmp(renderer, RENDERER_NAME_MOBILEGLUES);
    const char *forceAngleGlobal = getenv("AMETHYST_ANGLE_RTLD_GLOBAL");
    bool useLocalEGL = (isMobileGLRenderer(renderer) &&
                        !(forceGlobal && forceGlobal[0] == '1')) ||
                       (isMobileGlues &&
                        !(forceAngleGlobal && forceAngleGlobal[0] == '1'));
    int eglDlFlags = RTLD_NOW | (useLocalEGL ? RTLD_LOCAL : RTLD_GLOBAL);
    void* dl_handle = dlopen(eglPath.UTF8String, eglDlFlags);
    if (!dl_handle && strcmp(eglLibrary, RENDERER_NAME_MTL_ANGLE) != 0) {
        // 首选 EGL 不可用：回落到 ANGLE，与改动前的行为完全一致（不更差）。
        NSLog(@"EGLBridge: %@ unavailable for renderer %s (%s); falling back to %s",
              eglPath, renderer ?: "<unset>", dlerror() ?: "unknown dlopen error",
              RENDERER_NAME_MTL_ANGLE);
        eglPath = [NSString stringWithFormat:@"@rpath/%s", RENDERER_NAME_MTL_ANGLE];
        dl_handle = dlopen(eglPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    }
    if (!dl_handle) {
        NSLog(@"EGLBridge: failed to load %@ for renderer %s: %s",
            eglPath, renderer ?: "<unset>", dlerror() ?: "unknown dlopen error");
        return false;
    }

    // Task 36：MobileGlues 前端 EGL 准备（不改变任何行为，仅记录句柄/符号，
    // 真正的指针切换发生在 ame_mgBootstrap 成功之后）。
    if (renderer && strcmp(renderer, RENDERER_NAME_MOBILEGLUES) == 0 &&
        !isSelfEglRenderer(renderer)) {
        ame_mg_angle_handle = dl_handle;
        void *mg = dlopen("@rpath/" RENDERER_NAME_MOBILEGLUES, RTLD_NOW | RTLD_LOCAL);
        if (!mg) {
            mg = dlopen(RENDERER_NAME_MOBILEGLUES, RTLD_NOW | RTLD_LOCAL);
        }
        if (mg) {
            ame_mg_handle = mg;
            ame_mg_init_gles = (ame_mg_init_gles_t)dlsym(mg, "mg_init_gles");
            NSLog(@"[MG-Bridge] MobileGlues frontend image loaded (%p, mg_init_gles=%p); "
                  @"lifecycle EGL will route through it after bootstrap",
                  mg, (void *)ame_mg_init_gles);
        } else {
            NSLog(@"[MG-Bridge] failed to load " RENDERER_NAME_MOBILEGLUES
                  @" (%s) -- EGL stays on raw ANGLE (legacy behavior)",
                  dlerror() ?: "unknown");
        }
        // 引导与取证用的 raw 指针（始终来自 ANGLE 垫片）
        ame_raw_create_pbuffer   = (ame_fn_create_pbuffer)load_egl_symbol(dl_handle, "eglCreatePbufferSurface");
        ame_raw_query_surface    = (ame_fn_egl_query_surface)load_egl_symbol(dl_handle, "eglQuerySurface");
        ame_raw_create_context   = (PFNEGLCREATECONTEXTPROC)load_egl_symbol(dl_handle, "eglCreateContext");
        ame_raw_make_current     = (PFNEGLMAKECURRENTPROC)load_egl_symbol(dl_handle, "eglMakeCurrent");
        ame_raw_destroy_context  = (PFNEGLDESTROYCONTEXTPROC)load_egl_symbol(dl_handle, "eglDestroyContext");
        ame_raw_destroy_surface  = (PFNEGLDESTROYSURFACEPROC)load_egl_symbol(dl_handle, "eglDestroySurface");
    }

    // LTW 模式：eglCreateContext / eglDestroyContext / eglMakeCurrent 三个函数
    // 必须从 libltw.dylib 直接 dlsym 解析，而非 ANGLE。
    //
    // 原因：LTW 是 OpenGL Core 3.3 → OpenGL ES 3 的转译层，它在这三个函数中
    // 注入 wrapper 逻辑（创建 ES3 上下文 + 安装 GL 函数指针转译表 + 伪装 ARB 扩展）。
    // 如果直接使用 ANGLE 的 eglCreateContext，创建的是原生 ES3 上下文，MC 1.17+
    // 检测到 GL_VERSION 不含 "Core Profile" 会拒绝启动；Sodium/Iris 的 ARB 扩展
    // 查询也会全部失败。LTW 的 wrapper 让 MC 看到的是 OpenGL 3.3 Core Profile，
    // 且主动声明 GL_ARB_buffer_storage 等 ARB 扩展，让 Sodium 的 persistent mapped
    // buffers / texture buffers 和 Iris 的 draw_buffers_blend 正常工作。
    //
    // 注意：不能用 RTLD_DEFAULT dlsym（iOS 的 flat namespace 中 ANGLE 符号会先命中），
    // 必须显式 dlopen libltw.dylib 后从其 handle dlsym。
    //
    // 其余 EGL 函数（eglChooseConfig / eglCreateWindowSurface / eglSwapBuffers 等）
    // LTW 不做 wrapper，直接从 ANGLE 解析。
    BOOL useLTW = renderer && strcmp(renderer, RENDERER_NAME_LTW) == 0;
    void *ltw_handle = NULL;
    if (useLTW) {
        ltw_handle = dlopen("@rpath/" RENDERER_NAME_LTW, RTLD_NOW | RTLD_LOCAL);
        if (!ltw_handle) {
            NSLog(@"EGLBridge: LTW renderer selected but failed to load libltw.dylib: %s",
                  dlerror() ?: "unknown dlopen error");
            // 致命错误：LTW 模式下没有 LTW 的 wrapper，MC 1.17+ 无法启动
            return false;
        }
        NSLog(@"EGLBridge: LTW mode active, eglCreateContext/Destroy/MakeCurrent resolved from libltw.dylib");
    }

    memset(&handle, 0, sizeof(handle));
    handle.eglBindAPI = load_egl_symbol(dl_handle, "eglBindAPI");
    handle.eglChooseConfig = load_egl_symbol(dl_handle, "eglChooseConfig");
    if (useLTW && ltw_handle) {
        // 从 LTW 解析三个 wrapper 函数（关键：让 LTW 的 GL Core→ES 转译逻辑生效）
        handle.eglCreateContext = load_egl_symbol(ltw_handle, "eglCreateContext");
        handle.eglDestroyContext = load_egl_symbol(ltw_handle, "eglDestroyContext");
        handle.eglMakeCurrent = load_egl_symbol(ltw_handle, "eglMakeCurrent");
    } else {
        handle.eglCreateContext = load_egl_symbol(dl_handle, "eglCreateContext");
        handle.eglDestroyContext = load_egl_symbol(dl_handle, "eglDestroyContext");
        handle.eglMakeCurrent = load_egl_symbol(dl_handle, "eglMakeCurrent");
    }
    handle.eglCreateWindowSurface = load_egl_symbol(dl_handle, "eglCreateWindowSurface");
    handle.eglDestroySurface = load_egl_symbol(dl_handle, "eglDestroySurface");
    handle.eglGetConfigAttrib = load_egl_symbol(dl_handle, "eglGetConfigAttrib");
    handle.eglGetCurrentContext = load_egl_symbol(dl_handle, "eglGetCurrentContext");
    handle.eglGetDisplay = load_egl_symbol(dl_handle, "eglGetDisplay");
    handle.eglGetError = load_egl_symbol(dl_handle, "eglGetError");
    handle.eglGetPlatformDisplay = load_egl_symbol(dl_handle, "eglGetPlatformDisplay");
    handle.eglInitialize = load_egl_symbol(dl_handle, "eglInitialize");
    handle.eglQuerySurface = load_egl_symbol(dl_handle, "eglQuerySurface");
    handle.eglSwapBuffers = load_egl_symbol(dl_handle, "eglSwapBuffers");
    handle.eglReleaseThread = load_egl_symbol(dl_handle, "eglReleaseThread");
    handle.eglSwapInterval = load_egl_symbol(dl_handle, "eglSwapInterval");
    handle.eglTerminate = load_egl_symbol(dl_handle, "eglTerminate");
    handle.eglGetCurrentSurface = load_egl_symbol(dl_handle, "eglGetCurrentSurface");

    NSLog(@"EGLBridge: loaded %@ with %s for renderer %s",
          eglPath, useLocalEGL ? "RTLD_LOCAL" : "RTLD_GLOBAL", renderer ?: "<unset>");

    return handle.eglBindAPI && handle.eglChooseConfig && handle.eglCreateContext &&
        handle.eglCreateWindowSurface && handle.eglDestroyContext && handle.eglDestroySurface &&
        handle.eglGetConfigAttrib && handle.eglGetDisplay && handle.eglGetError &&
        handle.eglInitialize && handle.eglMakeCurrent && handle.eglSwapBuffers &&
        handle.eglReleaseThread && handle.eglSwapInterval && handle.eglTerminate;
}

static bool gl_init() {
    if (!dlsym_EGL()) {
        return false;
    }

    g_EglDisplay = handle.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_EglDisplay == EGL_NO_DISPLAY) {
        NSDebugLog(@"EGLBridge: eglGetDisplay(EGL_DEFAULT_DISPLAY) returned EGL_NO_DISPLAY");
        return false;
    }
    if (!handle.eglInitialize(g_EglDisplay, NULL, NULL)) {
        NSDebugLog(@"EGLBridge: Error eglInitialize() failed: 0x%x", handle.eglGetError());
        return false;
    }
    return true;
}

/// sdl3_hook.m 导出：SDL3 路径下建窗前是否已把 GL profile 强制为 ES。
/// 非 SDL3 路径（GLFW / MC 26.2 及以下）恒返回 false。
extern bool amethyst_sdl3_wants_gles_context(void);


#pragma mark - Task 53/55：EGL surface 几何自动重对齐（对齐 Air Task53/55）

// 根治「必须手动调一次分辨率才恢复」+「改分辨率后画面缩在左下角」。
//
// 统一根因：EGLSurface 只在 gl_init_context 里创建一次，此后再也不跟随
// CAMetalLayer 的呈现几何（bounds x contentsScale，随分辨率/旋转变化）：
//   - 启动时 surface 与实际呈现几何不符 -> 永久失配；只有改分辨率这类
//     外部动作偶然触发重建时才恢复（用户现象：必须手动调一次）；
//   - 改分辨率后 drawable 变成新值、surface 仍是旧值 -> present 只覆盖
//     后缓冲左下角一块 = 用户看到的「往左下角放大」。
//
// Air 定案（Task53/55）：几何失配检出后做梯度式重对齐，治本手段 = 销毁优先
// 重建 EGL window surface（先 MakeCurrent 解绑再销毁，避免同 layer 双
// surface 并存导致 EGL_BAD_ALLOC —— Task48 重建恒败的根因）。
static CFTypeRef  g_ame_geo_layer_cf = NULL;
static _Atomic int g_ame_geo_owns_layer = 0;
static int        g_ame_geo_attempts = 0;
static int        g_ame_geo_fused = 0;
static int        g_ame_geo_mismatch = 0;
static uint64_t   g_ame_geo_last_ms = 0;
static int        g_ame_geo_expect_w = 0;
static int        g_ame_geo_expect_h = 0;

bool ame_gl_surface_owns_layer(void) {
    return atomic_load(&g_ame_geo_owns_layer) != 0;
}

// 供 SurfaceViewController.updateSavedResolution 判断停火：失配未治愈期间
// 由本模块独占 drawableSize 写权，终结与宿主的拉锯战（Air Task53 同款）。
bool ame_gl_surface_transposed(void) {
    return g_ame_geo_mismatch != 0;
}

static uint64_t ame_geo_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

static void ame_geo_on_main(dispatch_block_t block) {
    if ([NSThread isMainThread]) { block(); return; }
    dispatch_sync(dispatch_get_main_queue(), block);
}

// 等主队列若干拍（每拍 flush 一次 CA 事务，给 ANGLE 跟随 layer 几何的机会）
static void ame_geo_wait_main_turns(int turns) {
    for (int i = 0; i < turns; ++i) {
        ame_geo_on_main(^{ @try { [CATransaction flush]; } @catch (NSException *e) {} });
    }
}

static BOOL ame_geo_query_surface(EGLSurface s, int *w, int *h) {
    if (s == EGL_NO_SURFACE || handle.eglQuerySurface == NULL) return NO;
    EGLint sw = 0, sh = 0;
    if (!handle.eglQuerySurface(g_EglDisplay, s, EGL_WIDTH, &sw)) return NO;
    if (!handle.eglQuerySurface(g_EglDisplay, s, EGL_HEIGHT, &sh)) return NO;
    if (sw <= 0 || sh <= 0) return NO;
    *w = (int)sw; *h = (int)sh;
    return YES;
}

// 期望几何：主线程权威 bounds x contentsScale（像素口径，Air Task60 单一事实源）
static BOOL ame_geo_expected_size(CALayer *layer, int *w, int *h) {
    if (layer == nil) return NO;
    __block int bw = 0, bh = 0;
    ame_geo_on_main(^{
        @try {
            CGFloat sc = layer.contentsScale > 0.0 ? layer.contentsScale : 1.0;
            bw = (int)round(layer.bounds.size.width * sc);
            bh = (int)round(layer.bounds.size.height * sc);
        } @catch (NSException *e) {}
    });
    if (bw < 2 || bh < 2) return NO;
    *w = bw; *h = bh;
    return YES;
}

static BOOL ame_geo_realign(basic_render_window_t *bundle) {
    CALayer *layer = (__bridge CALayer *)g_ame_geo_layer_cf;
    if (bundle == NULL || layer == nil || ![layer isKindOfClass:CAMetalLayer.class]) {
        NSLog(@"[GLGeo] realign: prerequisites missing -- fused off");
        g_ame_geo_fused = 1;
        return NO;
    }
    int expW = 0, expH = 0;
    if (!ame_geo_expected_size(layer, &expW, &expH)) return NO;

    int curW = 0, curH = 0;
    ame_geo_query_surface(bundle->gl.surface, &curW, &curH);
    NSLog(@"[GLGeo] realign attempt %d/6: surface=%dx%d expected=%dx%d (gradient A geometry-signal -> B destroy-first recreate)",
          g_ame_geo_attempts, curW, curH, expW, expH);

    // --- Step A：零销毁几何信号（drawableSize 写回 + bounds 轻碰 + 2 拍）---
    ame_geo_on_main(^{
        @try {
            CAMetalLayer *ml = (CAMetalLayer *)layer;
            ml.drawableSize = CGSizeMake((CGFloat)expW, (CGFloat)expH);
            CGRect b = layer.bounds;
            layer.bounds = CGRectMake(b.origin.x, b.origin.y, b.size.width, b.size.height + 1.0);
            layer.bounds = b;
        } @catch (NSException *e) { NSLog(@"[GLGeo] stepA exception: %@", e); }
    });
    ame_geo_wait_main_turns(2);
    if (ame_geo_query_surface(bundle->gl.surface, &curW, &curH) && curW == expW && curH == expH) {
        NSLog(@"[GLGeo] CURED by stepA: surface=%dx%d == bounds %.0fx%.0f (ANGLE follows layer geometry)",
              curW, curH, layer.bounds.size.width, layer.bounds.size.height);
        return YES;
    }
    NSLog(@"[GLGeo] stepA not cured: query=%dx%d expected=%dx%d", curW, curH, expW, expH);

    // --- Step B：销毁优先重建（先解绑再销毁，避免同 layer 双 surface）---
    EGLContext ctx = bundle->gl.context;
    EGLSurface old = bundle->gl.surface;
    handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);
    handle.eglDestroySurface(g_EglDisplay, old);
    while (handle.eglGetError() != EGL_SUCCESS) {}
    usleep(100 * 1000);

    const EGLint attribs[] = {
        EGL_WIDTH,  (EGLint)expW,
        EGL_HEIGHT, (EGLint)expH,
        EGL_NONE
    };
    EGLSurface newS = handle.eglCreateWindowSurface(g_EglDisplay, bundle->gl.config,
        (__bridge EGLNativeWindowType)layer, NULL);
    if (newS == EGL_NO_SURFACE) {
        newS = handle.eglCreateWindowSurface(g_EglDisplay, bundle->gl.config,
            (__bridge EGLNativeWindowType)layer, attribs);
    }
    if (newS == EGL_NO_SURFACE) {
        NSLog(@"[GLGeo] stepB FAILED: recreation refused (err=0x%x) -- compensation continues",
              (unsigned int)(uintptr_t)handle.eglGetError());
        bundle->gl.surface = EGL_NO_SURFACE;
        return NO;
    }
    if (!handle.eglMakeCurrent(g_EglDisplay, newS, newS, ctx)) {
        NSLog(@"[GLGeo] stepB FAILED: eglMakeCurrent err=0x%x", (unsigned int)(uintptr_t)handle.eglGetError());
        handle.eglDestroySurface(g_EglDisplay, newS);
        bundle->gl.surface = EGL_NO_SURFACE;
        return NO;
    }
    bundle->gl.surface = newS;
    while (handle.eglGetError() != EGL_SUCCESS) {}
    ame_geo_wait_main_turns(2);
    if (ame_geo_query_surface(newS, &curW, &curH) && curW == expW && curH == expH) {
        NSLog(@"[GLGeo] CURED by stepB: surface %p -> %p query=%dx%d (expected %dx%d)",
              (void *)old, (void *)newS, curW, curH, expW, expH);
        return YES;
    }
    NSLog(@"[GLGeo] stepB not cured: query=%dx%d expected=%dx%d", curW, curH, expW, expH);
    return NO;
}

// 每次 swap 前调用：surface 几何 != 期望几何 -> 预算内重对齐。
static void ame_geo_check_and_heal(basic_render_window_t *bundle) {
    if (g_ame_geo_fused) return;
    if (bundle == NULL || bundle->gl.surface == EGL_NO_SURFACE) return;
    CALayer *layer = (__bridge CALayer *)g_ame_geo_layer_cf;
    int expW = 0, expH = 0;
    if (!ame_geo_expected_size(layer, &expW, &expH)) return;

    // 期望几何变化（用户改分辨率 / 旋转）-> 重置预算与冷却，允许立即重对齐
    if (expW != g_ame_geo_expect_w || expH != g_ame_geo_expect_h) {
        if (g_ame_geo_expect_w != 0 || g_ame_geo_expect_h != 0) {
            NSLog(@"[GLGeo] expected geometry changed %dx%d -> %dx%d (budget reset)",
                  g_ame_geo_expect_w, g_ame_geo_expect_h, expW, expH);
        }
        g_ame_geo_expect_w = expW;
        g_ame_geo_expect_h = expH;
        g_ame_geo_attempts = 0;
        g_ame_geo_last_ms = 0;
    }

    int curW = 0, curH = 0;
    if (!ame_geo_query_surface(bundle->gl.surface, &curW, &curH)) return;
    if (curW == expW && curH == expH) { g_ame_geo_mismatch = 0; return; }

    if (g_ame_geo_mismatch == 0) {
        NSLog(@"[GLGeo] geometry mismatch ENGAGED: surface=%dx%d expected=%dx%d "
              @"(frame covers only %.0f%% of backbuffer -- needs realign)",
              curW, curH, expW, expH,
              100.0 * (double)curW * (double)curH / ((double)expW * (double)expH));
    }
    g_ame_geo_mismatch = 1;

    uint64_t now = ame_geo_now_ms();
    if (g_ame_geo_last_ms != 0 && now - g_ame_geo_last_ms < 500) return;
    if (g_ame_geo_attempts >= 6) {
        if (!g_ame_geo_fused) {
            g_ame_geo_fused = 1;
            NSLog(@"[GLGeo] budget exhausted after %d attempts -- fused off, compensation path continues",
                  g_ame_geo_attempts);
        }
        return;
    }
    g_ame_geo_last_ms = now;
    g_ame_geo_attempts++;
    if (ame_geo_realign(bundle)) {
        g_ame_geo_mismatch = 0;
        NSLog(@"[GLGeo] realign applied: surface=%dx%d == expected %dx%d", curW, curH, expW, expH);
    }
}

#pragma mark - EGL surface 像素尺寸（含 0 尺寸兜底）

// FCL 93bba5a 修复的是同一类问题：SDL 模式下原生侧拿到 0x0 尺寸 → 渲染黑屏。
//
// 我们这里的对应点：MobileGL 的 eglCreateWindowSurface 不会从 CALayer 推断尺寸，
// 必须由调用方显式给出像素宽高。原实现取 layer.bounds.size * contentsScale，但
// SDL3 路径下 GameSurfaceView 曾被执行过 hidden = YES（SDL 嵌入逻辑所为），UIKit
// 可能因此未完成布局，bounds 仍为 0 —— MAX(1.0, 0) 得到 1x1 的 surface。它既不
// 报错也不崩溃，只是画面全黑；而 EGLSurface 只在 gl_init_context 里创建一次，
// 后续恢复可见 / 窗口 resize 都不会重建，所以黑屏无法自愈。
//
// 兜底链：bounds*scale → CAMetalLayer.drawableSize → 主屏物理分辨率。
// 每档都打日志，便于一轮实测确认究竟走了哪一档。
static CGSize ame_eglSurfacePixelSize(CALayer *layer) {
    // 优先采用 CAMetalLayer.drawableSize：它由启动器显式配置为
    // physicalSize * resolutionScale，是精确的渲染分辨率，且与该 layer 的
    // 呈现缓冲严格一致。
    //
    // 不能反过来先算 bounds * contentsScale：SDL3 嵌入后宿主 view 的 frame
    // 可能被改写（缩小），此时 bounds*scale 会得到一个合法的、但明显偏小的
    // 值（例如 913x421）——既不会触发任何兜底，又让 EGLSurface 只覆盖 layer
    // 的一角，表现为画面缩在左下角、四周大面积黑边。drawableSize 不受 view
    // 布局影响，是唯一可靠的基准；用户调分辨率时它也同步变化，因此缩放依旧
    // 生效（体现在渲染像素数上，而非显示区域大小）。
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        CGSize ds = ((CAMetalLayer *)layer).drawableSize;
        // 门槛由 1.0 提到 2.0：1x1 是「偏好缺失/布局未完成」时的钳位产物，
        // 旧判定把它当成有效值直接返回，EGLSurface 于是建成 1x1 且永不重建
        // （只在 gl_init_context 创建一次）-> 永久黑屏。低于 2px 一律视为
        // 无效，继续走 bounds*scale / 主屏物理尺寸兜底链。
        if (ds.width >= 2.0 && ds.height >= 2.0) {
            NSLog(@"[gl_bridge] EGL surface size: from drawableSize %.0fx%.0f "
                  @"(bounds %.0fx%.0f @%.2fx would give %.0fx%.0f)",
                  ds.width, ds.height,
                  layer.bounds.size.width, layer.bounds.size.height,
                  layer.contentsScale,
                  layer.bounds.size.width * layer.contentsScale,
                  layer.bounds.size.height * layer.contentsScale);
            return ds;
        }
    }

    // 非 CAMetalLayer（或 drawableSize 尚未配置）：退回 bounds * contentsScale。
    CGFloat scale = layer.contentsScale > 0.0 ? layer.contentsScale : 1.0;
    CGFloat w = layer.bounds.size.width * scale;
    CGFloat h = layer.bounds.size.height * scale;
    if (w >= 1.0 && h >= 1.0) {
        NSLog(@"[gl_bridge] EGL surface size: from bounds %.0fx%.0f @%.2fx", w, h, scale);
        return CGSizeMake(w, h);
    }

    // 最后退回主屏物理分辨率（FCL 的做法）。MC 为横屏，故取长边为宽。
    CGSize native = UIScreen.mainScreen.nativeBounds.size;
    CGFloat pw = MAX(native.width, native.height);
    CGFloat ph = MIN(native.width, native.height);
    NSLog(@"[gl_bridge] EGL surface size: FALLBACK bounds %.0fx%.0f -> screen %.0fx%.0f",
          layer.bounds.size.width, layer.bounds.size.height, pw, ph);
    return CGSizeMake(pw, ph);
}

gl_render_window_t* gl_init_context(gl_render_window_t *share) {
    gl_render_window_t* bundle = calloc(1, sizeof(gl_render_window_t));

    NSString *renderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    // ANGLE / Mithril / MobileGL 导出的都是 desktop OpenGL，走 EGL_OPENGL_BIT +
    // eglBindAPI(EGL_OPENGL_API)；其余（gl4es / MobileGlues / LTW）是 OpenGL ES。
    BOOL desktopGL = isDesktopGLRenderer(renderer.UTF8String);
    BOOL mobileGL = isMobileGLRenderer(renderer.UTF8String);

    // MobileGL 的上下文语义：desktop GL 3.3 Core 还是 ES3。
    //
    // 依据：ZL2 在安卓上建窗前强制 ES profile，MC 因此生成 GLSL ES，走 glslang
    // 里最成熟的 ES->SPIR-V 路径，MobileGL 从不出问题；而 iOS 侧桥按
    // isDesktopGLRenderer() 把 MobileGL 归为 desktop，硬编码建 desktop GL 3.3
    // Core 上下文，MC 改发桌面 GLSL，其 desktop->SPIR-V 路径会在
    // TGlslangToSpvTraverser::visitAggregate 确定性崩溃（压并发无效，地址不变）。
    //
    // 三档优先级：
    //   1) AMETHYST_EGL_FORCE_ES 显式指定时以其为准（排障用，可强制回退）
    //   2) 否则跟随 SDL3 路径的 ZL2 式 ES 强制（sdl3_hook.m 建窗前写入）
    //   3) 都不是则沿用 desktop（GLFW 老路径恒走这条，行为不变）
    //
    // 仅影响 MobileGL；Mithril / ANGLE / gl4es 等完全不受影响。
    BOOL useDesktopCtx = mobileGL;

    NSString *forceES = NSProcessInfo.processInfo.environment[@"AMETHYST_EGL_FORCE_ES"];
    NSInteger forced = 0;  // 0=未指定 1=强制ES -1=强制desktop
    if (forceES != nil) {
        if ([forceES isEqualToString:@"1"] ||
            [forceES caseInsensitiveCompare:@"yes"] == NSOrderedSame) {
            forced = 1;
        } else if ([forceES isEqualToString:@"0"] ||
                   [forceES caseInsensitiveCompare:@"no"] == NSOrderedSame) {
            forced = -1;
        }
    }

    // SDL3 路径下 sdl3_hook 是否已把 profile 强制为 ES。GLFW 老路径（26.2 及
    // 以下）不会经过该 hook，恒为 NO —— MobileGL 在老路径上保持原有
    // desktop GL 行为，不受本次改动影响。
    BOOL sdl3WantsEs = amethyst_sdl3_wants_gles_context();

    BOOL wantES = (forced == 1) ? YES : (forced == -1) ? NO : sdl3WantsEs;
    if (wantES && mobileGL) {
        desktopGL = NO;
        useDesktopCtx = NO;
        NSDebugLog(@"EGLBridge: ES3 context for MobileGL (sdl3Forced=%d, envForced=%ld)",
                   (int)sdl3WantsEs, (long)forced);
    }

    const EGLint attribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT|EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, desktopGL ? EGL_OPENGL_BIT : EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };

    EGLint num_configs;
    EGLint vid;
    if (!handle.eglChooseConfig(g_EglDisplay, attribs, &bundle->config, 1, &num_configs)) {
        NSDebugLog(@"EGLBridge: Error couldn't get an EGL visual config: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    assert(bundle->config);
    assert(num_configs > 0);

    if (!handle.eglGetConfigAttrib(g_EglDisplay, bundle->config, EGL_NATIVE_VISUAL_ID, &vid)) {
        NSDebugLog(@"EGLBridge: Error eglGetConfigAttrib() failed: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    EGLBoolean bindResult;
    // Task 36：在首个前端 EGL 调用（eglBindAPI）之前完成 MobileGlues 引导 ——
    // 绑定后端句柄 + caps 检测 + 把生命周期指针切到前端。
    // 必须位于此处：config 已可用（引导需要），eglBindAPI/eglCreateContext
    // 尚未发生（前端函数内部 LOAD_EGL 静态指针需要后端已绑定）。
    ame_mgBootstrap(g_EglDisplay, bundle->config);
    if (desktopGL) {
        NSDebugLog(@"EGLBridge: Binding to desktop OpenGL");
        bindResult = handle.eglBindAPI(EGL_OPENGL_API);
    } else {
        NSDebugLog(@"EGLBridge: Binding to OpenGL ES");
        bindResult = handle.eglBindAPI(EGL_OPENGL_ES_API);
    }
    if (!bindResult) NSDebugLog(@"EGLBridge: bind failed: %p\n", handle.eglGetError());

    CALayer *layer = SurfaceViewController.surface.layer;
    // Task 53/55：保存呈现层引用并置位「GL 拥有呈现层」，供几何自动重对齐
    // 与 SurfaceViewController 的 drawableSize 停火 gate 使用。
    if (g_ame_geo_layer_cf != NULL) { CFRelease(g_ame_geo_layer_cf); g_ame_geo_layer_cf = NULL; }
    if (layer != nil) { g_ame_geo_layer_cf = (__bridge CFTypeRef)layer; if (g_ame_geo_layer_cf) CFRetain(g_ame_geo_layer_cf); }
    atomic_store(&g_ame_geo_owns_layer, layer != nil ? 1 : 0);

    // SDL3（MC 26.3+）黑屏修复。
    //
    // libSDL3 的嵌入逻辑（Amethyst_EmbedSDLViewIntoHostWindow）在把 SDL 视图挂进
    // 启动器层级时，会把 GameSurfaceView 设为 hidden，好让 SDL 的视图顶替它显示。
    // 但 OpenGL 后端下 EGL surface 正是绑在 GameSurfaceView 的 CAMetalLayer 上
    // （也就是上面这行拿到的 layer）——宿主 view 不可见，ANGLE 的渲染结果就无从
    // 呈现，表现为「画面全黑但输入正常」。Vulkan 后端不受影响，因为它走 SDL 自带
    // 的 metalview，本来就是可见的那一层；1.21.1 的 GLFW 路径没有 SDL 视图，
    // GameSurfaceView 始终可见，所以也正常。
    //
    // 两种补救方式：
    //   (1) 默认：保持绑在 GameSurfaceView 上，仅取消隐藏并提到 SDL 视图之上。
    //       分辨率沿用启动器配置的 drawableSize / contentsScale（尊重用户的
    //       分辨率缩放设置），改动面最小。
    //   (2) AMETHYST_EGL_SURFACE_LAYER=sdl：直接改绑 SDL 自己的 CAMetalLayer。
    //       注意该层由 SDL 以全分辨率创建（iPhone X 上为 2436x1125 @3x），
    //       会绕过启动器的分辨率缩放，性能开销明显更大。仅在 (1) 无效时试用。
    //
    // 两个函数都只在检测到 SDL_uikitview 时才动作，非 SDL3 路径恒为空操作。
    const char *layerMode = getenv("AMETHYST_EGL_SURFACE_LAYER");
    BOOL useSDLLayer = (layerMode != NULL && strcmp(layerMode, "sdl") == 0);
    CALayer *sdlLayer = useSDLLayer ? Amethyst_SDL3RenderLayer() : nil;
    if (sdlLayer != nil) {
        layer = sdlLayer;
        NSLog(@"[gl_bridge] SDL3 path: binding EGL surface to SDL CAMetalLayer "
              @"(mode=sdl, %.0fx%.0f @%.2fx)",
              sdlLayer.bounds.size.width * sdlLayer.contentsScale,
              sdlLayer.bounds.size.height * sdlLayer.contentsScale,
              sdlLayer.contentsScale);
    } else if (Amethyst_RestoreGameSurfaceVisibility()) {
        // 注：此处只保证渲染层可见与几何正确；z 序由 Task52 卫兵钉为
        //「画面层紧贴 SDL 触摸视图之下」（Air Task 52 定案），不再抬到最前。
        NSLog(@"[gl_bridge] SDL3 path: GameSurfaceView visibility restored "
              @"(mode=default, %.0fx%.0f @%.2fx)",
              layer.bounds.size.width * layer.contentsScale,
              layer.bounds.size.height * layer.contentsScale,
              layer.contentsScale);
        // Air Task 60（664f58a3）定案：1x 点数对齐（Task 50）已退役，此处
        // 刻意不再置位 g_ame_sdl3_points_surface。
        // 旧行为：置 YES 让下方 1x 对齐块把 contentsScale 压到 1.0、
        // drawableSize 压到 bounds 点数（812x375），而宿主
        // SurfaceViewController.updateSavedResolution 刚按物理像素口径写好
        // drawableSize（2436x1125）—— 两个写入者逐帧互覆（日志实证：
        // "[SurfaceVC] SDL3 path: ... px 2436x1125" 紧随
        // "[gl_bridge] SDL3 1x align: layer drawable -> 812x375 pts"），
        // 呈现几何永远收敛不了 = 文档根因 #2「无单一事实源」= 黑屏。
        // 现在统一由宿主按物理像素写 drawableSize，MC 侧窗口尺寸由 Task61
        // 三路（GetWindowSize / GetWindowSizeInPixels / 0x206-0x208）收敛到
        // 同一像素值，surface == drawable == viewport，无需降级到 1x。
    }

    // MobileGL 的 eglCreateWindowSurface 不会从 CALayer 推断尺寸，必须显式给出
    // 像素宽高（乘 contentsScale，与 drawableSize 保持一致），否则 surface 会按
    // 1x1 创建，进世界后画面异常。其余渲染器从 layer 自行推断，传 NULL。
    // 不能直接 MAX(1.0, bounds*scale)：bounds 为 0 时会静默建出 1x1 的 surface，
    // 表现为画面全黑且不可自愈（surface 只创建一次）。走兜底链取尺寸。
    // ===== SDL3（MC 26.3+）小窗根治：建 surface 前把呈现层对齐到「点」=====
    //
    // 日志实证：MC 26.3 + SDL3 的 glViewport 用的是「点」（iPhone X 上 812x375），
    // 而 EGL surface 一直是像素（2436x1125）—— 2436/812 = 1125/375 = 3.0，正好
    // 是设备 scale。MC 因此只画满后缓冲左上 1/9，表现为「小窗 / 画面缩在左上角」。
    //
    // 这也是本仓库此前十余版补丁全部失败的原因：只改 viewport 无法让两边收敛，
    // 因为 surface 与 MC 认知的窗口尺寸从创建那一刻起就不是同一个数。
    //
    // 修法（与 Air 启动器 Task 48/50 同源）：GL 拥有呈现层期间对齐 1x ——
    // contentsScale=1.0、drawableSize=bounds 点数，使
    //     EGL surface == drawable == MC viewport
    // 恒成立，CoreAnimation 再把 1x 帧放大到物理屏。
    // 对齐必须在 eglCreateWindowSurface 之前完成：surface 只创建一次，事后改
    // drawableSize 改不动它（改了就是 present 尺寸失配 = 黑屏/转置）。
    // 逃生开关（诊断用，默认关闭）：AMETHYST_MOBILEGL_NO_ALIGN=1 时 MobileGL
    // 不做 1x 对齐 —— layer 保持宿主配置（contentsScale=设备 scale、
    // drawableSize=像素），attribs 也随之回物理像素，完整复现「小窗时期」
    // 的呈现状态（画面缩在左上角但可见）。用于一轮实测二分根因：
    //   开关下出现小窗（有画面）→ 黑屏由 1x 对齐对 MobileGL 链路的影响引入；
    //   开关下仍黑屏          → 与对齐无关（vendor 更新 / 后端选择 / 呈现层），
    //                            看 [SDLHook][diag] 与 [MG-Bridge] 日志。
    // 只豁免 MobileGL（isMobileGLRenderer 精确匹配），ANGLE 系渲染器不受影响。
    static NSInteger ame_mgNoAlign = -1;
    if (ame_mgNoAlign < 0) {
        ame_mgNoAlign = (mobileGL && getenv("AMETHYST_MOBILEGL_NO_ALIGN") != NULL) ? 1 : 0;
        if (ame_mgNoAlign) {
            NSLog(@"[gl_bridge][diag] AMETHYST_MOBILEGL_NO_ALIGN=1 -> MobileGL skips "
                  @"1x layer align (legacy small-window state restored)");
        }
    }
    if (g_ame_sdl3_points_surface && !ame_mgNoAlign &&
        [layer isKindOfClass:CAMetalLayer.class]) {
        CALayer *ameAlignLayer = layer;
        void (^ameAlignBlock)(void) = ^{
            CGFloat ptsW = MAX(1.0, round(ameAlignLayer.bounds.size.width));
            CGFloat ptsH = MAX(1.0, round(ameAlignLayer.bounds.size.height));
            if (ptsW > 1.0 && ptsH > 1.0) {
                ameAlignLayer.contentsScale = 1.0;
                ((CAMetalLayer *)ameAlignLayer).drawableSize = CGSizeMake(ptsW, ptsH);
                NSLog(@"[gl_bridge] SDL3 1x align: layer drawable -> %.0fx%.0f pts "
                      @"(surface==drawable==MC viewport; small-window root cause fixed)",
                      ptsW, ptsH);
            } else {
                NSLog(@"[gl_bridge] SDL3 1x align skipped: layer bounds %.0fx%.0f (not laid out yet)",
                      ptsW, ptsH);
            }
        };
        if ([NSThread isMainThread]) {
            ameAlignBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), ameAlignBlock);
        }
    }

    CGSize surfacePx = ame_eglSurfacePixelSize(layer);
    const EGLint mobileGLSurfaceAttribs[] = {
        EGL_WIDTH,  (EGLint)MAX(1.0, round(surfacePx.width)),
        EGL_HEIGHT, (EGLint)MAX(1.0, round(surfacePx.height)),
        EGL_NONE
    };
    bundle->surface = handle.eglCreateWindowSurface(g_EglDisplay, bundle->config,
        (__bridge EGLNativeWindowType)layer, mobileGL ? mobileGLSurfaceAttribs : NULL);
    if (!bundle->surface) {
        NSDebugLog(@"EGLBridge: eglCreateWindowSurface finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    // Task 36 取证：surface 在 EGL 侧的真实尺寸（MC RenderPearl 的表面配置
    // 报 1180x820，若此处 eglQuerySurface 报 2360x1640 则存在 2x 不匹配，
    // 下一轮设备日志可据此判断合成/缩放行为）。
    if (ame_raw_query_surface != NULL && bundle->surface != EGL_NO_SURFACE) {
        EGLint sw = 0, sh = 0;
        if (ame_raw_query_surface(g_EglDisplay, bundle->surface, EGL_WIDTH, &sw) &&
            ame_raw_query_surface(g_EglDisplay, bundle->surface, EGL_HEIGHT, &sh)) {
            NSLog(@"[RenderDiag] eglQuerySurface: %dx%d", sw, sh);

            // ==== 黑屏根治：present 尺寸对齐（启动器像素为唯一权威）====
            // 实证（iPhone X）：传给 eglCreateWindowSurface 的 attribs 是
            // 2436x1124（SVC 对 375*3=1125 做了偶数化 --windowHeight），而
            // ANGLE 忽略 attribs、自行按 layer.bounds x contentsScale 建面，
            // eglQuerySurface 回报 2436x1125。present 要求 drawableSize 必须
            // 与 MC 的 viewport 一致，不等即失配 = 黑屏；surface 只创建一次
            // 且不会自愈 —— 这正是「必须手动调一次分辨率才有画面」的成因。
            //
            // 旧代码在此把启动器像素（偶数化后的 2436x1124）钉回 drawable，
            // 反而制造 drawable(1124) vs surface(1125) 的失配 —— 黑屏的
            // 直接成因。现已改为：宿主 SVC 去掉取偶，使 launchJVM 告知值
            // == drawable == bounds x contentsScale == surface 四者同源，
            // 创建时即一致；本块退化为「以 surface 为准」的一次性收敛
            // （正常情况下是同值 no-op）。
            // 只在创建后写入一次，不做每帧跨线程写（Air 已实证有害）。
            // 以 surface（present 的 backbuffer）为权威：Air 定案「drawable
            // 必须等于将要呈现的 backbuffer 尺寸」。宿主 SVC 已去掉取偶，
            // windowWidth/Height == bounds x contentsScale == surface，
            // 正常情况此处是同值 no-op；保留 surface 兜底只为收敛极端
            // 情况（如外接屏 scale 变化）。
            int alignW = (sw > 0) ? sw : windowWidth;
            int alignH = (sh > 0) ? sh : windowHeight;
            if (alignW > 0 && alignH > 0 && [layer isKindOfClass:CAMetalLayer.class]) {
                CALayer *alignLayer = layer;
                void (^presentAlignBlock)(void) = ^{
                    CAMetalLayer *ml = (CAMetalLayer *)alignLayer;
                    CGFloat curW = ml.drawableSize.width;
                    CGFloat curH = ml.drawableSize.height;
                    if (((int)round(curW)) != alignW || ((int)round(curH)) != alignH) {
                        NSLog(@"[gl_bridge] present align: drawableSize %.0fx%.0f -> %dx%d "
                              @"(surface authoritative; launcher px %dx%d)",
                              curW, curH, alignW, alignH, windowWidth, windowHeight);
                        ml.drawableSize = CGSizeMake((CGFloat)alignW, (CGFloat)alignH);
                    }
                };
                if ([NSThread isMainThread]) {
                    presentAlignBlock();
                } else {
                    dispatch_sync(dispatch_get_main_queue(), presentAlignBlock);
                }
            }
        }
    }

    // 诊断（release 可见，限一次）：MobileGL 建面后立刻 dump 全链尺寸口径。
    // 三者应一致：attribs（我们传的）== MG eglQuerySurface 回读（MG 状态层的
    // Window.Width/Height）== layer 实际几何（bounds×contentsScale ==
    // drawableSize，即后端 ANGLE 建面时推断的尺寸）。任何一处对不上即为
    // 「surface 尺寸语义分叉」，直接定位黑屏层级。
    if (mobileGL) {
        static BOOL ame_loggedMGSurface = NO;
        if (!ame_loggedMGSurface) {
            ame_loggedMGSurface = YES;
            EGLint qW = 0, qH = 0;
            if (handle.eglQuerySurface) {
                handle.eglQuerySurface(g_EglDisplay, bundle->surface, EGL_WIDTH, &qW);
                handle.eglQuerySurface(g_EglDisplay, bundle->surface, EGL_HEIGHT, &qH);
            }
            CGFloat cs = layer.contentsScale;
            NSLog(@"[MG-Bridge][diag] surface created: attribs=%dx%d "
                  @"eglQuerySurface=%dx%d | layer bounds=%.0fx%.0f contentsScale=%.2f "
                  @"drawable=%.0fx%.0f (bounds*scale=%.0fx%.0f) hidden=%d",
                  (int)mobileGLSurfaceAttribs[1], (int)mobileGLSurfaceAttribs[3],
                  (int)qW, (int)qH,
                  layer.bounds.size.width, layer.bounds.size.height, (double)cs,
                  [layer isKindOfClass:CAMetalLayer.class]
                      ? ((CAMetalLayer *)layer).drawableSize.width : 0.0,
                  [layer isKindOfClass:CAMetalLayer.class]
                      ? ((CAMetalLayer *)layer).drawableSize.height : 0.0,
                  layer.bounds.size.width * cs, layer.bounds.size.height * cs,
                  (int)layer.isHidden);
        }
    }

    const EGLint gles_ctx_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    // MobileGL 走真正的 desktop GL：要求 3.3 Core Profile。
    // Mithril 同样导出 desktop GL 3.3 Core，但其 EGLConfig 已同时声明
    // EGL_OPENGL_BIT | EGL_OPENGL_ES3_BIT，沿用 ES 版的 CLIENT_VERSION=3 即可
    // （与 Uniaball 官方 launcher-patch 中验证过的配置保持一致）。
    const EGLint desktop_ctx_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3,
        EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE
    };
    bundle->context = handle.eglCreateContext(g_EglDisplay, bundle->config, share ? share->context : EGL_NO_CONTEXT,
        useDesktopCtx ? desktop_ctx_attribs : gles_ctx_attribs);
    if (!bundle->context) {
        NSDebugLog(@"EGLBridge: Error eglCreateContext finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    //NSDebugLog(@"EGLBridge: Created CTX pointer = %p (source = %p)", bundle->context, share?share->context:0);

    return bundle;
}

// ===== 诊断探针：复现 LWJGL 3.4.1 GL.createCapabilities() 的取值路径 =====
//
// LWJGL 3.4.1 源码（GL.java:427-456，本仓库 lwjgl-lib/3.4.1-lwgjl 可查）：
//   GetError    = functionProvider.getFunctionAddress("glGetError");
//   GetString   = functionProvider.getFunctionAddress("glGetString");
//   GetIntegerv = functionProvider.getFunctionAddress("glGetIntegerv");
//   callPV(GL_MAJOR_VERSION, ..., GetIntegerv);
//   if (callI(GetError) == GL_NO_ERROR && 3 <= majorVersion) { /* 3.0+ 分支 */ }
//   else {
//       versionString = glGetString(GL_VERSION);
//       if (versionString == null || callI(GetError) != GL_NO_ERROR)
//           throw new IllegalStateException("There is no OpenGL context current...");
//   }
//
// GLFW 库句柄构造为 MacOSXLibraryDL("AngelAuraAmethyst", RTLD_DEFAULT)，
// 即 LWJGL 的 GL 入口点来自 dlsym(RTLD_DEFAULT, ...) 全局查找，
// 与 EGL 侧 eglMakeCurrent 用的是哪一份实现无关。
// 因此这里同样用 RTLD_DEFAULT 取值，才能反映 LWJGL 真正拿到的是谁的实现。
//
// 只打印前 3 次，避免日志刷屏。
static void ame_diagGlEntryPoints(void) {
    static int s_diagCount = 0;
    if (s_diagCount >= 3) { return; }
    s_diagCount++;

    enum { AME_GL_VERSION = 0x1F02, AME_GL_MAJOR_VERSION = 0x821B };
    typedef unsigned int ame_gl_enum_t;
    typedef int ame_gl_int_t;
    typedef const unsigned char *(*ame_glGetString_t)(ame_gl_enum_t);
    typedef void (*ame_glGetIntegerv_t)(ame_gl_enum_t, ame_gl_int_t *);
    typedef ame_gl_enum_t (*ame_glGetError_t)(void);

    void *curCtx = handle.eglGetCurrentContext ? handle.eglGetCurrentContext() : NULL;
    NSLog(@"[gl_bridge][diag] #%d eglGetCurrentContext=%p display=%p",
          s_diagCount, curCtx, g_EglDisplay);

    void *symGetString = dlsym(RTLD_DEFAULT, "glGetString");
    Dl_info dli;
    const char *image = "<unknown>";
    if (symGetString != NULL && dladdr(symGetString, &dli) != 0 && dli.dli_fname != NULL) {
        image = dli.dli_fname;
    }
    NSLog(@"[gl_bridge][diag] #%d dlsym(RTLD_DEFAULT,\"glGetString\")=%p image=%s",
          s_diagCount, symGetString, image);

    if (symGetString != NULL) {
        const unsigned char *version = ((ame_glGetString_t)symGetString)(AME_GL_VERSION);
        NSLog(@"[gl_bridge][diag] #%d glGetString(GL_VERSION)=%s",
              s_diagCount, version != NULL ? (const char *)version : "(NULL)");
    }

    void *symGetIntegerv = dlsym(RTLD_DEFAULT, "glGetIntegerv");
    void *symGetError = dlsym(RTLD_DEFAULT, "glGetError");
    if (symGetIntegerv != NULL && symGetError != NULL) {
        ((ame_glGetError_t)symGetError)();
        ame_gl_int_t major = -1;
        ((ame_glGetIntegerv_t)symGetIntegerv)(AME_GL_MAJOR_VERSION, &major);
        ame_gl_enum_t err = ((ame_glGetError_t)symGetError)();
        NSLog(@"[gl_bridge][diag] #%d glGetIntegerv(GL_MAJOR_VERSION)=%d glGetError=0x%x",
              s_diagCount, major, (unsigned)err);
    }
}
// ===== 诊断探针结束 =====

void gl_make_current(gl_render_window_t* bundle) {
    if(!bundle) {
        if(handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            currentBundle = NULL;
        }
        return;
    }

    if(handle.eglMakeCurrent(g_EglDisplay, bundle->surface, bundle->surface, bundle->context)) {
        currentBundle = (basic_render_window_t *)bundle;
        if (ame_mgFrontendActive) {
            NSLog(@"[MG-Bridge] eglMakeCurrent via frontend OK (ctx=%p) -- "
                  @"MGContext tracked, per-context state bound",
                  (void *)bundle->context);
        }

        // MobileGlues 2.0: on Apple, init GL ES function pointers now that
        // we have a current context.  mg_init_gles() uses RTLD_DEFAULT to
        // resolve ANGLE's GLES symbols and queries GL version/extensions.
        // Only runs once; subsequent calls are a no-op.
        // (Task 36 引导成功后这里是无害的 no-op；引导失败时仍是原始兜底路径。)
        static BOOL mgInitialized = NO;
        if (!mgInitialized) {
            mgInitialized = YES;
            typedef void (*mg_init_gles_t)(void);
            mg_init_gles_t fn = (mg_init_gles_t)dlsym(RTLD_DEFAULT, "mg_init_gles");
            if (fn) {
                fn();
                NSLog(@"[gl_bridge] mg_init_gles() called after eglMakeCurrent");
            } else {
                NSLog(@"[gl_bridge] mg_init_gles not found (old MobileGlues?)");
            }
        }

        // 帧率解锁关键点：在 EGL context 首次变为 current 后立即设置 swap interval=0。
        //
        // 为什么必须在这里设置（而不是等 MC 调用 glfwSwapInterval 时才设置）：
        //
        // 对于 zink 渲染器（Mesa 21.0），Vulkan swapchain 是延迟创建的——
        // 在第一次 eglSwapBuffers 或需要 swapchain 时才创建。
        // zink 创建 swapchain 时会根据当前 eglSwapInterval 的值选择 present mode：
        //   - interval=0 → VK_PRESENT_MODE_IMMEDIATE_KHR（不等 vsync，帧率可超 60）
        //   - interval=1 → VK_PRESENT_MODE_FIFO_KHR（等 vsync，锁在屏幕刷新率）
        //
        // 如果等 MC 调用 glfwSwapInterval(1) → pojavSwapInterval(0) → eglSwapInterval(0)
        // 时才设置，swapchain 可能已经用默认的 FIFO 创建了。
        // Mesa 21.0 的 zink 不会在 eglSwapInterval 变化时重建 swapchain，
        // 导致 present mode 固定为 FIFO，帧率被锁死在屏幕刷新率（60Hz/120Hz）。
        //
        // 在 gl_make_current 中提前设置 eglSwapInterval(0)，可确保 zink 创建
        // swapchain 时读到 interval=0，从而选择 IMMEDIATE present mode。
        //
        // 这对 ANGLE Metal 后端也有效（ANGLE 在 interval=0 时不等 vsync）。
        if (getenv("POJAV_DISABLE_VSYNC") && strcmp(getenv("POJAV_DISABLE_VSYNC"), "1") == 0) {
            static BOOL s_loggedInitialSwapInterval = NO;
            handle.eglSwapInterval(g_EglDisplay, 0);
            if (!s_loggedInitialSwapInterval) {
                s_loggedInitialSwapInterval = YES;
                NSLog(@"[gl_bridge] eglSwapInterval(0) set immediately after eglMakeCurrent (POJAV_DISABLE_VSYNC=1, renderer=%s)", getenv("AMETHYST_RENDERER") ?: "<unset>");
            }
        }
        ame_diagGlEntryPoints();
    } else {
        NSLog(@"EGLBridge: eglMakeCurrent returned with error: 0x%x", handle.eglGetError());
    }
}

void gl_swap_buffers() {
    // currentBundle 只在 eglMakeCurrent 成功后赋值。若 MC 在 MakeCurrent 之前
    // （或 MakeCurrent(NULL) 释放之后）调用 swap，这里解引用空指针会直接段错误。
    // SDL3 路径下 SDL_GL_SwapWindow 由我们接管，调用时机不再由 GLFW 约束，
    // 所以必须显式防护。
    if (currentBundle == NULL) {
        NSLog(@"EGLBridge: gl_swap_buffers called with no current context, ignored");
        return;
    }
    ame_geo_check_and_heal(currentBundle);
    if (!handle.eglSwapBuffers(g_EglDisplay, currentBundle->gl.surface) && handle.eglGetError() == EGL_BAD_SURFACE) {
        NSLog(@"eglSwapBuffers error 0x%x", handle.eglGetError());
        //stopSwapBuffers = true;
        //closeGLFWWindow();
    }
}

void gl_swap_interval(int swapInterval) {
    handle.eglSwapInterval(g_EglDisplay, swapInterval);
}

void gl_terminate() {
    atomic_store(&g_ame_geo_owns_layer, 0);
    g_ame_geo_mismatch = 0;
    g_ame_geo_attempts = 0;
    g_ame_geo_fused = 0;
    if (g_ame_geo_layer_cf != NULL) { CFRelease(g_ame_geo_layer_cf); g_ame_geo_layer_cf = NULL; }
    handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    handle.eglDestroySurface(g_EglDisplay, currentBundle->gl.surface);
    handle.eglDestroyContext(g_EglDisplay, currentBundle->gl.context);
    handle.eglTerminate(g_EglDisplay);
    handle.eglReleaseThread();
    free(currentBundle);
    currentBundle = nil;
}

void set_gl_bridge_tbl() {
    br_init = gl_init;
    br_init_context = (br_init_context_t) gl_init_context;
    br_make_current = (br_make_current_t) gl_make_current;
    br_swap_buffers = gl_swap_buffers;
    br_swap_interval = gl_swap_interval;
    br_terminate = gl_terminate;
}
