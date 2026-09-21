import { defineCloudflareConfig } from "@opennextjs/cloudflare";

// The landing page is built ahead of time and does not need an R2 cache.
export default defineCloudflareConfig();
