# ShortReel

A native Mac workspace for connected iPhones, with a Next.js landing page on Cloudflare Workers.

## Repository layout

| Directory | Contents |
| --- | --- |
| [`apple/`](apple/README.md) | macOS app, iOS runner, shared protocol, Xcode project, native tests, build scripts, and design docs |
| [`workers/web/`](workers/web/README.md) | Next.js landing page using the OpenNext Cloudflare adapter; Worker name `blau-shortreel` |

## Apple apps

Build, install, and launch the Mac app from the repository root:

```sh
bun run shortreel
```

Open `apple/ShortReel.xcodeproj` in Xcode. The project specification is
`apple/project.yml`; native build output is written under `apple/.build/`.
See the [Apple README](apple/README.md) for device setup, native tests, and the optional iOS runner.

## Landing page

Install dependencies once at the repository root. Bun workspaces share `bun.lock`.

```sh
bun install
bun run web:dev
```

The Next.js development server runs at `http://localhost:3000/shotreel`.

```sh
bun run web:types    # Generate Cloudflare binding types
bun run web:check    # ESLint and TypeScript
bun run web:build    # Build Next.js and the OpenNext Worker bundle
bun run web:preview  # Build and preview in the local Workers runtime
```

To publish when ready and authenticated with Cloudflare:

```sh
bun run web:deploy
```

The deployment targets `blau-shortreel` in the same Joe Blau Cloudflare account
as the `blau-app` router. Its public mount is `https://blau.app/shotreel`.
See [web setup](workers/web/README.md) for configuration and deployment details.
