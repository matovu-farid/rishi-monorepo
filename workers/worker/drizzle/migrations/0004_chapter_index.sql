CREATE TABLE IF NOT EXISTS `chapter_indexes` (
	`id` text NOT NULL,
	`user_id` text NOT NULL,
	`book_id` text NOT NULL,
	`content_version` text NOT NULL,
	`status` text NOT NULL,
	`model_identifier` text NOT NULL,
	`model_version` text NOT NULL,
	`completed_count` integer DEFAULT 0 NOT NULL,
	`total_count` integer DEFAULT 0 NOT NULL,
	`error_message` text,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `chapter_indexes_pk` PRIMARY KEY(`user_id`, `book_id`, `content_version`),
	CONSTRAINT `chapter_indexes_book_fk` FOREIGN KEY (`book_id`) REFERENCES `books`(`id`) ON DELETE cascade,
	CONSTRAINT `chapter_indexes_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `chapter_indexes_user_updated_idx` ON `chapter_indexes` (`user_id`,`updated_at`);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `chapter_indexes_version_key_uniq` ON `chapter_indexes` (`user_id`,`book_id`,`content_version`);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `chapter_index_chapters` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` text NOT NULL,
	`book_id` text NOT NULL,
	`content_version` text NOT NULL,
	`chapter_id` text NOT NULL,
	`source_position` integer NOT NULL,
	`name` text NOT NULL,
	`summary` text NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `chapter_index_chapters_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE cascade,
	CONSTRAINT `chapter_index_chapters_parent_fk` FOREIGN KEY (`user_id`, `book_id`, `content_version`) REFERENCES `chapter_indexes`(`user_id`, `book_id`, `content_version`) ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `chapter_index_chapters_version_chapter_uniq` ON `chapter_index_chapters` (`user_id`,`book_id`,`content_version`,`chapter_id`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `chapter_index_chapters_version_order_idx` ON `chapter_index_chapters` (`user_id`,`book_id`,`content_version`,`source_position`);
