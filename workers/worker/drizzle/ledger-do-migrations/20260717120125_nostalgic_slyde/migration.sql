CREATE TABLE `voice_session` (
	`rishi_session_id` text PRIMARY KEY,
	`plan_kind` text DEFAULT 'trial' NOT NULL,
	`status` text NOT NULL,
	`cap_intervals` integer NOT NULL,
	`consumed_intervals` integer DEFAULT 0 NOT NULL,
	`credits_per_interval` integer NOT NULL,
	`nonce_issued_at` integer NOT NULL,
	`nonce_signature` text NOT NULL,
	`nonce_used` integer DEFAULT false NOT NULL,
	`call_id` text,
	`call_registered_at` integer,
	`terminal_reason` text,
	`terminal_at` integer,
	`hangup_status` text DEFAULT 'not_started' NOT NULL,
	`hangup_attempts` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL
);
