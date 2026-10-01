import { readdirSync } from "node:fs";
import { join } from "node:path";
import type { MetadataRoute } from "next";

export const dynamic = "force-static";

const origin = "https://usespaces.dev";
const appDirectory = join(process.cwd(), "app");

// Route segments come from the folder layout: dynamic segments and private
// folders are not pages, and route groups do not appear in the URL.
function pageSegments(directory: string, segments: string[]): string[][] {
  const found: string[][] = [];
  const entries = readdirSync(directory, { withFileTypes: true });
  if (entries.some((entry) => entry.isFile() && entry.name === "page.tsx")) {
    found.push(segments);
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    if (entry.name.startsWith("[") || entry.name.startsWith("_")) continue;
    const isRouteGroup = entry.name.startsWith("(") && entry.name.endsWith(")");
    found.push(
      ...pageSegments(
        join(directory, entry.name),
        isRouteGroup ? segments : [...segments, entry.name],
      ),
    );
  }
  return found;
}

// No lastModified: the build time would claim every page changed on every deploy.
export default function sitemap(): MetadataRoute.Sitemap {
  return pageSegments(appDirectory, [])
    .map((segments) => (segments.length === 0 ? "/" : `/${segments.join("/")}/`))
    .sort()
    .map((path) => ({ url: `${origin}${path}` }));
}
