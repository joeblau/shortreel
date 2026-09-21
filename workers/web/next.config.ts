import type { NextConfig } from "next";
import { initOpenNextCloudflareForDev } from "@opennextjs/cloudflare";

initOpenNextCloudflareForDev();

const nextConfig: NextConfig = {
  basePath: "/shotreel",
  poweredByHeader: false,
};

export default nextConfig;
