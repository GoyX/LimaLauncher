/*
 * Stub override for org.lwjgl.sdl.SDLInit, tailored for Amethyst iOS.
 *
 * Amethyst iOS does not load a real libSDL3. The window/GL context and input
 * are handled by the app's own UIKit bridge (pojav* symbols + CallbackBridge).
 * This stub keeps the same public signatures as LWJGL 3.4.1 SDL bindings so that
 * Minecraft 26.3-snapshot-4+ (which links org.lwjgl.sdl) can resolve and run,
 * while delegating to the existing native wiring.
 */
package org.lwjgl.sdl;

import java.nio.ByteBuffer;

import javax.annotation.Nullable;

import org.lwjgl.system.*;

/** SDL init subsystem flags (kept from LWJGL SDL bindings). */
public class SDLInit {

    public static final int SDL_INIT_AUDIO     = 0x00000010;
    public static final int SDL_INIT_VIDEO     = 0x00000020;
    public static final int SDL_INIT_JOYSTICK  = 0x00000200;
    public static final int SDL_INIT_HAPTIC    = 0x00001000;
    public static final int SDL_INIT_GAMEPAD   = 0x00002000;
    public static final int SDL_INIT_EVENTS    = 0x00004000;
    public static final int SDL_INIT_SENSOR    = 0x00008000;
    public static final int SDL_INIT_CAMERA    = 0x00010000;

    public static final int SDL_APP_CONTINUE = 0;
    public static final int SDL_APP_SUCCESS  = 1;
    public static final int SDL_APP_FAILURE  = 2;

    public static final String SDL_PROP_APP_METADATA_NAME_STRING      = "SDL.app.metadata.name";
    public static final String SDL_PROP_APP_METADATA_VERSION_STRING   = "SDL.app.metadata.version";
    public static final String SDL_PROP_APP_METADATA_IDENTIFIER_STRING = "SDL.app.metadata.identifier";
    public static final String SDL_PROP_APP_METADATA_CREATOR_STRING   = "SDL.app.metadata.creator";
    public static final String SDL_PROP_APP_METADATA_COPYRIGHT_STRING = "SDL.app.metadata.copyright";
    public static final String SDL_PROP_APP_METADATA_URL_STRING       = "SDL.app.metadata.url";
    public static final String SDL_PROP_APP_METADATA_TYPE_STRING      = "SDL.app.metadata.type";

    protected SDLInit() {
        throw new UnsupportedOperationException();
    }

    /** Amethyst: window/GL/input are already brought up by the native bridge. Always succeed. */
    public static boolean SDL_Init(@NativeType("SDL_InitFlags") int flags) {
        return true;
    }

    public static boolean SDL_InitSubSystem(@NativeType("SDL_InitFlags") int flags) {
        return true;
    }

    public static void SDL_QuitSubSystem(@NativeType("SDL_InitFlags") int flags) {
    }

    @NativeType("SDL_InitFlags")
    public static int SDL_WasInit(@NativeType("SDL_InitFlags") int flags) {
        return flags & (SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_EVENTS);
    }

    public static void SDL_Quit() {
    }

    /** Amethyst: the JVM runs on the main thread via -XstartOnFirstThread; safe. */
    @NativeType("bool")
    public static boolean SDL_IsMainThread() {
        return true;
    }

    public static boolean SDL_RunOnMainThread(@NativeType("SDL_MainThreadCallbackI") SDL_MainThreadCallbackI callback, @NativeType("void *") long userdata, @NativeType("bool") boolean wait) {
        if (callback == null) return false;
        if (wait) {
            callback.invoke(userdata);
            return true;
        }
        new Thread(() -> callback.invoke(userdata)).start();
        return true;
    }

    public static boolean SDL_SetAppMetadata(@NativeType("const char *") CharSequence name, @NativeType("const char *") CharSequence version, @NativeType("const char *") CharSequence identifier) {
        return true;
    }

    public static boolean SDL_SetAppMetadataProperty(@NativeType("const char *") CharSequence name, @NativeType("const char *") CharSequence value) {
        return true;
    }
}