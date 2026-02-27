type ReseedGuardResult = {
  blocked: boolean;
  error: string | null;
};

export async function checkReseedGuard(
  db: any,
  interactionId: string,
): Promise<ReseedGuardResult> {
  const { data: spans, error: spansErr } = await db
    .from("conversation_spans")
    .select("id")
    .eq("interaction_id", interactionId);

  if (spansErr) {
    return { blocked: false, error: `conversation_spans_query_failed:${spansErr.message}` };
  }

  if (!Array.isArray(spans) || spans.length === 0) {
    return { blocked: false, error: null };
  }

  const spanIds = spans.map((s: any) => s?.id).filter(Boolean);
  if (spanIds.length === 0) {
    return { blocked: false, error: null };
  }

  const { data: attributions, error: attrErr } = await db
    .from("span_attributions")
    .select("id")
    .in("span_id", spanIds)
    .limit(1);

  if (attrErr) {
    return { blocked: false, error: `span_attributions_query_failed:${attrErr.message}` };
  }

  return { blocked: Array.isArray(attributions) && attributions.length > 0, error: null };
}
