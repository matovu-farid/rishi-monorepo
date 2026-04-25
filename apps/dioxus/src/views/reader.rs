use dioxus::prelude::*;

use crate::app::Route;

#[component]
pub fn Reader(id: i32) -> Element {
    let navigator = use_navigator();

    rsx! {
        div { class: "reader-page",
            div { class: "reader-toolbar",
                button {
                    onclick: move |_| { navigator.push(Route::Library {}); },
                    "\u{2190} Back to Library"
                }
                span { "Book #{id}" }
            }
            div { class: "reader-content",
                p { "Reader content will go here." }
            }
        }
    }
}
