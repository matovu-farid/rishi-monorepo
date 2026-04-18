// @generated automatically by Diesel CLI.

diesel::table! {
    bookmarks (id) {
        id -> Text,
        book_id -> Text,
        user_id -> Nullable<Text>,
        location -> Text,
        label -> Nullable<Text>,
        created_at -> Integer,
        updated_at -> Integer,
        sync_version -> Integer,
        is_dirty -> Integer,
        is_deleted -> Integer,
    }
}

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
        sync_id -> Nullable<Text>,
        file_hash -> Nullable<Text>,
        file_r2_key -> Nullable<Text>,
        cover_r2_key -> Nullable<Text>,
        format -> Text,
        current_cfi -> Nullable<Text>,
        current_page -> Nullable<Integer>,
        user_id -> Nullable<Text>,
        sync_version -> Integer,
        is_dirty -> Integer,
        is_deleted -> Integer,
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

diesel::table! {
    conversations (id) {
        id -> Text,
        book_id -> Text,
        user_id -> Nullable<Text>,
        title -> Text,
        created_at -> Integer,
        updated_at -> Integer,
        sync_version -> Integer,
        is_dirty -> Integer,
        is_deleted -> Integer,
    }
}

diesel::table! {
    highlights (id) {
        id -> Text,
        book_id -> Text,
        user_id -> Nullable<Text>,
        cfi_range -> Text,
        text -> Text,
        color -> Text,
        note -> Nullable<Text>,
        chapter -> Nullable<Text>,
        created_at -> Integer,
        updated_at -> Integer,
        sync_version -> Integer,
        is_dirty -> Integer,
        is_deleted -> Integer,
    }
}

diesel::table! {
    messages (id) {
        id -> Text,
        conversation_id -> Text,
        role -> Text,
        content -> Text,
        source_chunks -> Nullable<Text>,
        created_at -> Integer,
        updated_at -> Integer,
        sync_version -> Integer,
        is_dirty -> Integer,
        is_deleted -> Integer,
    }
}

diesel::table! {
    sync_meta (id) {
        id -> Text,
        last_sync_version -> Integer,
        last_sync_at -> Nullable<Integer>,
    }
}

diesel::allow_tables_to_appear_in_same_query!(
    bookmarks,
    books,
    chunk_data,
    conversations,
    highlights,
    messages,
    sync_meta,
);
