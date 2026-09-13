/*
 * Stub override for org.lwjgl.sdl.SDL, tailored for Amethyst iOS.
 *
 * The upstream LWJGL 3.4.1 class loads a real libSDL3 at class-init time via
 * Configuration.SDL_LIBRARY_NAME, a field that does not exist in the older
 * lwjgl-system this launcher ships. On iOS there is no real libSDL3 to load:
 * window / GL / input are provided by the app's own native bridge. So we
 * replace the loading logic with a bridge to the known-good shared library
 * (same symbol resolution as org.lwjgl.glfw.GLFW and SDLEvents).
 */
package org.lwjgl.sdl;

import javax.annotation.Nullable;

import org.lwjgl.system.SharedLibrary;
import org.lwjgl.system.macosx.DynamicLinkLoader;
import org.lwjgl.system.macosx.MacOSXLibraryDL;

/** Entry facade for SDL3 bindings. Amethyst iOS has no real libSDL3. */
public final class SDL {

    // Delegate symbol resolution to the app's native bridge library, exactly
    // like org.lwjgl.glfw.GLFW and SDLEvents. RTLD_DEFAULT reuses whatever is
    // already loaded so we never force-load an SDL dylib.
    private static final SharedLibrary SDL =
        new MacOSXLibraryDL("AngelAuraAmethyst", DynamicLinkLoader.RTLD_DEFAULT);

    private SDL() {
        throw new UnsupportedOperationException();
    }

    @Nullable
    public static SharedLibrary getLibrary() {
        return SDL;
    }
}