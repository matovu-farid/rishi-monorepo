CREATE TABLE `sync_events` (
	`sequence` integer PRIMARY KEY AUTOINCREMENT,
	`user_id` text NOT NULL,
	`operation_id` text NOT NULL,
	`status` text DEFAULT 'pending' NOT NULL,
	`kind` text NOT NULL,
	`entity_id` text NOT NULL,
	`payload` text NOT NULL,
	`updated_at` integer NOT NULL,
	`deleted` integer NOT NULL,
	`recorded_at` integer NOT NULL,
	CONSTRAINT `fk_sync_events_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX `sync_events_user_sequence_idx` ON `sync_events` (`user_id`,`sequence`);--> statement-breakpoint
CREATE UNIQUE INDEX `sync_events_user_operation_idx` ON `sync_events` (`user_id`,`operation_id`);
