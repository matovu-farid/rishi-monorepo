CREATE TABLE `trial_grant` (
	`user_id` text PRIMARY KEY NOT NULL,
	`initial_credits` integer DEFAULT 100 NOT NULL,
	`used_credits` integer DEFAULT 0 NOT NULL,
	`granted_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `allowance_period` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`plan` text NOT NULL,
	`period_start` integer NOT NULL,
	`period_end` integer NOT NULL,
	`narration_seconds_total` integer NOT NULL,
	`narration_seconds_used` integer DEFAULT 0 NOT NULL,
	`voice_chat_seconds_total` integer NOT NULL,
	`voice_chat_seconds_used` integer DEFAULT 0 NOT NULL,
	`transition_reason` text,
	`prior_period_id` text,
	`source_transaction_id` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`prior_period_id`) REFERENCES `allowance_period`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `allowance_period_user_id` ON `allowance_period` (`user_id`);--> statement-breakpoint
CREATE TABLE `usage_reservation` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`kind` text NOT NULL,
	`amount` integer NOT NULL,
	`status` text NOT NULL,
	`created_at` integer NOT NULL,
	`settled_at` integer,
	`metadata` text,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `usage_reservation_user_id` ON `usage_reservation` (`user_id`);--> statement-breakpoint
CREATE TABLE `usage_audit_log` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text,
	`event_type` text NOT NULL,
	`details` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `usage_audit_log_user_id` ON `usage_audit_log` (`user_id`);--> statement-breakpoint
ALTER TABLE `apple_subscriptions` ADD `app_account_token` text;
