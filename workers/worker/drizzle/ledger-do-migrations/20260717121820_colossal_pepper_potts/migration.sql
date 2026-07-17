CREATE TABLE `current_allowance_period` (
	`id` text PRIMARY KEY,
	`period_id` text NOT NULL,
	`plan` text NOT NULL,
	`period_start` integer NOT NULL,
	`period_end` integer NOT NULL,
	`narration_seconds_total` integer NOT NULL,
	`narration_seconds_used` integer DEFAULT 0 NOT NULL,
	`voice_chat_seconds_total` integer NOT NULL,
	`voice_chat_seconds_used` integer DEFAULT 0 NOT NULL,
	`updated_at` integer NOT NULL
);
