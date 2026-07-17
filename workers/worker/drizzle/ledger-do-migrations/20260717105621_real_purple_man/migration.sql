CREATE TABLE `reservations` (
	`id` text PRIMARY KEY,
	`user_id` text NOT NULL,
	`kind` text NOT NULL,
	`amount` integer NOT NULL,
	`status` text NOT NULL,
	`created_at` integer NOT NULL,
	`settled_at` integer
);
--> statement-breakpoint
CREATE TABLE `trial_ledger` (
	`id` text PRIMARY KEY,
	`user_id` text NOT NULL,
	`initial_credits` integer NOT NULL,
	`used_credits` integer NOT NULL,
	`granted_at` integer NOT NULL
);
