CREATE TABLE `share_package_items` (
	`id` text PRIMARY KEY,
	`package_id` text NOT NULL,
	`title` text NOT NULL,
	`author` text,
	`format` text NOT NULL,
	`file_r2_key` text NOT NULL,
	`cover_r2_key` text,
	`file_hash` text,
	`file_size` integer NOT NULL,
	`created_at` integer NOT NULL,
	CONSTRAINT `fk_share_package_items_package_id_share_packages_id_fk` FOREIGN KEY (`package_id`) REFERENCES `share_packages`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `share_packages` (
	`id` text PRIMARY KEY,
	`sender_user_id` text NOT NULL,
	`recipient_user_id` text,
	`token_hash` text,
	`kind` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`idempotency_key` text NOT NULL,
	`expires_at` integer NOT NULL,
	`created_at` integer NOT NULL,
	`claimed_at` integer,
	`claimed_by` text,
	CONSTRAINT `fk_share_packages_sender_user_id_user_id_fk` FOREIGN KEY (`sender_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_share_packages_recipient_user_id_user_id_fk` FOREIGN KEY (`recipient_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_share_packages_claimed_by_user_id_fk` FOREIGN KEY (`claimed_by`) REFERENCES `user`(`id`) ON DELETE SET NULL
);
--> statement-breakpoint
CREATE INDEX `share_package_items_package_id_idx` ON `share_package_items` (`package_id`);--> statement-breakpoint
CREATE INDEX `share_packages_recipient_status_idx` ON `share_packages` (`recipient_user_id`,`status`);--> statement-breakpoint
CREATE UNIQUE INDEX `share_packages_sender_idempotency_uniq` ON `share_packages` (`sender_user_id`,`idempotency_key`);--> statement-breakpoint
CREATE UNIQUE INDEX `share_packages_token_hash_uniq` ON `share_packages` (`token_hash`);