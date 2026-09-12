// MobileGlues - glx/lookup.cpp
// Copyright (c) 2025-2026 MobileGL-Dev
// Licensed under the GNU Lesser General Public License v2.1:
//   https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
// SPDX-License-Identifier: LGPL-2.1-only
// End of Source File Header

#include "lookup.h"

#include "../config/settings.h"
#include "../gl/envvars.h"
#include "../gl/log.h"
#include "../gl/mg.h"
#include "../includes.h"
#include <EGL/egl.h>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>

#define DEBUG 0

// The application can ask for a multi-draw entry point by name and call the
// result directly, bypassing the dispatcher in gl/multidraw.cpp. Hand back the
// symbol implementing whatever backend that entry point resolved to, so both
// routes agree. The suffix table lives in config/settings.cpp for exactly that
// reason.
std::string handle_multidraw_func_name(std::string name) {
    md_entry_t entry;
    if (name == "glMultiDrawElements") {
        entry = md_entry_t::Elements;
    } else if (name == "glMultiDrawElementsBaseVertex") {
        entry = md_entry_t::ElementsBaseVertex;
    } else {
        // Everything else -- glMultiDrawArrays, the two *Indirect entry points and
        // every EXT/ARB alias -- is a single exported definition that selects its
        // own backend internally, so the plain name is already correct.
        return name;
    }

    const char* suffix = md_backend_suffix(multidraw_backend_of(entry));
    if (!suffix) {
        // Auto should never survive init_settings_post. Fall back to the
        // dispatcher rather than to dlsym of a name that does not exist.
        LOG_W_FORCE("handle_multidraw_func_name: %s has no resolved backend, using the dispatcher", name.c_str())
        return name;
    }
    return "mg_" + name + suffix;
}

void* glXGetProcAddress(const char* name) {
    LOG()
    std::string real_func_name = handle_multidraw_func_name(std::string(name));
#ifdef __APPLE__
    // Resolve from this layer's OWN image handle instead of the process-wide
    // flat namespace.
    //
    // MC 26.3's renderpearl GlBackend.loadLibrary cross-checks its two GL entry
    // point providers: the LWJGL function provider (built on this layer's
    // exported glXGetProcAddress) and SDL_GL_GetProcAddress (hooked by the host
    // to dlsym this layer's handle). Both must return the SAME address for
    // "glGetError". Resolving through the flat namespace (RTLD_DEFAULT) put
    // this layer and the host's ANGLE libGLESv2 -- which also exports every
    // gl* name -- in a race decided by dyld image order: whoever loaded first
    // won, the two providers disagreed, renderpearl rejected the OpenGL backend
    // with "glGetError mismatch" and the game fell back to MoltenVK.
    //
    // RTLD_SELF / RTLD_NEXT are NOT usable here: dyld derives their caller
    // image from __builtin_return_address(0), and the host launcher rebinds
    // dlsym process-wide, so that address lands in the HOST BINARY rather than
    // in this layer. A handle-based dlsym has no caller-image ambiguity.
    //
    // The handle comes from dladdr on one of this layer's own functions plus
    // dlopen(RTLD_NOLOAD), which never maps a second copy of the image.
    // RTLD_DEFAULT stays as the fallback for entry points this layer does not
    // export (backend-only extension functions).
    static void* own_image = nullptr;
    static bool own_image_tried = false;
    if (!own_image_tried) {
        own_image_tried = true;
        Dl_info info{};
        if (dladdr((void*)&glXGetProcAddress, &info) && info.dli_fname != nullptr) {
            own_image = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
            if (own_image != nullptr) {
                LOG_W_FORCE("[MG] own-image resolution: handle for %s -- glXGetProcAddress resolves this layer's exports first", info.dli_fname)
            } else {
                const char* dlerr = dlerror();
                LOG_W_FORCE("[MG] own-image resolution: dlopen('%s', RTLD_NOLOAD) failed (%s), falling back to RTLD_DEFAULT",
                            info.dli_fname, dlerr != nullptr ? dlerr : "unknown")
            }
        } else {
            LOG_W_FORCE("[MG] own-image resolution: dladdr could not identify this image, falling back to RTLD_DEFAULT")
        }
    }
    void* resolved = nullptr;
    if (own_image != nullptr) {
        resolved = dlsym(own_image, real_func_name.c_str());
    }
    if (resolved == nullptr) {
        resolved = dlsym(RTLD_DEFAULT, real_func_name.c_str());
    }
    return resolved;
#else

    void* proc = nullptr;

    proc = dlsym(RTLD_DEFAULT, real_func_name.c_str());

    if (!proc) {
        LOG_W("Failed to get OpenGL function: %s", real_func_name.c_str())
        return nullptr;
    }

    return proc;
#endif
}

void* glXGetProcAddressARB(const char* name) {
    return glXGetProcAddress(name);
}