CREATE TABLE `share_package_redemptions` (
	`id` text PRIMARY KEY,
	`package_id` text NOT NULL,
	`user_id` text NOT NULL,
	`created_at` integer NOT NULL,
	CONSTRAINT `fk_share_package_redemptions_package_id_share_packages_id_fk` FOREIGN KEY (`package_id`) REFERENCES `share_packages`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_share_package_redemptions_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
ALTER TABLE `share_packages` ADD `access` text DEFAULT 'one_time' NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX `share_package_redemptions_package_user_uniq` ON `share_package_redemptions` (`package_id`,`user_id`);--> statement-breakpoint
CREATE INDEX `share_package_redemptions_package_id_idx` ON `share_package_redemptions` (`package_id`);