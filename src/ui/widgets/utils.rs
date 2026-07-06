use gettextrs::gettext;
use gtk::{
    Builder,
    SignalListItemFactory,
    gio,
    glib,
    prelude::*,
};

use super::{
    filter_panel::FilterPanelDialog,
    identify::IdentifyDialog,
    image_dialog::ImageDialog,
    tu_list_item::{
        TuListItem,
        imp::PosterType,
    },
    tu_overview_item::{
        TuOverviewItem,
        imp::ViewGroup,
    },
};

use crate::ui::provider::tu_object::TuObject;

pub trait TuItemBuildExt {
    fn tu_item(&self, poster: PosterType) -> &Self;
    fn tu_overview_item(&self, view_group: ViewGroup) -> &Self;
}

impl TuItemBuildExt for SignalListItemFactory {
    fn tu_item(&self, poster: PosterType) -> &Self {
        self.connect_setup(move |_, item| {
            let tu_item = TuListItem::default();
            tu_item.set_poster_type(poster);

            let list_item = item
                .downcast_ref::<gtk::ListItem>()
                .expect("Needs to be ListItem");
            list_item.set_child(Some(&tu_item));
            list_item
                .property_expression("item")
                .chain_property::<TuObject>("item")
                .bind(&tu_item, "item", gtk::Widget::NONE);
        });

        self.connect_unbind(|_, item| {
            let list_item = item
                .downcast_ref::<gtk::ListItem>()
                .expect("Needs to be ListItem");

            if let Some(tu_item) = list_item.child().and_downcast::<TuListItem>() {
                tu_item.unbind_item();
            }
        });

        self
    }

    fn tu_overview_item(&self, view_group: ViewGroup) -> &Self {
        self.connect_setup(move |_, item| {
            let tu_item = TuOverviewItem::default();
            tu_item.set_view_group(view_group);
            let list_item = item
                .downcast_ref::<gtk::ListItem>()
                .expect("Needs to be ListItem");
            list_item.set_child(Some(&tu_item));
            list_item
                .property_expression("item")
                .chain_property::<TuObject>("item")
                .bind(&tu_item, "item", gtk::Widget::NONE);
        });
        self
    }
}

const TRANSLATABLE_TEXT_PROPERTIES: &[&str] = &[
    "title",
    "subtitle",
    "label",
    "placeholder-text",
    "tooltip-text",
    "description",
];

pub fn translate_widget_tree(root: &impl IsA<gtk::Widget>) {
    let root = root.as_ref();
    translate_object_text(root.upcast_ref());

    let mut child = root.first_child();
    while let Some(widget) = child {
        translate_widget_tree(&widget);
        child = widget.next_sibling();
    }
}

pub fn translate_sidebar_section(section: &adw::SidebarSection) {
    translate_object_text(section.upcast_ref());

    for index in 0..section.items().n_items() {
        if let Some(item) = section.item(index) {
            translate_sidebar_item(&item);
        }
    }
}

pub fn translate_sidebar_item(item: &adw::SidebarItem) {
    translate_object_text(item.upcast_ref());
}

pub fn translated_builder_from_resource(resource_path: &str) -> Result<Builder, glib::Error> {
    let builder = Builder::new();
    builder.set_translation_domain(Some(crate::GETTEXT_PACKAGE));
    builder.add_from_resource(resource_path)?;
    Ok(builder)
}

pub fn translated_menu_model(model: &impl IsA<gio::MenuModel>) -> gio::Menu {
    let translated_menu = gio::Menu::new();
    let model = model.as_ref();

    for index in 0..model.n_items() {
        let item = gio::MenuItem::from_model(model, index);
        translate_menu_item_label(&item);
        translate_menu_item_link(&item, gio::MENU_LINK_SECTION);
        translate_menu_item_link(&item, gio::MENU_LINK_SUBMENU);
        translated_menu.append_item(&item);
    }

    translated_menu.freeze();
    translated_menu
}

fn translate_menu_item_label(item: &gio::MenuItem) {
    let Some(label) = item
        .attribute_value(gio::MENU_ATTRIBUTE_LABEL, None)
        .and_then(|label| label.get::<String>())
    else {
        return;
    };

    item.set_label(Some(&gettext(&label)));
}

fn translate_menu_item_link(item: &gio::MenuItem, link_name: &str) {
    let Some(link) = item.link(link_name) else {
        return;
    };

    let translated_link = translated_menu_model(&link);
    item.set_link(link_name, Some(&translated_link));
}

fn translate_object_text(object: &glib::Object) {
    for property in TRANSLATABLE_TEXT_PROPERTIES {
        translate_text_property(object, property);
    }
}

fn translate_text_property(object: &glib::Object, property: &str) {
    let Some(spec) = object.find_property(property) else {
        return;
    };

    if spec.value_type() != String::static_type()
        || !spec.flags().contains(glib::ParamFlags::WRITABLE)
    {
        return;
    }

    let value = object.property_value(property);
    let text = match value.get::<String>() {
        Ok(text) => text,
        Err(_) => match value.get::<Option<String>>() {
            Ok(Some(text)) => text,
            _ => return,
        },
    };

    if text.is_empty() {
        return;
    }

    let translated = gettext(&text);
    if translated != text {
        object.set_property(property, translated.as_str());
    }
}

pub const TU_ITEM_POST_SIZE: (i32, i32) = (167, 260);
pub const TU_ITEM_VIDEO_SIZE: (i32, i32) = (250, 141);
pub const TU_ITEM_SQUARE_SIZE: (i32, i32) = (190, 190);
pub const TU_ITEM_BANNER_SIZE: (i32, i32) = (375, 70);

pub trait GlobalToast {
    fn toast(&self, message: impl Into<String>);

    fn add_toast_inner(&self, toast: adw::Toast);
}

impl<T> GlobalToast for T
where
    T: IsA<gtk::Widget>,
{
    fn toast(&self, message: impl Into<String>) {
        let toast = adw::Toast::builder()
            .timeout(2)
            .use_markup(false)
            .title(message.into())
            .build();
        self.add_toast_inner(toast);
    }

    fn add_toast_inner(&self, toast: adw::Toast) {
        if let Some(dialog) = self
            .ancestor(adw::PreferencesDialog::static_type())
            .and_downcast::<adw::PreferencesDialog>()
        {
            use adw::prelude::PreferencesDialogExt;
            dialog.add_toast(toast);
        } else if let Some(overlay) = self
            .ancestor(adw::ToastOverlay::static_type())
            .and_downcast::<adw::ToastOverlay>()
        {
            overlay.add_toast(toast);
        } else if let Some(dialog) = self
            .ancestor(FilterPanelDialog::static_type())
            .and_downcast::<FilterPanelDialog>()
        {
            dialog.add_toast(toast);
        } else if let Some(dialog) = self
            .ancestor(IdentifyDialog::static_type())
            .and_downcast::<IdentifyDialog>()
        {
            dialog.add_toast(toast);
        } else if let Some(dialog) = self
            .ancestor(ImageDialog::static_type())
            .and_downcast::<ImageDialog>()
        {
            dialog.add_toast(toast);
        } else if let Some(root) = self.root() {
            #[allow(deprecated)]
            if let Some(window) = root.downcast_ref::<adw::PreferencesWindow>() {
                use adw::prelude::PreferencesWindowExt;
                window.add_toast(toast);
            } else if let Some(window) = root.downcast_ref::<crate::Window>() {
                window.add_toast(toast);
            } else {
                panic!("Trying to display a toast when the parent doesn't support it");
            }
        }
    }
}

pub fn run_time_ticks_to_label(run_time_ticks: u64) -> String {
    let duration = chrono::Duration::seconds((run_time_ticks / 10000000) as i64);
    let hours = duration.num_hours();
    let minutes = duration.num_minutes() % 60;
    let seconds = duration.num_seconds() % 60;

    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes}:{seconds:02}")
    }
}
