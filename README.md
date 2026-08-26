# sproutos-migrate-action

Run a database migration on [SproutOS](https://sproutos.me), from any CI, and wait for the result.

```yaml
permissions:
  contents: read
  # Required. Without it there is no OIDC token and the action fails at its first step with an
  # authentication error that does not mention permissions.
  id-token: write

steps:
  - uses: actions/checkout@v5
  - run: npm ci && npm run build:migrator
  - uses: MySproutOS/sproutos-migrate-action@v1
    with:
      project: my-api
      directory: apps/migrator/build
```

## What it does

Uploads the built migrator, publishes it as a run-to-completion Lambda beside your application, and
invokes it **synchronously** against the database in that project's environment. The step fails if
the migration fails.

Separate from the application's function on purpose: a migrator is a different program with a
different entry point and usually a different dependency set, and bundling it into the function that
serves requests would ship migration tooling into every cold start forever.

## Three things worth knowing before you rely on it

**The connection string comes from the project, never from you.** There is no input for one. An
endpoint that accepted a database URL would let anyone holding a deploy token point your project's
migrator at a database they chose. Provision the database on SproutOS and it arrives as
`DATABASE_URL`.

**Fifteen minutes is the ceiling**, because that is Lambda's. A migration that needs longer needs a
different tool, and discovering that mid-migration is the worst possible moment — so it is stated
here rather than found there.

**Nothing is retried.** Re-running a partially applied schema change is how a recoverable failure
becomes an unrecoverable one. Your migrator owns idempotency; this reports what it reported.

## `directory` must be built

Lambda cannot load a `.ts` file. Point this at compiled output whose entry point `handler` names —
`index.handler` by default. If your migration files are read from disk at runtime (Kysely's
`FileMigrationProvider` does this), compile them one-to-one into the archive rather than bundling
them: a bundle produces a migrator that finds no migrations and reports success having done nothing.

## Deploying and migrating together

You usually do not need this action. `MySproutOS/sproutos-deploy-action` takes a `migration-directory`
and runs the migration **before the new version takes traffic**, so a failed migration fails the
deploy and leaves the previous release serving. Reach for this one when your schema ships on its own
schedule, or when your CI is not GitHub Actions and you want the API directly:

```
POST /v1/deploy/upload-url    → a presigned URL for the archive
POST /v1/deploy/migrate       → runs it, and waits
```
