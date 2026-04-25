use dioxus::prelude::*;

#[derive(Clone, Copy)]
pub struct AuthState {
    pub user: Signal<Option<User>>,
    pub signing_in: Signal<bool>,
    pub hydrated: Signal<bool>,
    pub welcome_seen: Signal<bool>,
    pub banner_dismissed: Signal<bool>,
    pub dev_mode: Signal<bool>,
}

impl AuthState {
    pub fn new() -> Self {
        Self {
            user: Signal::new(None),
            signing_in: Signal::new(false),
            hydrated: Signal::new(false),
            welcome_seen: Signal::new(false),
            banner_dismissed: Signal::new(false),
            dev_mode: Signal::new(false),
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct User {
    pub id: String,
    pub email: Option<String>,
    pub first_name: Option<String>,
    pub last_name: Option<String>,
    pub image_url: Option<String>,
}
