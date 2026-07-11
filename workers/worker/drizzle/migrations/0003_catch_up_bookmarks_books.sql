CREATE TABLE `bookmarks` (
	`id` text PRIMARY KEY NOT NULL,
	`book_id` text NOT NULL,
	`user_id` text,
	`location` text NOT NULL,
	`label` text DEFAULT '' NOT NULL,
	`page_number` integer,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`sync_version` integer DEFAULT 0,
	`is_dirty` integer DEFAULT true,
	`is_deleted` integer DEFAULT false
);
--> statement-breakpoint
ALTER TABLE `books` ADD `last_progress_percent` real;--> statement-breakpoint
ALTER TABLE `books` ADD `file_size` integer DEFAULT 0;--> statement-breakpoint
ALTER TABLE `books` ADD `file_needs_redownload` integer DEFAULT false;