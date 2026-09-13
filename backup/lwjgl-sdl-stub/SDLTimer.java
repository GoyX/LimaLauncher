/*
 * Stub override for org.lwjgl.sdl.SDLTimer, tailored for Amethyst iOS.
 *
 * There is no real libSDL3. MC's tick/timing (Window.getFrame/refresh) relies
 * on SDL_GetTicks()/SDL_GetPerformanceCounter() for real elapsed time, so we
 * back them with System.nanoTime() rather than returning a constant. Timers
 * (SDL_AddTimer/SDL_RemoveTimer) and delays are real enough no-ops/Thread
 * sleeps so nothing deadlocks.
 */
package org.lwjgl.sdl;

import org.lwjgl.system.NativeType;

public class SDLTimer {

    public static final int  SDL_MS_PER_SECOND = 1000;
    public static final int  SDL_US_PER_SECOND = 1_000_000;
    public static final long SDL_NS_PER_SECOND = 1_000_000_000L;
    public static final int  SDL_NS_PER_MS     = 1_000_000;
    public static final int  SDL_NS_PER_US     = 1_000;

    private static final long s_bootNanos = System.nanoTime();

    private SDLTimer() {
    }

    @NativeType("Uint64")
    public static long SDL_GetTicks() {
        return (System.nanoTime() - s_bootNanos) / SDL_NS_PER_MS;
    }

    @NativeType("Uint64")
    public static long SDL_GetTicksNS() {
        return System.nanoTime() - s_bootNanos;
    }

    @NativeType("Uint64")
    public static long SDL_GetPerformanceCounter() {
        return System.nanoTime();
    }

    @NativeType("Uint64")
    public static long SDL_GetPerformanceFrequency() {
        return SDL_NS_PER_SECOND;
    }

    public static void SDL_Delay(@NativeType("Uint32") int ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public static void SDL_DelayNS(@NativeType("Uint64") long ns) {
        sleepNanos(ns);
    }

    public static void SDL_DelayPrecise(@NativeType("Uint64") long ns) {
        sleepNanos(ns);
    }

    private static void sleepNanos(long ns) {
        if (ns <= 0L) {
            return;
        }
        long ms = ns / SDL_NS_PER_MS;
        long rem = ns % SDL_NS_PER_MS;
        try {
            Thread.sleep(ms, (int) rem);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    public static int nSDL_AddTimer(int interval, long callback, long userdata) {
        return 0;
    }

    @NativeType("SDL_TimerID")
    public static int SDL_AddTimer(@NativeType("Uint32") int interval,
                                    @NativeType("SDL_TimerCallback") SDL_TimerCallbackI callback,
                                    @NativeType("void *") long userdata) {
        return 0;
    }

    public static int nSDL_AddTimerNS(long interval, long callback, long userdata) {
        return 0;
    }

    @NativeType("SDL_TimerID")
    public static int SDL_AddTimerNS(@NativeType("Uint64") long interval,
                                      @NativeType("SDL_NSTimerCallback") SDL_NSTimerCallbackI callback,
                                      @NativeType("void *") long userdata) {
        return 0;
    }

    @NativeType("bool")
    public static boolean SDL_RemoveTimer(@NativeType("SDL_TimerID") int id) {
        return false;
    }

    @NativeType("Uint64")
    public static long SDL_SECONDS_TO_NS(@NativeType("Uint64") long S) {
        return S * SDL_NS_PER_SECOND;
    }

    @NativeType("Uint64")
    public static long SDL_NS_TO_SECONDS(@NativeType("Uint64") long NS) {
        return NS / SDL_NS_PER_SECOND;
    }

    @NativeType("Uint64")
    public static long SDL_MS_TO_NS(@NativeType("Uint64") long MS) {
        return MS * SDL_NS_PER_MS;
    }

    @NativeType("Uint64")
    public static long SDL_NS_TO_MS(@NativeType("Uint64") long NS) {
        return NS / SDL_NS_PER_MS;
    }

    @NativeType("Uint64")
    public static long SDL_US_TO_NS(@NativeType("Uint64") long US) {
        return US * SDL_NS_PER_US;
    }

    @NativeType("Uint64")
    public static long SDL_NS_TO_US(@NativeType("Uint64") long NS) {
        return NS / SDL_NS_PER_US;
    }
}