use dioxus::prelude::*;

#[component]
pub fn Reader(id: i32) -> Element {
    rsx! {
        div { class: "reader",
            h2 { "Reader" }
            p { "Reading book {id}" }
        }
    }
}
