--
-- PostgreSQL database dump
--


-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11 (Postgres.app)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: private; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA private;


ALTER SCHEMA private OWNER TO postgres;

--
-- Name: audit_change(); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.audit_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare oldj jsonb; newj jsonb; key text; uid uuid; eid uuid;
begin
 oldj:=case when TG_OP='INSERT' then '{}'::jsonb else to_jsonb(OLD) end;
 newj:=to_jsonb(NEW); uid:=(newj->>'unit_id')::uuid; eid:=coalesce(newj->>'id',newj->>'transaction_id',newj->>'unit_id')::uuid;
 for key in select jsonb_object_keys(newj) loop
 if newj->key is distinct from oldj->key then
 insert into public.audit_log(unit_id,actor_id,entity,entity_id,field,old_value,new_value,reason)
 values(uid,auth.uid(),TG_TABLE_NAME,eid,key,oldj->key,newj->key,nullif(current_setting('app.change_reason',true),''));
 end if; end loop;
 return NEW;
end $$;


ALTER FUNCTION private.audit_change() OWNER TO postgres;

--
-- Name: can_access(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.can_access(u uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid());
$$;


ALTER FUNCTION private.can_access(u uuid) OWNER TO postgres;

--
-- Name: can_view_physical(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.can_view_physical(p_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
 select exists(select 1 from public.accounts where physical_account_id=p_id) and not exists(select 1 from public.accounts where physical_account_id=p_id and not private.can_access(unit_id));
$$;


ALTER FUNCTION private.can_view_physical(p_id uuid) OWNER TO postgres;

--
-- Name: require_admin(uuid); Type: FUNCTION; Schema: private; Owner: postgres
--

CREATE FUNCTION private.require_admin(u uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if auth.role()='service_role' then return; end if;
 if not exists(select 1 from public.memberships where unit_id=u and user_id=auth.uid() and role='admin') then raise exception 'Administrative access required' using errcode='42501'; end if;
end $$;


ALTER FUNCTION private.require_admin(u uuid) OWNER TO postgres;

--
-- Name: agreement_sequences; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.agreement_sequences (
    year integer NOT NULL,
    value bigint NOT NULL
);


ALTER TABLE private.agreement_sequences OWNER TO postgres;

--
-- Name: annual_sequences; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.annual_sequences (
    year integer NOT NULL,
    value integer NOT NULL
);


ALTER TABLE private.annual_sequences OWNER TO postgres;

--
-- Name: mutation_requests; Type: TABLE; Schema: private; Owner: postgres
--

CREATE TABLE private.mutation_requests (
    unit_id uuid NOT NULL,
    request_id uuid NOT NULL,
    payload_hash text NOT NULL,
    transaction_id uuid NOT NULL
);


ALTER TABLE private.mutation_requests OWNER TO postgres;

--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.audit_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    unit_id uuid NOT NULL,
    actor_id uuid,
    entity text NOT NULL,
    entity_id uuid NOT NULL,
    field text NOT NULL,
    old_value jsonb,
    new_value jsonb,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.audit_log OWNER TO postgres;

--
-- Name: business_units; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.business_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    CONSTRAINT business_units_code_check CHECK ((code = ANY (ARRAY['BOFT'::text, 'TOOLTAG'::text])))
);


ALTER TABLE public.business_units OWNER TO postgres;

--
-- Name: memberships; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.memberships (
    unit_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    CONSTRAINT memberships_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'viewer'::text])))
);


ALTER TABLE public.memberships OWNER TO postgres;

--
-- Name: unit_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.unit_settings (
    unit_id uuid NOT NULL,
    timezone text DEFAULT 'America/Denver'::text NOT NULL,
    quote_valid_days integer DEFAULT 7 NOT NULL,
    quote_reminder_days integer DEFAULT 2 NOT NULL,
    completion_days integer DEFAULT 3 NOT NULL,
    refund_days integer DEFAULT 14 NOT NULL,
    drive_root_id text,
    boft_url text,
    annual_vehicle_method text DEFAULT 'Fuel'::text NOT NULL,
    mileage_rate numeric(10,4),
    zelle_email text,
    venmo_handle text,
    payment_account_id uuid,
    CONSTRAINT unit_settings_annual_vehicle_method_check CHECK ((annual_vehicle_method = ANY (ARRAY['Fuel'::text, 'Mileage'::text]))),
    CONSTRAINT unit_settings_completion_days_check CHECK ((completion_days = 3)),
    CONSTRAINT unit_settings_mileage_rate_check CHECK ((mileage_rate >= (0)::numeric)),
    CONSTRAINT unit_settings_quote_reminder_days_check CHECK ((quote_reminder_days = 2)),
    CONSTRAINT unit_settings_quote_valid_days_check CHECK ((quote_valid_days = 7)),
    CONSTRAINT unit_settings_refund_days_check CHECK ((refund_days = 14))
);


ALTER TABLE public.unit_settings OWNER TO postgres;

