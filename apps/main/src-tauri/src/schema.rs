// @generated automatically by Diesel CLI.

diesel::table! {
    books (id) {
        id -> Integer,
        kind -> Text,
        cover -> Binary,
        title -> Text,
        author -> Text,
        publisher -> Text,
        filepath -> Text,
        location -> Text,
        cover_kind -> Text,
        version -> Integer,
        created_at -> Timestamp,
        updated_at -> Timestamp,
    }
}

diesel::table! {
    chunk_data (id) {
        id -> BigInt,
        pageNumber -> Integer,
        bookId -> Integer,
        data -> Text,
        created_at -> Timestamp,
        updated_at -> Timestamp,
    }
}

diesel::allow_tables_to_appear_in_same_query!(books, chunk_data,);
