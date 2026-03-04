
const supabaseUrl = process.env.SUPABASE_URL;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const edgeSecret = process.env.EDGE_SHARED_SECRET;

async function backfill() {
  // 1. Fetch 5 items needing backfill
  const resp = await fetch(`${supabaseUrl}/rest/v1/scheduler_items?start_at_utc=is.null&time_hint=not.is.null&limit=5`, {
    headers: {
      'apikey': serviceRoleKey,
      'Authorization': `Bearer ${serviceRoleKey}`
    }
  });
  const items = await resp.json();
  console.log(`Found ${items.length} items to backfill.`);

  for (const item of items) {
    console.log(`Processing item ${item.id}: "${item.time_hint}"`);
    
    // 2. Call time-resolver
    const resolveResp = await fetch(`${supabaseUrl}/functions/v1/time-resolver`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${serviceRoleKey}`,
        'X-Edge-Secret': edgeSecret,
        'X-Source': 'test',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        text: item.time_hint,
        reference_time_utc: item.created_at
      })
    });
    
    const resolution = await resolveResp.json();
    if (resolution.ok && resolution.start_at_utc) {
      console.log(`  Resolved to: ${resolution.start_at_utc}`);
      
      // 3. Patch the item
      const patchResp = await fetch(`${supabaseUrl}/rest/v1/scheduler_items?id=eq.${item.id}`, {
        method: 'PATCH',
        headers: {
          'apikey': serviceRoleKey,
          'Authorization': `Bearer ${serviceRoleKey}`,
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal'
        },
        body: JSON.stringify({
          start_at_utc: resolution.start_at_utc,
          due_at_utc: resolution.due_at_utc,
          attribution_confidence: resolution.confidence === 'HIGH' ? 1.0 : (resolution.confidence === 'MEDIUM' ? 0.7 : 0.4),
          needs_review: resolution.resolution.needs_review
        })
      });
      
      if (patchResp.ok) {
        console.log(`  Successfully patched item ${item.id}`);
      } else {
        console.error(`  Failed to patch item ${item.id}: ${patchResp.statusText}`);
      }
    } else {
      console.log(`  Could not resolve: ${resolution.error || 'no start_at_utc'}`);
    }
  }
}

backfill().catch(console.error);
