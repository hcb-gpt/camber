-- Ensure requested active projects are present in selector sources.
UPDATE public.projects
SET status = 'active',
    updated_at = now()
WHERE lower(name) IN ('young residence', 'moss residence');

INSERT INTO public.projects (name, status)
SELECT v.name, 'active'
FROM (VALUES ('Young Residence'), ('Moss Residence')) AS v(name)
WHERE NOT EXISTS (
  SELECT 1
  FROM public.projects p
  WHERE lower(p.name) = lower(v.name)
);

-- Remove deprecated Sittler location variants from the DB.
-- Names seen in production include both legacy and canonical label styles.
DO $$
DECLARE
  target_ids uuid[];
  rec record;
BEGIN
  SELECT COALESCE(array_agg(id), '{}'::uuid[])
  INTO target_ids
  FROM public.projects
  WHERE lower(name) IN (
    'sittler residence (athens)',
    'sittler residence (bishop)',
    'sittler residence (madison)',
    'sittler athens',
    'sittler bishop',
    'sittler madison'
  );

  IF array_length(target_ids, 1) IS NULL THEN
    RAISE NOTICE 'No deprecated Sittler projects found to remove.';
    RETURN;
  END IF;

  -- Defensive guard: block if unexpected composite FK exists.
  IF EXISTS (
    SELECT 1
    FROM pg_constraint con
    JOIN pg_class cls ON cls.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = cls.relnamespace
    WHERE con.contype = 'f'
      AND con.confrelid = 'public.projects'::regclass
      AND array_length(con.conkey, 1) > 1
      AND ns.nspname = 'public'
      AND cls.relname <> 'projects'
  ) THEN
    RAISE EXCEPTION 'Composite FK to public.projects detected; manual cleanup required.';
  END IF;

  -- Clear dependent references for all single-column public FKs to projects.
  FOR rec IN
    SELECT
      ns.nspname AS schema_name,
      cls.relname AS table_name,
      att.attname AS column_name,
      att.attnotnull AS is_not_null
    FROM pg_constraint con
    JOIN pg_class cls ON cls.oid = con.conrelid
    JOIN pg_namespace ns ON ns.oid = cls.relnamespace
    JOIN unnest(con.conkey) WITH ORDINALITY AS ck(attnum, ord) ON TRUE
    JOIN pg_attribute att ON att.attrelid = cls.oid AND att.attnum = ck.attnum
    WHERE con.contype = 'f'
      AND con.confrelid = 'public.projects'::regclass
      AND array_length(con.conkey, 1) = 1
      AND ns.nspname = 'public'
      AND cls.relname <> 'projects'
  LOOP
    IF rec.is_not_null THEN
      EXECUTE format(
        'DELETE FROM %I.%I WHERE %I = ANY($1)',
        rec.schema_name,
        rec.table_name,
        rec.column_name
      ) USING target_ids;
    ELSE
      EXECUTE format(
        'UPDATE %I.%I SET %I = NULL WHERE %I = ANY($1)',
        rec.schema_name,
        rec.table_name,
        rec.column_name,
        rec.column_name
      ) USING target_ids;
    END IF;
  END LOOP;

  DELETE FROM public.projects
  WHERE id = ANY(target_ids);
END;
$$;
