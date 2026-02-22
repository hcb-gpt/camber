/**
 * Shared Supabase client for the labeling pipeline.
 */

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

let _db: SupabaseClient | null = null;

export function getDb(): SupabaseClient {
  if (_db) return _db;

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!url || !key) {
    console.error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
    console.error("Source credentials with: source ~/.camber/credentials.env");
    Deno.exit(1);
  }

  _db = createClient(url, key);
  return _db;
}

/**
 * Generate a batch_run_id for this pipeline run.
 * Format: wm-label-{YYYYMMDD}-{8hex}
 */
export function generateBatchRunId(batchName?: string): string {
  const now = new Date();
  const dateStr = now.toISOString().slice(0, 10).replace(/-/g, "");
  const hex = crypto.randomUUID().slice(0, 8);
  return batchName || `wm-label-${dateStr}-${hex}`;
}
