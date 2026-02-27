import { assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import { checkReseedGuard } from "../supabase/functions/segment-call/reseed_guard.ts";

type SpanRow = {
  id: string;
  interaction_id: string;
  is_superseded: boolean;
};

type AttributionRow = {
  id: string;
  span_id: string;
};

type Fixtures = {
  conversation_spans: SpanRow[];
  span_attributions: AttributionRow[];
};

type QueryState = {
  table: string;
  eqs: Map<string, unknown>;
  inFilter: { column: string; values: unknown[] } | null;
  limitValue: number | null;
};

function makeMockDb(fixtures: Fixtures) {
  const eqTrace: Record<string, string[]> = {};

  function runQuery(state: QueryState) {
    if (state.table === "conversation_spans") {
      let rows = fixtures.conversation_spans.slice();
      for (const [column, value] of state.eqs.entries()) {
        rows = rows.filter((row) => (row as Record<string, unknown>)[column] === value);
      }
      return { data: rows.map((row) => ({ id: row.id })), error: null };
    }

    if (state.table === "span_attributions") {
      let rows = fixtures.span_attributions.slice();
      if (state.inFilter?.column === "span_id") {
        rows = rows.filter((row) => state.inFilter!.values.includes(row.span_id));
      }
      if (typeof state.limitValue === "number") {
        rows = rows.slice(0, state.limitValue);
      }
      return { data: rows.map((row) => ({ id: row.id })), error: null };
    }

    return { data: [], error: null };
  }

  const db = {
    from(table: string) {
      eqTrace[table] ||= [];
      const state: QueryState = {
        table,
        eqs: new Map<string, unknown>(),
        inFilter: null,
        limitValue: null,
      };

      const query = {
        select(_columns: string) {
          return query;
        },
        eq(column: string, value: unknown) {
          eqTrace[table].push(column);
          state.eqs.set(column, value);
          return query;
        },
        in(column: string, values: unknown[]) {
          state.inFilter = { column, values };
          return query;
        },
        limit(value: number) {
          state.limitValue = value;
          return query;
        },
        then(resolve: (value: unknown) => void, reject?: (reason: unknown) => void) {
          try {
            resolve(runQuery(state));
          } catch (error) {
            if (reject) reject(error);
          }
        },
      };

      return query;
    },
  };

  return { db, eqTrace };
}

Deno.test("reseed guard blocks when attribution exists only on superseded span", async () => {
  const { db, eqTrace } = makeMockDb({
    conversation_spans: [
      { id: "span_active", interaction_id: "int_1", is_superseded: false },
      { id: "span_old", interaction_id: "int_1", is_superseded: true },
    ],
    span_attributions: [
      { id: "attr_1", span_id: "span_old" },
    ],
  });

  const result = await checkReseedGuard(db, "int_1");
  assertEquals(result, { blocked: true, error: null });
  assertEquals(eqTrace.conversation_spans.includes("is_superseded"), false);
});

Deno.test("reseed guard allows run when interaction has no attributions", async () => {
  const { db } = makeMockDb({
    conversation_spans: [
      { id: "span_active", interaction_id: "int_2", is_superseded: false },
      { id: "span_old", interaction_id: "int_2", is_superseded: true },
    ],
    span_attributions: [],
  });

  const result = await checkReseedGuard(db, "int_2");
  assertEquals(result, { blocked: false, error: null });
});
