CREATE TABLE `apple_user_2` (
	`user_id` text PRIMARY KEY NOT NULL,
	`name` text,
	`email` text,
	`apple_sub` text NOT NULL,
	`created_at` integer DEFAULT CURRENT_TIMESTAMP NOT NULL,
	`updated_at` integer
);
--> statement-breakpoint
CREATE UNIQUE INDEX `apple_user_2_apple_sub_unique` ON `apple_user_2` (`apple_sub`);--> statement-breakpoint
DROP TABLE `apple_user`;--> statement-breakpoint
PRAGMA foreign_keys=OFF;--> statement-breakpoint
CREATE TABLE `__new_apple_notifications_logs` (
	`notification_uuid` text PRIMARY KEY NOT NULL,
	`notification_type` text NOT NULL,
	`subtype` text,
	`user_id` text,
	`apple_transaction_id` text,
	`raw_payload` text NOT NULL,
	`received_at` integer NOT NULL,
	`processed_at` integer,
	`processing_error` text,
	FOREIGN KEY (`user_id`) REFERENCES `apple_user_2`(`user_id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
INSERT INTO `__new_apple_notifications_logs`("notification_uuid", "notification_type", "subtype", "user_id", "apple_transaction_id", "raw_payload", "received_at", "processed_at", "processing_error") SELECT "notification_uuid", "notification_type", "subtype", "user_id", "apple_transaction_id", "raw_payload", "received_at", "processed_at", "processing_error" FROM `apple_notifications_logs`;--> statement-breakpoint
DROP TABLE `apple_notifications_logs`;--> statement-breakpoint
ALTER TABLE `__new_apple_notifications_logs` RENAME TO `apple_notifications_logs`;--> statement-breakpoint
PRAGMA foreign_keys=ON;--> statement-breakpoint
CREATE TABLE `__new_apple_subscriptions` (
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
	FOREIGN KEY (`user_id`) REFERENCES `apple_user_2`(`user_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
INSERT INTO `__new_apple_subscriptions`("apple_transaction_id", "apple_original_transaction_id", "user_id", "product_id", "status", "current_period_end", "environment", "auto_renew", "created_at", "updated_at") SELECT "apple_transaction_id", "apple_original_transaction_id", "user_id", "product_id", "status", "current_period_end", "environment", "auto_renew", "created_at", "updated_at" FROM `apple_subscriptions`;--> statement-breakpoint
DROP TABLE `apple_subscriptions`;--> statement-breakpoint
ALTER TABLE `__new_apple_subscriptions` RENAME TO `apple_subscriptions`;--> statement-breakpoint
CREATE INDEX `apple_subscriptions_user_id` ON `apple_subscriptions` (`user_id`);--> statement-breakpoint
CREATE INDEX `apple_subscriptions_original_txn` ON `apple_subscriptions` (`apple_original_transaction_id`);--> statement-breakpoint
CREATE TABLE `__new_conversations` (
	`id` text PRIMARY KEY NOT NULL,
	`book_id` text NOT NULL,
	`user_id` text NOT NULL,
	`title` text DEFAULT 'New conversation' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`sync_version` integer DEFAULT 0,
	`is_dirty` integer DEFAULT true,
	`is_deleted` integer DEFAULT false,
	FOREIGN KEY (`user_id`) REFERENCES `apple_user_2`(`user_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
INSERT INTO `__new_conversations`("id", "book_id", "user_id", "title", "created_at", "updated_at", "sync_version", "is_dirty", "is_deleted") SELECT "id", "book_id", "user_id", "title", "created_at", "updated_at", "sync_version", "is_dirty", "is_deleted" FROM `conversations`;--> statement-breakpoint
DROP TABLE `conversations`;--> statement-breakpoint
ALTER TABLE `__new_conversations` RENAME TO `conversations`;--> statement-breakpoint
CREATE INDEX `conversations_user_updated_idx` ON `conversations` (`user_id`,`updated_at`);--> statement-breakpoint
CREATE TABLE `__new_devices` (
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
	FOREIGN KEY (`user_id`) REFERENCES `apple_user_2`(`user_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
INSERT INTO `__new_devices`("id", "user_id", "device_token", "platform", "app_version", "bundle_id", "topic", "env", "created_at", "updated_at") SELECT "id", "user_id", "device_token", "platform", "app_version", "bundle_id", "topic", "env", "created_at", "updated_at" FROM `devices`;--> statement-breakpoint
DROP TABLE `devices`;--> statement-breakpoint
ALTER TABLE `__new_devices` RENAME TO `devices`;--> statement-breakpoint
CREATE UNIQUE INDEX `devices_user_token_uniq` ON `devices` (`user_id`,`device_token`);