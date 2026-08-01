-- Generated from workers/worker/src/db/schema.ts for entitlement retention.
CREATE TABLE `deletion_state` (
  `user_id` text PRIMARY KEY NOT NULL,
  `deletion_id` text NOT NULL,
  `ledger_name` text NOT NULL,
  `status` text NOT NULL,
  `retry_at` integer NOT NULL,
  `created_at` integer NOT NULL,
  `updated_at` integer NOT NULL,
  CONSTRAINT `fk_deletion_state_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `retained_apple_entitlement` (
  `identity_hash_version` integer NOT NULL,
  `identity_hash` text NOT NULL,
  `trial_state` text NOT NULL,
  `trial_initial_credits` integer NOT NULL,
  `trial_used_credits` integer NOT NULL,
  `reader_active_until` integer,
  `voice_active_until` integer,
  `reader_credits_total` integer NOT NULL,
  `reader_credits_used` integer NOT NULL,
  `voice_credits_total` integer NOT NULL,
  `voice_credits_used` integer NOT NULL,
  `reader_status` text,
  `voice_status` text,
  `deleted_at` integer NOT NULL,
  `retention_expires_at` integer NOT NULL,
  `updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `retained_apple_entitlement_identity_uniq` ON `retained_apple_entitlement` (`identity_hash_version`, `identity_hash`);
--> statement-breakpoint
CREATE TABLE `retained_apple_transaction` (
  `identity_hash_version` integer NOT NULL,
  `identity_hash` text NOT NULL,
  `transaction_hash_version` integer NOT NULL,
  `original_transaction_hash` text NOT NULL,
  `feature` text NOT NULL,
  `environment` text NOT NULL,
  `last_event_at` integer NOT NULL,
  `status` text NOT NULL,
  `period_end` integer,
  `retention_expires_at` integer NOT NULL,
  `updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `retained_apple_transaction_key_uniq` ON `retained_apple_transaction` (`transaction_hash_version`, `environment`, `original_transaction_hash`);
--> statement-breakpoint
CREATE TABLE `restored_apple_entitlement` (
  `user_id` text NOT NULL,
  `identity_hash_version` integer NOT NULL,
  `identity_hash` text NOT NULL,
  `transaction_hash_version` integer NOT NULL,
  `environment` text NOT NULL,
  `original_transaction_hash` text NOT NULL,
  `feature` text NOT NULL,
  `status` text NOT NULL,
  `period_end` integer,
  `updated_at` integer NOT NULL,
  CONSTRAINT `fk_restored_apple_entitlement_user_id_user_id_fk` FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE UNIQUE INDEX `restored_apple_entitlement_key_uniq` ON `restored_apple_entitlement` (`user_id`, `transaction_hash_version`, `environment`, `original_transaction_hash`);
