-- Run this entire script in Supabase SQL Editor on a fresh project.
create extension if not exists pgcrypto;
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 name text not null default '',
 role text not null default 'moderator' check(role in ('admin','moderator')),
 created_at timestamptz not null default now()
);
create table public.designs (
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 created_at timestamptz not null default now()
);
create table public.variants (
 id uuid primary key default gen_random_uuid(),
 design_id uuid not null references public.designs(id) on delete restrict,
 color text not null,
 size text not null,
 sku text unique,
 price numeric(12,2) not null default 0 check(price>=0),
 on_hand integer not null default 0 check(on_hand>=0),
 reserved integer not null default 0 check(reserved>=0 and reserved<=on_hand),
 active boolean not null default true,
 created_at timestamptz not null default now(),
 unique(design_id,color,size)
);
create table public.orders (
 id uuid primary key default gen_random_uuid(),
 customer_name text not null,
 customer_phone text,
 address text,
 notes text,
 status text not null default 'reserved' check(status in ('reserved','completed','cancelled')),
 created_by uuid not null references public.profiles(id),
 total numeric(12,2) not null default 0,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table public.order_items (
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.orders(id) on delete restrict,
 variant_id uuid not null references public.variants(id),
 quantity integer not null check(quantity>0),
 unit_price numeric(12,2) not null check(unit_price>=0),
 unique(order_id,variant_id)
);
create table public.stock_movements (
 id bigint generated always as identity primary key,
 variant_id uuid not null references public.variants(id),
 change_on_hand integer not null default 0,
 change_reserved integer not null default 0,
 reason text not null,
 order_id uuid references public.orders(id),
 actor uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create index on public.orders(created_at desc);
create index on public.order_items(order_id);
create index on public.variants(design_id);
create index on public.stock_movements(variant_id,created_at desc);

-- Explicitly insert users as moderators. An admin promotes them via SQL.
create or replace function public.make_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,name,role) values(new.id,coalesce(new.raw_user_meta_data->>'name',''),'moderator');
 return new;
end $$;
create trigger after_signup after insert on auth.users for each row execute function public.make_profile();

create or replace function public.is_staff() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=(select auth.uid()) and role in ('admin','moderator'))
$$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=(select auth.uid()) and role='admin')
$$;

alter table public.profiles enable row level security;
alter table public.designs enable row level security;
alter table public.variants enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.stock_movements enable row level security;
create policy profile_read on public.profiles for select to authenticated using(public.is_staff());
create policy design_read on public.designs for select to authenticated using(public.is_staff());
create policy variant_read on public.variants for select to authenticated using(public.is_staff());
create policy order_read on public.orders for select to authenticated using(public.is_staff());
create policy item_read on public.order_items for select to authenticated using(public.is_staff());
create policy movement_read on public.stock_movements for select to authenticated using(public.is_admin());
-- No direct writes allowed. All changes go through checked atomic RPC functions.

create or replace function public.add_design(p_name text) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not public.is_admin() then raise exception 'Admin only'; end if;
 if length(trim(coalesce(p_name,'')))=0 then raise exception 'Design required'; end if;
 insert into public.designs(name) values(trim(p_name)) returning id into result;
 return result;
end $$;

create or replace function public.add_variant(p_design uuid,p_color text,p_size text,p_price numeric,p_initial integer default 0)
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not public.is_admin() then raise exception 'Admin only'; end if;
 if length(trim(coalesce(p_color,'')))=0 or length(trim(coalesce(p_size,'')))=0 or p_price<0 or p_initial<0 then raise exception 'Invalid variant input'; end if;
 insert into public.variants(design_id,color,size,price,on_hand)
 values(p_design,trim(p_color),trim(p_size),p_price,p_initial) returning id into result;
 if p_initial>0 then
 insert into public.stock_movements(variant_id,change_on_hand,reason,actor) values(result,p_initial,'initial_stock',auth.uid());
 end if;
 return result;
end $$;

create or replace function public.adjust_stock(p_variant uuid,p_change integer)
returns void language plpgsql security definer set search_path='' as $$
declare v public.variants%rowtype;
begin
 if not public.is_admin() then raise exception 'Admin only'; end if;
 if p_change=0 then raise exception 'Change cannot be zero'; end if;
 select * into v from public.variants where id=p_variant for update;
 if not found then raise exception 'Variant not found'; end if;
 if v.on_hand+p_change<v.reserved then raise exception 'Not enough unreserved stock'; end if;
 update public.variants set on_hand=on_hand+p_change where id=p_variant;
 insert into public.stock_movements(variant_id,change_on_hand,reason,actor) values(p_variant,p_change,'manual_adjustment',auth.uid());
end $$;

-- Entire order + all reservations take effect together, or none do.
-- JSON input: [{"variant_id":"uuid","quantity":2}, ...]
create or replace function public.create_order(p_customer text,p_phone text,p_address text,p_notes text,p_items jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare entry record; v public.variants%rowtype; new_order uuid; grand_total numeric(12,2):=0; count_items integer; v_count integer;
begin
 if not public.is_staff() then raise exception 'Not authorized'; end if;
 if length(trim(coalesce(p_customer,'')))=0 then raise exception 'Customer name required'; end if;
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>100 then raise exception 'Invalid order items'; end if;
 -- Reject duplicates; process variants in deterministic UUID order to avoid deadlocks.
 select count(*),count(distinct item->>'variant_id') into count_items, v_count from jsonb_array_elements(p_items) item;
 if count_items <> v_count then raise exception 'Duplicate variants in order'; end if;
 insert into public.orders(customer_name,customer_phone,address,notes,created_by)
 values(trim(p_customer),nullif(trim(coalesce(p_phone,'')),''),nullif(trim(coalesce(p_address,'')),''),nullif(trim(coalesce(p_notes,'')),''),auth.uid()) returning id into new_order;
 for entry in select (item->>'variant_id')::uuid as vid,(item->>'quantity')::integer as qty
              from jsonb_array_elements(p_items) item order by (item->>'variant_id')::uuid loop
   if entry.qty is null or entry.qty<=0 then raise exception 'Quantity must be positive'; end if;
   select * into v from public.variants where id=entry.vid and active for update;
   if not found then raise exception 'Product unavailable'; end if;
   if v.on_hand-v.reserved<entry.qty then raise exception 'Insufficient stock for % / % (available %)',v.color,v.size,(v.on_hand-v.reserved); end if;
   update public.variants set reserved=reserved+entry.qty where id=entry.vid;
   insert into public.order_items(order_id,variant_id,quantity,unit_price) values(new_order,entry.vid,entry.qty,v.price);
   insert into public.stock_movements(variant_id,change_reserved,reason,order_id,actor) values(entry.vid,entry.qty,'order_reserved',new_order,auth.uid());
   grand_total:=grand_total+entry.qty*v.price;
 end loop;
 update public.orders set total=grand_total where id=new_order;
 return new_order;
end $$;

create or replace function public.change_order_status(p_order uuid,p_status text)
returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype; item record;
begin
 if not public.is_staff() then raise exception 'Not authorized'; end if;
 if p_status not in ('completed','cancelled') then raise exception 'Invalid transition'; end if;
 select * into o from public.orders where id=p_order for update;
 if not found then raise exception 'Order not found'; end if;
 if o.status<>'reserved' then raise exception 'Only reserved orders can change status'; end if;
 for item in select variant_id,quantity from public.order_items where order_id=p_order order by variant_id loop
   perform 1 from public.variants where id=item.variant_id for update;
   if p_status='cancelled' then
     update public.variants set reserved=reserved-item.quantity where id=item.variant_id;
     insert into public.stock_movements(variant_id,change_reserved,reason,order_id,actor)
     values(item.variant_id,-item.quantity,'order_cancelled',p_order,auth.uid());
   else
     update public.variants set reserved=reserved-item.quantity,on_hand=on_hand-item.quantity where id=item.variant_id;
     insert into public.stock_movements(variant_id,change_on_hand,change_reserved,reason,order_id,actor)
     values(item.variant_id,-item.quantity,-item.quantity,'order_completed',p_order,auth.uid());
   end if;
 end loop;
 update public.orders set status=p_status,updated_at=now() where id=p_order;
end $$;

-- Minimal privileges: staff reads via RLS; writes only through RPC.
revoke all on public.profiles,public.designs,public.variants,public.orders,public.order_items,public.stock_movements from anon,authenticated;
grant select on public.profiles,public.designs,public.variants,public.orders,public.order_items,public.stock_movements to authenticated;
revoke all on function public.add_design(text),public.add_variant(uuid,text,text,numeric,integer),public.adjust_stock(uuid,integer),public.create_order(text,text,text,text,jsonb),public.change_order_status(uuid,text) from public,anon;
grant execute on function public.add_design(text),public.add_variant(uuid,text,text,numeric,integer),public.adjust_stock(uuid,integer),public.create_order(text,text,text,text,jsonb),public.change_order_status(uuid,text) to authenticated;

-- After signing up your OWN admin user, run this separately with their email:
-- update public.profiles set role='admin' where id=(select id from auth.users where email='YOUR_EMAIL@example.com');
-- IMPORTANT: Disable public signup in Supabase Auth settings after staff accounts are provisioned.
