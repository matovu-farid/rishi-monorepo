mod app;

fn main() {
    dioxus::logger::init(tracing::Level::INFO).expect("failed to init logger");
    dioxus::launch(app::App);
}
