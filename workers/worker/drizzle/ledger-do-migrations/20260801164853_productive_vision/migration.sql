ALTER TABLE `current_allowance_period` ADD `reader_period_end` integer;--> statement-breakpoint
ALTER TABLE `current_allowance_period` ADD `reader_seconds_total` integer;--> statement-breakpoint
ALTER TABLE `current_allowance_period` ADD `reader_seconds_used` integer;--> statement-breakpoint
ALTER TABLE `current_allowance_period` ADD `reader_status` text;--> statement-breakpoint
ALTER TABLE `current_allowance_period` ADD `voice_period_end` integer;--> statement-breakpoint
ALTER TABLE `current_allowance_period` ADD `voice_seconds_total` integer;--> statement-breakpoint
ALTER TABLE `current_allowance_period` ADD `voice_seconds_used` integer;--> statement-breakpoint
ALTER TABLE `current_allowance_period` ADD `voice_status` text;