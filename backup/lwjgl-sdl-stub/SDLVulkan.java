/*
 * Stub override for org.lwjgl.sdl.SDLVulkan, tailored for Amethyst iOS.
 *
 * Amethyst renders through GL/OSMesa (GRAPHICS_API=prefer_opengl), so the Vulkan
 * SDL surface path is never taken. These stubs exist only so that if MC's
 * renderpearl Vulkan backend is ever touched, SDLVulkan's $Functions does not
 * abort its <clinit> looking for symbols in a nonexistent libSDL3.
 */
package org.lwjgl.sdl;

import javax.annotation.Nullable;

import java.nio.ByteBuffer;
import java.nio.LongBuffer;

import org.lwjgl.PointerBuffer;
import org.lwjgl.system.NativeType;
import org.lwjgl.vulkan.VkAllocationCallbacks;
import org.lwjgl.vulkan.VkInstance;
import org.lwjgl.vulkan.VkPhysicalDevice;

public class SDLVulkan {

    private SDLVulkan() {
    }

    public static boolean nSDL_Vulkan_LoadLibrary(long path) {
        return false;
    }

    @NativeType("bool")
    public static boolean SDL_Vulkan_LoadLibrary(@NativeType("char const *") @Nullable ByteBuffer path) {
        return false;
    }

    @NativeType("bool")
    public static boolean SDL_Vulkan_LoadLibrary(@NativeType("char const *") @Nullable CharSequence path) {
        return false;
    }

    @NativeType("SDL_FunctionPointer")
    public static long SDL_Vulkan_GetVkGetInstanceProcAddr() {
        return 0L;
    }

    public static void SDL_Vulkan_UnloadLibrary() {
        // no-op
    }

    public static long nSDL_Vulkan_GetInstanceExtensions(long count) {
        if (count != 0L) {
            org.lwjgl.system.MemoryUtil.memPutInt(count, 0);
        }
        return 0L;
    }

    @Nullable
    @NativeType("char const * const *")
    public static PointerBuffer SDL_Vulkan_GetInstanceExtensions() {
        return null;
    }

    public static boolean nSDL_Vulkan_CreateSurface(long window, long instance, long allocator, long surface) {
        return false;
    }

    @NativeType("bool")
    public static boolean SDL_Vulkan_CreateSurface(@NativeType("SDL_Window *") long window,
                                                    VkInstance instance,
                                                    @Nullable VkAllocationCallbacks allocator,
                                                    @NativeType("VkSurfaceKHR *") LongBuffer surface) {
        return false;
    }

    public static void nSDL_Vulkan_DestroySurface(long instance, long surface, long allocator) {
        // no-op
    }

    public static void SDL_Vulkan_DestroySurface(VkInstance instance,
                                                  @NativeType("VkSurfaceKHR") long surface,
                                                  @Nullable VkAllocationCallbacks allocator) {
        // no-op
    }

    @NativeType("bool")
    public static boolean SDL_Vulkan_GetPresentationSupport(VkInstance instance,
                                                            VkPhysicalDevice physicalDevice,
                                                            @NativeType("Uint32") int queueFamilyIndex) {
        return false;
    }
}