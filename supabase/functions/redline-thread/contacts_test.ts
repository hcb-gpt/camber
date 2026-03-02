import { assertEquals } from "https://deno.land/std@0.208.0/testing/asserts.ts";
import { deterministicUUID, parseSmsOnlyContactDigits } from "./index.ts";

Deno.test("deterministicUUID generates a stable and valid UUID format", () => {
  const input1 = "sms:7065551234";
  const input2 = "unknown:John Doe";

  const uuid1 = deterministicUUID(input1);
  const uuid2 = deterministicUUID(input2);

  // Assert correct UUID format
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/i;
  assertEquals(uuidRegex.test(uuid1), true, "UUID 1 is invalid format");
  assertEquals(uuidRegex.test(uuid2), true, "UUID 2 is invalid format");

  // Assert stability
  assertEquals(deterministicUUID(input1), uuid1);
  assertEquals(deterministicUUID(input2), uuid2);

  // Assert distinct
  if (uuid1 === uuid2) {
    throw new Error("UUIDs for different inputs collided.");
  }
});

Deno.test("parseSmsOnlyContactDigits correctly parses sms ids", () => {
  assertEquals(parseSmsOnlyContactDigits("sms:7065551234"), "7065551234");
  assertEquals(parseSmsOnlyContactDigits("sms:1234567"), "1234567");
  assertEquals(parseSmsOnlyContactDigits("sms:123456789012345"), "123456789012345");
  assertEquals(parseSmsOnlyContactDigits("unknown:contact"), null);
  assertEquals(parseSmsOnlyContactDigits("1234"), null);
  assertEquals(parseSmsOnlyContactDigits("sms:abc"), null);
});
