/**
 * Consolidated Synthetics Config
 *
 * Reads from pipeline_config table (scope='synthetics', config_key='SYNTHETICS_CONFIG_V1').
 * Falls back to environment variables if DB read fails.
 */

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface SyntheticsConfig {
  enabled: boolean;
  scenario_ids: string[];
  injection_rate: string;
  seed: number;
  namespace: "prod" | "synthetic";
  log_level: "debug" | "info" | "warn";
  artifact_retention_days: number;
  source: "pipeline_config" | "env_fallback";
}

const DEFAULTS: Omit<SyntheticsConfig, "source"> = {
  enabled: false,
  scenario_ids: [],
  injection_rate: "0 */6 * * *",
  seed: 42,
  namespace: "synthetic",
  log_level: "info",
  artifact_retention_days: 30,
};

const CACHE_TTL_MS = 5 * 60 * 1000;
let cached: { value: SyntheticsConfig; expiresAt: number } | null = null;

function envFallback(): SyntheticsConfig {
  const raw_scenarios = Deno.env.get("SYNTHETICS_SCENARIOS");
  let scenario_ids: string[] = DEFAULTS.scenario_ids;
  if (raw_scenarios) {
    try {
      const parsed = JSON.parse(raw_scenarios);
      if (Array.isArray(parsed)) scenario_ids = parsed;
    } catch {
      scenario_ids = raw_scenarios.split(",").map((s: string) => s.trim()).filter(Boolean);
    }
  }

  const raw_seed = Deno.env.get("SYNTHETICS_SEED");
  const seed = raw_seed ? (Number.parseInt(raw_seed, 10) || DEFAULTS.seed) : DEFAULTS.seed;

  const ns = Deno.env.get("SYNTHETICS_NAMESPACE");
  const namespace = (ns === "prod" || ns === "synthetic") ? ns : DEFAULTS.namespace;

  const ll = Deno.env.get("SYNTHETICS_LOG_LEVEL");
  const log_level = (ll === "debug" || ll === "info" || ll === "warn") ? ll : DEFAULTS.log_level;

  const raw_retention = Deno.env.get("SYNTHETICS_ARTIFACT_RETENTION_DAYS");
  const artifact_retention_days = raw_retention
    ? (Number.parseInt(raw_retention, 10) || DEFAULTS.artifact_retention_days)
    : DEFAULTS.artifact_retention_days;

  const raw_enabled = Deno.env.get("SYNTHETICS_ENABLED");
  const enabled = raw_enabled === "true" || raw_enabled === "1";

  const raw_rate = Deno.env.get("SYNTHETICS_INJECTION_RATE");
  const injection_rate = raw_rate || DEFAULTS.injection_rate;

  return {
    enabled,
    scenario_ids,
    injection_rate,
    seed,
    namespace,
    log_level,
    artifact_retention_days,
    source: "env_fallback",
  };
}

function coerce(row: Record<string, unknown>): SyntheticsConfig {
  const e = (k: string) => row[k] ?? (DEFAULTS as Record<string, unknown>)[k];
  const ns = String(e("namespace"));
  const ll = String(e("log_level"));
  const scenarios = e("scenario_ids");
  return {
    enabled: Boolean(e("enabled")),
    scenario_ids: Array.isArray(scenarios) ? scenarios : DEFAULTS.scenario_ids,
    injection_rate: String(e("injection_rate") || DEFAULTS.injection_rate),
    seed: Number(e("seed")) || DEFAULTS.seed,
    namespace: (ns === "prod" || ns === "synthetic") ? ns : DEFAULTS.namespace,
    log_level: (ll === "debug" || ll === "info" || ll === "warn") ? ll : DEFAULTS.log_level,
    artifact_retention_days: Number(e("artifact_retention_days")) || DEFAULTS.artifact_retention_days,
    source: "pipeline_config",
  };
}

export async function getSyntheticsConfig(db: SupabaseClient): Promise<SyntheticsConfig> {
  const now = Date.now();
  if (cached && cached.expiresAt > now) return cached.value;

  try {
    const { data, error } = await db
      .from("pipeline_config")
      .select("config_value")
      .eq("scope", "synthetics")
      .eq("config_key", "SYNTHETICS_CONFIG_V1")
      .maybeSingle();

    if (error) {
      console.warn(`[synthetics-config] DB read failed: ${error.message}. Using env fallback.`);
      const fb = envFallback();
      cached = { value: fb, expiresAt: now + CACHE_TTL_MS };
      return fb;
    }

    if (!data?.config_value) {
      console.warn("[synthetics-config] No config row found. Using env fallback.");
      const fb = envFallback();
      cached = { value: fb, expiresAt: now + CACHE_TTL_MS };
      return fb;
    }

    const config = coerce(data.config_value as Record<string, unknown>);
    cached = { value: config, expiresAt: now + CACHE_TTL_MS };
    return config;
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : "unknown_error";
    console.warn(`[synthetics-config] Exception: ${msg}. Using env fallback.`);
    const fb = envFallback();
    cached = { value: fb, expiresAt: now + CACHE_TTL_MS };
    return fb;
  }
}

/** Clear the in-memory cache (useful for tests). */
export function clearSyntheticsConfigCache(): void {
  cached = null;
}
