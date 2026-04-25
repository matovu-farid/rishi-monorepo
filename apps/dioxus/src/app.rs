use dioxus::prelude::*;
use crate::views::library::Library;
use crate::views::reader::Reader;

#[derive(Routable, Clone, PartialEq, Debug)]
#[rustfmt::skip]
pub enum Route {
    #[layout(RootLayout)]
        #[route("/")]
        Library {},
        #[route("/books/:id")]
        Reader { id: i32 },
}

#[component]
pub fn App() -> Element {
    rsx! {
        document::Stylesheet { href: asset!("/assets/main.css") }
        Router::<Route> {}
    }
}

#[component]
fn RootLayout() -> Element {
    rsx! {
        div { class: "app-root",
            Outlet::<Route> {}
        }
    }
}
