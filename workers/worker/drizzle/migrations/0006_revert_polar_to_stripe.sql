-- Reverts an out-of-band `0005_polar_billing.sql` migration that was applied
-- to remote D1 but never committed to this repo. Production has zero users
-- and zero subscriptions, so this is non-destructive.
--
-- IMPORTANT: this migration is intended for REMOTE D1 only. Local D1 was
-- never on Polar (its schema already matches 0004_stripe_billing). Seed the
-- local d1_migrations table with this filename manually if you want
-- `wrangler d1 migrations apply --local` to stay idempotent.

DROP TABLE IF EXISTS `subscription`;
--> statement-breakpoint
CREATE TABLE `subscription` (
	`id` text PRIMARY KEY NOT NULL,
	`plan` text NOT NULL,
	`reference_id` text NOT NULL,
	`stripe_customer_id` text,
	`stripe_subscription_id` text,
	`status` text DEFAULT 'incomplete',
	`period_start` integer,
	`period_end` integer,
	`trial_start` integer,
	`trial_end` integer,
	`cancel_at_period_end` integer DEFAULT false,
	`cancel_at` integer,
	`canceled_at` integer,
	`ended_at` integer,
	`seats` integer,
	`billing_interval` text,
	`stripe_schedule_id` text
);
--> statement-breakpoint
ALTER TABLE `user` DROP COLUMN `polar_customer_id`;
--> statement-breakpoint
ALTER TABLE `user` ADD `stripe_customer_id` text;
