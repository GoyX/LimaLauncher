/*
 * Stub override for org.lwjgl.sdl.SDLHints, tailored for Amethyst iOS.
 *
 * MC sets a handful of SDL hints at startup. They are stored in a static map
 * and returned on request; none have functional effect on the iOS bridge.
 */
package org.lwjgl.sdl;

import java.util.HashMap;
import java.util.Map;

import javax.annotation.Nullable;

import org.lwjgl.system.NativeType;

public class SDLHints {

    private static final Map<String, String> s_hints = new HashMap<>();

    public static final int SDL_HINT_DEFAULT    = 0;
    public static final int SDL_HINT_NORMAL     = 1;
    public static final int SDL_HINT_OVERRIDE   = 2;

    protected SDLHints() {
        throw new UnsupportedOperationException();
    }

    public static boolean SDL_SetHint(@Nullable CharSequence name, @Nullable CharSequence value) {
        if (name != null) {
            s_hints.put(name.toString(), value == null ? "" : value.toString());
        }
        return true;
    }

    public static boolean SDL_SetHintWithPriority(@Nullable CharSequence name, @Nullable CharSequence value, @NativeType("SDL_HintPriority") int priority) {
        return SDL_SetHint(name, value);
    }

    @Nullable
    public static String SDL_GetHint(@Nullable CharSequence name) {
        return name == null ? null : s_hints.get(name.toString());
    }

    public static boolean SDL_GetHintBoolean(@Nullable CharSequence name, @NativeType("bool") boolean default_value) {
        String v = SDL_GetHint(name);
        if (v == null || v.isEmpty()) return default_value;
        return v.equals("1") || v.equalsIgnoreCase("true") || v.equalsIgnoreCase("yes");
    }

    public static void SDL_ResetHints() {
        s_hints.clear();
    }
}