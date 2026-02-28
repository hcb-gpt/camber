-- Drop the old integer-parameter overload that doesn't have the trusted_cpa_write fix
DROP FUNCTION IF EXISTS public.derive_affinity_weights(uuid, integer, integer, numeric, boolean);;
