import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

export interface RuntimeModelConfig {
  provider: string;
  modelId: string;
  fallbackProvider: string | null;
  fallbackModelId: string | null;
  maxTokens: number;
  temperature: number;
  source: "pipeline_model_config" | "default";
}

interface ModelConfigDefaults {
  functionName: string;
  modelId: string;
  maxTokens: number;
  temperature: number;
  provider?: string;
  fallbackProvider?: string | null;
  fallbackModelId?: string | null;
  cacheTtlMs?: number;
}

const DEFAULT_CACHE_TTL_MS = 5 * 60 * 1000;
const modelConfigCache = new Map<string, { value: RuntimeModelConfig; expiresAt: number }>();

function toPositiveInt(value: unknown, fallback: number): number {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function toNumeric(value: unknown, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function defaultConfig(defaults: ModelConfigDefaults): RuntimeModelConfig {
  return {
    provider: defaults.provider || "openai",
    modelId: defaults.modelId,
    fallbackProvider: defaults.fallbackProvider ?? null,
    fallbackModelId: defaults.fallbackModelId ?? null,
    maxTokens: defaults.maxTokens,
    temperature: defaults.temperature,
    source: "default",
  };
}

export async function getModelConfigCached(
  db: SupabaseClient,
  defaults: ModelConfigDefaults,
): Promise<RuntimeModelConfig> {
  const now = Date.now();
  const ttlMs = defaults.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS;
  const cacheKey = defaults.functionName;
  const cached = modelConfigCache.get(cacheKey);
  if (cached && cached.expiresAt > now) {
    return cached.value;
  }

  const fallback = defaultConfig(defaults);

  try {
    const { data, error } = await db.rpc("get_model_config", {
      p_function_name: defaults.functionName,
    });

    if (error) {
      console.warn(
        `[model-config] get_model_config(${defaults.functionName}) failed: ${error.message}. Using defaults.`,
      );
      modelConfigCache.set(cacheKey, { value: fallback, expiresAt: now + ttlMs });
      return fallback;
    }

    const row = Array.isArray(data) ? data[0] : data;
    if (!row || !row.model_id) {
      modelConfigCache.set(cacheKey, { value: fallback, expiresAt: now + ttlMs });
      return fallback;
    }

    const resolved: RuntimeModelConfig = {
      provider: String(row.provider || fallback.provider),
      modelId: String(row.model_id || fallback.modelId),
      fallbackProvider: row.fallback_provider ? String(row.fallback_provider) : fallback.fallbackProvider,
      fallbackModelId: row.fallback_model_id ? String(row.fallback_model_id) : fallback.fallbackModelId,
      maxTokens: toPositiveInt(row.max_tokens, fallback.maxTokens),
      temperature: toNumeric(row.temperature, fallback.temperature),
      source: "pipeline_model_config",
    };

    modelConfigCache.set(cacheKey, { value: resolved, expiresAt: now + ttlMs });
    return resolved;
  } catch (error: any) {
    console.warn(
      `[model-config] get_model_config(${defaults.functionName}) exception: ${
        error?.message || "unknown_error"
      }. Using defaults.`,
    );
    modelConfigCache.set(cacheKey, { value: fallback, expiresAt: now + ttlMs });
    return fallback;
  }
}
