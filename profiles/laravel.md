# Stack Profile: laravel

Laravel applications — with or without Sail. Same four sections as
`profiles/generic.md`; only the content is Laravel-specific.

## detect

- `artisan` at the repo root.
- `composer.json` requiring `laravel/framework`; `laravel/sail` in `require-dev`
  means the suite runs inside containers (see test_default).

## inspect — where already-done work lives

- Migrations: `database/migrations/`. Seeders/factories: `database/seeders/`,
  `database/factories/`.
- Models: `app/Models/` — relationships, casts, fillable, soft deletes.
- HTTP layer: controllers, form requests, policies, middleware (`app/Http/`,
  `app/Policies/`).
- Frontend: Blade views (`resources/views/`), Livewire/Inertia/Vue/React
  components, routes (`routes/web.php`, `routes/api.php`).
- Tests: `tests/Feature/`, `tests/Unit/` (PHPUnit or Pest).

## foundation — what the first phases mean

1. **Data foundation** — all migrations from the schema, plus seeders for every
   lookup table.
2. **Entities & relationships** — every Eloquent model with **all relationships
   wired up front** (`belongsTo`, `hasMany`, `belongsToMany`, …), casts,
   fillable, soft deletes. Models come out of the foundation
   relationship-complete; never defer relationships to feature phases.
3. **Frontend foundation** — layout, design-system components, shared
   Blade/Livewire/Inertia components referenced by the design specs.

## data_model — what `init:database-schema` documents

- Full DBML schema following Eloquent conventions: plural snake_case tables,
  `id bigint pk increment`, `<singular>_id` foreign keys, `created_at`/
  `updated_at`, `deleted_at` for soft deletes, alphabetical pivot names
  (`role_user`).

## test_default — gate 2 command when none is declared

- With Sail: `vendor/bin/sail test` — the suite runs **inside** the container;
  `php artisan test` / `composer test` on the host will fail (no PHP, no DB).
  `scripts/ralph.sh` detects this and aborts when containers are down.
- Without Sail: `composer test` when the script exists, else `php artisan test`.
