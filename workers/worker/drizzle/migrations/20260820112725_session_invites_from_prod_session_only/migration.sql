CREATE TABLE `session_invite_deliveries` (
	`id` text PRIMARY KEY,
	`invite_id` text NOT NULL,
	`recipient_email` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`idempotency_key` text NOT NULL,
	`provider_message_id` text,
	`error_code` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	`sent_at` integer,
	CONSTRAINT `fk_session_invite_deliveries_invite_id_session_invites_id_fk` FOREIGN KEY (`invite_id`) REFERENCES `session_invites`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `session_invite_items` (
	`id` text PRIMARY KEY,
	`invite_id` text NOT NULL,
	`file_r2_key` text NOT NULL,
	`cover_r2_key` text,
	`file_hash` text NOT NULL,
	`file_size` integer NOT NULL,
	`created_at` integer NOT NULL,
	CONSTRAINT `fk_session_invite_items_invite_id_session_invites_id_fk` FOREIGN KEY (`invite_id`) REFERENCES `session_invites`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `session_invite_redemptions` (
	`id` text PRIMARY KEY,
	`invite_id` text NOT NULL,
	`user_id` text NOT NULL,
	`book_status` text DEFAULT 'pending' NOT NULL,
	`membership_status` text DEFAULT 'pending' NOT NULL,
	`last_admission_ticket_id` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `fk_session_invite_redemptions_invite_id_session_invites_id_fk` FOREIGN KEY (`invite_id`) REFERENCES `session_invites`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_session_invite_redemptions_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `session_invites` (
	`id` text PRIMARY KEY,
	`owner_user_id` text NOT NULL,
	`session_id` text NOT NULL,
	`source_book_id` text NOT NULL,
	`content_hash` text NOT NULL,
	`format` text NOT NULL,
	`token_hash` text NOT NULL,
	`status` text DEFAULT 'open' NOT NULL,
	`created_at` integer NOT NULL,
	`ended_at` integer,
	CONSTRAINT `fk_session_invites_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_session_invites_source_book_id_books_id_fk` FOREIGN KEY (`source_book_id`) REFERENCES `books`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX `session_invite_deliveries_invite_status_idx` ON `session_invite_deliveries` (`invite_id`,`status`);--> statement-breakpoint
CREATE UNIQUE INDEX `session_invite_deliveries_idempotency_key_uniq` ON `session_invite_deliveries` (`idempotency_key`);--> statement-breakpoint
CREATE UNIQUE INDEX `session_invite_deliveries_invite_email_uniq` ON `session_invite_deliveries` (`invite_id`,`recipient_email`);--> statement-breakpoint
CREATE UNIQUE INDEX `session_invite_items_invite_id_uniq` ON `session_invite_items` (`invite_id`);--> statement-breakpoint
CREATE INDEX `session_invite_redemptions_invite_status_idx` ON `session_invite_redemptions` (`invite_id`,`membership_status`);--> statement-breakpoint
CREATE INDEX `session_invite_redemptions_user_status_idx` ON `session_invite_redemptions` (`user_id`,`membership_status`);--> statement-breakpoint
CREATE UNIQUE INDEX `session_invite_redemptions_invite_user_uniq` ON `session_invite_redemptions` (`invite_id`,`user_id`);--> statement-breakpoint
CREATE INDEX `session_invites_owner_status_idx` ON `session_invites` (`owner_user_id`,`status`);--> statement-breakpoint
CREATE INDEX `session_invites_source_book_id_idx` ON `session_invites` (`source_book_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `session_invites_session_id_uniq` ON `session_invites` (`session_id`);--> statement-breakpoint
CREATE UNIQUE INDEX `session_invites_token_hash_uniq` ON `session_invites` (`token_hash`);