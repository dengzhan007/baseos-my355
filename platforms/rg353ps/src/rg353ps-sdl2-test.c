#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>
#include <SDL2/SDL_opengles2.h>

#include <stdio.h>
#include <stdlib.h>

typedef const GLubyte *(*GetStringFn)(GLenum);
typedef void (*ClearColorFn)(GLfloat, GLfloat, GLfloat, GLfloat);
typedef void (*ClearFn)(GLbitfield);
typedef void (*ViewportFn)(GLint, GLint, GLsizei, GLsizei);

static int fail(const char *where) {
    fprintf(stderr, "FAIL: %s: %s\n", where, SDL_GetError());
    SDL_Quit();
    return 1;
}

int main(void) {
    int ndrivers = SDL_GetNumVideoDrivers();
    printf("SDL version: %u.%u.%u\n",
           SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_PATCHLEVEL);
    printf("Compiled SDL video drivers (%d):\n", ndrivers);
    for (int i = 0; i < ndrivers; ++i) {
        printf("  %s\n", SDL_GetVideoDriver(i));
    }

    SDL_SetHint(SDL_HINT_KMSDRM_REQUIRE_DRM_MASTER, "1");
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
        return fail("SDL_Init");
    }

    const char *driver = SDL_GetCurrentVideoDriver();
    printf("Active SDL video driver: %s\n", driver ? driver : "(null)");
    if (!driver || SDL_strcasecmp(driver, "kmsdrm") != 0) {
        fprintf(stderr, "FAIL: requested KMSDRM, but active driver is %s\n",
                driver ? driver : "(null)");
        SDL_Quit();
        return 2;
    }

    int displays = SDL_GetNumVideoDisplays();
    printf("SDL displays: %d\n", displays);
    if (displays < 1) {
        return fail("SDL_GetNumVideoDisplays");
    }

    SDL_DisplayMode mode;
    if (SDL_GetCurrentDisplayMode(0, &mode) == 0) {
        printf("Display mode: %dx%d @ %d Hz, format=%s\n",
               mode.w, mode.h, mode.refresh_rate,
               SDL_GetPixelFormatName(mode.format));
    } else {
        printf("Display mode query warning: %s\n", SDL_GetError());
        SDL_ClearError();
    }

    if (SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                            SDL_GL_CONTEXT_PROFILE_ES) != 0 ||
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2) != 0 ||
        SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0) != 0) {
        return fail("SDL_GL_SetAttribute");
    }

    SDL_Window *window = SDL_CreateWindow(
        "RG353PS SDL2 KMSDRM test",
        SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
        640, 480, SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_SHOWN);
    if (!window) {
        return fail("SDL_CreateWindow");
    }

    SDL_GLContext context = SDL_GL_CreateContext(window);
    if (!context) {
        fprintf(stderr, "SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    GetStringFn get_string = (GetStringFn)SDL_GL_GetProcAddress("glGetString");
    ClearColorFn clear_color = (ClearColorFn)SDL_GL_GetProcAddress("glClearColor");
    ClearFn clear = (ClearFn)SDL_GL_GetProcAddress("glClear");
    ViewportFn viewport = (ViewportFn)SDL_GL_GetProcAddress("glViewport");
    if (!get_string || !clear_color || !clear || !viewport) {
        fprintf(stderr, "FAIL: required GLES function lookup failed\n");
        SDL_GL_DeleteContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return 1;
    }

    printf("GL_VENDOR: %s\n", get_string(GL_VENDOR));
    printf("GL_RENDERER: %s\n", get_string(GL_RENDERER));
    printf("GL_VERSION: %s\n", get_string(GL_VERSION));
    int width = 0, height = 0;
    SDL_GL_GetDrawableSize(window, &width, &height);
    printf("Drawable size: %dx%d\n", width, height);
    viewport(0, 0, width, height);
    (void)SDL_GL_SetSwapInterval(1);

    puts("Displaying red/green/blue/black test screens for 8 seconds...");
    fflush(stdout);
    const Uint64 started = SDL_GetTicks64();
    int quit = 0;
    while (!quit && SDL_GetTicks64() - started < 8000) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) {
                quit = 1;
            }
        }
        Uint64 elapsed = SDL_GetTicks64() - started;
        unsigned phase = (unsigned)(elapsed / 2000) % 4;
        switch (phase) {
            case 0: clear_color(0.9f, 0.05f, 0.05f, 1.0f); break;
            case 1: clear_color(0.05f, 0.8f, 0.05f, 1.0f); break;
            case 2: clear_color(0.05f, 0.1f, 0.9f, 1.0f); break;
            default: clear_color(0.02f, 0.02f, 0.02f, 1.0f); break;
        }
        clear(GL_COLOR_BUFFER_BIT);
        SDL_GL_SwapWindow(window);
        SDL_Delay(16);
    }

    SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    puts("PASS: SDL2 KMSDRM + EGL/GLES window rendered and exited cleanly.");
    return 0;
}
