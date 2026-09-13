/*
 * Stub override for org.lwjgl.sdl.SDLKeyboard, tailored for Amethyst iOS.
 *
 * Keyboard state on iOS is produced ad-hoc by the native bridge. This stub
 * keeps MC's SDL key lookup working (scancode<->key) with the same key codes
 * SDL3 uses; text input is accepted and treated as no-op (hardware keyboard
 * events arrive via the SDL event FIFO bridged from GLFW callbacks).
 */
package org.lwjgl.sdl;

import javax.annotation.Nullable;

import org.lwjgl.system.NativeType;

public class SDLKeyboard {

    protected SDLKeyboard() {
        throw new UnsupportedOperationException();
    }

    @NativeType("SDL_Keycode")
    public static int SDL_GetKeyFromScancode(@NativeType("SDL_Scancode") int scancode, @NativeType("SDL_Keymod") short modstate, @NativeType("bool") boolean platform_sensitive) {
        return scancode; // iOS: treat scancode as the key code (Q = 20 for SDL3)
    }

    @NativeType("SDL_Scancode")
    public static int SDL_GetScancodeFromKey(@NativeType("SDL_Keycode") int key, @Nullable @NativeType("SDL_Keymod *") java.nio.ShortBuffer modstate) {
        if (modstate != null) modstate.put(0, (short) 0);
        return key; // mirrored identity; MC mostly reads events, not unified conversion
    }

    public static boolean SDL_StartTextInput(@NativeType("SDL_Window *") long window) {
        return true;
    }

    public static boolean SDL_SetTextInputArea(@NativeType("SDL_Window *") long window, @Nullable @NativeType("const SDL_Rect *") SDL_Rect.Buffer rect, int cursor) {
        return true;
    }

    public static boolean SDL_ScreenKeyboardShown(@NativeType("SDL_Window *") long window) {
        return false;
    }
}