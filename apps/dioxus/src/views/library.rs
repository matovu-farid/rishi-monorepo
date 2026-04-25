use dioxus::prelude::*;

#[component]
pub fn Library() -> Element {
    rsx! {
        div { class: "library",
            h2 { "Library" }
            p { "Your books will appear here." }
        }
    }
}
