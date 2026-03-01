-- Seed consolidated synthetics configuration into pipeline_config.
-- Uses the scope-based schema from 20251227020641.
-- All settings live in one JSONB blob for atomic reads.

INSERT INTO pipeline_config (scope, config_key, config_value, description, updated_by)
VALUES (
    'synthetics',
    'SYNTHETICS_CONFIG_V1',
    '{
      "enabled": false,
      "scenario_ids": [],
      "injection_rate": "0 */6 * * *",
      "seed": 42,
      "namespace": "synthetic",
      "log_level": "info",
      "artifact_retention_days": 30
    }'::jsonb,
    'Consolidated synthetics test-pack configuration. enabled=master switch, scenario_ids=which scenarios to run, injection_rate=cron expression, seed=deterministic seed, namespace=write target (prod|synthetic), log_level=(debug|info|warn), artifact_retention_days=retention period.',
    'DEV-5 migration'
)
ON CONFLICT (scope, config_key) DO NOTHING;
