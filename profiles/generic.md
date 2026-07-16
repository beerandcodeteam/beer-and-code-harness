# Stack Profile: generic

Fallback profile for any stack without a dedicated profile file — and the base
contract every profile follows: the same four sections, with the same meaning.
Commands read the profile named by the **Stack Profile** block in
`.spec/init/project-description.md`; when the named file does not exist (or no
profile was declared), they use this one.

## detect

- No marker of a more specific profile (no `artisan`, no WordPress theme/plugin
  headers). Any stack whose conventions can be derived from its manifest and
  its ORM/framework documentation.

## inspect — where already-done work lives

- Build manifest(s) and lockfiles — name the language, framework, real versions.
- Data layer: migrations directory, ORM models/entities, `schema.prisma`, `*.sql` files.
- Routes / controllers / handlers / services.
- Frontend components, pages/screens.
- Existing tests (`tests/`, `spec/`, `__tests__/`) and CI workflows.

## foundation — what the first phases mean

1. **Data foundation** — the stack's schema mechanism: migrations, schema files,
   or entity definitions, plus seeds for lookup data.
2. **Entities & relationships** — every entity with **all relationships declared
   up front**, in the idiom of the detected ORM/data layer. Entities come out of
   the foundation relationship-complete; never defer relationships to feature phases.
3. **Frontend foundation** — design-system components, layout, shared/reusable
   components referenced by the design specs.

## data_model — what `init:database-schema` documents

- `data_layer: migrations-orm` or `schema-file` → a full DBML schema: one
  `Table` per entity, lookup tables for categorical fields, pivots for
  many-to-many.
- `data_layer: none` → record why nothing is persisted and keep the DBML block
  empty.

## test_default — gate 2 command when none is declared

- Whatever the manifest declares: `composer test`, `npm test`, `pytest`,
  `go test ./...`, `cargo test`. `scripts/ralph.sh` detects the same cascade;
  declaring `test_cmd` in the Stack Profile skips detection entirely.
