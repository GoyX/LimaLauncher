/*
 * Stub override for org.lwjgl.sdl.SDLMouse, tailored for Amethyst iOS.
 *
 * Minecraft surives on touch; a virtual pointer is tracked by the native
 * bridge. Relative mouse mode (used by MC for camera look) is routed to the
 * existing CallbackBridge.nativeSetGrabbing path exactly like the GLFW stub
 * does through glfwSetInputMode(GLFW_CURSOR_DISABLED). Coordinates clamp to
 * the window size read from glfw.windowSize.
 */
package org.lwjgl.sdl;

import java.nio.FloatBuffer;

import javax.annotation.Nullable;

import org.lwjgl.system.NativeType;

import static org.lwjgl.system.MemoryUtil.*;

public class SDLMouse {

    public static final int SDL_SYSTEM_CURSOR_DEFAULT     = 0;
    public static final int SDL_SYSTEM_CURSOR_TEXT        = 1;
    public static final int SDL_SYSTEM_CURSOR_WAIT        = 2;
    public static final int SDL_SYSTEM_CURSOR_CROSSHAIR   = 3;
    public static final int SDL_SYSTEM_CURSOR_PROGRESS    = 4;
    public static final int SDL_SYSTEM_CURSOR_NWSE_RESIZE = 5;
    public static final int SDL_SYSTEM_CURSOR_NESW_RESIZE = 6;
    public static final int SDL_SYSTEM_CURSOR_EW_RESIZE   = 7;
    public static final int SDL_SYSTEM_CURSOR_NS_RESIZE   = 8;
    public static final int SDL_SYSTEM_CURSOR_MOVE        = 9;
    public static final int SDL_SYSTEM_CURSOR_NOT_ALLOWED = 10;
    public static final int SDL_SYSTEM_CURSOR_POINTER     = 11;
    public static final int SDL_SYSTEM_CURSOR_NW_RESIZE   = 12;
    public static final int SDL_SYSTEM_CURSOR_N_RESIZE    = 13;
    public static final int SDL_SYSTEM_CURSOR_NE_RESIZE   = 14;
    public static final int SDL_SYSTEM_CURSOR_E_RESIZE    = 15;
    public static final int SDL_SYSTEM_CURSOR_SE_RESIZE   = 16;
    public static final int SDL_SYSTEM_CURSOR_S_RESIZE    = 17;
    public static final int SDL_SYSTEM_CURSOR_SW_RESIZE   = 18;
    public static final int SDL_SYSTEM_CURSOR_W_RESIZE    = 19;
    public static final int SDL_SYSTEM_CURSOR_COUNT       = 20;

    public static final int SDL_MOUSEWHEEL_NORMAL  = 0;
    public static final int SDL_MOUSEWHEEL_FLIPPED = 1;

    public static final int SDL_BUTTON_LEFT   = 1;
    public static final int SDL_BUTTON_MIDDLE = 2;
    public static final int SDL_BUTTON_RIGHT  = 3;
    public static final int SDL_BUTTON_X1     = 4;
    public static final int SDL_BUTTON_X2     = 5;
    public static final int SDL_BUTTON_LMASK  = SDLMouse.SDL_BUTTON_MASK(SDL_BUTTON_LEFT);
    public static final int SDL_BUTTON_MMASK  = SDLMouse.SDL_BUTTON_MASK(SDL_BUTTON_MIDDLE);
    public static final int SDL_BUTTON_RMASK  = SDLMouse.SDL_BUTTON_MASK(SDL_BUTTON_RIGHT);
    public static final int SDL_BUTTON_X1MASK = SDLMouse.SDL_BUTTON_MASK(SDL_BUTTON_X1);
    public static final int SDL_BUTTON_X2MASK = SDLMouse.SDL_BUTTON_MASK(SDL_BUTTON_X2);

    protected SDLMouse() {
        throw new UnsupportedOperationException();
    }

    public static int SDL_BUTTON_MASK(int button) {
        return 1 << (button - 1);
    }

    private static float s_x = 0f;
    private static float s_y = 0f;

    public static boolean SDL_HasMouse() {
        return true;
    }

    @NativeType("SDL_MouseID")
    public static long SDL_GetMouseFocus() {
        return 1L;
    }

    @NativeType("Uint32")
    public static int SDL_GetMouseState(@Nullable @NativeType("float *") FloatBuffer x, @Nullable @NativeType("float *") FloatBuffer y) {
        int[] size = windowSize();
        s_x = clamp(s_x, size[0]);
        s_y = clamp(s_y, size[1]);
        if (x != null) x.put(0, s_x);
        if (y != null) y.put(0, s_y);
        return 0;
    }

    @NativeType("Uint32")
    public static int nSDL_GetMouseState(long x, long y) {
        return SDL_GetMouseState(memFloatBuffer(x, 1), memFloatBuffer(y, 1));
    }

    @NativeType("Uint32")
    public static int SDL_GetGlobalMouseState(@Nullable @NativeType("float *") FloatBuffer x, @Nullable @NativeType("float *") FloatBuffer y) {
        return SDL_GetMouseState(x, y);
    }

    @NativeType("Uint32")
    public static int nSDL_GetGlobalMouseState(long x, long y) {
        return nSDL_GetMouseState(x, y);
    }

    @NativeType("Uint32")
    public static int SDL_GetRelativeMouseState(@Nullable @NativeType("float *") FloatBuffer x, @Nullable @NativeType("float *") FloatBuffer y) {
        // MC reads relative deltas; on touch the virtual pointer doesn't move by itself.
        if (x != null) x.put(0, 0f);
        if (y != null) y.put(0, 0f);
        return 0;
    }

    @NativeType("Uint32")
    public static int nSDL_GetRelativeMouseState(long x, long y) {
        return SDL_GetRelativeMouseState(memFloatBuffer(x, 1), memFloatBuffer(y, 1));
    }

    public static void SDL_WarpMouseInWindow(@NativeType("SDL_Window *") long window, float x, float y) {
        s_x = Math.max(0f, x);
        s_y = Math.max(0f, y);
    }

    public static boolean SDL_WarpMouseGlobal(float x, float y) {
        s_x = Math.max(0f, x);
        s_y = Math.max(0f, y);
        return true;
    }

    public static boolean SDL_SetWindowRelativeMouseMode(@NativeType("SDL_Window *") long window, @NativeType("bool") boolean enabled) {
        org.lwjgl.glfw.CallbackBridge.nativeSetGrabbing(enabled);
        return true;
    }

    public static boolean SDL_GetWindowRelativeMouseMode(@NativeType("SDL_Window *") long window) {
        return false;
    }

    @NativeType("bool")
    public static boolean SDL_CaptureMouse(@NativeType("bool") boolean enabled) {
        return true;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static int[] windowSize() {
        String size = System.getProperty("glfw.windowSize", "1280x720");
        String[] parts = size.split("x");
        int w = 1280, h = 720;
        try { w = Integer.parseInt(parts[0]); } catch (Exception ignored) {}
        try { h = parts.length > 1 ? Integer.parseInt(parts[1]) : 720; } catch (Exception ignored) {}
        return new int[]{ w, h };
    }

    private static float clamp(float v, int max) {
        return Math.max(0f, Math.min(v, max));
    }
}