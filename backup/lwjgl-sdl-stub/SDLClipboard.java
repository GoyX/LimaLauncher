/*
 * Stub override for org.lwjgl.sdl.SDLClipboard, tailored for Amethyst iOS.
 *
 * On iOS there is no real libSDL3; MC's ClipboardManager calls into SDL for
 * clipboard peek/read/write. Amethyst's GLFW path already routes clipboard
 * through CallbackBridge.nativeClipboard, but for SDL we keep a small local
 * JVM-side string store so MC's clipboard calls are harmless and functional
 * within the process.
 */
package org.lwjgl.sdl;

import javax.annotation.Nullable;

import java.nio.ByteBuffer;

import org.lwjgl.PointerBuffer;
import org.lwjgl.system.NativeType;

import static org.lwjgl.system.MemoryUtil.*;

public class SDLClipboard {

    private static String s_text = "";

    private SDLClipboard() {
    }

    public static boolean nSDL_SetClipboardText(long text) {
        s_text = text != 0L ? memASCII(text) : "";
        return true;
    }

    @NativeType("bool")
    public static boolean SDL_SetClipboardText(@NativeType("char const *") @Nullable ByteBuffer text) {
        if (text != null) {
            s_text = memUTF8(text, text.remaining());
        }
        return true;
    }

    @NativeType("bool")
    public static boolean SDL_SetClipboardText(@NativeType("char const *") @Nullable CharSequence text) {
        s_text = text == null ? "" : text.toString();
        return true;
    }

    public static long nSDL_GetClipboardText() {
        long addr = memAddress(memUTF8(s_text));
        return addr;
    }

    @Nullable
    @NativeType("char *")
    public static String SDL_GetClipboardText() {
        return s_text;
    }

    @NativeType("bool")
    public static boolean SDL_HasClipboardText() {
        return !s_text.isEmpty();
    }

    public static boolean nSDL_SetPrimarySelectionText(long text) {
        return nSDL_SetClipboardText(text);
    }

    @NativeType("bool")
    public static boolean SDL_SetPrimarySelectionText(@NativeType("char const *") @Nullable ByteBuffer text) {
        return SDL_SetClipboardText(text);
    }

    @NativeType("bool")
    public static boolean SDL_SetPrimarySelectionText(@NativeType("char const *") @Nullable CharSequence text) {
        return SDL_SetClipboardText(text);
    }

    public static long nSDL_GetPrimarySelectionText() {
        return nSDL_GetClipboardText();
    }

    @Nullable
    @NativeType("char *")
    public static String SDL_GetPrimarySelectionText() {
        return s_text;
    }

    @NativeType("bool")
    public static boolean SDL_HasPrimarySelectionText() {
        return SDL_HasClipboardText();
    }

    public static boolean nSDL_SetClipboardData(long callback, long cleanup, long userdata, long mime_types, long num_mime_types) {
        return true;
    }

    @NativeType("bool")
    public static boolean SDL_SetClipboardData(@Nullable SDL_ClipboardDataCallbackI callback,
                                                @Nullable SDL_ClipboardCleanupCallbackI cleanup,
                                                @NativeType("void *") long userdata,
                                                @NativeType("char const * const *") PointerBuffer mime_types) {
        return true;
    }

    @NativeType("bool")
    public static boolean SDL_ClearClipboardData() {
        s_text = "";
        return true;
    }

    public static long nSDL_GetClipboardData(long mime_type, long size) {
        if (size != 0L) {
            memPutInt(size, memUTF8(s_text).limit());
        }
        return 0L;
    }

    @Nullable
    @NativeType("void *")
    public static ByteBuffer SDL_GetClipboardData(@NativeType("char const *") @Nullable ByteBuffer mime_type) {
        return null;
    }

    @Nullable
    @NativeType("void *")
    public static ByteBuffer SDL_GetClipboardData(@NativeType("char const *") @Nullable CharSequence mime_type) {
        return null;
    }

    public static boolean nSDL_HasClipboardData(long mime_type) {
        return false;
    }

    @NativeType("bool")
    public static boolean SDL_HasClipboardData(@NativeType("char const *") @Nullable ByteBuffer mime_type) {
        return false;
    }

    @NativeType("bool")
    public static boolean SDL_HasClipboardData(@NativeType("char const *") @Nullable CharSequence mime_type) {
        return false;
    }

    public static long nSDL_GetClipboardMimeTypes(long num_mime_types) {
        if (num_mime_types != 0L) {
            memPutLong(num_mime_types, 0L);
        }
        return 0L;
    }

    @Nullable
    @NativeType("char **")
    public static PointerBuffer SDL_GetClipboardMimeTypes() {
        return null;
    }
}