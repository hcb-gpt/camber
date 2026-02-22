-- WP-A: Correspondent Promotion
-- Explode scope.correspondents (8 facts) and scope.contact (22 facts)
-- from project_facts into project_contacts.
--
-- Results: 41 new project_contacts rows, 6 new contacts created
-- Placeholder phone pattern: +1000000NNNN (existing: 0001-0004, this batch: 0005-0010)
-- Does NOT delete source facts from project_facts.
-- Owner: wp-a-worker (world-model-prep team)
-- Applied: 2026-02-16

BEGIN;

DO $$
DECLARE
  rec RECORD;
  role_key TEXT;
  role_value TEXT;
  extracted_name TEXT;
  matched_contact_id UUID;
  new_contact_id UUID;
  placeholder_seq INTEGER;
  placeholder_phone TEXT;
  new_trade TEXT;
  batch_id TEXT := 'wp_a_correspondent_' || to_char(now(), 'YYYYMMDD_HH24MISS');
  p1_promoted INTEGER := 0;
  p1_created INTEGER := 0;
  p1_skipped INTEGER := 0;
  p2_promoted INTEGER := 0;
  p2_created INTEGER := 0;
  p2_skipped INTEGER := 0;
BEGIN
  -- Next placeholder phone sequence (existing: +10000000001 through +10000000004)
  SELECT COALESCE(MAX(substring(phone from 9)::integer), 4) + 1
  INTO placeholder_seq
  FROM contacts
  WHERE phone LIKE '+1000000%';

  RAISE NOTICE 'WP-A batch=% next_seq=%', batch_id, placeholder_seq;

  -- ============================================================
  -- PASS 1: scope.correspondents key_roles -> project_contacts
  -- ============================================================

  FOR rec IN
    SELECT pf.id AS fact_id, pf.project_id, pf.fact_payload
    FROM project_facts pf
    WHERE pf.fact_kind = 'scope.correspondents'
      AND pf.fact_payload ? 'key_roles'
  LOOP
    FOR role_key, role_value IN
      SELECT k, v FROM jsonb_each_text(rec.fact_payload->'key_roles') AS t(k, v)
    LOOP
      -- Extract primary name from value string
      extracted_name := role_value;
      -- Strip parenthetical: "Brian Dove (bkdove@me.com)" -> "Brian Dove"
      extracted_name := regexp_replace(extracted_name, '\s*\([^)]*\)', '', 'g');
      -- Strip trailing emails
      extracted_name := regexp_replace(extracted_name, '\s+\S+@\S+', '', 'g');
      -- Take first if comma-separated
      IF extracted_name LIKE '%,%' THEN
        extracted_name := trim(split_part(extracted_name, ',', 1));
      END IF;
      -- Take first if plus-separated
      IF extracted_name LIKE '% + %' THEN
        extracted_name := trim(split_part(extracted_name, ' + ', 1));
      END IF;
      extracted_name := trim(extracted_name);

      IF extracted_name IS NULL OR length(extracted_name) < 2 THEN
        p1_skipped := p1_skipped + 1; CONTINUE;
      END IF;

      -- Fuzzy match cascade: exact -> partial -> company -> alias
      matched_contact_id := NULL;

      SELECT c.id INTO matched_contact_id
      FROM contacts c WHERE c.name ILIKE extracted_name LIMIT 1;

      IF matched_contact_id IS NULL THEN
        SELECT c.id INTO matched_contact_id
        FROM contacts c
        WHERE c.name ILIKE '%' || extracted_name || '%'
           OR extracted_name ILIKE '%' || c.name || '%'
        LIMIT 1;
      END IF;

      IF matched_contact_id IS NULL THEN
        SELECT c.id INTO matched_contact_id
        FROM contacts c WHERE c.company ILIKE '%' || extracted_name || '%' LIMIT 1;
      END IF;

      IF matched_contact_id IS NULL THEN
        SELECT c.id INTO matched_contact_id
        FROM contacts c
        WHERE EXISTS (
          SELECT 1 FROM unnest(c.aliases) AS alias
          WHERE alias ILIKE '%' || extracted_name || '%'
             OR extracted_name ILIKE '%' || alias || '%'
        ) LIMIT 1;
      END IF;

      -- No match -> create new contact with placeholder phone
      IF matched_contact_id IS NULL THEN
        placeholder_phone := '+1000000' || lpad(placeholder_seq::text, 4, '0');
        placeholder_seq := placeholder_seq + 1;

        new_trade := CASE
          WHEN role_key IN ('framer','trim','exterior','lumber','lumber_rep','lumber_ewp',
                            'hvac','electrical','concrete','cabinetry','tile','vent',
                            'granite','landscaping','door_builder','windows','window_rep',
                            'plumbing_fixture','materials','site_plan','site_super','site_supers',
                            'lien_waiver') THEN role_key
          ELSE NULL
        END;

        INSERT INTO contacts (phone, name, contact_type, trade, source, created_at, updated_at)
        VALUES (
          placeholder_phone, extracted_name,
          CASE
            WHEN role_key IN ('homeowner', 'homeowner_spouse') THEN 'client'
            WHEN role_key IN ('bookkeeper', 'architect', 'engineer', 'plan_designer', 'county', 'soil_scientist') THEN 'professional'
            ELSE 'subcontractor'
          END,
          new_trade, 'correspondent_promotion', now(), now()
        )
        RETURNING id INTO new_contact_id;

        matched_contact_id := new_contact_id;
        p1_created := p1_created + 1;

        INSERT INTO project_contacts_promotion_log
          (inserted_by, batch_id, contact_id, project_id, is_active, method, notes)
        VALUES ('wp_a_worker', batch_id, matched_contact_id, rec.project_id, true,
           'contact_created',
           'New from correspondents.' || role_key || '="' || left(role_value, 100) || '" ph=' || placeholder_phone);
      END IF;

      -- Insert project_contacts row (skip if already exists)
      INSERT INTO project_contacts (contact_id, project_id, role, trade, is_active, source, created_at, updated_at)
      VALUES (
        matched_contact_id, rec.project_id, role_key,
        CASE
          WHEN role_key IN ('framer','trim','exterior','lumber','lumber_rep','lumber_ewp',
                            'hvac','electrical','concrete','cabinetry','tile','vent',
                            'granite','landscaping','door_builder','windows','window_rep',
                            'plumbing_fixture','materials','site_plan')
          THEN role_key ELSE NULL
        END,
        true, 'correspondent_promotion', now(), now()
      )
      ON CONFLICT (contact_id, project_id) DO NOTHING;

      IF FOUND THEN
        p1_promoted := p1_promoted + 1;
        INSERT INTO project_contacts_promotion_log
          (inserted_by, batch_id, contact_id, project_id, is_active, method, notes)
        VALUES ('wp_a_worker', batch_id, matched_contact_id, rec.project_id, true,
           'correspondent_promoted', 'correspondents.' || role_key || ' name="' || extracted_name || '"');
      ELSE
        p1_skipped := p1_skipped + 1;
      END IF;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'Pass1: promoted=% created=% skipped=%', p1_promoted, p1_created, p1_skipped;

  -- ============================================================
  -- PASS 2: scope.contact facts -> project_contacts
  -- ============================================================

  FOR rec IN
    SELECT pf.id AS fact_id, pf.project_id,
           pf.fact_payload->>'feature' AS feature,
           pf.fact_payload->>'value' AS value,
           pf.fact_payload->>'person' AS person,
           pf.fact_payload->>'contact' AS contact_name,
           pf.fact_payload->>'email' AS email,
           pf.fact_payload->>'phone' AS phone
    FROM project_facts pf
    WHERE pf.fact_kind = 'scope.contact'
  LOOP
    extracted_name := COALESCE(rec.person, rec.contact_name);
    IF extracted_name IS NULL THEN
      extracted_name := rec.value;
      extracted_name := regexp_replace(extracted_name, '\s*\([^)]*\)', '', 'g');
      extracted_name := regexp_replace(extracted_name, '\s+\S+@\S+', '', 'g');
      extracted_name := trim(extracted_name);
    END IF;

    -- Skip email-only or phone-only values
    IF extracted_name ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN p2_skipped := p2_skipped + 1; CONTINUE; END IF;
    IF extracted_name ~ '^\+?[\d\s\-\.\(\)]+$' THEN p2_skipped := p2_skipped + 1; CONTINUE; END IF;
    IF extracted_name IS NULL OR length(extracted_name) < 2 THEN p2_skipped := p2_skipped + 1; CONTINUE; END IF;

    -- Fuzzy match cascade
    matched_contact_id := NULL;

    SELECT c.id INTO matched_contact_id FROM contacts c WHERE c.name ILIKE extracted_name LIMIT 1;

    IF matched_contact_id IS NULL THEN
      SELECT c.id INTO matched_contact_id FROM contacts c
      WHERE c.name ILIKE '%' || extracted_name || '%'
         OR extracted_name ILIKE '%' || c.name || '%' LIMIT 1;
    END IF;

    IF matched_contact_id IS NULL THEN
      SELECT c.id INTO matched_contact_id FROM contacts c
      WHERE c.company ILIKE '%' || extracted_name || '%' LIMIT 1;
    END IF;

    IF matched_contact_id IS NULL THEN
      SELECT c.id INTO matched_contact_id FROM contacts c
      WHERE EXISTS (
        SELECT 1 FROM unnest(c.aliases) AS alias
        WHERE alias ILIKE '%' || extracted_name || '%'
           OR extracted_name ILIKE '%' || alias || '%'
      ) LIMIT 1;
    END IF;

    IF matched_contact_id IS NULL THEN
      placeholder_phone := '+1000000' || lpad(placeholder_seq::text, 4, '0');
      placeholder_seq := placeholder_seq + 1;

      new_trade := CASE
        WHEN rec.feature ILIKE '%tile%' THEN 'tile'
        WHEN rec.feature ILIKE '%cabinetry%' THEN 'cabinetry'
        WHEN rec.feature ILIKE '%lumber%' THEN 'lumber'
        WHEN rec.feature ILIKE '%windows%' THEN 'windows'
        ELSE NULL
      END;

      INSERT INTO contacts (phone, name, contact_type, trade, email, source, created_at, updated_at)
      VALUES (
        placeholder_phone, extracted_name,
        CASE
          WHEN rec.feature ILIKE '%homeowner%' OR rec.feature = 'owner' THEN 'client'
          WHEN rec.feature ILIKE '%architect%' OR rec.feature ILIKE '%designer%' THEN 'professional'
          WHEN rec.feature ILIKE '%vendor%' THEN 'subcontractor'
          ELSE 'other'
        END,
        new_trade, rec.email, 'correspondent_promotion', now(), now()
      )
      RETURNING id INTO new_contact_id;

      matched_contact_id := new_contact_id;
      p2_created := p2_created + 1;

      INSERT INTO project_contacts_promotion_log
        (inserted_by, batch_id, contact_id, project_id, is_active, method, notes)
      VALUES ('wp_a_worker', batch_id, matched_contact_id, rec.project_id, true,
         'contact_created',
         'New from scope.contact.' || rec.feature || ' val="' || left(rec.value, 100) || '" ph=' || placeholder_phone);
    END IF;

    INSERT INTO project_contacts (contact_id, project_id, role, trade, is_active, source, created_at, updated_at)
    VALUES (
      matched_contact_id, rec.project_id,
      CASE
        WHEN rec.feature ILIKE '%homeowner%' OR rec.feature = 'owner' THEN 'homeowner'
        WHEN rec.feature ILIKE '%architect%' THEN 'architect'
        WHEN rec.feature ILIKE '%designer%' THEN 'plan_designer'
        WHEN rec.feature ILIKE '%vendor.tile%' THEN 'tile'
        WHEN rec.feature ILIKE '%vendor.cabinetry%' THEN 'cabinetry'
        WHEN rec.feature ILIKE '%vendor.lumber%' THEN 'lumber'
        WHEN rec.feature ILIKE '%vendor.windows%' THEN 'windows'
        ELSE rec.feature
      END,
      CASE
        WHEN rec.feature ILIKE '%tile%' THEN 'tile'
        WHEN rec.feature ILIKE '%cabinetry%' THEN 'cabinetry'
        WHEN rec.feature ILIKE '%lumber%' THEN 'lumber'
        WHEN rec.feature ILIKE '%windows%' THEN 'windows'
        WHEN rec.feature ILIKE '%architect%' THEN 'architecture'
        ELSE NULL
      END,
      true, 'correspondent_promotion', now(), now()
    )
    ON CONFLICT (contact_id, project_id) DO NOTHING;

    IF FOUND THEN
      p2_promoted := p2_promoted + 1;
      INSERT INTO project_contacts_promotion_log
        (inserted_by, batch_id, contact_id, project_id, is_active, method, notes)
      VALUES ('wp_a_worker', batch_id, matched_contact_id, rec.project_id, true,
         'correspondent_promoted', 'scope.contact.' || rec.feature || ' name="' || extracted_name || '"');
    ELSE
      p2_skipped := p2_skipped + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'Pass2: promoted=% created=% skipped=%', p2_promoted, p2_created, p2_skipped;
  RAISE NOTICE 'TOTAL: p1_promoted=% p2_promoted=% contacts_created=%', p1_promoted, p2_promoted, p1_created + p2_created;
END $$;

COMMIT;
