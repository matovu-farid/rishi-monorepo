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
CREATE UNIQUE INDEX `devices_user_token_uniq` ON `devices` (`user_id`,`device_token`);