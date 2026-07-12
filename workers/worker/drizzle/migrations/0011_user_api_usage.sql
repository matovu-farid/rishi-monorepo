CREATE TABLE `user_api_usage` (
	`user_id` text PRIMARY KEY NOT NULL,
	`voice_chat_requests` integer DEFAULT 0 NOT NULL,
	`tts_requests` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON UPDATE no action ON DELETE cascade
);
