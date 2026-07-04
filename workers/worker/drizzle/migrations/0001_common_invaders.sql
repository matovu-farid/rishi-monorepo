ALTER TABLE `apple_users` ADD `user_id` text REFERENCES user(id);--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_bookmarks` (
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
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
INSERT INTO `__new_bookmarks`("id", "book_id", "user_id", "location", "label", "snippet", "page_number", "created_at", "updated_at", "sync_version", "is_dirty", "is_deleted") SELECT "id", "book_id", "user_id", "location", "label", "snippet", "page_number", "created_at", "updated_at", "sync_version", "is_dirty", "is_deleted" FROM `bookmarks`;--> statement-breakpoint
DROP TABLE `bookmarks`;--> statement-breakpoint
ALTER TABLE `__new_bookmarks` RENAME TO `bookmarks`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE TABLE `__new_books` (
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
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
INSERT INTO `__new_books`("id", "user_id", "title", "author", "cover_path", "file_path", "format", "current_cfi", "current_page", "last_progress_percent", "file_hash", "file_r2_key", "cover_r2_key", "file_size", "file_needs_redownload", "created_at", "updated_at", "sync_version", "is_dirty", "is_deleted", "extraction_status", "extracted_pages", "total_pages", "extraction_error") SELECT "id", "user_id", "title", "author", "cover_path", "file_path", "format", "current_cfi", "current_page", "last_progress_percent", "file_hash", "file_r2_key", "cover_r2_key", "file_size", "file_needs_redownload", "created_at", "updated_at", "sync_version", "is_dirty", "is_deleted", "extraction_status", "extracted_pages", "total_pages", "extraction_error" FROM `books`;--> statement-breakpoint
DROP TABLE `books`;--> statement-breakpoint
ALTER TABLE `__new_books` RENAME TO `books`;--> statement-breakpoint
CREATE TABLE `__new_highlights` (
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
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
INSERT INTO `__new_highlights`("id", "book_id", "user_id", "cfi_range", "text", "color", "note", "chapter", "created_at", "updated_at", "sync_version", "is_dirty", "is_deleted") SELECT "id", "book_id", "user_id", "cfi_range", "text", "color", "note", "chapter", "created_at", "updated_at", "sync_version", "is_dirty", "is_deleted" FROM `highlights`;--> statement-breakpoint
DROP TABLE `highlights`;--> statement-breakpoint
ALTER TABLE `__new_highlights` RENAME TO `highlights`;