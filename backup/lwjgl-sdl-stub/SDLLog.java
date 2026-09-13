/*
 * Stub override for org.lwjgl.sdl.SDLLog, tailored for Amethyst iOS.
 *
 * On iOS there is no real libSDL3, so the upstream $Functions class cannot
 * resolve SDL_SetLogPriorities etc. and its <clinit> aborts with
 * "A required function is missing". We replace the module with local-state
 * stubs. MC only uses SDL_SetLogOutputFunction + a few log setters; making
 * everything a no-op keeps it healthy.
 */
package org.lwjgl.sdl;

import javax.annotation.Nullable;

import java.nio.ByteBuffer;

import org.lwjgl.system.NativeType;
import org.lwjgl.system.Callback;

import static org.lwjgl.system.MemoryUtil.*;

public class SDLLog {

    public static final int SDL_LOG_CATEGORY_APPLICATION = 0;
    public static final int SDL_LOG_CATEGORY_ERROR       = 1;
    public static final int SDL_LOG_CATEGORY_ASSERT      = 2;
    public static final int SDL_LOG_CATEGORY_SYSTEM      = 3;
    public static final int SDL_LOG_CATEGORY_AUDIO       = 4;
    public static final int SDL_LOG_CATEGORY_VIDEO       = 5;
    public static final int SDL_LOG_CATEGORY_RENDER      = 6;
    public static final int SDL_LOG_CATEGORY_INPUT       = 7;
    public static final int SDL_LOG_CATEGORY_TEST        = 8;
    public static final int SDL_LOG_CATEGORY_GPU         = 9;
    public static final int SDL_LOG_CATEGORY_RESERVED2   = 10;
    public static final int SDL_LOG_CATEGORY_RESERVED3   = 11;
    public static final int SDL_LOG_CATEGORY_RESERVED4   = 12;
    public static final int SDL_LOG_CATEGORY_RESERVED5   = 13;
    public static final int SDL_LOG_CATEGORY_RESERVED6   = 14;
    public static final int SDL_LOG_CATEGORY_RESERVED7   = 15;
    public static final int SDL_LOG_CATEGORY_RESERVED8   = 16;
    public static final int SDL_LOG_CATEGORY_RESERVED9   = 17;
    public static final int SDL_LOG_CATEGORY_RESERVED10  = 18;
    public static final int SDL_LOG_CATEGORY_CUSTOM      = 19;

    public static final int SDL_LOG_PRIORITY_INVALID  = 0;
    public static final int SDL_LOG_PRIORITY_TRACE    = 1;
    public static final int SDL_LOG_PRIORITY_VERBOSE  = 2;
    public static final int SDL_LOG_PRIORITY_DEBUG    = 3;
    public static final int SDL_LOG_PRIORITY_INFO     = 4;
    public static final int SDL_LOG_PRIORITY_WARN     = 5;
    public static final int SDL_LOG_PRIORITY_ERROR    = 6;
    public static final int SDL_LOG_PRIORITY_CRITICAL = 7;
    public static final int SDL_LOG_PRIORITY_COUNT    = 8;

    private SDLLog() {
    }

    public static void SDL_SetLogPriorities(@NativeType("SDL_LogPriority") int priority) {
        // no-op: no SDL logging on iOS stub
    }

    public static void SDL_SetLogPriority(int category, @NativeType("SDL_LogPriority") int priority) {
        // no-op
    }

    @NativeType("SDL_LogPriority")
    public static int SDL_GetLogPriority(int category) {
        return SDL_LOG_PRIORITY_INFO;
    }

    public static void SDL_ResetLogPriorities() {
        // no-op
    }

    public static boolean nSDL_SetLogPriorityPrefix(int priority, long prefix) {
        return true;
    }

    @NativeType("bool")
    public static boolean SDL_SetLogPriorityPrefix(@NativeType("SDL_LogPriority") int priority,
                                                    @NativeType("char const *") @Nullable ByteBuffer prefix) {
        return true;
    }

    @NativeType("bool")
    public static boolean SDL_SetLogPriorityPrefix(@NativeType("SDL_LogPriority") int priority,
                                                    @NativeType("char const *") @Nullable CharSequence prefix) {
        return true;
    }

    public static void nSDL_Log(long fmt) {
        // no-op
    }

    public static void SDL_Log(@NativeType("char const *") @Nullable ByteBuffer fmt) {
        // no-op
    }

    public static void SDL_Log(@NativeType("char const *") @Nullable CharSequence fmt) {
        // no-op
    }

    public static void nSDL_LogTrace(int category, long fmt) { }
    public static void SDL_LogTrace(int category, @NativeType("char const *") @Nullable ByteBuffer fmt) { }
    public static void SDL_LogTrace(int category, @NativeType("char const *") @Nullable CharSequence fmt) { }

    public static void nSDL_LogVerbose(int category, long fmt) { }
    public static void SDL_LogVerbose(int category, @NativeType("char const *") @Nullable ByteBuffer fmt) { }
    public static void SDL_LogVerbose(int category, @NativeType("char const *") @Nullable CharSequence fmt) { }

    public static void nSDL_LogDebug(int category, long fmt) { }
    public static void SDL_LogDebug(int category, @NativeType("char const *") @Nullable ByteBuffer fmt) { }
    public static void SDL_LogDebug(int category, @NativeType("char const *") @Nullable CharSequence fmt) { }

    public static void nSDL_LogInfo(int category, long fmt) { }
    public static void SDL_LogInfo(int category, @NativeType("char const *") @Nullable ByteBuffer fmt) { }
    public static void SDL_LogInfo(int category, @NativeType("char const *") @Nullable CharSequence fmt) { }

    public static void nSDL_LogWarn(int category, long fmt) { }
    public static void SDL_LogWarn(int category, @NativeType("char const *") @Nullable ByteBuffer fmt) { }
    public static void SDL_LogWarn(int category, @NativeType("char const *") @Nullable CharSequence fmt) { }

    public static void nSDL_LogError(int category, long fmt) { }
    public static void SDL_LogError(int category, @NativeType("char const *") @Nullable ByteBuffer fmt) { }
    public static void SDL_LogError(int category, @NativeType("char const *") @Nullable CharSequence fmt) { }

    public static void nSDL_LogCritical(int category, long fmt) { }
    public static void SDL_LogCritical(int category, @NativeType("char const *") @Nullable ByteBuffer fmt) { }
    public static void SDL_LogCritical(int category, @NativeType("char const *") @Nullable CharSequence fmt) { }

    public static void nSDL_LogMessage(int category, int priority, long fmt) { }
    public static void SDL_LogMessage(int category, @NativeType("SDL_LogPriority") int priority,
                                       @NativeType("char const *") @Nullable ByteBuffer fmt) { }
    public static void SDL_LogMessage(int category, @NativeType("SDL_LogPriority") int priority,
                                       @NativeType("char const *") @Nullable CharSequence fmt) { }

    public static void nSDL_LogMessageV(int category, int priority, long fmt, long ap) { }
    public static void SDL_LogMessageV(int category, @NativeType("SDL_LogPriority") int priority,
                                        @NativeType("char const *") @Nullable ByteBuffer fmt, long ap) { }
    public static void SDL_LogMessageV(int category, @NativeType("SDL_LogPriority") int priority,
                                        @NativeType("char const *") @Nullable CharSequence fmt, long ap) { }

    @Nullable
    public static Callback nSDL_GetDefaultLogOutputFunction() {
        return null;
    }

    @Nullable
    public static Callback SDL_GetDefaultLogOutputFunction() {
        return null;
    }

    public static void nSDL_SetLogOutputFunction(long callback, long userdata) {
        // no-op
    }

    public static void SDL_SetLogOutputFunction(@Nullable SDL_LogOutputFunctionI callback, long userdata) {
        // no-op
    }

    public static void nSDL_GetLogOutputFunction(long callback, long userdata) {
        if (callback != 0L) {
            memPutAddress(callback, 0L);
        }
        if (userdata != 0L) {
            memPutAddress(userdata, 0L);
        }
    }

    public static void SDL_GetLogOutputFunction(@Nullable org.lwjgl.PointerBuffer callback,
                                                @Nullable org.lwjgl.PointerBuffer userdata) {
        if (callback != null) callback.put(0, 0L);
        if (userdata != null) userdata.put(0, 0L);
    }
}