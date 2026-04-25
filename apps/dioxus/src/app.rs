use dioxus::prelude::*;
use crate::db;
use crate::state::auth::AuthState;
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
    use_context_provider(AuthState::new);

    let mut db_ready = use_signal(|| false);

    use_future(move || async move {
        match tokio::task::spawn_blocking(db::setup_database).await {
            Ok(Ok(())) => {
                tracing::info!("Database ready");
                db_ready.set(true);
            }
            Ok(Err(e)) => {
                tracing::error!("Failed to initialize database: {}", e);
            }
            Err(e) => {
                tracing::error!("Database init task panicked: {}", e);
            }
        }
    });

    if !db_ready() {
        return rsx! {
            div { class: "loading-screen",
                p { "Loading..." }
            }
        };
    }

    rsx! {
        div { class: "app-root",
            Outlet::<Route> {}
        }
    }
}
