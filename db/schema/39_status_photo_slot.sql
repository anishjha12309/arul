-- Where the clip's own photo frame sits, so the app can lay the user's photo over it: {left, top, size, shape}, left
-- and size as fractions of the clip's width, top of its height, the slot a square of side size × width. NULL = no
-- frame (a CMS upload) -> the app falls back to its own corner avatar. build-catalog ships it through SELECT *.
alter table statuses add column if not exists photo_slot jsonb;

-- CASE, not AND: Postgres may evaluate AND in any order, and the casts must only see numbers. ELSE false, because a
-- CHECK that evaluates to NULL passes.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'statuses_photo_slot_check'
  ) then
    alter table statuses add constraint statuses_photo_slot_check check (
      photo_slot is null
      or case
           when jsonb_typeof(photo_slot) = 'object'
            and jsonb_typeof(photo_slot -> 'left') = 'number'
            and jsonb_typeof(photo_slot -> 'top') = 'number'
            and jsonb_typeof(photo_slot -> 'size') = 'number'
            and jsonb_typeof(photo_slot -> 'shape') = 'string'
           then (photo_slot ->> 'left')::numeric between 0 and 1
            and (photo_slot ->> 'top')::numeric between 0 and 1
            and (photo_slot ->> 'size')::numeric between 0 and 1
            and photo_slot ->> 'shape' in ('circle', 'soft_circle', 'pin', 'soft_square', 'square')
           else false
         end
    );
  end if;
end
$$;
