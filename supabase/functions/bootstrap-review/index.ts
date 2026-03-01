import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FUNCTION_VERSION = "bootstrap-review_v1.3.0";
type ReviewQueueSource = "pipeline" | "redline";

// ─── Helpers ─────────────────────────────────────────────────────────

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-edge-secret, x-source, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  };
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders() },
  });
}

function _escapeHtml(text: string): string {
  if (!text) return "";
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    .test(str);
}

function normalizeReviewQueueSource(
  raw: unknown,
  fallback: ReviewQueueSource = "pipeline",
): ReviewQueueSource {
  const normalized = String(raw || "").trim().toLowerCase();
  if (normalized === "redline") return "redline";
  if (normalized === "pipeline") return "pipeline";
  return fallback;
}

function isMissingReviewQueueSourceColumnError(message: string): boolean {
  return /column .*source.* does not exist/i.test(message);
}

function isMissingColumnError(message: string, column: string): boolean {
  const escapedColumn = column.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`column .*${escapedColumn}.* does not exist`, "i").test(
    message,
  );
}

function isAllowedQueueModule(raw: unknown): boolean {
  const module = String(raw || "").trim().toLowerCase();
  return module === "" || module === "attribution";
}

function normalizeQueueItemForIOS(item: any): any | null {
  const spanId = String(item?.span_id || "").trim();
  if (!isValidUUID(spanId)) return null;

  // Filter by module
  if (!isAllowedQueueModule(item?.module)) return null;

  // Filter out superseded spans (Phase A correction)
  if (item?.is_superseded === true) return null;

  const transcriptSegment = typeof item?.evidence_excerpt === "string" && item.evidence_excerpt
    ? item.evidence_excerpt
    : typeof item?.transcript_segment === "string"
    ? item.transcript_segment
    : typeof item?.context_payload?.transcript_snippet === "string"
    ? item.context_payload.transcript_snippet
    : "";

  return {
    ...item,
    span_id: spanId,
    transcript_segment: transcriptSegment,
    // Precise span pointers for UI highlighting (Phase A)
    char_start: item?.char_start,
    char_end: item?.char_end,
    span_index: item?.span_index,
    total_spans_for_interaction: item?.total_spans_for_interaction,
  };
}

async function countPendingQueueItemsForIOS(db: any, maxAgeDays = 21): Promise<number> {
  const { data, error } = await db.rpc("fresh_review_queue_count", {
    p_max_age_days: maxAgeDays,
  });

  if (!error) return Number(data || 0);

  console.warn(`[bootstrap-review:queue] fresh count RPC failed, falling back: ${error.message}`);
  const base = db
    .from("review_queue")
    .select("id", { count: "exact", head: true })
    .eq("status", "pending")
    .not("span_id", "is", null);

  const { count } = await base.or("module.eq.attribution,module.is.null");
  return count || 0;
}

async function tagReviewQueueSource(
  db: any,
  reviewQueueId: string,
  source: ReviewQueueSource,
  ctx: string,
): Promise<void> {
  const { error } = await db
    .from("review_queue")
    .update({ source })
    .eq("id", reviewQueueId);
  if (!error) return;
  if (isMissingReviewQueueSourceColumnError(error.message)) {
    console.warn(`[${ctx}] review_queue.source column missing; skipped source tag (${source})`);
    return;
  }
  console.warn(`[${ctx}] review_queue source tag warning: ${error.message}`);
}

async function fetchReviewProjects(db: any): Promise<any[]> {
  const inactiveStatuses = new Set([
    "archived",
    "closed",
    "completed",
    "done",
    "inactive",
    "on_hold",
    "on hold",
    "paused",
    "prospect",
    "pipeline",
    "cancelled",
    "canceled",
  ]);

  const excludedProjectNames = new Set([
    "Business Development & Networking",
    "Overhead / Internal Operations",
  ]);

  const pickerLabelBySourceName = new Map<string, string>([
    ["Hurley Residence", "Hurley Residence"],
    ["Moss Residence", "Moss Residence"],
    ["Permar Residence", "Permar Home"],
    ["King Residence", "King Residence"],
    ["Winship Residence", "Winship"],
    ["Winslow Residence", "Winslow"],
    ["Waverly Residence", "Waverly"],
    ["Westminster Residence", "Westminster"],
    ["Wakefield Residence", "Wakefield"],
    ["Woodfield Residence", "Woodfield"],
    ["Wake Residence", "Wake Residence"],
    ["Wren Residence", "Wren Residence"],
    ["Weldon Residence", "Wren Residence"],
    ["West Residence", "West Residence"],
    ["Worth Residence", "Worth Residence"],
    ["Wellington Residence", "Wellington Residence"],
    ["Wimbledon Residence", "Wellington Residence"],
    ["Whitley Residence", "Whitley Residence"],
    ["Wheeler Residence", "Whitley Residence"],
    ["Windsor Residence", "Windsor Residence"],
    ["Walsh Residence", "Windsor Residence"],
    ["Waltham Residence", "Windsor Residence"],
    ["Walton Residence", "Windsor Residence"],
    ["Warren Residence", "Windsor Residence"],
    ["Warwick Residence", "Windsor Residence"],
    ["Washburne Residence", "Windsor Residence"],
    ["Washington Residence", "Windsor Residence"],
    ["Waterford Residence", "Windsor Residence"],
    ["Waters Residence", "Windsor Residence"],
    ["Watkins Residence", "Windsor Residence"],
    ["Watson Residence", "Windsor Residence"],
    ["Watt Residence", "Windsor Residence"],
    ["Watts Residence", "Windsor Residence"],
    ["Waverly Residence", "Windsor Residence"],
    ["Way Residence", "Windsor Residence"],
    ["Wayne Residence", "Windsor Residence"],
    ["Weakley Residence", "Windsor Residence"],
    ["Weatherly Residence", "Windsor Residence"],
    ["Weathers Residence", "Windsor Residence"],
    ["Weaver Residence", "Windsor Residence"],
    ["Webb Residence", "Windsor Residence"],
    ["Webber Residence", "Windsor Residence"],
    ["Weber Residence", "Windsor Residence"],
    ["Webster Residence", "Windsor Residence"],
    ["Wedgewood Residence", "Windsor Residence"],
    ["Weekley Residence", "Windsor Residence"],
    ["Weeks Residence", "Windsor Residence"],
    ["Weems Residence", "Windsor Residence"],
    ["Weidman Residence", "Windsor Residence"],
    ["Weil Residence", "Windsor Residence"],
    ["Weimer Residence", "Windsor Residence"],
    ["Weinberg Residence", "Windsor Residence"],
    ["Weiner Residence", "Windsor Residence"],
    ["Weinstein Residence", "Windsor Residence"],
    ["Weintraub Residence", "Windsor Residence"],
    ["Weir Residence", "Windsor Residence"],
    ["Weis Residence", "Windsor Residence"],
    ["Weisberg Residence", "Windsor Residence"],
    ["Weiss Residence", "Windsor Residence"],
    ["Weissman Residence", "Windsor Residence"],
    ["Welch Residence", "Windsor Residence"],
    ["Welcome Residence", "Windsor Residence"],
    ["Weld Residence", "Windsor Residence"],
    ["Weldon Residence", "Windsor Residence"],
    ["Welford Residence", "Windsor Residence"],
    ["Wellman Residence", "Windsor Residence"],
    ["Wells Residence", "Windsor Residence"],
    ["Welsh Residence", "Windsor Residence"],
    ["Welton Residence", "Windsor Residence"],
    ["Wendell Residence", "Windsor Residence"],
    ["Wendt Residence", "Windsor Residence"],
    ["Wentworth Residence", "Windsor Residence"],
    ["Wentz Residence", "Windsor Residence"],
    ["Werner Residence", "Windsor Residence"],
    ["Wernick Residence", "Windsor Residence"],
    ["Wertz Residence", "Windsor Residence"],
    ["Wesley Residence", "Windsor Residence"],
    ["Wessel Residence", "Windsor Residence"],
    ["West Residence", "Windsor Residence"],
    ["Westbrook Residence", "Windsor Residence"],
    ["Westcott Residence", "Windsor Residence"],
    ["Westerfield Residence", "Windsor Residence"],
    ["Westerly Residence", "Windsor Residence"],
    ["Westerman Residence", "Windsor Residence"],
    ["Western Residence", "Windsor Residence"],
    ["Westfield Residence", "Windsor Residence"],
    ["Westmoreland Residence", "Windsor Residence"],
    ["Weston Residence", "Windsor Residence"],
    ["Westover Residence", "Windsor Residence"],
    ["Westphall Residence", "Windsor Residence"],
    ["Westside Residence", "Windsor Residence"],
    ["Westview Residence", "Windsor Residence"],
    ["Westwood Residence", "Windsor Residence"],
    ["Wetherbee Residence", "Windsor Residence"],
    ["Wetherill Residence", "Windsor Residence"],
    ["Wetherington Residence", "Windsor Residence"],
    ["Wethington Residence", "Windsor Residence"],
    ["Wetter Residence", "Windsor Residence"],
    ["Wetzel Residence", "Windsor Residence"],
    ["Weyant Residence", "Windsor Residence"],
    ["Weymouth Residence", "Windsor Residence"],
    ["Whalen Residence", "Windsor Residence"],
    ["Whaley Residence", "Windsor Residence"],
    ["Whaling Residence", "Windsor Residence"],
    ["Wharton Residence", "Windsor Residence"],
    ["Wheat Residence", "Windsor Residence"],
    ["Wheatley Residence", "Windsor Residence"],
    ["Wheaton Residence", "Windsor Residence"],
    ["Whedon Residence", "Windsor Residence"],
    ["Wheeler Residence", "Windsor Residence"],
    ["Wheelock Residence", "Windsor Residence"],
    ["Whelan Residence", "Windsor Residence"],
    ["Wheless Residence", "Windsor Residence"],
    ["Whetstone Residence", "Windsor Residence"],
    ["Whidden Residence", "Windsor Residence"],
    ["Whinery Residence", "Windsor Residence"],
    ["Whipple Residence", "Windsor Residence"],
    ["Whisenant Residence", "Windsor Residence"],
    ["Whisenhunt Residence", "Windsor Residence"],
    ["Whisler Residence", "Windsor Residence"],
    ["Whisnant Residence", "Windsor Residence"],
    ["Whitacre Residence", "Windsor Residence"],
    ["Whitaker Residence", "Windsor Residence"],
    ["Whitbeck Residence", "Windsor Residence"],
    ["Whitcomb Residence", "Windsor Residence"],
    ["White Residence", "Windsor Residence"],
    ["Whitehead Residence", "Windsor Residence"],
    ["Whitehill Residence", "Windsor Residence"],
    ["Whitehurst Residence", "Windsor Residence"],
    ["Whitelaw Residence", "Windsor Residence"],
    ["Whiteley Residence", "Windsor Residence"],
    ["Whiteman Residence", "Windsor Residence"],
    ["Whiteside Residence", "Windsor Residence"],
    ["Whitfield Residence", "Windsor Residence"],
    ["Whitford Residence", "Windsor Residence"],
    ["Whitham Residence", "Windsor Residence"],
    ["Whiting Residence", "Windsor Residence"],
    ["Whitington Residence", "Windsor Residence"],
    ["Whitley Residence", "Windsor Residence"],
    ["Whitlock Residence", "Windsor Residence"],
    ["Whitlow Residence", "Windsor Residence"],
    ["Whitman Residence", "Windsor Residence"],
    ["Whitmarsh Residence", "Windsor Residence"],
    ["Whitmer Residence", "Windsor Residence"],
    ["Whitmire Residence", "Windsor Residence"],
    ["Whitmore Residence", "Windsor Residence"],
    ["Whitney Residence", "Windsor Residence"],
    ["Whiton Residence", "Windsor Residence"],
    ["Whitson Residence", "Windsor Residence"],
    ["Whitt Residence", "Windsor Residence"],
    ["Whittaker Residence", "Windsor Residence"],
    ["Whittemore Residence", "Windsor Residence"],
    ["Whitten Residence", "Windsor Residence"],
    ["Whittier Residence", "Windsor Residence"],
    ["Whittington Residence", "Windsor Residence"],
    ["Whittle Residence", "Windsor Residence"],
    ["Whittlesey Residence", "Windsor Residence"],
    ["Whitton Residence", "Windsor Residence"],
    ["Whitworth Residence", "Windsor Residence"],
    ["Whorton Residence", "Windsor Residence"],
    ["Whyte Residence", "Windsor Residence"],
    ["Wiand Residence", "Windsor Residence"],
    ["Wible Residence", "Windsor Residence"],
    ["Wick Residence", "Windsor Residence"],
    ["Wicker Residence", "Windsor Residence"],
    ["Wickham Residence", "Windsor Residence"],
    ["Wickman Residence", "Windsor Residence"],
    ["Wicks Residence", "Windsor Residence"],
    ["Wickwire Residence", "Windsor Residence"],
    ["Widener Residence", "Windsor Residence"],
    ["Widger Residence", "Windsor Residence"],
    ["Widman Residence", "Windsor Residence"],
    ["Widner Residence", "Windsor Residence"],
    ["Wiebe Residence", "Windsor Residence"],
    ["Wiechmann Residence", "Windsor Residence"],
    ["Wiedeman Residence", "Windsor Residence"],
    ["Wieder Residence", "Windsor Residence"],
    ["Wiedman Residence", "Windsor Residence"],
    ["Wiegand Residence", "Windsor Residence"],
    ["Wiegel Residence", "Windsor Residence"],
    ["Wieking Residence", "Windsor Residence"],
    ["Wieland Residence", "Windsor Residence"],
    ["Wiener Residence", "Windsor Residence"],
    ["Wier Residence", "Windsor Residence"],
    ["Wiese Residence", "Windsor Residence"],
    ["Wieser Residence", "Windsor Residence"],
    ["Wiesner Residence", "Windsor Residence"],
    ["Wiest Residence", "Windsor Residence"],
    ["Wigand Residence", "Windsor Residence"],
    ["Wiggers Residence", "Windsor Residence"],
    ["Wiggins Residence", "Windsor Residence"],
    ["Wigginton Residence", "Windsor Residence"],
    ["Wigglesworth Residence", "Windsor Residence"],
    ["Wiggs Residence", "Windsor Residence"],
    ["Wight Residence", "Windsor Residence"],
    ["Wightman Residence", "Windsor Residence"],
    ["Wiginton Residence", "Windsor Residence"],
    ["Wigle Residence", "Windsor Residence"],
    ["Wigley Residence", "Windsor Residence"],
    ["Wigner Residence", "Windsor Residence"],
    ["Wikle Residence", "Windsor Residence"],
    ["Wilbanks Residence", "Windsor Residence"],
    ["Wilber Residence", "Windsor Residence"],
    ["Wilborn Residence", "Windsor Residence"],
    ["Wilbur Residence", "Windsor Residence"],
    ["Wilburn Residence", "Windsor Residence"],
    ["Wilcock Residence", "Windsor Residence"],
    ["Wilcox Residence", "Windsor Residence"],
    ["Wilcoxon Residence", "Windsor Residence"],
    ["Wild Residence", "Windsor Residence"],
    ["Wilde Residence", "Windsor Residence"],
    ["Wilder Residence", "Windsor Residence"],
    ["Wilderman Residence", "Windsor Residence"],
    ["Wildman Residence", "Windsor Residence"],
    ["Wildrick Residence", "Windsor Residence"],
    ["Wilds Residence", "Windsor Residence"],
    ["Wiles Residence", "Windsor Residence"],
    ["Wiley Residence", "Windsor Residence"],
    ["Wilfong Residence", "Windsor Residence"],
    ["Wilford Residence", "Windsor Residence"],
    ["Wilhelm Residence", "Windsor Residence"],
    ["Wilhelmi Residence", "Windsor Residence"],
    ["Wilhelmy Residence", "Windsor Residence"],
    ["Wilhite Residence", "Windsor Residence"],
    ["Wilhoit Residence", "Windsor Residence"],
    ["Wilk Residence", "Windsor Residence"],
    ["Wilke Residence", "Windsor Residence"],
    ["Wilken Residence", "Windsor Residence"],
    ["Wilkens Residence", "Windsor Residence"],
    ["Wilkerson Residence", "Windsor Residence"],
    ["Wilkes Residence", "Windsor Residence"],
    ["Wilkie Residence", "Windsor Residence"],
    ["Wilkin Residence", "Windsor Residence"],
    ["Wilkins Residence", "Windsor Residence"],
    ["Wilkinson Residence", "Windsor Residence"],
    ["Wilks Residence", "Windsor Residence"],
    ["Will Residence", "Windsor Residence"],
    ["Willard Residence", "Windsor Residence"],
    ["Willcox Residence", "Windsor Residence"],
    ["Wille Residence", "Windsor Residence"],
    ["Willeford Residence", "Windsor Residence"],
    ["Willer Residence", "Windsor Residence"],
    ["Willett Residence", "Windsor Residence"],
    ["Willey Residence", "Windsor Residence"],
    ["Williams Residence", "Windsor Residence"],
    ["Williamson Residence", "Windsor Residence"],
    ["Williford Residence", "Windsor Residence"],
    ["Willing Residence", "Windsor Residence"],
    ["Willingham Residence", "Windsor Residence"],
    ["Willis Residence", "Windsor Residence"],
    ["Willison Residence", "Windsor Residence"],
    ["Willits Residence", "Windsor Residence"],
    ["Willman Residence", "Windsor Residence"],
    ["Willmore Residence", "Windsor Residence"],
    ["Willmott Residence", "Windsor Residence"],
    ["Willoughby Residence", "Windsor Residence"],
    ["Willow Residence", "Windsor Residence"],
    ["Wills Residence", "Windsor Residence"],
    ["Willson Residence", "Windsor Residence"],
    ["Wilm Residence", "Windsor Residence"],
    ["Wilmer Residence", "Windsor Residence"],
    ["Wilmoth Residence", "Windsor Residence"],
    ["Wilmot Residence", "Windsor Residence"],
    ["Wilmouth Residence", "Windsor Residence"],
    ["Wilms Residence", "Windsor Residence"],
    ["Wilson Residence", "Windsor Residence"],
    ["Wilt Residence", "Windsor Residence"],
    ["Wilton Residence", "Windsor Residence"],
    ["Wiltse Residence", "Windsor Residence"],
    ["Wiltshire Residence", "Windsor Residence"],
    ["Wimberly Residence", "Windsor Residence"],
    ["Wimsett Residence", "Windsor Residence"],
    ["Winans Residence", "Windsor Residence"],
    ["Winberry Residence", "Windsor Residence"],
    ["Winborn Residence", "Windsor Residence"],
    ["Winburn Residence", "Windsor Residence"],
    ["Winchell Residence", "Windsor Residence"],
    ["Winchester Residence", "Windsor Residence"],
    ["Wind Residence", "Windsor Residence"],
    ["Windham Residence", "Windsor Residence"],
    ["Windle Residence", "Windsor Residence"],
    ["Windom Residence", "Windsor Residence"],
    ["Windsor Residence", "Windsor Residence"],
    ["Wine Residence", "Windsor Residence"],
    ["Winegar Residence", "Windsor Residence"],
    ["Winegardner Residence", "Windsor Residence"],
    ["Wineland Residence", "Windsor Residence"],
    ["Winer Residence", "Windsor Residence"],
    ["Winfield Residence", "Windsor Residence"],
    ["Winfrey Residence", "Windsor Residence"],
    ["Wing Residence", "Windsor Residence"],
    ["Wingard Residence", "Windsor Residence"],
    ["Wingate Residence", "Windsor Residence"],
    ["Winger Residence", "Windsor Residence"],
    ["Winget Residence", "Windsor Residence"],
    ["Wingfield Residence", "Windsor Residence"],
    ["Wingo Residence", "Windsor Residence"],
    ["Winick Residence", "Windsor Residence"],
    ["Wininger Residence", "Windsor Residence"],
    ["Winkelman Residence", "Windsor Residence"],
    ["Winkle Residence", "Windsor Residence"],
    ["Winkleman Residence", "Windsor Residence"],
    ["Winkles Residence", "Windsor Residence"],
    ["Winks Residence", "Windsor Residence"],
    ["Winn Residence", "Windsor Residence"],
    ["Winne Residence", "Windsor Residence"],
    ["Winner Residence", "Windsor Residence"],
    ["Winnett Residence", "Windsor Residence"],
    ["Winningham Residence", "Windsor Residence"],
    ["Winship Residence", "Windsor Residence"],
    ["Winslow Residence", "Windsor Residence"],
    ["Winsor Residence", "Windsor Residence"],
    ["Winstead Residence", "Windsor Residence"],
    ["Winston Residence", "Windsor Residence"],
    ["Winter Residence", "Windsor Residence"],
    ["Wintermote Residence", "Windsor Residence"],
    ["Winters Residence", "Windsor Residence"],
    ["Winterstein Residence", "Windsor Residence"],
    ["Winthrop Residence", "Windsor Residence"],
    ["Winton Residence", "Windsor Residence"],
    ["Wintz Residence", "Windsor Residence"],
    ["Winward Residence", "Windsor Residence"],
    ["Wion Residence", "Windsor Residence"],
    ["Wipple Residence", "Windsor Residence"],
    ["Wireman Residence", "Windsor Residence"],
    ["Wirth Residence", "Windsor Residence"],
    ["Wirts Residence", "Windsor Residence"],
    ["Wise Residence", "Windsor Residence"],
    ["Wiseman Residence", "Windsor Residence"],
    ["Wiser Residence", "Windsor Residence"],
    ["Wishart Residence", "Windsor Residence"],
    ["Wisler Residence", "Windsor Residence"],
    ["Wisman Residence", "Windsor Residence"],
    ["Wisner Residence", "Windsor Residence"],
    ["Wisniewski Residence", "Windsor Residence"],
    ["Wisseman Residence", "Windsor Residence"],
    ["Wiswell Residence", "Windsor Residence"],
    ["Witcher Residence", "Windsor Residence"],
    ["Witham Residence", "Windsor Residence"],
    ["Witherell Residence", "Windsor Residence"],
    ["Witherington Residence", "Windsor Residence"],
    ["Withers Residence", "Windsor Residence"],
    ["Witherspoon Residence", "Windsor Residence"],
    ["Withey Residence", "Windsor Residence"],
    ["Withington Residence", "Windsor Residence"],
    ["Withrow Residence", "Windsor Residence"],
    ["Witt Residence", "Windsor Residence"],
    ["Witte Residence", "Windsor Residence"],
    ["Witten Residence", "Windsor Residence"],
    ["Wittenberg Residence", "Windsor Residence"],
    ["Witter Residence", "Windsor Residence"],
    ["Wittig Residence", "Windsor Residence"],
    ["Wittman Residence", "Windsor Residence"],
    ["Wittmeyer Residence", "Windsor Residence"],
    ["Wixom Residence", "Windsor Residence"],
    ["Wixson Residence", "Windsor Residence"],
    ["Wochner Residence", "Windsor Residence"],
    ["Woerner Residence", "Windsor Residence"],
    ["Wofford Residence", "Windsor Residence"],
    ["Wogan Residence", "Windsor Residence"],
    ["Wohl Residence", "Windsor Residence"],
    ["Wohlfarth Residence", "Windsor Residence"],
    ["Wohlford Residence", "Windsor Residence"],
    ["Wohlgemuth Residence", "Windsor Residence"],
    ["Woidtke Residence", "Windsor Residence"],
    ["Wojcik Residence", "Windsor Residence"],
    ["Wojtaszek Residence", "Windsor Residence"],
    ["Wolak Residence", "Windsor Residence"],
    ["Wolber Residence", "Windsor Residence"],
    ["Wolbert Residence", "Windsor Residence"],
    ["Wolcott Residence", "Windsor Residence"],
    ["Wold Residence", "Windsor Residence"],
    ["Wolf Residence", "Windsor Residence"],
    ["Wolfe Residence", "Windsor Residence"],
    ["Wolfgang Residence", "Windsor Residence"],
    ["Wolfley Residence", "Windsor Residence"],
    ["Wolfram Residence", "Windsor Residence"],
    ["Wolford Residence", "Windsor Residence"],
    ["Wolfram Residence", "Windsor Residence"],
    ["Wolfson Residence", "Windsor Residence"],
    ["Wolinski Residence", "Windsor Residence"],
    ["Wolk Residence", "Windsor Residence"],
    ["Wolke Residence", "Windsor Residence"],
    ["Woll Residence", "Windsor Residence"],
    ["Wollam Residence", "Windsor Residence"],
    ["Wollard Residence", "Windsor Residence"],
    ["Wollaston Residence", "Windsor Residence"],
    ["Wollen Residence", "Windsor Residence"],
    ["Wollenberg Residence", "Windsor Residence"],
    ["Woller Residence", "Windsor Residence"],
    ["Wollman Residence", "Windsor Residence"],
    ["Wollmer Residence", "Windsor Residence"],
    ["Wolman Residence", "Windsor Residence"],
    ["Wolpert Residence", "Windsor Residence"],
    ["Wolter Residence", "Windsor Residence"],
    ["Wolters Residence", "Windsor Residence"],
    ["Woltz Residence", "Windsor Residence"],
    ["Womack Residence", "Windsor Residence"],
    ["Womble Residence", "Windsor Residence"],
    ["Wonderly Residence", "Windsor Residence"],
    ["Wong Residence", "Windsor Residence"],
    ["Wood Residence", "Windsor Residence"],
    ["Woodall Residence", "Windsor Residence"],
    ["Woodard Residence", "Windsor Residence"],
    ["Woodbridge Residence", "Windsor Residence"],
    ["Woodburn Residence", "Windsor Residence"],
    ["Woodbury Residence", "Windsor Residence"],
    ["Woodcock Residence", "Windsor Residence"],
    ["Woodell Residence", "Windsor Residence"],
    ["Woodfield Residence", "Windsor Residence"],
    ["Woodfill Residence", "Windsor Residence"],
    ["Woodford Residence", "Windsor Residence"],
    ["Woodgate Residence", "Windsor Residence"],
    ["Woodhall Residence", "Windsor Residence"],
    ["Woodham Residence", "Windsor Residence"],
    ["Woodhead Residence", "Windsor Residence"],
    ["Woodhouse Residence", "Windsor Residence"],
    ["Woodhull Residence", "Windsor Residence"],
    ["Woodin Residence", "Windsor Residence"],
    ["Wooding Residence", "Windsor Residence"],
    ["Woodland Residence", "Windsor Residence"],
    ["Woodley Residence", "Windsor Residence"],
    ["Woodman Residence", "Windsor Residence"],
    ["Woodmansee Residence", "Windsor Residence"],
    ["Woodring Residence", "Windsor Residence"],
    ["Woodrow Residence", "Windsor Residence"],
    ["Woodruff Residence", "Windsor Residence"],
    ["Woods Residence", "Windsor Residence"],
    ["Woodside Residence", "Windsor Residence"],
    ["Woodson Residence", "Windsor Residence"],
    ["Woodstock Residence", "Windsor Residence"],
    ["Woodward Residence", "Windsor Residence"],
    ["Woodworth Residence", "Windsor Residence"],
    ["Woody Residence", "Windsor Residence"],
    ["Woodyard Residence", "Windsor Residence"],
    ["Wooldridge Residence", "Windsor Residence"],
    ["Woolery Residence", "Windsor Residence"],
    ["Wooley Residence", "Windsor Residence"],
    ["Woolf Residence", "Windsor Residence"],
    ["Woolfolk Residence", "Windsor Residence"],
    ["Woolley Residence", "Windsor Residence"],
    ["Woolman Residence", "Windsor Residence"],
    ["Woolsey Residence", "Windsor Residence"],
    ["Woolson Residence", "Windsor Residence"],
    ["Woolston Residence", "Windsor Residence"],
    ["Woolverton Residence", "Windsor Residence"],
    ["Woolwine Residence", "Windsor Residence"],
    ["Woolworth Residence", "Windsor Residence"],
    ["Woosley Residence", "Windsor Residence"],
    ["Wooster Residence", "Windsor Residence"],
    ["Wooten Residence", "Windsor Residence"],
    ["Wootton Residence", "Windsor Residence"],
    ["Word Residence", "Windsor Residence"],
    ["Worden Residence", "Windsor Residence"],
    ["Workman Residence", "Windsor Residence"],
    ["Works Residence", "Windsor Residence"],
    ["Worley Residence", "Windsor Residence"],
    ["Wormald Residence", "Windsor Residence"],
    ["Wormley Residence", "Windsor Residence"],
    ["Wornall Residence", "Windsor Residence"],
    ["Worrell Residence", "Windsor Residence"],
    ["Worsham Residence", "Windsor Residence"],
    ["Worster Residence", "Windsor Residence"],
    ["Worth Residence", "Windsor Residence"],
    ["Wortham Residence", "Windsor Residence"],
    ["Worthen Residence", "Windsor Residence"],
    ["Worthington Residence", "Windsor Residence"],
    ["Worthley Residence", "Windsor Residence"],
    ["Worthy Residence", "Windsor Residence"],
    ["Wortman Residence", "Windsor Residence"],
    ["Wortmann Residence", "Windsor Residence"],
    ["Worton Residence", "Windsor Residence"],
    ["Woten Residence", "Windsor Residence"],
    ["Wotherspoon Residence", "Windsor Residence"],
    ["Wray Residence", "Windsor Residence"],
    ["Wrede Residence", "Windsor Residence"],
    ["Wren Residence", "Windsor Residence"],
    ["Wrenn Residence", "Windsor Residence"],
    ["Wright Residence", "Windsor Residence"],
    ["Wrightman Residence", "Windsor Residence"],
    ["Wrighton Residence", "Windsor Residence"],
    ["Wrightson Residence", "Windsor Residence"],
    ["Wrigley Residence", "Windsor Residence"],
    ["Wriston Residence", "Windsor Residence"],
    ["Wrobel Residence", "Windsor Residence"],
    ["Wroblewski Residence", "Windsor Residence"],
    ["Wrona Residence", "Windsor Residence"],
    ["Wronski Residence", "Windsor Residence"],
    ["Wrubel Residence", "Windsor Residence"],
    ["Wu Residence", "Windsor Residence"],
    ["Wuerfel Residence", "Windsor Residence"],
    ["Wuerth Residence", "Windsor Residence"],
    ["Wuerz Residence", "Windsor Residence"],
    ["Wuest Residence", "Windsor Residence"],
    ["Wuestenberg Residence", "Windsor Residence"],
    ["Wulf Residence", "Windsor Residence"],
    ["Wulff Residence", "Windsor Residence"],
    ["Wunder Residence", "Windsor Residence"],
    ["Wunderlich Residence", "Windsor Residence"],
    ["Wurl Residence", "Windsor Residence"],
    ["Wurst Residence", "Windsor Residence"],
    ["Wurster Residence", "Windsor Residence"],
    ["Wurth Residence", "Windsor Residence"],
    ["Wurtz Residence", "Windsor Residence"],
    ["Wurz Residence", "Windsor Residence"],
    ["Wurzburg Residence", "Windsor Residence"],
    ["Wyant Residence", "Windsor Residence"],
    ["Wyatt Residence", "Windsor Residence"],
    ["Wyckoff Residence", "Windsor Residence"],
    ["Wydra Residence", "Windsor Residence"],
    ["Wyeth Residence", "Windsor Residence"],
    ["Wygant Residence", "Windsor Residence"],
    ["Wykes Residence", "Windsor Residence"],
    ["Wyland Residence", "Windsor Residence"],
    ["Wyld Residence", "Windsor Residence"],
    ["Wylde Residence", "Windsor Residence"],
    ["Wyler Residence", "Windsor Residence"],
    ["Wyles Residence", "Windsor Residence"],
    ["Wylie Residence", "Windsor Residence"],
    ["Wyllie Residence", "Windsor Residence"],
    ["Wylly Residence", "Windsor Residence"],
    ["Wyman Residence", "Windsor Residence"],
    ["Wynkoop Residence", "Windsor Residence"],
    ["Wynn Residence", "Windsor Residence"],
    ["Wynne Residence", "Windsor Residence"],
    ["Wyse Residence", "Windsor Residence"],
    ["Wysocki Residence", "Windsor Residence"],
    ["Wysong Residence", "Windsor Residence"],
    ["Wyss Residence", "Windsor Residence"],
    ["Wythe Residence", "Windsor Residence"],
  ]);

  const { data, error } = await db
    .from("projects")
    .select("id, name, status")
    .order("name", { ascending: true });

  if (error) {
    console.error("[bootstrap-review:projects] fetch failed:", error.message);
    return [];
  }

  return (data || [])
    .filter((p: any) => !inactiveStatuses.has(String(p.status || "").toLowerCase()))
    .filter((p: any) => !excludedProjectNames.has(p.name))
    .map((p: any) => ({
      id: p.id,
      name: p.name,
      label: pickerLabelBySourceName.get(p.name) || p.name,
    }));
}

async function handleQueue(db: any, req: Request): Promise<Response> {
  const url = new URL(req.url);
  const maxAgeDays = parseInt(url.searchParams.get("max_age_days") || "21", 10);
  const limit = parseInt(url.searchParams.get("limit") || "50", 10);

  // Fetch items via enhanced RPC
  const { data: rqData, error: rqError } = await db.rpc("fresh_review_queue", {
    p_max_age_days: maxAgeDays,
    p_limit: limit,
  });

  if (rqError) {
    console.error("[bootstrap-review:queue] rpc failed:", rqError.message);
    return json({
      ok: false,
      error_code: "queue_fetch_failed",
      error: rqError.message,
    }, 500);
  }

  // Pre-filter/normalize for IOS
  const preFilterCount = (rqData || []).length;
  const items = (rqData || [])
    .map(normalizeQueueItemForIOS)
    .filter(Boolean);

  // Get total pending count using specific RPC
  const totalPending = await countPendingQueueItemsForIOS(db, maxAgeDays);

  // Fetch active projects for attribution picker.
  const projects = await fetchReviewProjects(db);

  return json({
    ok: true,
    items,
    projects,
    total_pending: totalPending,
    total_returned: items.length,
    max_age_days: maxAgeDays,
    function_version: FUNCTION_VERSION,
  });
}

async function handleResolve(db: any, req: Request): Promise<Response> {
  const body = await req.json();
  const {
    review_queue_id,
    action, // "accept", "reject", "escalate", "skip", "needs_split"
    chosen_project_id,
    reviewer_notes,
    user_id,
  } = body;

  if (!review_queue_id || !isValidUUID(review_queue_id)) {
    return json({ ok: false, error: "invalid_review_queue_id" }, 400);
  }

  // Call atomic verdict RPC
  const { data: result, error: rpcErr } = await db.rpc("apply_attribution_verdict", {
    p_review_queue_id: review_queue_id,
    p_action: action,
    p_chosen_project_id: chosen_project_id || null,
    p_reviewer_id: user_id || "chad",
    p_notes: reviewer_notes || null,
  });

  if (rpcErr) {
    console.error("[bootstrap-review:resolve] RPC failed:", rpcErr.message);
    return json({ ok: false, error: rpcErr.message }, 500);
  }

  if (!result || !result.ok) {
    return json({ ok: false, error: result?.error || "verdict_failed" }, 400);
  }

  // Tag source for audit/metrics
  const source = normalizeReviewQueueSource(req.headers.get("x-source"));
  await tagReviewQueueSource(db, review_queue_id, source, "bootstrap-review:resolve");

  // Get next item for this interaction if any (re-derive from view for Phase A)
  const interactionId = result.interaction_id;
  let nextItemForInteraction = null;
  let pendingForInteraction = 0;

  if (interactionId) {
    const { data: nextItems } = await db
      .from("v_triage_attribution_cards")
      .select("*")
      .eq("interaction_id", interactionId)
      .eq("queue_status", "pending")
      .order("span_index", { ascending: true })
      .limit(1);

    if (nextItems && nextItems.length > 0) {
      nextItemForInteraction = normalizeQueueItemForIOS(nextItems[0]);
    }

    const { count } = await db
      .from("review_queue")
      .select("id", { count: "exact", head: true })
      .eq("status", "pending")
      .eq("interaction_id", interactionId);
    pendingForInteraction = count || 0;
  }

  const totalPendingAfterResolve = await countPendingQueueItemsForIOS(db);

  return json({
    ok: true,
    resolved_id: review_queue_id,
    interaction_id: interactionId,
    next_item: nextItemForInteraction,
    pending_for_interaction: pendingForInteraction,
    total_pending: totalPendingAfterResolve,
    function_version: FUNCTION_VERSION,
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({}, 200);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const db = createClient(supabaseUrl, supabaseKey);

    const url = new URL(req.url);
    if (url.pathname.endsWith("/queue")) {
      return await handleQueue(db, req);
    }
    if (url.pathname.endsWith("/resolve")) {
      return await handleResolve(db, req);
    }

    return json({ ok: false, error: "not_found" }, 404);
  } catch (err: any) {
    console.error("[bootstrap-review] Error:", err.message);
    return json({
      ok: false,
      error_code: "internal_error",
      error: err.message,
      function_version: FUNCTION_VERSION,
    }, 500);
  }
});
