/*
 * Stub override for org.lwjgl.sdl.SDLError, tailored for Amethyst iOS.
 *
 * MC logs SDL errors through SDL_GetError/SDL_SetError. Keep a small in-Java
 * string so the game's GL init failure reporting stays benign.
 */
package org.lwjgl.sdl;

import javax.annotation.Nullable;

public class SDLError {

    private static String s_lastError = null;

    protected SDLError() {
        throw new UnsupportedOperationException();
    }

    public static boolean nSDL_SetError(long message) {
        s_lastError = "";
        return true;
    }

    public static boolean SDL_SetError(@Nullable java.nio.ByteBuffer message) {
        s_lastError = "";
        return true;
    }

    public static boolean SDL_SetError(@Nullable CharSequence message) {
        s_lastError = message == null ? "" : message.toString();
        return true;
    }

    public static boolean SDL_OutOfMemory() {
        s_lastError = "Out of memory";
        return false;
    }

    public static long nSDL_GetError() {
        String e = s_lastError == null ? "" : s_lastError;
        return org.lwjgl.system.MemoryUtil.memAddress(org.lwjgl.system.MemoryUtil.memUTF8(e));
    }

    @Nullable
    public static String SDL_GetError() {
        return s_lastError;
    }

    public static boolean SDL_ClearError() {
        s_lastError = null;
        return true;
    }
}