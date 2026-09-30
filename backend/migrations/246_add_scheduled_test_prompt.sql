ALTER TABLE scheduled_test_plans
    ADD COLUMN IF NOT EXISTS prompt_text TEXT NOT NULL DEFAULT '';
