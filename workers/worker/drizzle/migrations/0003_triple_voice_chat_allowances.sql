-- Triple Voice Chat monthly caps and trial credit pool (gpt-realtime-mini cost headroom).
-- Active paid periods and legacy trial rows are bumped in place; usage counters are preserved.

UPDATE `allowance_period`
SET `voice_chat_seconds_total` = 16200
WHERE `plan` = 'reader'
  AND `voice_chat_seconds_total` = 5400
  AND `period_end` > (cast(strftime('%s', 'now') as integer) * 1000);

UPDATE `allowance_period`
SET `voice_chat_seconds_total` = 32400
WHERE `plan` = 'voice'
  AND `voice_chat_seconds_total` = 10800
  AND `period_end` > (cast(strftime('%s', 'now') as integer) * 1000);

UPDATE `trial_grant`
SET `initial_credits` = 300
WHERE `initial_credits` = 100;
