import type { NextConfig } from "next";
const config: NextConfig = {
  agentRules: false,
  async rewrites() {
    return [
      { source: "/", destination: "/index.html" },
      { source: "/hub", destination: "/hub/index.html" },
      {
        source: "/hub/:module(falcon|tiempos)",
        destination: "/hub/:module/index.html",
      },
    ];
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "same-origin" },
          { key: "X-Frame-Options", value: "DENY" },
        ],
      },
    ];
  },
};
export default config;
