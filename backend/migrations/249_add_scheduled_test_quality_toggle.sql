ALTER TABLE scheduled_test_plans
    ADD COLUMN IF NOT EXISTS quality_check_enabled BOOLEAN NOT NULL DEFAULT false;

-- Existing plans using either supported built-in Pelican prompt should keep
-- their quality verdicts after the feature becomes explicitly configurable.
UPDATE scheduled_test_plans
SET quality_check_enabled = TRUE
WHERE md5(prompt_text) IN (
    '15caede62ffea7c47ee2ccf2c8674e87',
    '297caf9418b914f791fe7df9ef44f58e'
);
