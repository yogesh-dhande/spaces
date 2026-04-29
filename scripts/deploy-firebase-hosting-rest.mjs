#!/usr/bin/env node

import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { promises as fs } from "node:fs";
import path from "node:path";

const projectRoot = process.cwd();
const siteRoot = path.join(projectRoot, "apps", "web");
const configPath = path.join(siteRoot, "firebase.json");

const projectId = requireEnv("FIREBASE_PROJECT_ID");
const accessToken =
  process.env.FIREBASE_DEPLOY_ACCESS_TOKEN ??
  process.env.GOOGLE_GHA_ACCESS_TOKEN ??
  "";
const siteId = process.env.FIREBASE_HOSTING_SITE_ID || projectId;
const dryRun = process.argv.includes("--dry-run");

if (!accessToken) {
  throw new Error(
    "Missing FIREBASE_DEPLOY_ACCESS_TOKEN or GOOGLE_GHA_ACCESS_TOKEN.",
  );
}

const firebaseConfig = JSON.parse(await fs.readFile(configPath, "utf8"));
const hostingConfig = normalizeHostingConfig(firebaseConfig.hosting);
const publicDir = path.resolve(siteRoot, hostingConfig.public ?? "out");

const files = await collectDeployFiles(publicDir);
if (files.length === 0) {
  throw new Error(`No deployable files found in ${publicDir}.`);
}

const versionConfig = sanitizeVersionConfig(hostingConfig);
const fileMap = {};
const contentByHash = new Map();

for (const relativeFile of files) {
  const absoluteFile = path.join(publicDir, relativeFile);
  const rawContent = await fs.readFile(absoluteFile);
  const gzippedContent = gzipSync(rawContent);
  const hash = createHash("sha256").update(gzippedContent).digest("hex");
  const hostingPath = `/${relativeFile.split(path.sep).join("/")}`;
  fileMap[hostingPath] = hash;
  contentByHash.set(hash, gzippedContent);
}

if (dryRun) {
  console.log(
    JSON.stringify(
      {
        siteId,
        publicDir,
        fileCount: files.length,
        sampleFiles: files.slice(0, 10),
        versionConfig,
      },
      null,
      2,
    ),
  );
  process.exit(0);
}

const version = await apiRequest(
  `https://firebasehosting.googleapis.com/v1beta1/sites/${encodeURIComponent(siteId)}/versions`,
  {
    method: "POST",
    body: JSON.stringify({ config: versionConfig }),
  },
);

const versionName = version.name;
if (!versionName) {
  throw new Error("Firebase Hosting API did not return a version name.");
}

const populate = await apiRequest(
  `https://firebasehosting.googleapis.com/v1beta1/${versionName}:populateFiles`,
  {
    method: "POST",
    body: JSON.stringify({ files: fileMap }),
  },
);

const uploadBaseUrl = populate.uploadUrl;
if (!uploadBaseUrl) {
  throw new Error("Firebase Hosting API did not return an upload URL.");
}

for (const hash of populate.uploadRequiredHashes ?? []) {
  const content = contentByHash.get(hash);
  if (!content) {
    throw new Error(`Missing content for hash ${hash}.`);
  }

  await apiRequest(`${uploadBaseUrl}/${hash}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
    },
    body: content,
  });
}

await apiRequest(
  `https://firebasehosting.googleapis.com/v1beta1/${versionName}?update_mask=status`,
  {
    method: "PATCH",
    body: JSON.stringify({ status: "FINALIZED" }),
  },
);

const releaseUrl = new URL(
  `https://firebasehosting.googleapis.com/v1beta1/sites/${encodeURIComponent(siteId)}/releases`,
);
releaseUrl.searchParams.set("versionName", versionName);

const release = await apiRequest(releaseUrl, { method: "POST" });

console.log(
  JSON.stringify(
    {
      siteId,
      version: versionName,
      release: release.name,
      url: `https://${siteId}.web.app`,
    },
    null,
    2,
  ),
);

function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing ${name}.`);
  }
  return value;
}

function normalizeHostingConfig(config) {
  if (Array.isArray(config)) {
    if (config.length !== 1) {
      throw new Error("This deploy script supports exactly one Hosting config.");
    }
    return config[0];
  }

  if (!config || typeof config !== "object") {
    throw new Error("apps/web/firebase.json is missing a hosting config.");
  }

  return config;
}

function sanitizeVersionConfig(config) {
  const {
    public: _public,
    ignore: _ignore,
    target: _target,
    site: _site,
    source: _source,
    ...rest
  } = config;

  return rest;
}

async function collectDeployFiles(rootDir) {
  const entries = await fs.readdir(rootDir, { withFileTypes: true });
  const files = [];

  for (const entry of entries) {
    if (shouldIgnoreEntry(entry.name)) {
      continue;
    }

    const absolutePath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      const nestedFiles = await collectDeployFiles(absolutePath);
      for (const nestedFile of nestedFiles) {
        files.push(path.join(entry.name, nestedFile));
      }
      continue;
    }

    if (entry.isFile()) {
      files.push(entry.name);
    }
  }

  return files.sort();
}

function shouldIgnoreEntry(name) {
  return name === "node_modules" || name.startsWith(".");
}

async function apiRequest(url, options) {
  const response = await fetch(url, {
    ...options,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      ...(options?.headers ?? {}),
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(
      `Firebase Hosting API request failed (${response.status} ${response.statusText}): ${body}`,
    );
  }

  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.includes("application/json")) {
    return null;
  }

  return response.json();
}
