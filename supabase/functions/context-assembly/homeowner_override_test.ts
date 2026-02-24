import { assertEquals } from "https://deno.land/std@0.218.0/assert/mod.ts";
import {
  findHomeownerOverrideConflict,
  isExplicitContradictoryProjectAnchor,
  isHomeownerRoleLabel,
} from "./homeowner_override.ts";

Deno.test("isHomeownerRoleLabel recognizes homeowner/owner labels", () => {
  assertEquals(isHomeownerRoleLabel("homeowner"), true);
  assertEquals(isHomeownerRoleLabel("Home Owner"), true);
  assertEquals(isHomeownerRoleLabel("property owner"), true);
  assertEquals(isHomeownerRoleLabel("owner"), true);
  assertEquals(isHomeownerRoleLabel("electrician"), false);
  assertEquals(isHomeownerRoleLabel("business owner"), false);
});

Deno.test("isHomeownerRoleLabel excludes bare owner when trade is present", () => {
  // "owner" with a trade = company owner (sub/vendor), not homeowner
  assertEquals(isHomeownerRoleLabel("owner", "Framing"), false);
  assertEquals(isHomeownerRoleLabel("owner", "Tile"), false);
  assertEquals(isHomeownerRoleLabel("owner", "Plumbing"), false);
  // Explicit homeowner labels still match even with a trade
  assertEquals(isHomeownerRoleLabel("homeowner", "General Contractor"), true);
  assertEquals(isHomeownerRoleLabel("property owner", "Landscaping"), true);
  // No trade = bare owner still matches
  assertEquals(isHomeownerRoleLabel("owner"), true);
  assertEquals(isHomeownerRoleLabel("owner", null), true);
  assertEquals(isHomeownerRoleLabel("owner", ""), true);
});

Deno.test("isExplicitContradictoryProjectAnchor accepts explicit name/alias anchors", () => {
  assertEquals(isExplicitContradictoryProjectAnchor("name_match", "Winship Residence"), true);
  assertEquals(isExplicitContradictoryProjectAnchor("alias_match", "White Residence"), true);
  assertEquals(isExplicitContradictoryProjectAnchor("alias_match", "1234 Oak St"), true);
  assertEquals(isExplicitContradictoryProjectAnchor("alias_match", "white"), false);
  assertEquals(isExplicitContradictoryProjectAnchor("location_match", "sparta"), false);
});

Deno.test("findHomeownerOverrideConflict returns first conflicting explicit anchor", () => {
  const conflict = findHomeownerOverrideConflict("proj_homeowner", [
    {
      project_id: "proj_homeowner",
      alias_matches: [{ term: "Homeowner Job", match_type: "name_match" }],
    },
    {
      project_id: "proj_other",
      alias_matches: [
        { term: "white", match_type: "alias_match" }, // too weak
        { term: "Permar Residence", match_type: "name_match" }, // explicit
      ],
    },
  ]);

  assertEquals(conflict, {
    project_id: "proj_other",
    term: "Permar Residence",
  });
});

Deno.test("findHomeownerOverrideConflict returns null when non-homeowner anchors are weak", () => {
  const conflict = findHomeownerOverrideConflict("proj_homeowner", [
    {
      project_id: "proj_other",
      alias_matches: [
        { term: "white", match_type: "alias_match" },
        { term: "oak", match_type: "alias_match" },
        { term: "atlanta", match_type: "location_match" },
      ],
    },
  ]);

  assertEquals(conflict, null);
});
