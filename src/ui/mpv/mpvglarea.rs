use glib::Object;
use gtk::{
    gio,
    glib,
    prelude::*,
    subclass::prelude::*,
};
use libmpv2::SetData;
use tracing::info;

use super::tsukimi_mpv::{
    ACTIVE,
    TrackSelection,
    TsukimiMPV,
};
use crate::{
    client::jellyfin_client::JELLYFIN_CLIENT,
    utils::spawn,
};

mod imp {
    use std::ffi::c_void;

    #[cfg(target_os = "linux")]
    use gdk_wayland::{
        WaylandDisplay,
        wayland_client::Proxy,
    };

    #[cfg(target_os = "linux")]
    use gdk_x11::X11Display;

    use gettextrs::gettext;
    use glow::HasContext;
    use gtk::{
        gdk::{
            Display,
            GLContext,
        },
        glib,
        prelude::*,
        subclass::prelude::*,
    };
    use libmpv2::render::{
        OpenGLInitParams,
        RenderContext,
        RenderParam,
        RenderParamApiType,
    };
    use once_cell::{
        sync::OnceCell,
        unsync::OnceCell as LocalOnceCell,
    };
    use tracing::{
        debug,
        warn,
    };

    use crate::{
        close_on_error,
        ui::mpv::tsukimi_mpv::{
            RENDER_UPDATE,
            TsukimiMPV,
        },
    };

    #[derive(Default)]
    pub struct MPVGLArea {
        pub mpv: LocalOnceCell<TsukimiMPV>,

        pub ctx: OnceCell<glow::Context>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for MPVGLArea {
        const NAME: &'static str = "MPVGLArea";
        type Type = super::MPVGLArea;
        type ParentType = gtk::GLArea;
    }

    impl ObjectImpl for MPVGLArea {
        fn constructed(&self) {
            self.parent_constructed();
            let obj = self.obj();
            obj.set_auto_render(false);
            #[cfg(target_os = "macos")]
            obj.set_allowed_apis(gtk::gdk::GLAPI::GL);
        }

        fn dispose(&self) {
            if let Some(mpv) = self.mpv.get() {
                mpv.shutdown_event_thread();
            }
        }
    }

    impl WidgetImpl for MPVGLArea {
        fn realize(&self) {
            self.parent_realize();
            let obj = self.obj();

            if obj.error().is_some() {
                close_on_error!(obj, gettext("Failed to realize GLArea"));
                return;
            }

            obj.make_current();
            let Some(gl_context) = obj.context() else {
                close_on_error!(obj, gettext("Failed to get GLContext"));
                return;
            };

            if let Some(mpv) = self.mpv.get() {
                self.setup_mpv(mpv, gl_context, obj.display());
            }

            glib::spawn_future_local(glib::clone!(
                #[weak]
                obj,
                async move {
                    while RENDER_UPDATE.rx.recv_async().await.is_ok() {
                        obj.queue_render();
                    }
                }
            ));
        }

        fn unrealize(&self) {
            self.parent_unrealize();
        }
    }

    impl GLAreaImpl for MPVGLArea {
        fn render(&self, _context: &GLContext) -> glib::Propagation {
            let Some(mpv) = self.mpv.get() else {
                self.clear_framebuffer();
                return glib::Propagation::Stop;
            };

            let binding = mpv.ctx.borrow();
            let Some(ctx) = binding.as_ref() else {
                self.clear_framebuffer();
                return glib::Propagation::Stop;
            };

            let obj = self.obj();
            let factor = obj.scale_factor();
            let width = obj.width() * factor;
            let height = obj.height() * factor;
            if width <= 0 || height <= 0 {
                return glib::Propagation::Stop;
            }

            unsafe {
                let fbo = self.glow_cxt().get_parameter_i32(glow::FRAMEBUFFER_BINDING);
                if let Err(error) = ctx.render::<GLContext>(fbo, width, height, true) {
                    warn!(
                        "Failed to render mpv frame: error={}, fbo={}, width={}, height={}",
                        error, fbo, width, height
                    );
                }
            }
            glib::Propagation::Stop
        }
    }

    impl MPVGLArea {
        pub fn mpv(&self) -> &TsukimiMPV {
            let mpv = self.mpv.get_or_init(TsukimiMPV::default);
            self.ensure_render_context(mpv);
            mpv
        }

        pub fn initialized_mpv(&self) -> Option<&TsukimiMPV> {
            self.mpv.get()
        }

        fn ensure_render_context(&self, mpv: &TsukimiMPV) {
            if !mpv.uses_libmpv_render_api() {
                mpv.process_events();
                return;
            }

            if mpv.ctx.borrow().is_some() || !self.obj().is_realized() {
                return;
            }

            let obj = self.obj();
            if obj.error().is_some() {
                close_on_error!(obj, gettext("Failed to realize GLArea"));
                return;
            }

            obj.make_current();
            let Some(gl_context) = obj.context() else {
                close_on_error!(obj, gettext("Failed to get GLContext"));
                return;
            };

            self.setup_mpv(mpv, gl_context, obj.display());
        }

        fn setup_mpv(
            &self, mpv: &TsukimiMPV, gl_context: GLContext,
            #[cfg_attr(not(target_os = "linux"), allow(unused_variables))] display: Display,
        ) {
            if !mpv.uses_libmpv_render_api() {
                mpv.process_events();
                return;
            }

            let render_params = vec![
                RenderParam::ApiType(RenderParamApiType::OpenGl),
                RenderParam::InitParams(OpenGLInitParams {
                    get_proc_address,
                    ctx: gl_context,
                }),
            ];

            // MPV render params to enable hardware decoding on X11 and Wayland
            // displays.
            //
            // See mpv's render_gl.h for the native display params required by
            // hardware decoding.
            #[cfg(target_os = "linux")]
            let mut render_params = render_params;
            #[cfg(target_os = "linux")]
            if let Ok(display_wrapper) = display.clone().downcast::<X11Display>() {
                render_params.push(RenderParam::X11Display(
                    unsafe { display_wrapper.xdisplay() } as *const c_void,
                ));
            } else if let Some(display_wrapper) = display.clone().downcast::<WaylandDisplay>().ok()
                && let Some(wl_display) = display_wrapper.wl_display()
            {
                render_params.push(RenderParam::WaylandDisplay(
                    wl_display.id().as_ptr() as *const c_void
                ));
            }

            let mut handle = mpv.mpv.ctx;
            let mut ctx = match RenderContext::new(unsafe { handle.as_mut() }, render_params) {
                Ok(ctx) => ctx,
                Err(error) => {
                    warn!("Failed creating mpv render context: {error}");
                    close_on_error!(self.obj(), gettext("Failed creating render context"));
                    return;
                }
            };
            debug!(
                "Created mpv render context: api={:?}, scale_factor={}",
                self.obj().api(),
                self.obj().scale_factor()
            );

            ctx.set_update_callback(|| {
                let _ = RENDER_UPDATE.tx.send(true);
            });

            mpv.ctx.replace(Some(ctx));

            mpv.process_events();
        }

        fn glow_cxt(&self) -> &glow::Context {
            self.ctx.get_or_init(|| unsafe {
                glow::Context::from_loader_function(epoxy::get_proc_addr)
            })
        }

        fn clear_framebuffer(&self) {
            unsafe {
                let gl = self.glow_cxt();
                gl.clear_color(0.0, 0.0, 0.0, 1.0);
                gl.clear(glow::COLOR_BUFFER_BIT);
            }
        }
    }

    fn get_proc_address(_ctx: &GLContext, name: &str) -> *mut c_void {
        epoxy::get_proc_addr(name) as *mut c_void
    }
}

glib::wrapper! {
    pub struct MPVGLArea(ObjectSubclass<imp::MPVGLArea>)
        @extends gtk::Widget ,gtk::GLArea,
        @implements gio::ActionGroup, gio::ActionMap, gtk::Accessible, gtk::Buildable,
                    gtk::ConstraintTarget, gtk::Native, gtk::ShortcutManager;
}

impl Default for MPVGLArea {
    fn default() -> Self {
        Self::new()
    }
}

impl MPVGLArea {
    pub fn new() -> Self {
        Object::builder().build()
    }

    fn with_initialized_mpv(&self, apply: impl FnOnce(&TsukimiMPV)) {
        if let Some(mpv) = self.imp().initialized_mpv() {
            apply(mpv);
        }
    }

    pub fn release_resources(&self) {
        if let Some(mpv) = self.imp().initialized_mpv() {
            mpv.pause(true);
            mpv.stop();
            mpv.ctx.replace(None);
            mpv.event_thread_alive.store(
                super::tsukimi_mpv::PAUSED,
                std::sync::atomic::Ordering::SeqCst,
            );
        }
        self.queue_render();
    }

    pub fn play(&self, url: &str, start_seconds: f64) {
        let url = url.to_owned();

        spawn(glib::clone!(
            #[weak(rename_to = obj)]
            self,
            async move {
                let mpv = &obj.imp().mpv();

                mpv.event_thread_alive
                    .store(ACTIVE, std::sync::atomic::Ordering::SeqCst);
                atomic_wait::wake_all(&*mpv.event_thread_alive);

                let url = JELLYFIN_CLIENT.get_streaming_url(&url).await;

                info!("Now Playing: {}", url);
                mpv.set_start(start_seconds);

                mpv.load_video(&url);

                mpv.pause(false);
            }
        ));
    }

    pub fn add_sub(&self, url: &str) {
        self.with_initialized_mpv(|mpv| mpv.add_sub(url));
    }

    pub fn seek_forward(&self, value: i64) {
        self.with_initialized_mpv(|mpv| mpv.seek_forward(value));
    }

    pub fn seek_backward(&self, value: i64) {
        self.with_initialized_mpv(|mpv| mpv.seek_backward(value));
    }

    pub fn set_position(&self, value: f64) {
        self.with_initialized_mpv(|mpv| mpv.set_position(value));
    }

    pub fn position(&self) -> f64 {
        self.imp()
            .initialized_mpv()
            .map_or(0.0, TsukimiMPV::position)
    }

    pub fn set_aid(&self, value: TrackSelection) {
        self.with_initialized_mpv(|mpv| mpv.set_aid(value));
    }

    pub fn get_track_id(&self, type_: &str) -> i64 {
        self.imp()
            .initialized_mpv()
            .map_or(0, |mpv| mpv.get_track_id(type_))
    }

    pub fn set_sid(&self, value: TrackSelection) {
        self.with_initialized_mpv(|mpv| mpv.set_sid(value));
    }

    pub fn press_key(&self, key: u32, state: gtk::gdk::ModifierType) {
        self.with_initialized_mpv(|mpv| mpv.press_key(key, state));
    }

    pub fn release_key(&self, key: u32, state: gtk::gdk::ModifierType) {
        self.with_initialized_mpv(|mpv| mpv.release_key(key, state));
    }

    pub fn set_speed(&self, value: f64) {
        self.with_initialized_mpv(|mpv| mpv.set_speed(value));
    }

    pub fn set_volume(&self, value: i64) {
        self.with_initialized_mpv(|mpv| mpv.set_volume(value));
    }

    pub fn display_stats_toggle(&self) {
        self.with_initialized_mpv(TsukimiMPV::display_stats_toggle);
    }

    pub fn paused(&self) -> bool {
        self.imp().initialized_mpv().is_none_or(TsukimiMPV::paused)
    }

    pub fn pause(&self) {
        self.with_initialized_mpv(TsukimiMPV::command_pause);
    }

    pub fn volume_scroll(&self, value: i64) {
        self.with_initialized_mpv(|mpv| mpv.volume_scroll(value));
    }

    pub fn set_slang(&self, value: String) {
        self.with_initialized_mpv(|mpv| mpv.set_slang(value));
    }

    pub fn set_property<V>(&self, property: &str, value: V)
    where
        V: SetData + Send + 'static,
    {
        if let Some(mpv) = self.imp().initialized_mpv() {
            mpv.set_property(property, value);
        }
    }
}
