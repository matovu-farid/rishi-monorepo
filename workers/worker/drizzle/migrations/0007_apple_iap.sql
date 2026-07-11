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
CREATE INDEX `apple_subscriptions_original_txn` ON `apple_subscriptions` (`apple_original_transaction_id`);