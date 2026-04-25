fn main() {
    dioxus::logger::init(tracing::Level::INFO).expect("failed to init logger");
    dioxus::launch(rishi_dioxus::app::App);
}
