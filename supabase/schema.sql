-- =====================================================================
-- ZOKENT TOKO - skema Supabase (proyek baru)
-- Jalankan SELURUH file ini di Supabase > SQL Editor > New query > Run.
-- Peran: owner (kendali penuh) dan cashier (hanya kasir).
-- Semua perubahan data sensitif lewat fungsi (RPC) agar atomik dan aman.
-- =====================================================================

-- ---------- 1. TABEL ----------

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  role        text not null default 'cashier' check (role in ('owner', 'cashier')),
  is_active   boolean not null default false,
  created_at  timestamptz not null default now()
);

create table if not exists public.categories (
  id          bigint generated always as identity primary key,
  name        text not null unique check (length(trim(name)) > 0),
  created_at  timestamptz not null default now()
);

create table if not exists public.products (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null check (length(trim(name)) > 0),
  barcode              text unique,
  category_id          bigint references public.categories(id) on delete set null,
  buy_price            integer not null default 0 check (buy_price >= 0),
  sell_price           integer not null check (sell_price >= 0),
  stock                integer not null default 0 check (stock >= 0),
  low_stock_threshold  integer not null default 5 check (low_stock_threshold >= 0),
  unit                 text not null default 'pcs',
  image_url            text,
  is_active            boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists products_name_idx on public.products (lower(name));
create index if not exists products_category_idx on public.products (category_id);

create table if not exists public.orders (
  id                uuid primary key default gen_random_uuid(),
  order_no          text not null unique,
  source            text not null check (source in ('online', 'pos')),
  status            text not null default 'new'
                    check (status in ('new', 'confirmed', 'completed', 'cancelled')),
  customer_name     text not null default '',
  customer_phone    text not null default '',
  customer_address  text not null default '',
  note              text not null default '',
  total             integer not null default 0 check (total >= 0),
  paid              integer not null default 0 check (paid >= 0),
  change_amount     integer not null default 0 check (change_amount >= 0),
  payment_method    text not null default 'cash' check (payment_method in ('cash', 'qris', 'transfer')),
  cashier_id        uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now()
);
create index if not exists orders_created_idx on public.orders (created_at desc);
create index if not exists orders_status_idx on public.orders (status);

create table if not exists public.order_items (
  id            bigint generated always as identity primary key,
  order_id      uuid not null references public.orders(id) on delete cascade,
  product_id    uuid references public.products(id) on delete set null,
  product_name  text not null,
  unit_price    integer not null check (unit_price >= 0),
  buy_price     integer not null default 0 check (buy_price >= 0),
  qty           integer not null check (qty > 0),
  subtotal      integer not null check (subtotal >= 0)
);
create index if not exists order_items_order_idx on public.order_items (order_id);
create index if not exists order_items_product_idx on public.order_items (product_id);

create table if not exists public.stock_movements (
  id            bigint generated always as identity primary key,
  product_id    uuid not null references public.products(id) on delete cascade,
  change        integer not null check (change <> 0),
  reason        text not null check (reason in ('sale_pos', 'sale_online', 'cancel', 'restock', 'adjustment')),
  reference_id  uuid,
  created_by    uuid references auth.users(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists stock_movements_product_idx on public.stock_movements (product_id, created_at desc);

-- ---------- 2. FUNGSI BANTU ----------

create or replace function public.current_role_name()
returns text
language sql stable security definer set search_path = public
as $$
  select role from public.profiles where id = auth.uid() and is_active = true;
$$;

create or replace function public.is_owner()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_role_name() = 'owner', false);
$$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.current_role_name() in ('owner', 'cashier'), false);
$$;

create sequence if not exists public.order_no_seq;

create or replace function public.next_order_no(p_prefix text)
returns text
language sql security definer set search_path = public
as $$
  select p_prefix || '-' || to_char(now() at time zone 'Asia/Jakarta', 'YYMMDD')
         || '-' || lpad(nextval('public.order_no_seq')::text, 5, '0');
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists products_touch_updated_at on public.products;
create trigger products_touch_updated_at
  before update on public.products
  for each row execute function public.touch_updated_at();

-- Akun baru dari Authentication > Users otomatis dapat profil NONAKTIF (cashier).
-- Owner mengaktifkannya lewat dasbor admin. Owner pertama diatur manual (lihat README).
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role, is_active)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)), 'cashier', false)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 3. VIEW PUBLIK (tanpa harga beli) ----------

create or replace view public.products_public
with (security_barrier = true) as
  select id, name, barcode, category_id, sell_price, stock, unit, image_url
  from public.products
  where is_active;

-- ---------- 4. FUNGSI TRANSAKSI (RPC) ----------

-- 4a. Pesanan online dari pelanggan (boleh tanpa login). Harga selalu dari database.
create or replace function public.create_online_order(
  p_customer_name    text,
  p_customer_phone   text,
  p_customer_address text,
  p_note             text,
  p_items            jsonb
)
returns table (o_id uuid, o_order_no text, o_total integer)
language plpgsql security definer set search_path = public
as $$
declare
  v_order_id uuid;
  v_order_no text;
  v_total    integer := 0;
  v_item     jsonb;
  v_qty      integer;
  v_prod     record;
begin
  if coalesce(trim(p_customer_name), '') = '' then
    raise exception 'Nama pelanggan wajib diisi';
  end if;
  if coalesce(trim(p_customer_phone), '') = '' then
    raise exception 'Nomor WhatsApp wajib diisi';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'Keranjang kosong atau terlalu besar';
  end if;

  v_order_no := public.next_order_no('ON');

  insert into public.orders (order_no, source, status, customer_name, customer_phone,
                             customer_address, note, total, payment_method)
  values (v_order_no, 'online', 'new',
          left(trim(p_customer_name), 100), left(trim(p_customer_phone), 30),
          left(coalesce(p_customer_address, ''), 300), left(coalesce(p_note, ''), 300),
          0, 'transfer')
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty < 1 or v_qty > 999 then
      raise exception 'Jumlah produk tidak valid';
    end if;

    select id, name, sell_price, buy_price, stock
      into v_prod
      from public.products
     where id = (v_item ->> 'product_id')::uuid and is_active;
    if not found then
      raise exception 'Ada produk yang sudah tidak tersedia';
    end if;
    if v_prod.stock < v_qty then
      raise exception 'Stok % tidak cukup (sisa %)', v_prod.name, v_prod.stock;
    end if;

    insert into public.order_items (order_id, product_id, product_name, unit_price, buy_price, qty, subtotal)
    values (v_order_id, v_prod.id, v_prod.name, v_prod.sell_price, v_prod.buy_price, v_qty,
            v_prod.sell_price * v_qty);
    v_total := v_total + v_prod.sell_price * v_qty;
  end loop;

  update public.orders set total = v_total where id = v_order_id;

  return query select v_order_id, v_order_no, v_total;
end;
$$;

-- 4b. Penjualan kasir (owner atau cashier aktif). Atomik: stok berkurang dalam transaksi yang sama.
create or replace function public.create_pos_sale(
  p_items          jsonb,
  p_paid           integer,
  p_payment_method text default 'cash'
)
returns table (o_id uuid, o_order_no text, o_total integer, o_paid integer, o_change integer)
language plpgsql security definer set search_path = public
as $$
declare
  v_order_id uuid;
  v_order_no text;
  v_total    integer := 0;
  v_paid     integer;
  v_change   integer;
  v_item     jsonb;
  v_qty      integer;
  v_prod     record;
begin
  if not public.is_staff() then
    raise exception 'Akun Anda tidak punya akses kasir';
  end if;
  if p_payment_method not in ('cash', 'qris', 'transfer') then
    raise exception 'Metode pembayaran tidak valid';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 100 then
    raise exception 'Keranjang kosong atau terlalu besar';
  end if;

  v_order_no := public.next_order_no('POS');

  insert into public.orders (order_no, source, status, total, paid, change_amount, payment_method, cashier_id)
  values (v_order_no, 'pos', 'completed', 0, 0, 0, p_payment_method, auth.uid())
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item ->> 'qty')::integer;
    if v_qty is null or v_qty < 1 or v_qty > 999 then
      raise exception 'Jumlah produk tidak valid';
    end if;

    select id, name, sell_price, buy_price, stock
      into v_prod
      from public.products
     where id = (v_item ->> 'product_id')::uuid and is_active
       for update;
    if not found then
      raise exception 'Ada produk yang tidak ditemukan atau nonaktif';
    end if;
    if v_prod.stock < v_qty then
      raise exception 'Stok % tidak cukup (sisa %)', v_prod.name, v_prod.stock;
    end if;

    update public.products set stock = stock - v_qty where id = v_prod.id;

    insert into public.order_items (order_id, product_id, product_name, unit_price, buy_price, qty, subtotal)
    values (v_order_id, v_prod.id, v_prod.name, v_prod.sell_price, v_prod.buy_price, v_qty,
            v_prod.sell_price * v_qty);

    insert into public.stock_movements (product_id, change, reason, reference_id, created_by)
    values (v_prod.id, -v_qty, 'sale_pos', v_order_id, auth.uid());

    v_total := v_total + v_prod.sell_price * v_qty;
  end loop;

  if p_payment_method = 'cash' then
    if p_paid is null or p_paid < v_total then
      raise exception 'Uang bayar kurang dari total';
    end if;
    v_paid := p_paid;
  else
    v_paid := v_total;
  end if;
  v_change := v_paid - v_total;

  update public.orders
     set total = v_total, paid = v_paid, change_amount = v_change
   where id = v_order_id;

  return query select v_order_id, v_order_no, v_total, v_paid, v_change;
end;
$$;

-- 4c. Owner mengubah status pesanan online. Stok berkurang saat dikonfirmasi, kembali saat dibatalkan.
create or replace function public.set_order_status(p_order_id uuid, p_status text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_item  record;
begin
  if not public.is_owner() then
    raise exception 'Hanya owner yang boleh mengubah status pesanan';
  end if;
  if p_status not in ('confirmed', 'completed', 'cancelled') then
    raise exception 'Status tidak valid';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Pesanan tidak ditemukan';
  end if;
  if v_order.source <> 'online' then
    raise exception 'Hanya pesanan online yang bisa diubah statusnya';
  end if;

  if v_order.status = 'new' and p_status = 'confirmed' then
    for v_item in select product_id, product_name, qty from public.order_items where order_id = p_order_id loop
      if v_item.product_id is null then
        raise exception 'Produk % sudah dihapus dari katalog', v_item.product_name;
      end if;
      update public.products set stock = stock - v_item.qty
       where id = v_item.product_id and stock >= v_item.qty;
      if not found then
        raise exception 'Stok % tidak cukup untuk dikonfirmasi', v_item.product_name;
      end if;
      insert into public.stock_movements (product_id, change, reason, reference_id, created_by)
      values (v_item.product_id, -v_item.qty, 'sale_online', p_order_id, auth.uid());
    end loop;

  elsif v_order.status = 'new' and p_status = 'cancelled' then
    null; -- stok belum pernah dikurangi

  elsif v_order.status = 'confirmed' and p_status = 'completed' then
    null;

  elsif v_order.status = 'confirmed' and p_status = 'cancelled' then
    for v_item in select product_id, qty from public.order_items where order_id = p_order_id loop
      if v_item.product_id is not null then
        update public.products set stock = stock + v_item.qty where id = v_item.product_id;
        insert into public.stock_movements (product_id, change, reason, reference_id, created_by)
        values (v_item.product_id, v_item.qty, 'cancel', p_order_id, auth.uid());
      end if;
    end loop;

  else
    raise exception 'Perubahan status % ke % tidak diizinkan', v_order.status, p_status;
  end if;

  update public.orders set status = p_status where id = p_order_id;
end;
$$;

-- 4d. Owner menambah atau mengoreksi stok.
create or replace function public.adjust_stock(p_product_id uuid, p_change integer, p_reason text)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_new_stock integer;
begin
  if not public.is_owner() then
    raise exception 'Hanya owner yang boleh mengubah stok';
  end if;
  if p_reason not in ('restock', 'adjustment') then
    raise exception 'Alasan tidak valid';
  end if;
  if p_change is null or p_change = 0 then
    raise exception 'Jumlah perubahan tidak boleh nol';
  end if;

  update public.products set stock = stock + p_change
   where id = p_product_id and stock + p_change >= 0
  returning stock into v_new_stock;
  if not found then
    raise exception 'Produk tidak ditemukan atau stok akan menjadi negatif';
  end if;

  insert into public.stock_movements (product_id, change, reason, created_by)
  values (p_product_id, p_change, p_reason, auth.uid());

  return v_new_stock;
end;
$$;

-- ---------- 5. ROW LEVEL SECURITY ----------

alter table public.profiles         enable row level security;
alter table public.categories       enable row level security;
alter table public.products         enable row level security;
alter table public.orders           enable row level security;
alter table public.order_items      enable row level security;
alter table public.stock_movements  enable row level security;

-- profiles: user lihat profil sendiri; owner kelola semua
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_owner());

drop policy if exists profiles_owner_update on public.profiles;
create policy profiles_owner_update on public.profiles
  for update to authenticated
  using (public.is_owner()) with check (public.is_owner());

drop policy if exists profiles_owner_delete on public.profiles;
create policy profiles_owner_delete on public.profiles
  for delete to authenticated
  using (public.is_owner() and id <> auth.uid());

-- categories: publik baca, owner ubah
drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories
  for select to anon, authenticated using (true);

drop policy if exists categories_owner_write on public.categories;
create policy categories_owner_write on public.categories
  for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- products: tabel penuh (ada harga beli) hanya untuk owner. Publik/kasir pakai view products_public.
drop policy if exists products_owner_all on public.products;
create policy products_owner_all on public.products
  for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- orders: owner lihat semua; kasir hanya penjualan POS miliknya. Tidak ada insert langsung (lewat RPC).
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders
  for select to authenticated
  using (public.is_owner() or (public.is_staff() and cashier_id = auth.uid()));

drop policy if exists order_items_select on public.order_items;
create policy order_items_select on public.order_items
  for select to authenticated
  using (exists (
    select 1 from public.orders o
    where o.id = order_items.order_id
      and (public.is_owner() or (public.is_staff() and o.cashier_id = auth.uid()))
  ));

-- stock_movements: hanya owner
drop policy if exists stock_movements_owner_select on public.stock_movements;
create policy stock_movements_owner_select on public.stock_movements
  for select to authenticated using (public.is_owner());

-- ---------- 6. HAK AKSES (GRANT) ----------

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- anon (pengunjung)
grant usage on schema public to anon, authenticated;
grant select on public.categories      to anon, authenticated;
grant select on public.products_public to anon, authenticated;
grant execute on function public.create_online_order(text, text, text, text, jsonb) to anon, authenticated;

-- authenticated (owner/cashier; dibatasi lagi oleh RLS dan pengecekan di fungsi)
grant select, update, delete on public.profiles        to authenticated;
grant insert, update, delete on public.categories      to authenticated;
grant select, insert, update, delete on public.products to authenticated;
grant select on public.orders, public.order_items, public.stock_movements to authenticated;
grant execute on function public.create_pos_sale(jsonb, integer, text)        to authenticated;
grant execute on function public.set_order_status(uuid, text)                to authenticated;
grant execute on function public.adjust_stock(uuid, integer, text)            to authenticated;
grant execute on function public.current_role_name()                          to authenticated;
grant execute on function public.is_owner()                                   to authenticated;
grant execute on function public.is_staff()                                   to authenticated;

-- ---------- 7. STORAGE FOTO PRODUK ----------

insert into storage.buckets (id, name, public)
values ('product-images', 'product-images', true)
on conflict (id) do nothing;

drop policy if exists product_images_owner_insert on storage.objects;
create policy product_images_owner_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_owner());

drop policy if exists product_images_owner_update on storage.objects;
create policy product_images_owner_update on storage.objects
  for update to authenticated
  using (bucket_id = 'product-images' and public.is_owner());

drop policy if exists product_images_owner_delete on storage.objects;
create policy product_images_owner_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'product-images' and public.is_owner());
