use std::{
    env,
    path::PathBuf,
    sync::LazyLock,
};

mod app;
mod arg;
mod config;
mod gstl;
mod macros;
#[cfg(target_os = "linux")]
mod mpris_common;
mod ui;
mod utils;

pub mod client;

pub use arg::Args;
pub use config::GETTEXT_PACKAGE;
use config::{
    LOCALEDIR,
    PKGDATADIR,
    version,
};
use once_cell::sync::OnceCell;

use clap::Parser;
use gettextrs::*;
use gtk::prelude::*;

pub use ui::Window;

pub use app::TsukimiApplication as Application;

use crate::{
    client::runtime::runtime,
    ui::widgets,
};

pub static USER_AGENT: LazyLock<String> =
    LazyLock::new(|| format!("{}/{} - {}", CLIENT_ID, version(), env::consts::OS));

pub const APP_ID: &str = "moe.tsuna.tsukimi";
pub const CLIENT_ID: &str = "Tsukimi";
const APP_RESOURCE_PATH: &str = "/moe/tsuna/tsukimi";
const GRESOURCE_FILE: &str = "tsukimi.gresource";

pub fn locale_dir() -> PathBuf {
    static FLOCALEDIR: OnceCell<PathBuf> = OnceCell::new();
    FLOCALEDIR.get_or_init(app_locale_dir).clone()
}

pub fn run() -> gtk::glib::ExitCode {
    Args::parse().init();
    init_gettext();

    adw::init().expect("Failed to initialize Adwaita");
    register_gio_resources();

    widgets::init();

    // Initialize the GTK application
    gtk::glib::set_application_name(CLIENT_ID);

    let _tokio_guard = runtime().enter();
    Application::new().run_with_args::<&str>(&[])
}

fn init_gettext() {
    apply_configured_language();
    let _ = setlocale(LocaleCategory::LcAll, "");
    bind_textdomain_codeset(GETTEXT_PACKAGE, "UTF-8").expect("Failed to set textdomain codeset");
    let locale_dir = locale_dir();
    bindtextdomain(GETTEXT_PACKAGE, &locale_dir)
        .expect("Invalid argument passed to bindtextdomain");

    textdomain(GETTEXT_PACKAGE).expect("Invalid string passed to textdomain");
}

fn apply_configured_language() {
    let gettext_locale = crate::ui::SETTINGS.app_language_locale();
    if gettext_locale.is_empty() {
        return;
    }

    let system_locale = posix_locale_for_gettext(gettext_locale);
    let language_priority = gettext_language_priority(gettext_locale);
    unsafe {
        env::set_var("LANGUAGE", language_priority);
        env::set_var("LANG", system_locale);
        env::set_var("LC_MESSAGES", system_locale);
        env::set_var("LC_ALL", system_locale);
    }
}

fn gettext_language_priority(locale: &str) -> &'static str {
    match locale {
        "en" => "en",
        "zh_CN" => "zh_CN:zh",
        "zh_Hant" => "zh_Hant:zh_TW:zh",
        "ja" => "ja",
        "fr" => "fr",
        "de" => "de",
        "pt_BR" => "pt_BR:pt",
        "ru" => "ru",
        "ar" => "ar",
        _ => "",
    }
}

fn posix_locale_for_gettext(locale: &str) -> &'static str {
    match locale {
        "en" => "en_US.UTF-8",
        "zh_CN" => "zh_CN.UTF-8",
        "zh_Hant" => "zh_TW.UTF-8",
        "ja" => "ja_JP.UTF-8",
        "fr" => "fr_FR.UTF-8",
        "de" => "de_DE.UTF-8",
        "pt_BR" => "pt_BR.UTF-8",
        "ru" => "ru_RU.UTF-8",
        "ar" => "ar.UTF-8",
        _ => "",
    }
}

fn register_gio_resources() {
    let path = pkg_data_dir().join(GRESOURCE_FILE);
    let resources = gtk::gio::Resource::load(path).expect("Failed to load resources.");
    gtk::gio::resources_register(&resources);
}

fn pkg_data_dir() -> PathBuf {
    static FPKGDATADIR: OnceCell<PathBuf> = OnceCell::new();
    FPKGDATADIR.get_or_init(app_pkg_data_dir).clone()
}

fn app_locale_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    if let Some(share_dir) = macos_bundle_share_dir() {
        let locale_dir = share_dir.join("locale");
        if locale_dir.is_dir() {
            return locale_dir;
        }
    }

    PathBuf::from(LOCALEDIR)
}

fn app_pkg_data_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    if let Some(share_dir) = macos_bundle_share_dir() {
        let pkg_data_dir = share_dir.join("tsukimi");
        if pkg_data_dir.join(GRESOURCE_FILE).is_file() {
            return pkg_data_dir;
        }
    }

    PathBuf::from(PKGDATADIR)
}

#[cfg(target_os = "macos")]
fn macos_bundle_share_dir() -> Option<PathBuf> {
    let executable = env::current_exe().ok()?;
    let contents_dir = executable.parent()?.parent()?;
    let resources_dir = contents_dir.join("Resources");

    if resources_dir.is_dir() {
        Some(resources_dir.join("share"))
    } else {
        None
    }
}
