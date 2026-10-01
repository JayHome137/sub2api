-- Keep the existing Pelican quality evaluator as the default and add a
-- deterministic answer-based mode for low-token scheduled checks.
ALTER TABLE scheduled_test_plans
    ADD COLUMN IF NOT EXISTS quality_mode VARCHAR(20) NOT NULL DEFAULT 'pelican';
ALTER TABLE scheduled_test_plans
    ADD COLUMN IF NOT EXISTS quality_expected_answer TEXT NOT NULL DEFAULT '';

ALTER TABLE scheduled_test_results
    ADD COLUMN IF NOT EXISTS quality_mode VARCHAR(20) NOT NULL DEFAULT 'pelican';

UPDATE scheduled_test_plans
SET quality_mode = 'pelican'
WHERE quality_mode IS NULL OR quality_mode = '';

UPDATE scheduled_test_results
SET quality_mode = 'pelican'
WHERE quality_mode IS NULL OR quality_mode = '';
