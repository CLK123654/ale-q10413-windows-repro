\set ON_ERROR_STOP on

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'settlement_owner') THEN CREATE ROLE settlement_owner NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'settlement_reader') THEN CREATE ROLE settlement_reader NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'settlement_writer') THEN CREATE ROLE settlement_writer NOLOGIN; END IF;
END
$roles$;

BEGIN;
DROP SCHEMA IF EXISTS settlement CASCADE;
CREATE SCHEMA settlement;

CREATE TABLE settlement.policy AS
SELECT policy_kind,policy_key,policy_value,priority FROM pg_temp.task_policy;
ALTER TABLE settlement.policy ADD PRIMARY KEY(policy_kind,policy_key);

CREATE TABLE settlement.tenant_account AS TABLE raw.raw_tenant_account;
ALTER TABLE settlement.tenant_account ADD PRIMARY KEY(tenant_id);

CREATE TABLE settlement.merchant_profile AS TABLE raw.raw_merchant_profile;
ALTER TABLE settlement.merchant_profile ADD PRIMARY KEY(tenant_id,merchant_id);
ALTER TABLE settlement.merchant_profile ADD FOREIGN KEY(tenant_id) REFERENCES settlement.tenant_account(tenant_id);

CREATE TABLE settlement.reversal_review AS
WITH reversal_input AS (
  SELECT r.*,o.tenant_id AS original_tenant_id,o.entry_type AS original_entry_type,
    o.gross_cents AS original_gross_cents,o.fee_cents AS original_fee_cents,o.net_cents AS original_net_cents
  FROM raw.raw_settlement_ledger r
  LEFT JOIN raw.raw_settlement_ledger o ON o.voucher_id=r.original_voucher_id
  WHERE r.entry_type='reversal'
),
base_reason AS (
  SELECT voucher_id,'cross_tenant_reference'::text AS reason FROM reversal_input WHERE original_tenant_id<>tenant_id
  UNION ALL
  SELECT voucher_id,'reversal_of_reversal' FROM reversal_input WHERE original_tenant_id=tenant_id AND original_entry_type='reversal'
  UNION ALL
  SELECT voucher_id,'amount_mismatch' FROM reversal_input
    WHERE original_tenant_id=tenant_id AND original_entry_type<>'reversal'
      AND (gross_cents<>-original_gross_cents OR fee_cents<>-original_fee_cents OR net_cents<>-original_net_cents)
),
base_valid AS (
  SELECT r.* FROM reversal_input r WHERE NOT EXISTS(SELECT 1 FROM base_reason b WHERE b.voucher_id=r.voucher_id)
),
ranked AS (
  SELECT b.*,row_number() OVER(PARTITION BY tenant_id,original_voucher_id ORDER BY occurred_at_utc,voucher_id) AS reversal_rank
  FROM base_valid b
),
all_reason AS (
  SELECT * FROM base_reason
  UNION ALL
  SELECT voucher_id,'duplicate_reversal' FROM ranked WHERE reversal_rank>1
),
chosen AS (
  SELECT DISTINCT ON(r.voucher_id) r.voucher_id,r.reason,p.policy_value AS expected_sqlstate
  FROM all_reason r JOIN settlement.policy p ON p.policy_kind='reversal_reason' AND p.policy_key=r.reason
  ORDER BY r.voucher_id,p.priority
)
SELECT r.voucher_id,r.tenant_id,r.original_voucher_id,
  CASE WHEN c.reason IS NULL THEN 'valid' ELSE 'rejected' END::text AS check_status,
  COALESCE(c.reason,'amount_mirrors_original')::text AS reason,
  c.expected_sqlstate::text,
  NULL::text AS observed_sqlstate
FROM reversal_input r LEFT JOIN chosen c USING(voucher_id);
ALTER TABLE settlement.reversal_review ADD PRIMARY KEY(voucher_id);

CREATE TABLE settlement.settlement_ledger AS
SELECT l.* FROM raw.raw_settlement_ledger l
JOIN raw.raw_tenant_account t USING(tenant_id)
JOIN raw.raw_merchant_profile m USING(tenant_id,merchant_id)
LEFT JOIN settlement.reversal_review r USING(voucher_id)
WHERE t.tenant_status=(SELECT policy_value FROM settlement.policy WHERE policy_kind='scalar' AND policy_key='active_tenant_status')
  AND EXISTS(SELECT 1 FROM settlement.policy p WHERE p.policy_kind='active_merchant_status' AND p.policy_key=m.merchant_status)
  AND l.entry_status=(SELECT policy_value FROM settlement.policy WHERE policy_kind='scalar' AND policy_key='posted_status')
  AND EXISTS(SELECT 1 FROM settlement.policy p WHERE p.policy_kind='allowed_entry_type' AND p.policy_key=l.entry_type)
  AND l.occurred_at_utc>=(SELECT policy_value::timestamptz FROM settlement.policy WHERE policy_kind='scalar' AND policy_key='report_start_utc')
  AND l.occurred_at_utc<(SELECT policy_value::timestamptz FROM settlement.policy WHERE policy_kind='scalar' AND policy_key='report_end_utc')
  AND (l.entry_type<>'reversal' OR r.check_status='valid');
ALTER TABLE settlement.settlement_ledger ADD PRIMARY KEY(tenant_id,voucher_id);
ALTER TABLE settlement.settlement_ledger ADD FOREIGN KEY(tenant_id,merchant_id) REFERENCES settlement.merchant_profile(tenant_id,merchant_id);
ALTER TABLE settlement.settlement_ledger ADD FOREIGN KEY(tenant_id,original_voucher_id) REFERENCES settlement.settlement_ledger(tenant_id,voucher_id);
ALTER TABLE settlement.settlement_ledger ADD CONSTRAINT reversal_shape CHECK((entry_type='reversal')=(original_voucher_id IS NOT NULL));
CREATE UNIQUE INDEX one_reversal_per_original ON settlement.settlement_ledger(tenant_id,original_voucher_id) WHERE entry_type='reversal';

CREATE OR REPLACE FUNCTION settlement.enforce_reversal_amount()
RETURNS trigger LANGUAGE plpgsql AS $body$
DECLARE original settlement.settlement_ledger%ROWTYPE;
BEGIN
  IF NEW.entry_type<>'reversal' THEN RETURN NEW; END IF;
  SELECT * INTO original FROM settlement.settlement_ledger WHERE tenant_id=NEW.tenant_id AND voucher_id=NEW.original_voucher_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'original voucher unavailable in tenant' USING ERRCODE='23503'; END IF;
  IF original.entry_type='reversal' THEN RAISE EXCEPTION 'reversal cannot reverse a reversal' USING ERRCODE='23514'; END IF;
  IF NEW.gross_cents<>-original.gross_cents OR NEW.fee_cents<>-original.fee_cents OR NEW.net_cents<>-original.net_cents THEN
    RAISE EXCEPTION 'reversal amount mismatch' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END
$body$;
CREATE TRIGGER enforce_reversal_amount BEFORE INSERT OR UPDATE ON settlement.settlement_ledger
FOR EACH ROW EXECUTE FUNCTION settlement.enforce_reversal_amount();

CREATE OR REPLACE FUNCTION settlement.exercise_reversal_constraints()
RETURNS void LANGUAGE plpgsql AS $body$
DECLARE item record;state text;
BEGIN
  FOR item IN
    SELECT raw.* FROM raw.raw_settlement_ledger raw JOIN settlement.reversal_review review USING(voucher_id)
    WHERE review.check_status='rejected' ORDER BY raw.voucher_id
  LOOP
    BEGIN
      INSERT INTO settlement.settlement_ledger VALUES(item.voucher_id,item.tenant_id,item.merchant_id,item.original_voucher_id,item.entry_type,item.entry_status,item.currency,item.gross_cents,item.fee_cents,item.net_cents,item.occurred_at_utc,item.source_event_id);
      state='00000';
      DELETE FROM settlement.settlement_ledger WHERE tenant_id=item.tenant_id AND voucher_id=item.voucher_id;
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS state=RETURNED_SQLSTATE;
    END;
    UPDATE settlement.reversal_review SET observed_sqlstate=state WHERE voucher_id=item.voucher_id;
  END LOOP;
END
$body$;
SELECT settlement.exercise_reversal_constraints();
DROP FUNCTION settlement.exercise_reversal_constraints();

CREATE OR REPLACE FUNCTION settlement.current_tenant()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,settlement AS $body$
  SELECT current_setting((SELECT policy_value FROM settlement.policy WHERE policy_kind='scalar' AND policy_key='tenant_setting'),true)
$body$;

ALTER TABLE settlement.tenant_account ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement.tenant_account FORCE ROW LEVEL SECURITY;
ALTER TABLE settlement.merchant_profile ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement.merchant_profile FORCE ROW LEVEL SECURITY;
ALTER TABLE settlement.settlement_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement.settlement_ledger FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_account_scope ON settlement.tenant_account TO settlement_reader,settlement_writer
  USING(tenant_id=settlement.current_tenant()) WITH CHECK(tenant_id=settlement.current_tenant());
CREATE POLICY merchant_profile_scope ON settlement.merchant_profile TO settlement_reader,settlement_writer
  USING(tenant_id=settlement.current_tenant()) WITH CHECK(tenant_id=settlement.current_tenant());
CREATE POLICY settlement_ledger_scope ON settlement.settlement_ledger TO settlement_reader,settlement_writer
  USING(tenant_id=settlement.current_tenant()) WITH CHECK(tenant_id=settlement.current_tenant());

CREATE VIEW settlement.settlement_export WITH(security_invoker=true) AS
SELECT l.tenant_id,l.merchant_id,m.merchant_name,l.currency,count(*)::integer AS posted_entry_count,
  sum(l.gross_cents)::integer AS gross_cents,sum(l.fee_cents)::integer AS fee_cents,sum(l.net_cents)::integer AS net_cents,
  count(*) FILTER(WHERE l.entry_type='reversal')::integer AS reversed_original_count,
  CASE WHEN sum(l.net_cents)=0 THEN 'ready_zero' ELSE 'ready' END::text AS statement_status
FROM settlement.settlement_ledger l JOIN settlement.merchant_profile m USING(tenant_id,merchant_id)
GROUP BY l.tenant_id,l.merchant_id,m.merchant_name,l.currency;

CREATE TABLE settlement.tenant_access_probe(
  probe_id text PRIMARY KEY,role_name text NOT NULL,tenant_context text,statement_kind text NOT NULL,
  observed_rows integer,observed_sqlstate text
);

CREATE TABLE settlement.database_contract(object_name text,evidence_key text,observed_value text,PRIMARY KEY(object_name,evidence_key));

GRANT USAGE ON SCHEMA settlement TO settlement_reader,settlement_writer;
GRANT SELECT ON settlement.tenant_account,settlement.merchant_profile,settlement.settlement_ledger TO settlement_reader;
GRANT SELECT,INSERT,UPDATE,DELETE ON settlement.tenant_account,settlement.merchant_profile,settlement.settlement_ledger TO settlement_writer;
GRANT SELECT ON settlement.settlement_export TO settlement_reader,settlement_writer;
GRANT EXECUTE ON FUNCTION settlement.current_tenant() TO settlement_reader,settlement_writer;

ALTER SCHEMA settlement OWNER TO settlement_owner;
ALTER TABLE settlement.policy OWNER TO settlement_owner;
ALTER TABLE settlement.tenant_account OWNER TO settlement_owner;
ALTER TABLE settlement.merchant_profile OWNER TO settlement_owner;
ALTER TABLE settlement.reversal_review OWNER TO settlement_owner;
ALTER TABLE settlement.settlement_ledger OWNER TO settlement_owner;
ALTER TABLE settlement.tenant_access_probe OWNER TO settlement_owner;
ALTER TABLE settlement.database_contract OWNER TO settlement_owner;
ALTER VIEW settlement.settlement_export OWNER TO settlement_owner;
ALTER FUNCTION settlement.enforce_reversal_amount() OWNER TO settlement_owner;
ALTER FUNCTION settlement.current_tenant() OWNER TO settlement_owner;
COMMIT;

SELECT tenant_id AS probe_tenant_a FROM raw.raw_tenant_account WHERE tenant_status='active' ORDER BY tenant_id LIMIT 1 \gset
SELECT tenant_id AS probe_tenant_b FROM raw.raw_tenant_account WHERE tenant_status='active' ORDER BY tenant_id OFFSET 1 LIMIT 1 \gset
SELECT merchant_id AS probe_merchant_b FROM raw.raw_merchant_profile WHERE tenant_id=:'probe_tenant_b' AND merchant_status='active' ORDER BY merchant_id LIMIT 1 \gset
SELECT merchant_id AS probe_merchant_a FROM raw.raw_merchant_profile WHERE tenant_id=:'probe_tenant_a' AND merchant_status='active' ORDER BY merchant_id LIMIT 1 \gset

SELECT set_config('app.current_tenant','',false);

SET ROLE settlement_reader;
SELECT set_config('app.current_tenant',:'probe_tenant_a',false);
SELECT count(*) AS probe_rows FROM settlement.settlement_export \gset
RESET ROLE;
INSERT INTO settlement.tenant_access_probe VALUES('P01','settlement_reader',:'probe_tenant_a','select own export',:probe_rows,NULL);

SET ROLE settlement_reader;
SELECT set_config('app.current_tenant',:'probe_tenant_b',false);
SELECT count(*) AS probe_rows FROM settlement.settlement_export \gset
RESET ROLE;
INSERT INTO settlement.tenant_access_probe VALUES('P02','settlement_reader',:'probe_tenant_b','select second tenant export',:probe_rows,NULL);

SET ROLE settlement_reader;
SELECT set_config('app.current_tenant',:'probe_tenant_a',false);
SELECT count(*) AS probe_rows FROM settlement.settlement_ledger WHERE tenant_id=:'probe_tenant_b' \gset
RESET ROLE;
INSERT INTO settlement.tenant_access_probe VALUES('P03','settlement_reader',:'probe_tenant_a','select other tenant ledger',:probe_rows,NULL);

SELECT set_config('app.current_tenant','',false);
SET ROLE settlement_reader;
SELECT count(*) AS probe_rows FROM settlement.settlement_export \gset
RESET ROLE;
INSERT INTO settlement.tenant_access_probe VALUES('P04','settlement_reader',NULL,'select without tenant context',:probe_rows,NULL);

\set ON_ERROR_STOP off
SET ROLE settlement_writer;
SELECT set_config('app.current_tenant',:'probe_tenant_a',false);
INSERT INTO settlement.settlement_ledger VALUES('PROBE-CROSS',:'probe_tenant_b',:'probe_merchant_b',NULL,'sale','posted','EUR',100,3,97,clock_timestamp(),'probe_cross');
\set probe_state :SQLSTATE
RESET ROLE;
\set ON_ERROR_STOP on
INSERT INTO settlement.tenant_access_probe VALUES('P05','settlement_writer',:'probe_tenant_a','insert other tenant ledger',NULL,:'probe_state');

BEGIN;
SET ROLE settlement_writer;
SELECT set_config('app.current_tenant',:'probe_tenant_a',false);
WITH inserted AS (
  INSERT INTO settlement.settlement_ledger VALUES('PROBE-OWN',:'probe_tenant_a',:'probe_merchant_a',NULL,'sale','posted','USD',100,3,97,clock_timestamp(),'probe_own') RETURNING 1
) SELECT count(*) AS probe_rows FROM inserted \gset
RESET ROLE;
ROLLBACK;
INSERT INTO settlement.tenant_access_probe VALUES('P06','settlement_writer',:'probe_tenant_a','insert own tenant then rollback',:probe_rows,NULL);

INSERT INTO settlement.database_contract
SELECT c.relname,'rls_enabled_and_forced',(c.relrowsecurity AND c.relforcerowsecurity)::text
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='settlement' AND c.relname IN('tenant_account','merchant_profile','settlement_ledger');
INSERT INTO settlement.database_contract
SELECT policyname,'using_and_with_check',(qual IS NOT NULL AND with_check IS NOT NULL)::text
FROM pg_policies WHERE schemaname='settlement';
INSERT INTO settlement.database_contract VALUES('settlement_export','security_invoker',(
  SELECT COALESCE('security_invoker=true'=ANY(c.reloptions),false)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='settlement' AND c.relname='settlement_export'
));
INSERT INTO settlement.database_contract VALUES('settlement_policies','policy_count',(
  SELECT count(*)::text FROM pg_policies WHERE schemaname='settlement'
));
