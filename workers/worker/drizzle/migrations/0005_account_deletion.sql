CREATE TABLE `account` (
  `id` text PRIMARY KEY NOT NULL,
  `account_id` text NOT NULL,
  `provider_id` text NOT NULL,
  `user_id` text NOT NULL,
  `access_token` text,
  `refresh_token` text,
  `id_token` text,
  `access_token_expires_at` integer,
  `refresh_token_expires_at` integer,
  `scope` text,
  `password` text,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade
);
--> statement-breakpoint
ALTER TABLE `apple_users` ADD `siwa_refresh_token_ciphertext` text;
--> statement-breakpoint
ALTER TABLE `apple_users` ADD `siwa_refresh_token_nonce` text;
--> statement-breakpoint
PRAGMA foreign_keys=OFF;
--> statement-breakpoint
DROP INDEX IF EXISTS `apple_users_apple_user_id_unique`;
DROP INDEX IF EXISTS `conversations_user_updated_idx`;
DROP INDEX IF EXISTS `messages_conv_updated_idx`;
DROP INDEX IF EXISTS `chapter_index_chapters_version_chapter_uniq`;
DROP INDEX IF EXISTS `chapter_index_chapters_version_order_idx`;
DROP INDEX IF EXISTS `chapter_indexes_user_updated_idx`;
DROP INDEX IF EXISTS `chapter_indexes_version_key_uniq`;
--> statement-breakpoint
ALTER TABLE `apple_notifications_log` RENAME TO `__old_apple_notifications_log`;
ALTER TABLE `apple_users` RENAME TO `__old_apple_users`;
ALTER TABLE `book_pages` RENAME TO `__old_book_pages`;
ALTER TABLE `book_paragraphs` RENAME TO `__old_book_paragraphs`;
ALTER TABLE `book_words` RENAME TO `__old_book_words`;
ALTER TABLE `bookmarks` RENAME TO `__old_bookmarks`;
ALTER TABLE `books` RENAME TO `__old_books`;
ALTER TABLE `conversations` RENAME TO `__old_conversations`;
ALTER TABLE `highlights` RENAME TO `__old_highlights`;
ALTER TABLE `messages` RENAME TO `__old_messages`;
ALTER TABLE `chapter_indexes` RENAME TO `__old_chapter_indexes`;
ALTER TABLE `chapter_index_chapters` RENAME TO `__old_chapter_index_chapters`;
--> statement-breakpoint
CREATE TABLE `apple_notifications_log` (
  `notification_uuid` text PRIMARY KEY NOT NULL,
  `notification_type` text NOT NULL,
  `subtype` text,
  `user_id` text,
  `apple_transaction_id` text,
  `raw_payload` text NOT NULL,
  `received_at` integer NOT NULL,
  `processed_at` integer,
  `processing_error` text,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade
);
CREATE TABLE `apple_users` (
  `id` text PRIMARY KEY NOT NULL,
  `apple_user_id` text NOT NULL UNIQUE,
  `user_id` text,
  `email` text,
  `email_verified` integer NOT NULL,
  `private_email` integer NOT NULL,
  `siwa_refresh_token_ciphertext` text,
  `siwa_refresh_token_nonce` text,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade
);
CREATE TABLE `book_pages` (
  `book_id` text NOT NULL,
  `page_number` integer NOT NULL,
  `text` text DEFAULT '' NOT NULL,
  `width_pts` real NOT NULL,
  `height_pts` real NOT NULL,
  `indexed_at` integer NOT NULL,
  PRIMARY KEY(`book_id`, `page_number`),
  FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE cascade
);
CREATE TABLE `book_paragraphs` (
  `book_id` text NOT NULL,
  `page_number` integer NOT NULL,
  `paragraph_index` text NOT NULL,
  `text` text NOT NULL,
  PRIMARY KEY(`book_id`, `page_number`, `paragraph_index`),
  FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE cascade
);
CREATE TABLE `book_words` (
  `book_id` text NOT NULL,
  `page_number` integer NOT NULL,
  `idx` integer NOT NULL,
  `text` text NOT NULL,
  `x` real NOT NULL,
  `y` real NOT NULL,
  `w` real NOT NULL,
  `h` real NOT NULL,
  PRIMARY KEY(`book_id`, `page_number`, `idx`),
  FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE cascade
);
CREATE TABLE `bookmarks` (
  `id` text PRIMARY KEY NOT NULL,
  `book_id` text NOT NULL,
  `user_id` text,
  `location` text NOT NULL,
  `label` text DEFAULT '' NOT NULL,
  `snippet` text,
  `page_number` integer,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  `sync_version` integer DEFAULT 0,
  `is_dirty` integer DEFAULT true,
  `is_deleted` integer DEFAULT false,
  FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE cascade,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade
);
CREATE TABLE `books` (
  `id` text PRIMARY KEY NOT NULL,
  `user_id` text,
  `title` text NOT NULL,
  `author` text DEFAULT 'Unknown' NOT NULL,
  `cover_path` text,
  `file_path` text NOT NULL,
  `format` text DEFAULT 'epub' NOT NULL,
  `current_cfi` text,
  `current_page` integer,
  `last_progress_percent` real,
  `file_hash` text,
  `file_r2_key` text,
  `cover_r2_key` text,
  `file_size` integer DEFAULT 0,
  `file_needs_redownload` integer DEFAULT false,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  `sync_version` integer DEFAULT 0,
  `is_dirty` integer DEFAULT true,
  `is_deleted` integer DEFAULT false,
  `extraction_status` text,
  `extracted_pages` integer DEFAULT 0,
  `total_pages` integer,
  `extraction_error` text,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade
);
CREATE TABLE `conversations` (
  `id` text PRIMARY KEY NOT NULL,
  `book_id` text NOT NULL,
  `user_id` text NOT NULL,
  `title` text DEFAULT 'New conversation' NOT NULL,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  `sync_version` integer DEFAULT 0,
  `is_dirty` integer DEFAULT true,
  `is_deleted` integer DEFAULT false,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade
);
CREATE TABLE `highlights` (
  `id` text PRIMARY KEY NOT NULL,
  `book_id` text NOT NULL,
  `user_id` text,
  `cfi_range` text NOT NULL,
  `text` text NOT NULL,
  `color` text DEFAULT 'yellow' NOT NULL,
  `note` text,
  `chapter` text,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  `sync_version` integer DEFAULT 0,
  `is_dirty` integer DEFAULT true,
  `is_deleted` integer DEFAULT false,
  FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE cascade,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade
);
CREATE TABLE `messages` (
  `id` text PRIMARY KEY NOT NULL,
  `conversation_id` text NOT NULL,
  `role` text NOT NULL,
  `content` text NOT NULL,
  `source_chunks` text,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  `sync_version` integer DEFAULT 0,
  `is_dirty` integer DEFAULT true,
  `is_deleted` integer DEFAULT false,
  FOREIGN KEY (`conversation_id`) REFERENCES `conversations`(`id`) ON DELETE cascade
);
CREATE TABLE `chapter_indexes` (
  `id` text NOT NULL,
  `user_id` text NOT NULL,
  `book_id` text NOT NULL,
  `content_version` text NOT NULL,
  `status` text NOT NULL,
  `model_identifier` text NOT NULL,
  `model_version` text NOT NULL,
  `completed_count` integer DEFAULT 0 NOT NULL,
  `total_count` integer DEFAULT 0 NOT NULL,
  `error_message` text,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  CONSTRAINT `chapter_indexes_pk` PRIMARY KEY(`user_id`, `book_id`, `content_version`),
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade,
  FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE cascade
);
CREATE TABLE `chapter_index_chapters` (
  `id` text PRIMARY KEY NOT NULL,
  `user_id` text NOT NULL,
  `book_id` text NOT NULL,
  `content_version` text NOT NULL,
  `chapter_id` text NOT NULL,
  `source_position` integer NOT NULL,
  `name` text NOT NULL,
  `summary` text NOT NULL,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade,
  FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE cascade,
  FOREIGN KEY (`user_id`, `book_id`, `content_version`) REFERENCES `chapter_indexes`(`user_id`, `book_id`, `content_version`) ON DELETE cascade
);
--> statement-breakpoint
INSERT INTO `apple_notifications_log` SELECT * FROM `__old_apple_notifications_log`;
INSERT INTO `apple_users` (`id`, `apple_user_id`, `user_id`, `email`, `email_verified`, `private_email`, `created_at`, `updated_at`)
SELECT `id`, `apple_user_id`, `user_id`, `email`, `email_verified`, `private_email`, `created_at`, `updated_at`
FROM `__old_apple_users`;
INSERT INTO `book_pages` SELECT * FROM `__old_book_pages`;
INSERT INTO `book_paragraphs` SELECT * FROM `__old_book_paragraphs`;
INSERT INTO `book_words` SELECT * FROM `__old_book_words`;
INSERT INTO `bookmarks` SELECT * FROM `__old_bookmarks`;
INSERT INTO `books` SELECT * FROM `__old_books`;
INSERT INTO `conversations` SELECT * FROM `__old_conversations`;
INSERT INTO `highlights` SELECT * FROM `__old_highlights`;
INSERT INTO `messages` SELECT * FROM `__old_messages`;
INSERT INTO `chapter_indexes` SELECT * FROM `__old_chapter_indexes`;
INSERT INTO `chapter_index_chapters` SELECT * FROM `__old_chapter_index_chapters`;
--> statement-breakpoint
DROP TABLE `__old_apple_notifications_log`;
DROP TABLE `__old_apple_users`;
DROP TABLE `__old_book_pages`;
DROP TABLE `__old_book_paragraphs`;
DROP TABLE `__old_book_words`;
DROP TABLE `__old_bookmarks`;
DROP TABLE `__old_books`;
DROP TABLE `__old_conversations`;
DROP TABLE `__old_highlights`;
DROP TABLE `__old_messages`;
DROP TABLE `__old_chapter_indexes`;
DROP TABLE `__old_chapter_index_chapters`;
--> statement-breakpoint
CREATE UNIQUE INDEX `apple_users_apple_user_id_unique` ON `apple_users` (`apple_user_id`);
CREATE INDEX `conversations_user_updated_idx` ON `conversations` (`user_id`, `updated_at`);
CREATE INDEX `messages_conv_updated_idx` ON `messages` (`conversation_id`, `updated_at`);
CREATE INDEX `chapter_indexes_user_updated_idx` ON `chapter_indexes` (`user_id`, `updated_at`);
CREATE UNIQUE INDEX `chapter_indexes_version_key_uniq` ON `chapter_indexes` (`user_id`, `book_id`, `content_version`);
CREATE UNIQUE INDEX `chapter_index_chapters_version_chapter_uniq` ON `chapter_index_chapters` (`user_id`, `book_id`, `content_version`, `chapter_id`);
CREATE INDEX `chapter_index_chapters_version_order_idx` ON `chapter_index_chapters` (`user_id`, `book_id`, `content_version`, `source_position`);
PRAGMA foreign_keys=ON;
