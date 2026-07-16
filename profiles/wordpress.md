# Stack Profile: wordpress

WordPress themes and plugins — sites managed through the WP admin, built as a
custom theme, a plugin, or both. Same four sections as `profiles/generic.md`;
only the content is WordPress-specific.

## detect

- Theme: `style.css` whose header comment carries `Theme Name:`.
- Plugin: a root `*.php` file whose header comment carries `Plugin Name:`.
- Site repo: `wp-content/` (or `wp-config.php`) in the tree.

## inspect — where already-done work lives

- Entry files: theme `style.css` + `functions.php`, or the main plugin file
  (headers, constants, bootstrap).
- Content model: `register_post_type` / `register_taxonomy` calls,
  `register_post_meta`, ACF field groups (`acf-json/` or PHP), options pages,
  `block.json` for custom blocks.
- Presentation: template hierarchy files (`single-*.php`, `archive-*.php`,
  `page-*.php`, `templates/` for block themes), template parts, patterns.
- Wiring: hooks and filters added (`add_action` / `add_filter`), shortcodes,
  REST routes (`register_rest_route`), enqueued assets
  (`wp_enqueue_script/style`).
- Tests: `tests/` with PHPUnit + `phpunit.xml(.dist)`, `.wp-env.json`, or
  Playwright/e2e configs.

## foundation — what the first phases mean

1. **Data foundation** — register the whole content model: every custom post
   type, taxonomy, meta field (native or ACF), options page, and any real
   custom table (`$wpdb` + `dbDelta`) from the data model doc.
2. **Entities & relationships** — every CPT with its taxonomies attached, meta
   registered with types/defaults, and cross-references between content types
   (post-to-post relations, term meta) declared up front. The content model
   comes out of the foundation complete; never defer registrations to feature
   phases.
3. **Frontend foundation** — theme/plugin skeleton: headers, enqueue setup,
   base template hierarchy or block patterns, shared template parts/components
   referenced by the design specs.

## data_model — what `init:database-schema` documents

- `data_layer: cpt-taxonomy` — the artifact documents the **content model**,
  not a SQL schema: one entry per post type, taxonomy, and options group, each
  with its meta fields (key, type, required, notes).
- DBML `Table` blocks only for real custom tables (`$wpdb`); **zero custom
  tables is a valid schema** for most themes/plugins.
- The lookup-table rule maps to WordPress primitives: categorical values become
  a **taxonomy** (queryable, user-editable) or a constrained **meta/options
  field** — never a hardcoded enum scattered through templates.

## test_default — gate 2 command when none is declared

- `vendor/bin/phpunit` when `phpunit.xml` / `phpunit.xml.dist` exists and the
  binary is installed (`scripts/ralph.sh` detects this).
- With `wp-env`: declare the full command in the Stack Profile `test_cmd`, e.g.
  `npx wp-env run tests-cli --env-cwd=wp-content/plugins/<plugin> vendor/bin/phpunit`
  — the suite runs **inside** the wp-env container, host PHPUnit will not see
  WordPress.
- No automated tests (common for pure presentation themes): leave `test_cmd`
  as `—`; gate 2 stays off and the gate-3 verifier carries validation alone.
