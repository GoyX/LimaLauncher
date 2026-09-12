// MobileGlues - main.cpp
// Copyright (c) 2025-2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v2.1:
//   https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
// SPDX-License-Identifier: LGPL-2.1-only
// End of Source File Header

#include "config/settings.h"
#include "config/stats.h"
#include "egl/egl.h"
#include "egl/loader.h"
#include "gl/envvars.h"
#include "gl/gl.h"
#include "gl/log.h"
#include "gl/mg.h"
#include "gles/loader.h"
#include "includes.h"
#include <cerrno>
#include <cstring>
#include <sys/stat.h>

#define DEBUG 0

#ifndef __APPLE__
__attribute__((used))
#endif
const char* license = "GNU LGPL-2.1 License";

void init_config() {
    if (!check_path()) return;
    config_refresh();
    // One dlopen of this library is one launch. Counting it here, before any
    // rendering work, means a game that crashes on the first frame still counts.
    bump_launch_count();
}

void show_license() {
    LOG_V("The Open Source License of MobileGlues: ");
    LOG_V("  %s", license);
}

#if PROFILING

PERFETTO_TRACK_EVENT_STATIC_STORAGE();

void init_perfetto() {
    perfetto::TracingInitArgs args;

    args.backends |= perfetto::kSystemBackend;

    perfetto::Tracing::Initialize(args);
    perfetto::TrackEvent::Register();
}
#endif

void proc_init() {
    init_config();

    clear_log();
    start_log();

    LOG_V("Initializing %s ...", RENDERERNAME);
    show_license();

    init_settings();

    load_libs();
    init_target_egl();
    init_target_gles();
    set_multidraw_setting();

    init_settings_post();

#if PROFILING
    init_perfetto();
#endif

    // Cleanup
#ifndef __APPLE__
    destroy_temp_egl_ctx();
#endif
    g_initialized = 1;
}

// ============================================================================
// Air 启动器 Task 36 同款显式初始化入口（对齐 fork 2.0.16 的 mg_init_gles）。
//
// 背景：proc_init（静态构造）在 dlopen 本镜像时运行，彼时进程里没有任何
// 当前 GL 上下文 —— init_target_gles() 尾部的 caps 检测（set_hardware /
// set_es_version，经 glGetString / glGetIntegerv 查询 ES 版本与能力）在
// 无上下文环境下得到的值不可靠。宿主 bridge（gl_bridge）在 gl_init_context
// 里用一次性 raw pbuffer+ES3 上下文 makeCurrent 后调用本入口，让 caps
// 检测在"有当前上下文"的正确环境中完成/校正。
//
// 幂等：仅执行一次；后续调用为无操作（与 fork 2.0.16 的语义一致）。
//   * load_libs(): iOS 分支是显式 dlopen 已加载的 ANGLE frameworks，
//     重复调用仅增加引用计数，无副作用。
//   * init_target_egl(): LOAD_EGL 静态指针重复赋值无害；内部 32x32
//     probe 会再多留一个一次性 pbuffer/ctx（Apple 上本就不销毁），可接受。
//   * init_target_gles(): 函数表 memset 后重填（幂等）；init_gl_state()
//     只重置 proxy 状态与各 Map 的初始容量（彼时尚无任何渲染对象）；
//     尾部 caps 检测是本入口的核心价值 —— 在有当前上下文的环境重测。
// ============================================================================
__attribute__((visibility("default")))
void mg_init_gles(void) {
    static int s_done = 0;
    if (s_done) {
        LOG_D("mg_init_gles: already initialized, no-op");
        return;
    }
    s_done = 1;

    LOG_W_FORCE("[MG] mg_init_gles: explicit init (caps re-detected under a current context)\n");

    load_libs();
    init_target_egl();
    init_target_gles();
    set_multidraw_setting();
}
