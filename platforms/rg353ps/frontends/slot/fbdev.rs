// RG353PS-specific replacement for Slot's framebuffer-native EGL surface.
// The upstream fbdev surface creates an EGL native window using a device-specific
// struct. This build instead uses SDL2's proven KMSDRM backend and GLES context.
use std::ffi::{c_char, c_int, c_void, CStr, CString};

use libloading::Library;

use crate::surface::{GfxError, Surface};

const FALLBACK_PANEL: (u32, u32) = (640, 480);
const SDL_INIT_VIDEO: u32 = 0x0000_0020;
const SDL_GL_RED_SIZE: c_int = 0;
const SDL_GL_GREEN_SIZE: c_int = 1;
const SDL_GL_BLUE_SIZE: c_int = 2;
const SDL_GL_ALPHA_SIZE: c_int = 3;
const SDL_GL_DOUBLEBUFFER: c_int = 5;
const SDL_GL_CONTEXT_MAJOR_VERSION: c_int = 17;
const SDL_GL_CONTEXT_MINOR_VERSION: c_int = 18;
const SDL_GL_CONTEXT_PROFILE_MASK: c_int = 21;
const SDL_GL_CONTEXT_PROFILE_ES: c_int = 4;
const SDL_WINDOW_FULLSCREEN: u32 = 0x0000_0001;
const SDL_WINDOW_OPENGL: u32 = 0x0000_0002;
const SDL_WINDOW_SHOWN: u32 = 0x0000_0004;
const SDL_WINDOWPOS_UNDEFINED: c_int = 0x1fff_0000u32 as c_int;
const EGL_SUCCESS: i32 = 0x3000;

type Ptr = *mut c_void;
type Init = unsafe extern "C" fn(u32) -> c_int;
type Quit = unsafe extern "C" fn();
type SetEnv = unsafe extern "C" fn(*const c_char, *const c_char, c_int) -> c_int;
type SetHint = unsafe extern "C" fn(*const c_char, *const c_char) -> c_int;
type GetError = unsafe extern "C" fn() -> *const c_char;
type GlSetAttribute = unsafe extern "C" fn(c_int, c_int) -> c_int;
type CreateWindow =
    unsafe extern "C" fn(*const c_char, c_int, c_int, c_int, c_int, u32) -> Ptr;
type DestroyWindow = unsafe extern "C" fn(Ptr);
type GlCreateContext = unsafe extern "C" fn(Ptr) -> Ptr;
type GlMakeCurrent = unsafe extern "C" fn(Ptr, Ptr) -> c_int;
type GlSetSwapInterval = unsafe extern "C" fn(c_int) -> c_int;
type GlSwapWindow = unsafe extern "C" fn(Ptr);
type GlDeleteContext = unsafe extern "C" fn(Ptr);
type GlGetProcAddress = unsafe extern "C" fn(*const c_char) -> *const c_void;
type GetWindowSize = unsafe extern "C" fn(Ptr, *mut c_int, *mut c_int);
type GetCurrentVideoDriver = unsafe extern "C" fn() -> *const c_char;

struct Sdl {
    init: Init,
    quit: Quit,
    set_env: SetEnv,
    set_hint: SetHint,
    get_error: GetError,
    gl_set_attribute: GlSetAttribute,
    create_window: CreateWindow,
    destroy_window: DestroyWindow,
    gl_create_context: GlCreateContext,
    gl_make_current: GlMakeCurrent,
    gl_set_swap_interval: GlSetSwapInterval,
    gl_swap_window: GlSwapWindow,
    gl_delete_context: GlDeleteContext,
    gl_get_proc_address: GlGetProcAddress,
    get_window_size: GetWindowSize,
    get_current_video_driver: GetCurrentVideoDriver,
    _lib: Library,
}

impl Sdl {
    fn load() -> Result<Self, GfxError> {
        let lib = unsafe { Library::new("libSDL2-2.0.so.0") }
            .or_else(|_| unsafe { Library::new("libSDL2.so") })
            .map_err(|e| GfxError::Context(format!("SDL2 load: {e}")))?;
        unsafe {
            macro_rules! sym {
                ($name:literal, $ty:ty) => {
                    *lib.get::<$ty>(concat!($name, "\0").as_bytes())
                        .map_err(|e| GfxError::Context(format!("SDL2 {}: {e}", $name)))?
                };
            }
            Ok(Self {
                init: sym!("SDL_Init", Init),
                quit: sym!("SDL_Quit", Quit),
                set_env: sym!("SDL_setenv", SetEnv),
                set_hint: sym!("SDL_SetHint", SetHint),
                get_error: sym!("SDL_GetError", GetError),
                gl_set_attribute: sym!("SDL_GL_SetAttribute", GlSetAttribute),
                create_window: sym!("SDL_CreateWindow", CreateWindow),
                destroy_window: sym!("SDL_DestroyWindow", DestroyWindow),
                gl_create_context: sym!("SDL_GL_CreateContext", GlCreateContext),
                gl_make_current: sym!("SDL_GL_MakeCurrent", GlMakeCurrent),
                gl_set_swap_interval: sym!("SDL_GL_SetSwapInterval", GlSetSwapInterval),
                gl_swap_window: sym!("SDL_GL_SwapWindow", GlSwapWindow),
                gl_delete_context: sym!("SDL_GL_DeleteContext", GlDeleteContext),
                gl_get_proc_address: sym!("SDL_GL_GetProcAddress", GlGetProcAddress),
                get_window_size: sym!("SDL_GetWindowSize", GetWindowSize),
                get_current_video_driver: sym!("SDL_GetCurrentVideoDriver", GetCurrentVideoDriver),
                _lib: lib,
            })
        }
    }

    fn error(&self, operation: &str) -> GfxError {
        let detail = unsafe {
            let p = (self.get_error)();
            if p.is_null() {
                "no SDL error string".to_string()
            } else {
                CStr::from_ptr(p).to_string_lossy().into_owned()
            }
        };
        GfxError::Context(format!("{operation}: {detail}"))
    }
}

pub fn egl_error(what: &str, code: i32) -> GfxError {
    match code {
        EGL_SUCCESS => GfxError::Context(format!("{what}: refused, EGL flagged nothing")),
        _ => GfxError::Context(format!("{what}: EGL error 0x{code:x}")),
    }
}

// Keep these helpers public because the upstream graphics crate tests them.
pub fn panel_mode(text: &str) -> Option<(u32, u32)> {
    let body = text.lines().next()?.rsplit(':').next()?;
    let (w, rest) = body.split_once('x')?;
    let h: String = rest.chars().take_while(char::is_ascii_digit).collect();
    let (w, h) = (w.trim().parse().ok()?, h.parse().ok()?);
    (w > 0 && h > 0).then_some((w, h))
}

pub fn panel_size(text: &str) -> Option<(u32, u32)> {
    let (w, h) = text.trim().split_once(',')?;
    let (w, h) = (w.trim().parse().ok()?, h.trim().parse().ok()?);
    (w > 0 && h > 0).then_some((w, h))
}

pub struct FbdevSurface {
    sdl: Sdl,
    gles: Library,
    window: Ptr,
    context: Ptr,
    size: (u32, u32),
}

impl FbdevSurface {
    pub fn new() -> Result<Self, GfxError> {
        let sdl = Sdl::load()?;
        let driver_key = CString::new("SDL_VIDEODRIVER").unwrap();
        let driver_value = CString::new("kmsdrm").unwrap();
        let master_key = CString::new("SDL_KMSDRM_REQUIRE_DRM_MASTER").unwrap();
        let master_value = CString::new("1").unwrap();
        unsafe {
            if (sdl.set_env)(driver_key.as_ptr(), driver_value.as_ptr(), 1) != 0 {
                return Err(sdl.error("SDL_setenv(SDL_VIDEODRIVER)"));
            }
            (sdl.set_hint)(master_key.as_ptr(), master_value.as_ptr());
            if (sdl.init)(SDL_INIT_VIDEO) != 0 {
                return Err(sdl.error("SDL_Init(SDL_INIT_VIDEO)"));
            }
        }

        let driver_ptr = unsafe { (sdl.get_current_video_driver)() };
        let driver = if driver_ptr.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(driver_ptr).to_string_lossy().into_owned() }
        };
        eprintln!("slot: SDL video driver {driver}");
        if !driver.eq_ignore_ascii_case("kmsdrm") {
            unsafe { (sdl.quit)() };
            return Err(GfxError::Context(format!(
                "expected SDL KMSDRM video driver, got {driver:?}"
            )));
        }

        let attributes = [
            (SDL_GL_RED_SIZE, 8),
            (SDL_GL_GREEN_SIZE, 8),
            (SDL_GL_BLUE_SIZE, 8),
            (SDL_GL_ALPHA_SIZE, 0),
            (SDL_GL_DOUBLEBUFFER, 1),
            (SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES),
            (SDL_GL_CONTEXT_MAJOR_VERSION, 2),
            (SDL_GL_CONTEXT_MINOR_VERSION, 0),
        ];
        for (attr, value) in attributes {
            if unsafe { (sdl.gl_set_attribute)(attr, value) } != 0 {
                let err = sdl.error("SDL_GL_SetAttribute");
                unsafe { (sdl.quit)() };
                return Err(err);
            }
        }

        let title = CString::new("Slot - RG353PS").unwrap();
        let mut size = FALLBACK_PANEL;
        let window = unsafe {
            (sdl.create_window)(
                title.as_ptr(),
                SDL_WINDOWPOS_UNDEFINED,
                SDL_WINDOWPOS_UNDEFINED,
                size.0 as c_int,
                size.1 as c_int,
                SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_SHOWN,
            )
        };
        if window.is_null() {
            let err = sdl.error("SDL_CreateWindow(KMSDRM)");
            unsafe { (sdl.quit)() };
            return Err(err);
        }

        let context = unsafe { (sdl.gl_create_context)(window) };
        if context.is_null() {
            let err = sdl.error("SDL_GL_CreateContext");
            unsafe {
                (sdl.destroy_window)(window);
                (sdl.quit)();
            }
            return Err(err);
        }
        if unsafe { (sdl.gl_make_current)(window, context) } != 0 {
            let err = sdl.error("SDL_GL_MakeCurrent");
            unsafe {
                (sdl.gl_delete_context)(context);
                (sdl.destroy_window)(window);
                (sdl.quit)();
            }
            return Err(err);
        }
        let _ = unsafe { (sdl.gl_set_swap_interval)(1) };
        let (mut w, mut h) = (0, 0);
        unsafe { (sdl.get_window_size)(window, &mut w, &mut h) };
        if w > 0 && h > 0 {
            size = (w as u32, h as u32);
        }
        eprintln!("slot: SDL KMSDRM surface {}x{}", size.0, size.1);

        let gles = match unsafe { Library::new("libGLESv2.so.2") }
            .or_else(|_| unsafe { Library::new("libGLESv2.so") })
        {
            Ok(lib) => lib,
            Err(e) => {
                unsafe {
                    (sdl.gl_delete_context)(context);
                    (sdl.destroy_window)(window);
                    (sdl.quit)();
                }
                return Err(GfxError::Context(format!("GLES library: {e}")));
            }
        };

        Ok(Self {
            sdl,
            gles,
            window,
            context,
            size,
        })
    }
}

impl Surface for FbdevSurface {
    fn make_current(&mut self) -> Result<(), GfxError> {
        match unsafe { (self.sdl.gl_make_current)(self.window, self.context) } {
            0 => Ok(()),
            _ => Err(self.sdl.error("SDL_GL_MakeCurrent")),
        }
    }

    fn window_size(&self) -> (u32, u32) {
        self.size
    }

    fn swap(&mut self) -> Result<(), GfxError> {
        unsafe { (self.sdl.gl_swap_window)(self.window) };
        Ok(())
    }

    fn proc_address(&self, name: &str) -> *const c_void {
        let Ok(c) = CString::new(name) else {
            return std::ptr::null();
        };
        let proc = unsafe { (self.sdl.gl_get_proc_address)(c.as_ptr()) };
        if !proc.is_null() {
            return proc;
        }
        unsafe {
            self.gles
                .get::<unsafe extern "C" fn()>(c.as_bytes_with_nul())
                .map(|f| *f as *const c_void)
                .unwrap_or(std::ptr::null())
        }
    }
}

impl Drop for FbdevSurface {
    fn drop(&mut self) {
        unsafe {
            (self.sdl.gl_make_current)(
                self.window,
                std::ptr::null_mut(),
            );
            (self.sdl.gl_delete_context)(self.context);
            (self.sdl.destroy_window)(self.window);
            (self.sdl.quit)();
        }
    }
}
