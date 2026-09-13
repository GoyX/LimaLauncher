/*
 * Stub override for org.lwjgl.sdl.SDLPlatform, tailored for Amethyst iOS.
 *
 * Upstream calls SDL_GetPlatform() through a native function pointer
 * resolved from libSDL3. On iOS there is no real libSDL3, so we return the
 * platform string directly. The value is only surfaced by MC in the system
 * report / diagnostics; we report "iOS" so the game never dereferences a
 * null platform string.
 */
package org.lwjgl.sdl;

import javax.annotation.Nullable;

import org.lwjgl.system.NativeType;

import static org.lwjgl.system.MemoryUtil.*;

public class SDLPlatform {

    protected SDLPlatform() {
        throw new UnsupportedOperationException();
    }

    /** Amethyst iOS: report the platform, bypassing the (absent) native SDL. */
    @NativeType("const char *")
    public static long nSDL_GetPlatform() {
        return memAddress(memUTF8("iOS"));
    }

    @Nullable
    @NativeType("const char *")
    public static String SDL_GetPlatform() {
        return "iOS";
    }
}