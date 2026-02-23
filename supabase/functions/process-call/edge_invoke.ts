/**
 * Bounded retry helper for fire-and-forget edge function invocations.
 * Used by process-call to invoke segment-call and chain-detect with
 * configurable timeout and retry on transient failures.
 */

interface InvokeOptions {
  label: string;
  timeoutMs: number;
  maxAttempts: number;
  payload: Record<string, unknown>;
}

interface InvokeResult {
  status: number;
  attempts: number;
  warnings: string[];
}

export async function invokeEdgeWithRetry(
  url: string,
  edgeSecret: string,
  opts: InvokeOptions,
): Promise<InvokeResult> {
  const { label, timeoutMs, maxAttempts, payload } = opts;
  const warnings: string[] = [];
  let lastStatus = 0;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const resp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Edge-Secret": edgeSecret,
          "X-Source": "process-call",
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      clearTimeout(timer);
      lastStatus = resp.status;
      if (resp.ok || resp.status < 500) {
        return { status: resp.status, attempts: attempt, warnings };
      }
      warnings.push(
        `${label}_retry: attempt ${attempt}/${maxAttempts} got ${resp.status}`,
      );
    } catch (e: unknown) {
      clearTimeout(timer);
      const msg = e instanceof Error ? e.message : String(e);
      if (msg.includes("abort")) {
        warnings.push(
          `${label}_timeout: attempt ${attempt}/${maxAttempts} exceeded ${timeoutMs}ms`,
        );
      } else {
        warnings.push(
          `${label}_error: attempt ${attempt}/${maxAttempts} ${msg}`,
        );
      }
    }
  }
  return { status: lastStatus, attempts: maxAttempts, warnings };
}
