/**
 * sms-thread-assembler v1.0.0
 *
 * Groups sms_messages by contact_phone + 4h time window into threaded
 * transcripts, writes ONE calls_raw + interactions row per thread
 * (channel='sms_thread'), then invokes segment-call to push each
 * thread through the attribution pipeline.
 *
 * Auth: verify_jwt=false, X-Edge-Secret + X-Source allowlist.
 * Scheduled: pg_cron every 4h (or manual invoke).
 *
 * Idempotency: sets sms_messages.thread_assembled_at on processed rows.
 * Reseed guard: segment-call handles 409 if span_attributions already exist.
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { authErrorResponse, requireEdgeSecret } from "../_shared/auth.ts";

const VERSION = "sms-thread-assembler_v1.0.0";
const THREAD_GAP_MS = 4 * 60 * 60 * 1000; // 4 hours
const SEGMENT_CALL_TIMEOUT_MS = 10_000;

const ALLOWED_SOURCES = [
  "sms-thread-assembler",
  "cron",
  "admin-reseed",
  "edge",
  "test",
];

const jsonHeaders = { "Content-Type": "application/json" };

interface SmsMessage {
  id: string;
  message_id: string;
  thread_id: string;
  contact_phone: string | null;
  contact_name: string | null;
  direction: string | null;
  content: string | null;
  sent_at: string;
  sender_user_id: string;
}

interface Thread {
  phone: string;
  contactName: string;
  messages: SmsMessage[];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204 });
  }

  // ── Auth gate ──
  const auth = requireEdgeSecret(req, ALLOWED_SOURCES);
  if (!auth.ok) return authErrorResponse(auth.error_code!);

  // ── Parse body ──
  const body = await req.json().catch(() => ({}));
  const dryRun = body.dry_run ?? false;

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabase = createClient(
    supabaseUrl,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // ── 1. Fetch unassembled SMS messages ──
  const { data: messages, error: fetchError } = await supabase
    .from("sms_messages")
    .select("*")
    .is("thread_assembled_at", null)
    .order("sent_at", { ascending: true });

  if (fetchError) {
    return new Response(
      JSON.stringify({
        ok: false,
        error_code: "fetch_failed",
        detail: fetchError.message,
        version: VERSION,
      }),
      { status: 500, headers: jsonHeaders },
    );
  }

  if (!messages || messages.length === 0) {
    return new Response(
      JSON.stringify({
        ok: true,
        version: VERSION,
        threads_processed: 0,
        message: "no_unassembled_messages",
      }),
      { status: 200, headers: jsonHeaders },
    );
  }

  // ── 2. Group by contact_phone ──
  const byPhone = new Map<string, SmsMessage[]>();
  for (const msg of messages as SmsMessage[]) {
    const phone = msg.contact_phone || "unknown";
    if (!byPhone.has(phone)) byPhone.set(phone, []);
    byPhone.get(phone)!.push(msg);
  }

  // ── 3. Split into threads by 4h gap ──
  const threads: Thread[] = [];
  for (const [phone, phoneMsgs] of byPhone) {
    let currentThread: SmsMessage[] = [phoneMsgs[0]];
    for (let i = 1; i < phoneMsgs.length; i++) {
      const gap = new Date(phoneMsgs[i].sent_at).getTime() -
        new Date(phoneMsgs[i - 1].sent_at).getTime();
      if (gap > THREAD_GAP_MS) {
        threads.push({
          phone,
          contactName: currentThread[0].contact_name || phone,
          messages: currentThread,
        });
        currentThread = [phoneMsgs[i]];
      } else {
        currentThread.push(phoneMsgs[i]);
      }
    }
    threads.push({
      phone,
      contactName: currentThread[0].contact_name || phone,
      messages: currentThread,
    });
  }

  // ── Dry run: return thread summary without writing ──
  if (dryRun) {
    return new Response(
      JSON.stringify({
        ok: true,
        version: VERSION,
        dry_run: true,
        source_messages: messages.length,
        threads: threads.length,
        thread_summary: threads.map((t) => ({
          phone: t.phone,
          contact: t.contactName,
          message_count: t.messages.length,
          first: t.messages[0].sent_at,
          last: t.messages[t.messages.length - 1].sent_at,
        })),
      }),
      { status: 200, headers: jsonHeaders },
    );
  }

  // ── 4. Write all thread data (fast DB operations) ──
  const warnings: string[] = [];
  const written: { interactionId: string; transcript: string; thread: Thread }[] = [];

  for (const thread of threads) {
    const transcript = buildTranscript(thread);
    const interactionId = buildInteractionId(thread);
    const threadKey = `${thread.phone}_${Math.floor(new Date(thread.messages[0].sent_at).getTime() / 1000)}`;
    const hasOutbound = thread.messages.some((m) => m.direction === "outbound");

    // ── Upsert calls_raw (fail closed) ──
    const { error: crError } = await supabase
      .from("calls_raw")
      .upsert({
        interaction_id: interactionId,
        channel: "sms_thread",
        zap_version: VERSION,
        thread_key: threadKey,
        direction: hasOutbound ? "outbound" : "inbound",
        other_party_name: thread.contactName,
        other_party_phone: thread.phone,
        event_at_utc: thread.messages[0].sent_at,
        summary: `SMS thread: ${thread.contactName} (${thread.messages.length} msgs)`,
        transcript,
        ingested_at_utc: new Date().toISOString(),
        capture_source: VERSION,
        is_shadow: false,
        raw_snapshot_json: {
          source: "sms-thread-assembler",
          message_ids: thread.messages.map((m) => m.message_id),
          message_count: thread.messages.length,
          window_start: thread.messages[0].sent_at,
          window_end: thread.messages[thread.messages.length - 1].sent_at,
        },
      }, { onConflict: "interaction_id" });

    if (crError) {
      return new Response(
        JSON.stringify({
          ok: false,
          error_code: "calls_raw_write_failed",
          interaction_id: interactionId,
          detail: crError.message,
          version: VERSION,
        }),
        { status: 500, headers: jsonHeaders },
      );
    }

    // ── Upsert interactions (fail closed) ──
    const { error: intError } = await supabase
      .from("interactions")
      .upsert({
        interaction_id: interactionId,
        channel: "sms_thread",
        source_zap: VERSION,
        contact_name: thread.contactName,
        contact_phone: thread.phone,
        thread_key: threadKey,
        event_at_utc: thread.messages[0].sent_at,
        ingested_at_utc: new Date().toISOString(),
        human_summary: `SMS thread: ${thread.contactName} (${thread.messages.length} msgs)`,
        transcript_chars: transcript.length,
        is_nonsegmentable: transcript.length === 0,
        is_shadow: false,
      }, { onConflict: "interaction_id" });

    if (intError) {
      return new Response(
        JSON.stringify({
          ok: false,
          error_code: "interactions_write_failed",
          interaction_id: interactionId,
          detail: intError.message,
          version: VERSION,
        }),
        { status: 500, headers: jsonHeaders },
      );
    }

    // ── Mark source messages assembled ──
    const messageIds = thread.messages.map((m) => m.id);
    const { error: markError } = await supabase
      .from("sms_messages")
      .update({ thread_assembled_at: new Date().toISOString() })
      .in("id", messageIds);

    if (markError) {
      warnings.push(
        `mark_assembled_failed:${interactionId}:${markError.message}`,
      );
    }

    written.push({ interactionId, transcript, thread });
  }

  // ── 5. Invoke segment-call for all threads in parallel ──
  const PARALLEL_CONCURRENCY = 5;
  const results: Record<string, unknown>[] = [];

  for (let i = 0; i < written.length; i += PARALLEL_CONCURRENCY) {
    const batch = written.slice(i, i + PARALLEL_CONCURRENCY);
    const settled = await Promise.allSettled(
      batch.map((w) =>
        invokeSegmentCall(supabaseUrl, {
          interaction_id: w.interactionId,
          transcript: w.transcript,
          source: "sms-thread-assembler",
        })
      ),
    );

    for (let j = 0; j < batch.length; j++) {
      const w = batch[j];
      const outcome = settled[j];
      const segStatus = outcome.status === "fulfilled" ? outcome.value.status : 0;
      if (
        outcome.status === "fulfilled" && outcome.value.warning
      ) {
        warnings.push(outcome.value.warning);
      }
      if (outcome.status === "rejected") {
        warnings.push(
          `segment_call_rejected:${w.interactionId}:${outcome.reason}`,
        );
      }

      results.push({
        interaction_id: w.interactionId,
        contact: w.thread.contactName,
        phone: w.thread.phone,
        message_count: w.thread.messages.length,
        transcript_chars: w.transcript.length,
        segment_call_status: segStatus,
      });
    }
  }

  return new Response(
    JSON.stringify({
      ok: true,
      version: VERSION,
      source_messages: messages.length,
      threads_processed: results.length,
      results,
      warnings,
    }),
    { status: 200, headers: jsonHeaders },
  );
});

// ── Helpers ──

function buildTranscript(thread: Thread): string {
  return thread.messages.map((m) => {
    const ts = new Date(m.sent_at);
    const hh = String(ts.getUTCHours()).padStart(2, "0");
    const mm = String(ts.getUTCMinutes()).padStart(2, "0");
    const speaker = m.direction === "outbound" ? "HCB" : (m.contact_name || "Contact");
    return `[${hh}:${mm}] ${speaker}: ${m.content || ""}`;
  }).join("\n");
}

function buildInteractionId(thread: Thread): string {
  const firstSentAt = new Date(thread.messages[0].sent_at);
  const epoch = Math.floor(firstSentAt.getTime() / 1000);
  const phoneClean = (thread.phone || "unknown").replace(/\D/g, "").slice(-10);
  return `sms_thread_${phoneClean}_${epoch}`;
}

async function invokeSegmentCall(
  supabaseUrl: string,
  payload: Record<string, unknown>,
): Promise<{ status: number; warning?: string }> {
  const url = `${supabaseUrl}/functions/v1/segment-call`;
  const edgeSecret = Deno.env.get("EDGE_SHARED_SECRET")!;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), SEGMENT_CALL_TIMEOUT_MS);
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Edge-Secret": edgeSecret,
        "X-Source": "sms-thread-assembler",
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    clearTimeout(timer);
    return { status: resp.status };
  } catch (e: unknown) {
    clearTimeout(timer);
    const msg = e instanceof Error ? e.message : String(e);
    return {
      status: 0,
      warning: `segment_call_failed:${payload.interaction_id}:${msg}`,
    };
  }
}
