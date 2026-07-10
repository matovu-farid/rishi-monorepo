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
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `apple_notifications_logs` (
	`notification_uuid` text PRIMARY KEY NOT NULL,
	`notification_type` text NOT NULL,
	`subtype` text,
	`user_id` text,
	`apple_transaction_id` text,
	`raw_payload` text NOT NULL,
	`received_at` integer NOT NULL,
	`processed_at` integer,
	`processing_error` text,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE TABLE `apple_subscriptions` (
	`apple_transaction_id` text PRIMARY KEY NOT NULL,
	`apple_original_transaction_id` text NOT NULL,
	`user_id` text NOT NULL,
	`product_id` text NOT NULL,
	`status` text NOT NULL,
	`current_period_end` integer NOT NULL,
	`environment` text NOT NULL,
	`auto_renew` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `apple_subscriptions_user_id` ON `apple_subscriptions` (`user_id`);--> statement-breakpoint
CREATE INDEX `apple_subscriptions_original_txn` ON `apple_subscriptions` (`apple_original_transaction_id`);--> statement-breakpoint
CREATE TABLE `siwa_user` (
	`user_id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`email` text NOT NULL,
	`created_at` integer DEFAULT CURRENT_TIMESTAMP NOT NULL,
	`updated_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `siwa_user_email_unique` ON `siwa_user` (`email`);--> statement-breakpoint
CREATE TABLE `book_pages` (
	`book_id` text NOT NULL,
	`page_number` integer NOT NULL,
	`text` text DEFAULT '' NOT NULL,
	`width_pts` real NOT NULL,
	`height_pts` real NOT NULL,
	`indexed_at` integer NOT NULL,
	PRIMARY KEY(`book_id`, `page_number`)
);
--> statement-breakpoint
CREATE TABLE `book_paragraphs` (
	`book_id` text NOT NULL,
	`page_number` integer NOT NULL,
	`paragraph_index` text NOT NULL,
	`text` text NOT NULL,
	PRIMARY KEY(`book_id`, `page_number`, `paragraph_index`)
);
--> statement-breakpoint
CREATE TABLE `book_words` (
	`book_id` text NOT NULL,
	`page_number` integer NOT NULL,
	`idx` integer NOT NULL,
	`text` text NOT NULL,
	`x` real NOT NULL,
	`y` real NOT NULL,
	`w` real NOT NULL,
	`h` real NOT NULL,
	PRIMARY KEY(`book_id`, `page_number`, `idx`)
);
--> statement-breakpoint
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
	`is_deleted` integer DEFAULT false
);
--> statement-breakpoint
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
	`extraction_error` text
);
--> statement-breakpoint
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
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `conversations_user_updated_idx` ON `conversations` (`user_id`,`updated_at`);--> statement-breakpoint
CREATE TABLE `devices` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`device_token` text NOT NULL,
	`platform` text NOT NULL,
	`app_version` text NOT NULL,
	`bundle_id` text NOT NULL,
	`topic` text NOT NULL,
	`env` text DEFAULT 'production' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `devices_user_token_uniq` ON `devices` (`user_id`,`device_token`);--> statement-breakpoint
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
	`is_deleted` integer DEFAULT false
);
--> statement-breakpoint
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
	`is_deleted` integer DEFAULT false
);
--> statement-breakpoint
CREATE INDEX `messages_conv_updated_idx` ON `messages` (`conversation_id`,`updated_at`);--> statement-breakpoint
CREATE TABLE `passkey` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text,
	`public_key` text NOT NULL,
	`user_id` text NOT NULL,
	`credential_id` text NOT NULL,
	`counter` integer NOT NULL,
	`device_type` text NOT NULL,
	`backed_up` integer NOT NULL,
	`transports` text,
	`created_at` integer,
	`aaguid` text,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `session` (
	`id` text PRIMARY KEY NOT NULL,
	`expires_at` integer NOT NULL,
	`token` text NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`ip_address` text,
	`user_agent` text,
	`user_id` text NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `session_token_unique` ON `session` (`token`);--> statement-breakpoint
CREATE TABLE `subscription` (
	`id` text PRIMARY KEY NOT NULL,
	`plan` text NOT NULL,
	`reference_id` text NOT NULL,
	`stripe_customer_id` text,
	`stripe_subscription_id` text,
	`status` text DEFAULT 'incomplete',
	`period_start` integer,
	`period_end` integer,
	`trial_start` integer,
	`trial_end` integer,
	`cancel_at_period_end` integer DEFAULT false,
	`cancel_at` integer,
	`canceled_at` integer,
	`ended_at` integer,
	`seats` integer,
	`billing_interval` text,
	`stripe_schedule_id` text
);
--> statement-breakpoint
CREATE TABLE `sync_meta` (
	`id` text PRIMARY KEY NOT NULL,
	`last_sync_version` integer DEFAULT 0,
	`last_sync_at` integer
);
--> statement-breakpoint
CREATE TABLE `user` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`email` text NOT NULL,
	`email_verified` integer NOT NULL,
	`image` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`stripe_customer_id` text
);
--> statement-breakpoint
CREATE UNIQUE INDEX `user_email_unique` ON `user` (`email`);--> statement-breakpoint
CREATE TABLE `verification` (
	`id` text PRIMARY KEY NOT NULL,
	`identifier` text NOT NULL,
	`value` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer,
	`updated_at` integer
);
