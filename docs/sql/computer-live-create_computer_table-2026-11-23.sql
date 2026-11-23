-- Captured from the live database on 2026-11-23 (md5 7f804511bc76a0228d7158c544e1fdec). The committed computer-normie.sql does not match what is live; this is the true pre-join-create text.
--
-- Committed with step 3, slice A: docs/sql/join-create-rollback.sql restores
-- create_computer_table from THIS text (byte for byte), and
-- join-create-precheck.sql accepts its md5. It is a record of the live
-- function, not a migration: running it changes nothing that isn't already
-- live. What the live catalog reported for public.create_computer_table(text,
-- text) on 2026-11-23:
--   md5(prosrc)  7f804511bc76a0228d7158c544e1fdec (CRLF, 1258 chars)
--                71f74319e76ab1cfe2a25d39e1d9d7ec (the same text with LF, 1215 chars)
--   SECURITY DEFINER, SET search_path TO 'public', RETURNS TABLE(table_id uuid, code text)
--   EXECUTE: authenticated and service_role only (not PUBLIC, not anon)
-- It is computer-normie.sql's function with that file's comments missing:
-- the two differ ONLY in comments (same levels, messages, checks, inserts,
-- return shape, settings).
-- The body below (between the $function$ markers) hashes to the CRLF md5
-- above when this file keeps CRLF line endings. Below is pg_get_functiondef's
-- output, unchanged.

CREATE OR REPLACE FUNCTION public.create_computer_table(p_level text, p_code text)
 RETURNS TABLE(table_id uuid, code text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_caller uuid := auth.uid();
  v_computer uuid;
  v_table_id uuid;
  v_code text;
begin
  if v_caller is null then
    raise exception 'You must be logged in to start a table.';
  end if;

  if p_level is null or p_level not in ('easy', 'casual', 'medium', 'hard') then
    raise exception 'Unknown computer level "%": choose easy, casual, medium or hard.', coalesce(p_level, '');
  end if;

  select ca.user_id
  into v_computer
  from public.computer_accounts ca
  where ca.level = p_level;

  if v_computer is null then
    raise exception 'The % computer is not set up yet.', p_level;
  end if;

  if v_computer = v_caller then
    raise exception 'A computer account cannot start a computer table.';
  end if;

  insert into public.tables (code, created_by, is_public, is_muggins, max_players, computer_level)
  values (p_code, v_caller, false, false, 2, p_level)
  returning tables.id, tables.code into v_table_id, v_code;

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_caller);

  insert into public.table_members (table_id, user_id)
  values (v_table_id, v_computer);

  table_id := v_table_id;
  code := v_code;
  return next;
end;
$function$
