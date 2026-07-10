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
	`file_hash` text,
	`file_r2_key` text,
	`cover_r2_key` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`sync_version` integer DEFAULT 0,
	`is_dirty` integer DEFAULT true,
	`is_deleted` integer DEFAULT false
);
--> statement-breakpoint
CREATE TABLE `sync_meta` (
	`id` text PRIMARY KEY NOT NULL,
	`last_sync_version` integer DEFAULT 0,
	`last_sync_at` integer
);
