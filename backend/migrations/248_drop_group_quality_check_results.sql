-- 248: Drop the standalone group quality check probe table.
--
-- Group degradation status is derived from existing scheduled test results;
-- a second probe loop would duplicate the same work. Keep group settings.
DROP TABLE IF EXISTS group_quality_check_results;
