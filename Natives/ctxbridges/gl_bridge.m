#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <string.h>
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

// 是否允许把 CAMetalLayer 本身对齐成 1x（contentsScale=1.0 + drawableSize=点数）。
//
// 1x 对齐要解决的是一个**只对 ANGLE 存在**的问题：ANGLE 从 layer 推断
// window surface 尺寸，它读的是 bounds × contentsScale，而 MC 26.3+SDL3 以
// 「点」设置 viewport —— 两者差一个设备 scale，画面只占后缓冲左上 1/9。
// 把 layer 对齐 1x 后 ANGLE 读到的就是点数，与 MC viewport 收敛。
//
// 但这条修法**不能无差别套用到自带 EGL 的 desktop GL 渲染器**（MobileGL 系列：
// isSelfEglRenderer + isDesktopGLRenderer）。它们的 window surface 尺寸不是
// ANGLE 那样「从 layer 推断」，而是本文件用 mobileGLSurfaceAttribs **显式传入**，
// 且其呈现后端（DirectGLES）内部会用 eglQuerySurface 回读该尺寸来建自己的
// ES/Metal 呈现面。于是 1x 对齐对这种渲染器产生的是纯粹的副作用：
//   drawableSize 由物理像素（2436x1125）被改成点数（812x375），
//   ame_eglSurfacePixelSize() 又优先返回 drawableSize，
//   显式 attribs 随之从「像素」变成「点数」，
//   而它的呈现面仍要合成到 3x 的物理屏上 —— 尺寸语义塌陷，画面全黑
//   （fps 正常、零 GL 错误，因为渲染确实发生了，只是没落在呈现面上）。
//
// 回归实证：本仓库 8f36d4d9（引入 1x 对齐）之前，MobileGL-gles 的表现是
// 「小窗」（画面缩在左上角，即渲染成功、只是尺寸错），该提交之后才变成黑屏；
// 72 分钟后即出现 b3e362ed「修复 MC 26.3 OpenGL 后端黑屏」，此后一路补丁。
//
// 因此本标志只在「确实需要修正 ANGLE 读取源」时置位。
static BOOL g_ame_sdl3_align_layer_1x = NO;

BOOL Amethyst_SDL3SurfaceWantsPoints(void) {
    // 对外语义保持不变（SDL3 + GL 路径即为 YES），但由 gl_init_context 依据
    // 渲染器决定是否真的对 layer 做 1x 对齐。
    return g_ame_sdl3_points_surface && g_ame_sdl3_align_layer_1x;
}

// 与 Amethyst_SDL3SurfaceWantsPoints() 互补：SDL3 + GL 路径成立，但 layer 保持
// 物理像素（即自带 EGL 的桌面 GL 渲染器，1x 对齐被跳过）。此时 MC 仍以「点」
// 回报窗口尺寸，因此 windowWidth/Height 要按点数上报，而 drawableSize 保持像素。
// 宿主的 updateSavedResolution 用它区分「送 JVM 的窗口尺寸」与「layer 的呈现尺寸」。
BOOL Amethyst_SDL3SurfaceWantsPhysicalLayer(void) {
    return g_ame_sdl3_points_surface && !g_ame_sdl3_align_layer_1x;
}

// 供 egl_bridge 的 viewport 守护判定：当前是否为「SDL3 + 点数窗口」路径
// （即 MC 以点设置 viewport）。此时 EGL surface 的像素尺寸与 viewport 的
// 点数尺寸本来就不同口径，守护不得据此改写 viewport。
BOOL amethyst_sdl3_wants_points_window(void) {
    return g_ame_sdl3_points_surface;
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

static bool dlsym_EGL() {
    // EGL 符号来源：
    //   - Mithril / MobileGL：自带完整 EGL 实现，必须从自身 dylib 解析。
    //     若复用 ANGLE 的 EGL，会创建 ANGLE 的 Metal 上下文而不是渲染器自己的
    //     surface，且 eglChooseConfig 在这些渲染器请求的属性组合下可能返回 0
    //     个配置，触发 gl_init_context 里的 assert(bundle->config) 崩溃。
    //   - 其余渲染器（gl4es / ANGLE / MobileGlues / LTW）：仍从 ANGLE 解析。
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

// ============================================================================
// 关于「MobileGlues 前端 EGL 路由」（Air 启动器 Task 36）：本仓库**刻意不移植**。
//
// 评估结论（2026-09 复核）：
//   1) Air 的 Task 36 门控为
//          strcmp(renderer, RENDERER_NAME_MOBILEGLUES) == 0 && !isSelfEglRenderer(renderer)
//      只作用于 **mobileglues**，且明确排除自带 EGL 的渲染器。
//      Air 从未对 libMobileGL.dylib / libMobileGL-gles.dylib 做过前端路由。
//   2) 本次黑屏的复现条件（用户实测）是 `libMobileGL-gles.dylib` —— 它属于
//      isSelfEglRenderer，EGL 全部来自自身镜像，不存在「MGContext 未建立」这条链
//      （那是 MobileGlues 的架构，与 MobileGL 无关）。
//   3) 时间线否证：在 8f36d4d9 引入 1x 呈现层对齐之前，MobileGL-gles 的表现是
//      「小窗」（画面缩在左上角），说明其 EGL 上下文 / 翻译管线 / swap 链路一直是
//      通的。若 EGL 生命周期真的被绕过，1x 之前就该是黑屏而非小窗。
//
// 因此本文件不引入 MobileGlues 前端路由；本次黑屏的修复集中在 1x 对齐的
// 适用条件上（见文件上方 g_ame_sdl3_align_layer_1x 的说明）。
// ============================================================================


/// sdl3_hook.m 导出：SDL3 路径下建窗前是否已把 GL profile 强制为 ES。
/// 非 SDL3 路径（GLFW / MC 26.2 及以下）恒返回 false。
extern bool amethyst_sdl3_wants_gles_context(void);


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
        if (ds.width >= 1.0 && ds.height >= 1.0) {
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
    if (desktopGL) {
        NSDebugLog(@"EGLBridge: Binding to desktop OpenGL");
        bindResult = handle.eglBindAPI(EGL_OPENGL_API);
    } else {
        NSDebugLog(@"EGLBridge: Binding to OpenGL ES");
        bindResult = handle.eglBindAPI(EGL_OPENGL_ES_API);
    }
    if (!bindResult) NSDebugLog(@"EGLBridge: bind failed: %p\n", handle.eglGetError());

    CALayer *layer = SurfaceViewController.surface.layer;

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
        NSLog(@"[gl_bridge] SDL3 path: restored GameSurfaceView above SDL view "
              @"(mode=default, %.0fx%.0f @%.2fx)",
              layer.bounds.size.width * layer.contentsScale,
              layer.bounds.size.height * layer.contentsScale,
              layer.contentsScale);
        // MC 以「点」设置 viewport，呈现层必须同步对齐 1x，见下方对齐块说明。
        // 但仅对「EGL surface 尺寸从 layer 推断」的渲染器（ANGLE 系）需要动
        // layer；自带 EGL 的桌面 GL 渲染器（MobileGL / Mithril）的 surface 尺寸
        // 由显式 attribs 决定，动 layer 只会把尺寸语义改坏 —— 见 g_ame_sdl3_align_layer_1x
        // 声明处的完整说明与回归时间线。
        g_ame_sdl3_points_surface = YES;
        g_ame_sdl3_align_layer_1x = !isSelfEglRenderer(renderer.UTF8String)
                                    && !isDesktopGLRenderer(renderer.UTF8String);
        if (!g_ame_sdl3_align_layer_1x) {
            NSLog(@"[gl_bridge] SDL3 1x layer align SKIPPED for renderer %s "
                  @"(self-EGL desktop GL: surface size comes from explicit attribs; "
                  @"realigning the layer would collapse its size semantics -> black screen)",
                  renderer.UTF8String ?: "<unset>");
        }
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
    if (g_ame_sdl3_align_layer_1x && [layer isKindOfClass:CAMetalLayer.class]) {
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
    // MobileGL 系列的 window surface 尺寸完全由这里显式决定（它的
    // eglCreateWindowSurface 不会从 CALayer 推断），因此这是修「小窗」的正确
    // 着力点 —— 不需要动 layer。
    //
    // 尺寸语义（关键，黑屏回归的根源）：
    //   MC 26.3+SDL3 以「点」设置 viewport（812x375），所以这里也必须给点数，
    //   surface 才会 == MC viewport，小窗才会消失。
    //   - 1x 对齐生效时（ANGLE 系）：layer 的 contentsScale 已被改成 1.0，
    //     ame_eglSurfacePixelSize 返回的 drawableSize 就是点数，直接可用。
    //   - 1x 对齐被跳过时（MobileGL 等 self-EGL desktop GL）：layer 仍保持
    //     物理像素（contentsScale=3.0、drawableSize=2436x1125），此时
    //     surfacePx 是像素，**必须除以 contentsScale 换算成点数**，否则又退回
    //     原来那个「surface=像素、viewport=点」的 1/9 小窗。
    CGSize surfaceAttribSize = surfacePx;
    if (!g_ame_sdl3_align_layer_1x && layer.contentsScale > 1.0) {
        surfaceAttribSize = CGSizeMake(surfacePx.width / layer.contentsScale,
                                       surfacePx.height / layer.contentsScale);
        NSLog(@"[gl_bridge] SDL3 points surface (self-EGL renderer, 1x layer align "
              @"skipped): explicit attribs %.0fx%.0f px -> %.0fx%.0f pts (== MC viewport)",
              surfacePx.width, surfacePx.height,
              surfaceAttribSize.width, surfaceAttribSize.height);
    }
    const EGLint mobileGLSurfaceAttribs[] = {
        EGL_WIDTH,  (EGLint)MAX(1.0, round(surfaceAttribSize.width)),
        EGL_HEIGHT, (EGLint)MAX(1.0, round(surfaceAttribSize.height)),
        EGL_NONE
    };
    if (mobileGL) {
        // 黑屏取证：MobileGL 路径把尺寸来源全量留痕，一轮实测即可确认
        // surface / viewport / layer 三者是否收敛。
        NSLog(@"[gl_bridge] MobileGL window surface: EGL_WIDTH=%d EGL_HEIGHT=%d | "
              @"layer bounds=%.0fx%.0f contentsScale=%.2f drawableSize=%.0fx%.0f | "
              @"1xLayerAlign=%d pointsSurface=%d",
              (int)mobileGLSurfaceAttribs[1], (int)mobileGLSurfaceAttribs[3],
              layer.bounds.size.width, layer.bounds.size.height,
              (double)layer.contentsScale,
              [layer isKindOfClass:CAMetalLayer.class]
                  ? ((CAMetalLayer *)layer).drawableSize.width : 0.0,
              [layer isKindOfClass:CAMetalLayer.class]
                  ? ((CAMetalLayer *)layer).drawableSize.height : 0.0,
              (int)g_ame_sdl3_align_layer_1x, (int)g_ame_sdl3_points_surface);
    }
    bundle->surface = handle.eglCreateWindowSurface(g_EglDisplay, bundle->config,
        (__bridge EGLNativeWindowType)layer, mobileGL ? mobileGLSurfaceAttribs : NULL);
    if (!bundle->surface) {
        NSDebugLog(@"EGLBridge: eglCreateWindowSurface finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
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
