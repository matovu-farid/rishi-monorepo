CREATE TABLE `share_link_slots` (
	`id` text PRIMARY KEY,
	`owner_user_id` text NOT NULL,
	`book_id` text NOT NULL,
	`access` text NOT NULL,
	`active_package_id` text,
	`generation` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `fk_share_link_slots_owner_user_id_user_id_fk` FOREIGN KEY (`owner_user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_share_link_slots_book_id_books_id_fk` FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_share_link_slots_active_package_id_share_packages_id_fk` FOREIGN KEY (`active_package_id`) REFERENCES `share_packages`(`id`) ON DELETE SET NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `share_link_slots_owner_book_access_uniq` ON `share_link_slots` (`owner_user_id`,`book_id`,`access`);
--> statement-breakpoint
CREATE INDEX `share_link_slots_owner_book_idx` ON `share_link_slots` (`owner_user_id`,`book_id`);
--> statement-breakpoint
CREATE INDEX `share_link_slots_active_package_idx` ON `share_link_slots` (`active_package_id`);
