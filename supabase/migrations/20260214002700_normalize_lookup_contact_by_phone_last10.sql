-- Ensure contact lookup follows pipeline phone normalization:
-- digits-only + last-10 matching across both primary and secondary phone fields.
CREATE OR REPLACE FUNCTION public.lookup_contact_by_phone(p_phone text)
RETURNS TABLE (
    contact_id uuid,
    contact_name text,
    contact_company text,
    contact_type text,
    matched_on text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_digits text;
BEGIN
    -- Normalize input to digits only.
    v_digits := regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g');

    -- Return empty if no usable digits.
    IF v_digits = '' OR length(v_digits) < 7 THEN
        RETURN;
    END IF;

    -- Pipeline rule: if longer than 10, compare on last 10.
    IF length(v_digits) > 10 THEN
        v_digits := RIGHT(v_digits, 10);
    END IF;

    -- Match primary phone by exact digits or last-10 digits.
    RETURN QUERY
    SELECT
        c.id,
        c.name,
        c.company,
        c.contact_type,
        'phone'::text
    FROM contacts c
    WHERE c.phone_digits = v_digits
       OR RIGHT(c.phone_digits, 10) = v_digits
    LIMIT 1;

    IF FOUND THEN RETURN; END IF;

    -- Match secondary phone by exact digits or last-10 digits.
    RETURN QUERY
    SELECT
        c.id,
        c.name,
        c.company,
        c.contact_type,
        'secondary_phone'::text
    FROM contacts c
    WHERE c.secondary_phone_digits != ''
      AND (
        c.secondary_phone_digits = v_digits
        OR RIGHT(c.secondary_phone_digits, 10) = v_digits
      )
    LIMIT 1;
END;
$$;
GRANT EXECUTE ON FUNCTION public.lookup_contact_by_phone(text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.lookup_contact_by_phone(text) FROM anon, authenticated;
COMMENT ON FUNCTION public.lookup_contact_by_phone IS
'Lookup contact by normalized phone digits. Uses digits-only matching and last-10 fallback on phone + secondary_phone.';
