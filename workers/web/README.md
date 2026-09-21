# ShortReel web

Next.js App Router landing page deployed to Cloudflare Workers through
`@opennextjs/cloudflare` (OpenNext). Both the package and Worker are named
`blau-shortreel`.

## Development

From the repository root:

```sh
bun install
bun run web:dev
```

From this directory, use `bun run dev` instead. The page is served at
`http://localhost:3000/shotreel`. The main page is `src/app/page.tsx`, styles are in
`src/app/globals.css`, and page metadata is in `src/app/layout.tsx`.

Optional local environment values belong in `.dev.vars`; copy `.dev.vars.example`
when needed. Never commit credentials. The landing page has no required secrets.

## Verify and preview

```sh
bun run cf-typegen
bun run lint
bun run typecheck
bun run build:worker
bunx wrangler deploy --dry-run
bun run preview
```

`build` runs Next.js; `build:worker` runs OpenNext, which invokes that build and
writes `.open-next/worker.js` and `.open-next/assets`, then moves `_headers` to
the asset root so Wrangler reads the `/shotreel/_next/static/*` cache rule.
`preview` uses Cloudflare's
local Workers runtime. Generated Worker types live in `cloudflare-env.d.ts` and
should be regenerated after changing bindings in `wrangler.jsonc`.

This page is prerendered. No R2 cache, database, or remote image service is needed.
The device workspace artwork is an illustration made in CSS; no live phone data
is embedded in the site. CTAs link to the workflow section and the project on GitHub.

## Deploy

This app is built with `basePath: "/shotreel"` for `https://blau.app/shotreel`.
The existing `blau-app` router forwards that prefix unchanged through its
`WEB_SHORTREEL` service binding. `assets.run_worker_first: true` enables
OpenNext's asset resolver. Retain `ASSETS` and `WORKER_SELF_REFERENCE`, and
rebuild after any base path change. Prefix public asset URLs with `/shotreel`.

Both Workers select the Joe Blau account (`2b04333c55d653550f69d1c732b92d98`)
using the default Wrangler environment. Deploy this app before deploying the
router's binding. No named `production` Wrangler environment is configured.
See `joeblau/blau`'s `docs/shotreel-routing.md` for connected preview commands.

```sh
bunx wrangler login
bun run deploy
```

`wrangler.jsonc` names the Worker `blau-shortreel`. The router owns the public
route; this Worker needs no additional domain. For Cloudflare Git builds, use the repository root
as the build root (so Bun resolves the workspace lockfile), `bun install --frozen-lockfile`
as the install command, and `bun run web:deploy` as the deployment command.

References: [OpenNext setup](https://opennext.js.org/cloudflare/get-started) and
[Cloudflare's OpenNext guide](https://developers.cloudflare.com/workers/framework-guides/web-apps/opennext/).
