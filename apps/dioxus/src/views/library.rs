use dioxus::prelude::*;

#[component]
pub fn Library() -> Element {
    rsx! {
        div { class: "library-page",
            h1 { "Your Library" }
            p { "No books yet. Import one to get started." }
        }
    }
}
