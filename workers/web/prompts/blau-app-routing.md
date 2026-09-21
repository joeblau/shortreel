# Route blau.app/shotreel to blau-shortreel

Use this prompt in the repository that owns the `blau.app` routing Worker.

---

Implement routing so `https://blau.app/shotreel` serves the ShortReel website from
the Cloudflare Worker named `blau-shortreel`, with the browser remaining on
`blau.app`. Include all paths beneath `/shotreel/` and preserve existing routing
for the rest of the site. Use `/shotreel` exactly as requested; the project and
Worker names remain **ShortReel** and **blau-shortreel**.

Inspect this repository's agent instructions, Worker entrypoint, route registry,
Wrangler configuration, bindings, environment overrides, and tests. Follow the
existing routing architecture. Verify the target Worker and router use the same
Cloudflare account and identify the intended deployment environment rather than
inventing an account ID, zone ID, hostname, or router Worker name.

The target application's source is in the `joeblau/shortreel` repository:

- `workers/web/wrangler.jsonc`: Worker name `blau-shortreel`, entrypoint
  `.open-next/worker.js`, `ASSETS` binding to `.open-next/assets`, and an existing
  `WORKER_SELF_REFERENCE` binding to `blau-shortreel`.
- `workers/web/next.config.ts`: Next.js configuration. At prompt creation, it has
  no `basePath` and the app serves from `/`.
- `workers/web/src/app/`: landing page, styles, metadata, and icon.
- Root commands: `bun run web:types`, `bun run web:check`, `bun run web:build`,
  `bun run web:preview`, and `bun run web:deploy`.

Implement the following:

1. Add a service binding from the existing `blau.app` router to `blau-shortreel`.
   Use the repository's binding naming convention, or `BLAU_SHORTREEL` if none
   exists. Merge this entry into the existing service list and the applicable
   environment configuration, and regenerate the router's binding types:

   ```json
   { "binding": "BLAU_SHORTREEL", "service": "blau-shortreel" }
   ```

   Forward matching requests through `env.BLAU_SHORTREEL.fetch(request)` using
   Cloudflare's [HTTP service binding interface](https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/http/).
   Preserve the method, query string, headers, body, and response stream. Do not
   proxy through a public URL that could route back into the same router.

2. Match the exact path `/shotreel` or the prefix `/shotreel/` on `blau.app`.
   `/shotreel-other` and `/shotreels` must continue through existing routing.
   Register this match before any catch-all handler. Retain the site's existing
   behavior for `/`, unrelated applications, and other hostnames.

3. Coordinate the target app's subpath support with the router. Build ShortReel
   with `basePath: "/shotreel"` and preserve that prefix when forwarding to the
   target. Next.js [basePath](https://nextjs.org/docs/app/api-reference/config/next-config-js/basePath)
   is a build-time setting, so rebuild the OpenNext bundle. Check the installed
   Next.js documentation before editing the app. If its checkout is unavailable,
   produce an explicit companion patch for `joeblau/shortreel` and identify it as
   a deployment prerequisite.

4. Verify the generated asset URLs and the OpenNext static-asset routing under
   `/shotreel`, including JavaScript, CSS, icons, public files, and any framework
   navigation requests. Update manually authored root-relative URLs and canonical
   metadata where needed. Keep redirects on `https://blau.app/shotreel` and follow
   the app's trailing-slash convention without a redirect loop. Do not take over
   the host's global `/_next/*` namespace or use HTML string replacement to patch
   asset URLs. Preserve the target's existing self-reference and asset bindings.

5. Add focused router tests for the exact mount, trailing slash, nested paths,
   query strings, method/body forwarding, nonmatching prefixes, and existing
   routes. Run the repository's lint, type checks, and relevant tests. Build and
   preview both Workers together with the service binding connected. Load the
   mounted page in a browser and verify that assets load with correct content
   types, navigation works, and no hydration or asset errors appear. A successful
   HTML response alone is insufficient.

Document the files changed, the binding and route, test results, and deployment
commands. Deploy the rebuilt `blau-shortreel` target before enabling its route in
the `blau.app` router when carrying out the release. Report local verification
separately from production verification, and do not claim the public URL works
until it has been checked after deployment.
