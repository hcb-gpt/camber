/**
 * Labeling Pipeline Orchestrator
 *
 * Runs the complete labeling pipeline (Pass 0 → Pass 1 → Pass 2 → Pass 3 → Pass 4)
 * sequentially as separate Deno subprocesses.
 *
 * Each pass is invoked with the same batch_run_id and --unlabeled-only flag.
 * The orchestrator captures stdout/stderr from each pass and prints a summary at the end.
 *
 * CLI args:
 *   --batch-name <name>       Custom batch name (default: auto-generated)
 *   --target <all|file:path>  Target spans (all or interaction_ids from file)
 *   --dry-run                 Dry-run mode (passed to all passes)
 *   --passes <comma-sep>      Run only specified passes (e.g., "0,1,2")
 *   --max-spans <n>           Max spans to process in Pass 2/3 (passed through)
 *
 * Usage:
 *   source ~/.camber/credentials.env
 *   deno run --allow-all labeling_pipeline.ts --batch-name "wm-prep-v1" --target all
 */

import { generateBatchRunId } from "./shared/db.ts";

// ============================================================
// CONFIG
// ============================================================

const args = Deno.args;

function getArg(name: string): string | null {
  const arg = args.find((a) => a.startsWith(`--${name}=`));
  return arg?.split("=", 2)[1] || null;
}

function hasFlag(name: string): boolean {
  return args.includes(`--${name}`);
}

const BATCH_NAME = getArg("batch-name");
const TARGET = getArg("target") || "all";
const DRY_RUN = hasFlag("dry-run");
const PASSES_ARG = getArg("passes");
const MAX_SPANS = getArg("max-spans");

// Generate batch_run_id
const BATCH_RUN_ID = generateBatchRunId(BATCH_NAME);

// Parse which passes to run (default: all)
const ALL_PASSES = ["0", "1", "2", "3", "4"];
const PASSES_TO_RUN = PASSES_ARG
  ? PASSES_ARG.split(",").map((p) => p.trim())
  : ALL_PASSES;

// Pass script paths
const SCRIPT_DIR = new URL(".", import.meta.url).pathname;
const PASS_SCRIPTS: Record<string, string> = {
  "0": `${SCRIPT_DIR}pass0_deterministic.ts`,
  "1": `${SCRIPT_DIR}pass1_graph_propagation.ts`,
  "2": `${SCRIPT_DIR}pass2_haiku_triage.ts`,
  "3": `${SCRIPT_DIR}pass3_opus_deep_label.ts`,
  "4": `${SCRIPT_DIR}pass4_review_queue.ts`,
};

// ============================================================
// SUBPROCESS RUNNER
// ============================================================

interface PassResult {
  pass_number: string;
  pass_name: string;
  success: boolean;
  stdout: string;
  stderr: string;
  duration_ms: number;
}

async function runPass(
  passNumber: string,
  extraArgs: string[] = [],
): Promise<PassResult> {
  const scriptPath = PASS_SCRIPTS[passNumber];
  if (!scriptPath) {
    throw new Error(`Unknown pass number: ${passNumber}`);
  }

  const passArgs = [
    "run",
    "--allow-all",
    scriptPath,
    `--batch-run-id=${BATCH_RUN_ID}`,
    "--unlabeled-only",
  ];

  if (DRY_RUN) {
    passArgs.push("--dry-run");
  }

  passArgs.push(...extraArgs);

  console.log(`\n${"=".repeat(60)}`);
  console.log(`Running Pass ${passNumber}: ${scriptPath}`);
  console.log(`${"=".repeat(60)}\n`);

  const startTime = Date.now();
  const command = new Deno.Command("deno", { args: passArgs });
  const { code, stdout, stderr } = await command.output();
  const duration = Date.now() - startTime;

  const stdoutText = new TextDecoder().decode(stdout);
  const stderrText = new TextDecoder().decode(stderr);

  console.log(stdoutText);
  if (stderrText) {
    console.error(stderrText);
  }

  return {
    pass_number: passNumber,
    pass_name: `Pass ${passNumber}`,
    success: code === 0,
    stdout: stdoutText,
    stderr: stderrText,
    duration_ms: duration,
  };
}

// ============================================================
// SUMMARY EXTRACTION
// ============================================================

interface PassSummary {
  pass_number: string;
  pass_name: string;
  total_input: number;
  labeled: number;
  deferred: number;
  errors: number;
  duration_ms: number;
  cost?: number;
  tokens?: number;
  facts_extracted?: number;
}

function extractSummary(result: PassResult): PassSummary {
  const summary: PassSummary = {
    pass_number: result.pass_number,
    pass_name: result.pass_name,
    total_input: 0,
    labeled: 0,
    deferred: 0,
    errors: 0,
    duration_ms: result.duration_ms,
  };

  // Parse stdout for stats
  const lines = result.stdout.split("\n");
  for (const line of lines) {
    const totalMatch = line.match(/Total input:\s+(\d+)/);
    if (totalMatch) summary.total_input = parseInt(totalMatch[1], 10);

    const labeledMatch = line.match(/Total labeled:\s+(\d+)/);
    if (labeledMatch) summary.labeled = parseInt(labeledMatch[1], 10);

    const deferredMatch = line.match(/Deferred to Pass \d+:\s+(\d+)/);
    if (deferredMatch) summary.deferred = parseInt(deferredMatch[1], 10);

    const errorsMatch = line.match(/Errors:\s+(\d+)/);
    if (errorsMatch) summary.errors = parseInt(errorsMatch[1], 10);

    // For Pass 2/3: cost + tokens
    const costMatch = line.match(/Total cost:\s+\$([0-9.]+)/);
    if (costMatch) summary.cost = parseFloat(costMatch[1]);

    const tokensMatch = line.match(/Total tokens:\s+([0-9,]+)/);
    if (tokensMatch) summary.tokens = parseInt(tokensMatch[1].replace(/,/g, ""), 10);

    // For Pass 3: facts extracted
    const factsMatch = line.match(/Facts extracted:\s+(\d+)/);
    if (factsMatch) summary.facts_extracted = parseInt(factsMatch[1], 10);

    // Alternate patterns (enqueued for Pass 4)
    const enqueuedMatch = line.match(/Total enqueued:\s+(\d+)/);
    if (enqueuedMatch) summary.labeled = parseInt(enqueuedMatch[1], 10);
  }

  return summary;
}

// ============================================================
// MAIN
// ============================================================

async function main() {
  console.log("=== Labeling Pipeline Orchestrator ===");
  console.log(`Batch run ID: ${BATCH_RUN_ID}`);
  console.log(`Target: ${TARGET}`);
  console.log(`Mode: ${DRY_RUN ? "DRY RUN" : "LIVE"}`);
  console.log(`Passes to run: ${PASSES_TO_RUN.join(", ")}`);
  if (MAX_SPANS) {
    console.log(`Max spans (Pass 2/3): ${MAX_SPANS}`);
  }
  console.log("");

  const results: PassResult[] = [];
  const summaries: PassSummary[] = [];

  // Run passes sequentially
  for (const passNum of PASSES_TO_RUN) {
    const extraArgs: string[] = [];

    // Pass max-spans to Pass 2/3
    if ((passNum === "2" || passNum === "3") && MAX_SPANS) {
      extraArgs.push(`--max-spans=${MAX_SPANS}`);
    }

    // TODO: if TARGET is file:path, parse interaction_ids and pass --interaction-ids to each pass
    // For now, only "all" is supported

    const result = await runPass(passNum, extraArgs);
    results.push(result);

    if (!result.success) {
      console.error(`\n❌ Pass ${passNum} FAILED (exit code non-zero)`);
      console.error("Stopping pipeline.");
      break;
    }

    summaries.push(extractSummary(result));
  }

  // Print final summary
  console.log("\n" + "=".repeat(80));
  console.log("=== Pipeline Summary ===");
  console.log("=".repeat(80));
  console.log(`Batch run ID: ${BATCH_RUN_ID}`);
  console.log("");

  let totalLabeled = 0;
  let totalCost = 0;
  let totalTokens = 0;
  let totalFacts = 0;

  for (const s of summaries) {
    const yieldPct = s.total_input > 0
      ? ((s.labeled / s.total_input) * 100).toFixed(1)
      : "0.0";

    console.log(
      `Pass ${s.pass_number}: ${s.labeled}/${s.total_input} spans labeled (${yieldPct}%) | ` +
        `deferred=${s.deferred} errors=${s.errors} | ` +
        `duration=${(s.duration_ms / 1000).toFixed(1)}s`,
    );

    if (s.cost) {
      console.log(`  └─ cost=$${s.cost.toFixed(2)}`);
      totalCost += s.cost;
    }
    if (s.tokens) {
      console.log(`  └─ tokens=${s.tokens.toLocaleString()}`);
      totalTokens += s.tokens;
    }
    if (s.facts_extracted) {
      console.log(`  └─ facts_extracted=${s.facts_extracted}`);
      totalFacts += s.facts_extracted;
    }

    totalLabeled += s.labeled;
  }

  console.log("");
  console.log("=".repeat(80));
  console.log(`Total labeled: ${totalLabeled}`);
  if (totalCost > 0) {
    console.log(`Total cost: $${totalCost.toFixed(2)}`);
  }
  if (totalTokens > 0) {
    console.log(`Total tokens: ${totalTokens.toLocaleString()}`);
  }
  if (totalFacts > 0) {
    console.log(`Total facts extracted: ${totalFacts}`);
  }

  const allSuccess = results.every((r) => r.success);
  if (allSuccess) {
    console.log("\n✅ Pipeline completed successfully.");
  } else {
    console.log("\n❌ Pipeline failed (see errors above).");
    Deno.exit(1);
  }

  if (DRY_RUN) {
    console.log("\n[DRY-RUN] No writes were made.");
  }
}

main().catch((err) => {
  console.error("Pipeline orchestrator failed:", err);
  Deno.exit(1);
});
