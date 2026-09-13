/*
 * Stub override for org.lwjgl.sdl.SDLEvents, tailored for Amethyst iOS.
 *
 * Minecraft 26.3-snapshot-4+ polls events via SDL_PollEvent(SDL_Event) instead of
 * GLFW callbacks. On iOS the underlying input is produced by the app's existing
 * native bridge (input_bridge_v3.m) which already writes into the GLFW event
 * cycle; SDL_PumpEvents drives that native pump. SDL_PollEvent then materializes
 * SDL events from a small Java FIFO that the bridge (or a future native export)
 * feeds.
 *
 * This follows the same "stub over the proven native wiring" strategy as
 * org.lwjgl.glfw.GLFW. The event payload layout matches LWJGL 3.4.1 SDL bindings.
 */
package org.lwjgl.sdl;

import java.util.ArrayDeque;
import java.util.Deque;

import javax.annotation.Nullable;

import org.lwjgl.system.NativeType;
import org.lwjgl.system.macosx.*;

import static org.lwjgl.system.JNI.*;
import static org.lwjgl.system.APIUtil.*;

public class SDLEvents {

    public static final int SDL_EVENT_FIRST = 0;

    public static final int SDL_EVENT_QUIT            = 0x100;
    public static final int SDL_EVENT_TERMINATING     = 0x101;
    public static final int SDL_EVENT_LOW_MEMORY      = 0x102;
    public static final int SDL_EVENT_LOCALE_CHANGED  = 0x110;
    public static final int SDL_EVENT_SYSTEM_THEME_CHANGED = 0x111;

    public static final int SDL_EVENT_DISPLAY_FIRST = 0x150;
    public static final int SDL_EVENT_DISPLAY_ORIENTATION = 0x160;

    public static final int SDL_EVENT_WINDOW_FIRST        = 0x200;
    public static final int SDL_EVENT_WINDOW_SHOWN        = 0x200;
    public static final int SDL_EVENT_WINDOW_HIDDEN       = 0x201;
    public static final int SDL_EVENT_WINDOW_EXPOSED      = 0x202;
    public static final int SDL_EVENT_WINDOW_MOVED        = 0x203;
    public static final int SDL_EVENT_WINDOW_RESIZED      = 0x205;
    public static final int SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED = 0x206;
    public static final int SDL_EVENT_WINDOW_MINIMIZED    = 0x207;
    public static final int SDL_EVENT_WINDOW_MAXIMIZED    = 0x208;
    public static final int SDL_EVENT_WINDOW_RESTORED     = 0x209;
    public static final int SDL_EVENT_WINDOW_MOUSE_ENTER  = 0x20A;
    public static final int SDL_EVENT_WINDOW_MOUSE_LEAVE  = 0x20B;
    public static final int SDL_EVENT_WINDOW_FOCUS_GAINED = 0x20C;
    public static final int SDL_EVENT_WINDOW_FOCUS_LOST   = 0x20D;
    public static final int SDL_EVENT_WINDOW_CLOSE_REQUESTED = 0x20E;
    public static final int SDL_EVENT_WINDOW_LAST         = 0x21C;

    public static final int SDL_EVENT_KEY_DOWN   = 0x300;
    public static final int SDL_EVENT_KEY_UP     = 0x301;
    public static final int SDL_EVENT_TEXT_EDITING = 0x302;
    public static final int SDL_EVENT_TEXT_INPUT = 0x303;
    public static final int SDL_EVENT_KEYMAP_CHANGED = 0x304;

    public static final int SDL_EVENT_MOUSE_MOTION    = 0x400;
    public static final int SDL_EVENT_MOUSE_BUTTON_DOWN = 0x401;
    public static final int SDL_EVENT_MOUSE_BUTTON_UP = 0x402;
    public static final int SDL_EVENT_MOUSE_WHEEL     = 0x403;
    public static final int SDL_EVENT_MOUSE_ADDED     = 0x404;
    public static final int SDL_EVENT_MOUSE_REMOVED   = 0x405;

    public static final int SDL_EVENT_JOYSTICK_FIRST       = 0x600;
    public static final int SDL_EVENT_GAMEPAD_FIRST        = 0x650;
    public static final int SDL_EVENT_FINGER_DOWN          = 0x700;
    public static final int SDL_EVENT_FINGER_UP            = 0x701;
    public static final int SDL_EVENT_FINGER_MOTION        = 0x702;
    public static final int SDL_EVENT_PEN_FIRST            = 0x750;
    public static final int SDL_EVENT_CLIPBOARD_UPDATE     = 0x900;
    public static final int SDL_EVENT_DROP_FILE            = 0x1000;
    public static final int SDL_EVENT_USER_EVENT           = 0x8000;

    protected SDLEvents() {
        throw new UnsupportedOperationException();
    }

    /** Pending SDL events. Feeds from native bridge; drained by SDL_PollEvent. */
    private static final Deque<int[]> s_pending = new ArrayDeque<>();

    // A window event is placed once the window is ready so MC's first
    // SDL_PollEvent sees a sane size (mirrors GLFW stub's early framebuffer event).
    private static boolean s_windowEventPosted = false;

    // ------------------------------------------------------------------
    // Native bridge (same symbols as GLFW stub)
    // ------------------------------------------------------------------
    static {
        try {
            System.load(System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst");
        } catch (UnsatisfiedLinkError e) {
            e.printStackTrace();
        }
    }

    private static final org.lwjgl.system.SharedLibrary SDL =
        new org.lwjgl.system.macosx.MacOSXLibraryDL("AngelAuraAmethyst", DynamicLinkLoader.RTLD_DEFAULT);

    public static final class Functions {
        private Functions() {}
        public static final long
            PumpEvents   = apiGetFunctionAddress(SDL, "pojavPumpEvents"),
            RewindEvents = apiGetFunctionAddress(SDL, "pojavRewindEvents");
    }

    /** Queue a synthetic SDL event payload {type,i0,i1,i2,dx,dy}. */
    public static void enqueueEvent(@NativeType("SDL_EventType") int type, int a, int b, int c, float dx, float dy) {
        synchronized (s_pending) {
            s_pending.addLast(new int[]{ type, a, b, c, Float.floatToRawIntBits(dx), Float.floatToRawIntBits(dy) });
            if (s_pending.size() > 256) {
                s_pending.removeFirst();
            }
        }
    }

    public static void SDL_PumpEvents() {
        ensureWindowEvent();
        ensureCallbacks();
        // Drive the input pump on the active window like glfwPollEvents.
        long window = org.lwjgl.sdl.SDLVideo.windowAddress();
        if (window != 0L) {
            callJV(window, Functions.PumpEvents);
        }
        callV(Functions.RewindEvents);
    }

    public static boolean SDL_PollEvent(@NativeType("SDL_Event *") SDL_Event event) {
        ensureWindowEvent();
        int[] payload;
        synchronized (s_pending) {
            payload = s_pending.pollFirst();
        }
        if (payload == null || event == null) {
            return false;
        }
        int type = payload[0];
        event.common().type(type).timestamp(System.currentTimeMillis());
        switch (type) {
            case SDL_EVENT_WINDOW_RESIZED:
            case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                event.window().type(type).timestamp(System.currentTimeMillis())
                    .windowID((int) SDLVideo.windowAddress())
                    .data1(payload[1]).data2(payload[2]);
                break;
            case SDL_EVENT_KEY_DOWN:
            case SDL_EVENT_KEY_UP:
                event.key().type(type).timestamp(System.currentTimeMillis())
                    .windowID((int) SDLVideo.windowAddress())
                    .key(payload[1]).scancode(payload[2])
                    .down(type == SDL_EVENT_KEY_DOWN).repeat(false);
                break;
            case SDL_EVENT_MOUSE_BUTTON_DOWN:
            case SDL_EVENT_MOUSE_BUTTON_UP:
                event.button().type(type).timestamp(System.currentTimeMillis())
                    .windowID((int) SDLVideo.windowAddress())
                    .button((byte) payload[1])
                    .down(type == SDL_EVENT_MOUSE_BUTTON_DOWN)
                    .x(Float.intBitsToFloat(payload[4]))
                    .y(Float.intBitsToFloat(payload[5]));
                break;
            case SDL_EVENT_FINGER_DOWN:
            case SDL_EVENT_FINGER_UP:
            case SDL_EVENT_FINGER_MOTION:
                event.tfinger().type(type).timestamp(System.currentTimeMillis())
                    .fingerID(payload[1])
                    .x(Float.intBitsToFloat(payload[4]))
                    .y(Float.intBitsToFloat(payload[5]));
                break;
            default:
                break;
        }
        return true;
    }

    public static boolean nSDL_PollEvent(@NativeType("long") long eventAddress) {
        return SDL_PollEvent(eventAddress == 0L ? null : SDL_Event.create(eventAddress));
    }

    public static boolean SDL_PushEvent(@NativeType("SDL_Event *") SDL_Event event) {
        if (event == null) return false;
        int type = event.type();
        synchronized (s_pending) {
            s_pending.addLast(new int[]{ type, 0, 0, 0, 0, 0 });
        }
        return true;
    }

    public static void SDL_FlushEvent(@NativeType("SDL_EventType") int type) {
        synchronized (s_pending) {
            s_pending.removeIf(e -> e[0] == type);
        }
    }

    public static boolean SDL_HasEvent(@NativeType("SDL_EventType") int type) {
        synchronized (s_pending) {
            for (int[] e : s_pending) {
                if (e[0] == type) return true;
            }
        }
        return false;
    }

    @NativeType("SDL_EventType")
    public static int SDL_GetWindowFromEvent(@NativeType("SDL_Event *") SDL_Event event) {
        return event == null ? 0 : (int) SDLVideo.windowAddress();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static void ensureWindowEvent() {
        if (s_windowEventPosted) return;
        long window = SDLVideo.windowAddress();
        if (window != 0L) {
            enqueueEvent(SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, 0, 0, 0, 0, 0);
            s_windowEventPosted = true;
        }
    }

    // ------------------------------------------------------------------
    // GLFW-callback bridging for input
    //
    // iOS input arrives via the native bridge which invokes the GLFW
    // callback objects the GLFW stub registered (GLFW_invoke_*). When MC
    // runs in SDL mode it does not install GLFW callbacks, so we register
    // our own anonymous callbacks once and translate them into the SDL FIFO.
    // This reuses the proven native input path without touching C.
    // ------------------------------------------------------------------

    private static boolean s_callbacksInstalled = false;

    private static void ensureCallbacks() {
        if (s_callbacksInstalled) return;
        s_callbacksInstalled = true;
        long w = SDLVideo.windowAddress();
        if (w == 0L) return;

        org.lwjgl.glfw.GLFW.glfwSetKeyCallback(w, (window, key, scancode, action, mods) -> {
            int sdlType = (action == org.lwjgl.glfw.GLFW.GLFW_RELEASE)
                ? SDL_EVENT_KEY_UP : SDL_EVENT_KEY_DOWN;
            enqueueEvent(sdlType, key, scancode, mods, 0f, 0f);
        });
        org.lwjgl.glfw.GLFW.glfwSetMouseButtonCallback(w, (window, button, action, mods) -> {
            int sdlType = (action == org.lwjgl.glfw.GLFW.GLFW_RELEASE)
                ? SDL_EVENT_MOUSE_BUTTON_UP : SDL_EVENT_MOUSE_BUTTON_DOWN;
            float[] pos = s_mousePos;
            enqueueEvent(sdlType, button + 1, 0, 0, pos[0], pos[1]);
        });
        org.lwjgl.glfw.GLFW.glfwSetCursorPosCallback(w, (window, x, y) -> {
            s_mousePos[0] = (float) x;
            s_mousePos[1] = (float) y;
        });
        org.lwjgl.glfw.GLFW.glfwSetScrollCallback(w, (window, dx, dy) -> {
            enqueueEvent(SDL_EVENT_MOUSE_WHEEL, 0, 0, 0, (float) dx, (float) dy);
        });
    }

    private static final float[] s_mousePos = new float[2];
}