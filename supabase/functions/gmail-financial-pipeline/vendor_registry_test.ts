import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  buildInternalPatterns,
  buildInternalVendorNormals,
  buildRejectSet,
  buildVendorHintList,
  canonicalizeVendorDisplay,
  lookupVendor,
  type VendorRegistryRow,
} from "./vendor_registry.ts";

const MOCK_REGISTRY: VendorRegistryRow[] = [
  {
    id: "aaa",
    vendor_name: "Accounts Receivable",
    vendor_normalized: "accounts receivable",
    vendor_type: "boilerplate",
    status: "rejected",
    match_pattern: null,
  },
  {
    id: "bbb",
    vendor_name: "QuickBooks",
    vendor_normalized: "quickbooks",
    vendor_type: "platform",
    status: "rejected",
    match_pattern: null,
  },
  {
    id: "ccc",
    vendor_name: "HCB",
    vendor_normalized: "hcb",
    vendor_type: "internal",
    status: "rejected",
    match_pattern: "^hcb$",
  },
  {
    id: "ddd",
    vendor_name: "Heartwood Custom Builders",
    vendor_normalized: "heartwood custom builders",
    vendor_type: "internal",
    status: "rejected",
    match_pattern: "^heartwood",
  },
  {
    id: "eee",
    vendor_name: "Carter Lumber",
    vendor_normalized: "carter lumber",
    vendor_type: "external_vendor",
    status: "active",
    match_pattern: null,
  },
  {
    id: "fff",
    vendor_name: "Grounded Siteworks",
    vendor_normalized: "grounded siteworks",
    vendor_type: "external_vendor",
    status: "active",
    match_pattern: null,
  },
];

Deno.test("buildRejectSet includes boilerplate and platform rejected vendors", () => {
  const rejectSet = buildRejectSet(MOCK_REGISTRY);
  assertEquals(rejectSet.has("accounts receivable"), true);
  assertEquals(rejectSet.has("quickbooks"), true);
  assertEquals(rejectSet.has("carter lumber"), false);
  assertEquals(rejectSet.has("hcb"), false);
});

Deno.test("buildInternalPatterns returns RegExp array from internal vendors with match_pattern", () => {
  const patterns = buildInternalPatterns(MOCK_REGISTRY);
  assertEquals(patterns.length, 2);
  assertEquals(patterns[0].test("hcb"), true);
  assertEquals(patterns[0].test("hcb homes"), false);
  assertEquals(patterns[1].test("heartwood custom builders"), true);
  assertEquals(patterns[1].test("heartwoodcustombuildersllc"), true);
});

Deno.test("buildInternalVendorNormals returns normalized names for all internal vendors", () => {
  const normals = buildInternalVendorNormals(MOCK_REGISTRY);
  assertEquals(normals.has("hcb"), true);
  assertEquals(normals.has("heartwood custom builders"), true);
  assertEquals(normals.has("carter lumber"), false);
});

Deno.test("buildVendorHintList returns only active external vendors", () => {
  const hints = buildVendorHintList(MOCK_REGISTRY);
  assertEquals(hints.includes("Carter Lumber"), true);
  assertEquals(hints.includes("Grounded Siteworks"), true);
  assertEquals(hints.includes("HCB"), false);
  assertEquals(hints.includes("QuickBooks"), false);
});

Deno.test("buildInternalPatterns returns empty array when no internal vendors have patterns", () => {
  const noPatterns: VendorRegistryRow[] = [
    {
      id: "xxx",
      vendor_name: "SomeInternal",
      vendor_normalized: "someinternal",
      vendor_type: "internal",
      status: "rejected",
      match_pattern: null,
    },
  ];
  const patterns = buildInternalPatterns(noPatterns);
  assertEquals(patterns.length, 0);
});

Deno.test("lookupVendor finds known vendor by normalized name", () => {
  const result = lookupVendor(MOCK_REGISTRY, "carter lumber");
  assertEquals(result?.vendor_name, "Carter Lumber");
  assertEquals(result?.vendor_type, "external_vendor");
});

Deno.test("lookupVendor returns null for unknown vendor", () => {
  const result = lookupVendor(MOCK_REGISTRY, "totally unknown vendor");
  assertEquals(result, null);
});

Deno.test("canonicalizeVendorDisplay returns registry name when found", () => {
  const rows: VendorRegistryRow[] = [
    {
      id: "1",
      vendor_name: "Carter Lumber",
      vendor_normalized: "carter lumber",
      vendor_type: "external_vendor",
      status: "active",
      match_pattern: null,
    },
    {
      id: "2",
      vendor_name: "GA Insulation",
      vendor_normalized: "ga insulation",
      vendor_type: "external_vendor",
      status: "active",
      match_pattern: null,
    },
  ];
  assertEquals(
    canonicalizeVendorDisplay(rows, "carter lumber", "CARTER LUMBER CO"),
    "Carter Lumber",
  );
  assertEquals(
    canonicalizeVendorDisplay(rows, "ga insulation", "GA INSULATION LLC"),
    "GA Insulation",
  );
});

Deno.test("canonicalizeVendorDisplay returns raw vendor when not in registry", () => {
  const rows: VendorRegistryRow[] = [];
  assertEquals(
    canonicalizeVendorDisplay(rows, "unknown vendor", "Unknown Vendor LLC"),
    "Unknown Vendor LLC",
  );
});

Deno.test("canonicalizeVendorDisplay returns raw vendor for null normalized", () => {
  assertEquals(
    canonicalizeVendorDisplay([], null, "Carter Lumber Inc"),
    "Carter Lumber Inc",
  );
});
