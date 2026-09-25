// Regenerates the Editor's file-type icon sprite and its name/extension table from the
// vscode-icons pack (MIT, https://github.com/vscode-icons/vscode-icons) pinned below.
//
// Run it by hand (`npm run icons`) whenever the pinned commit moves; it is NOT part of
// `npm run build`, which stays offline. Its three outputs are checked in:
//
//   src/app/fileTypeIconSprite.ts  the <symbol> markup for every icon we ship
//   src/app/fileTypeIconTable.ts   the pack's file-name and extension mappings, narrowed to
//                                  the icons in the sprite
//   public/vscode-icons-LICENSE.txt the pack's license text; Vite copies public/ into the
//                                  built bundle, so the notice ships inside the app beside the art
//
// The icon SET is ours (see ICON_SEEDS: the file kinds the Editor's trees are expected to
// name). Every MAPPING is the pack's: the seeds are resolved through the pack's own manifest,
// and the emitted table then carries every file name and extension that manifest points at one
// of the resulting icons, so which files get which icon is the pack's answer, not ours.

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PACK_COMMIT = "d3800d6b8c70b035f357a0b3f3f8b0f16c99a43e";
const PACK_REPO = "https://github.com/vscode-icons/vscode-icons";
const RAW_BASE = `https://raw.githubusercontent.com/vscode-icons/vscode-icons/${PACK_COMMIT}`;

/**
 * The file kinds the Editor's Files tree and Changes list are expected to name at a glance,
 * each written the way a user would write it. Each seed is resolved through the pack's manifest
 * to whichever icon the pack gives it; the seeds pick the icons to ship, they do not decide what
 * maps to them. A seed the pack has no icon for (a bare `.lock`, `Makefile`) resolves to the
 * default file icon and is reported by this script rather than mapped by hand.
 */
const ICON_SEEDS = [
  "package.json",
  "package-lock.json",
  "Dockerfile",
  ".gitignore",
  "spaces.yaml",
  "Cargo.lock",
  "LICENSE",
  "README.md",
  "Makefile",
  "main.ts",
  "App.tsx",
  "main.js",
  "App.jsx",
  "data.json",
  "tsconfig.jsonc",
  "notes.md",
  "script.py",
  "notebook.ipynb",
  "build.sh",
  "profile.zsh",
  "config.yaml",
  "config.yml",
  "Cargo.toml",
  "index.html",
  "styles.css",
  "styles.scss",
  "logo.svg",
  "shot.png",
  "shot.jpg",
  "shot.jpeg",
  "anim.gif",
  "shot.webp",
  "rows.csv",
  "rows.tsv",
  "notes.txt",
  "lib.rs",
  "main.go",
  "App.swift",
  "main.c",
  "main.h",
  "main.cpp",
  "Main.java",
  "app.rb",
  "deps.lock",
  "doc.xml",
  "paper.pdf",
  "bundle.zip",
];

const here = path.dirname(fileURLToPath(new URL(import.meta.url)));
const webRoot = path.resolve(here, "..");
const appDir = path.join(webRoot, "src", "app");
// Vite copies this directory into the built bundle untouched, so what lands here ships inside the app.
const publicDir = path.join(webRoot, "public");

async function fetchText(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`GET ${url} failed: ${response.status}`);
  return await response.text();
}

/**
 * Evaluates the pack's two manifest sources as plain JavaScript. They are ordinary object
 * literals behind a handful of TypeScript-only tokens, so stripping the imports, the type
 * annotations and the `FileFormat` enum reference is enough to read them exactly as written
 * rather than re-typing their contents here.
 */
function readManifest(languagesSource, extensionsSource) {
  const withoutImports = (source) => source.replace(/^import[\s\S]*?;\s*$/gm, "");
  const languages = withoutImports(languagesSource)
    .replace(/export const languages\s*=/, "const languages =")
    .replace(/\}\s*satisfies[^;]*;/, "};");
  const extensions = withoutImports(extensionsSource)
    .replace(/export const extensions\s*:\s*IFileCollection\s*=/, "const extensions =")
    .replace(/FileFormat\.(\w+)/g, "'$1'");
  return new Function(`${languages}\n${extensions}\nreturn extensions;`)();
}

/**
 * Rebuilds the pack's own file-name and extension maps, following `ManifestBuilder.buildFiles`:
 * disabled entries are dropped, the rest are walked in icon-name order, and a later entry
 * overwrites an earlier one. Entries contribute through two channels, and a name/extension
 * spelled out in an entry's own `extensions` list beats one inherited from a language's
 * `knownExtensions`, which is the precedence the pack applies when it emits its Zed themes.
 */
function buildPackMaps(manifest) {
  const supported = manifest.supported
    .filter((entry) => !entry.disabled && entry.icon)
    .sort((a, b) => (a.icon < b.icon ? -1 : a.icon > b.icon ? 1 : 0));

  const languageNames = new Map();
  const languageExtensions = new Map();
  const declaredNames = new Map();
  const declaredExtensions = new Map();
  /** Every language id that claimed an extension, so the tie-break below can consult them. */
  const extensionClaims = new Map();

  for (const entry of supported) {
    for (const language of entry.languages ?? []) {
      const ids = Array.isArray(language.ids) ? language.ids : [language.ids];
      for (const extension of language.knownExtensions ?? []) {
        languageExtensions.set(extension, entry.icon);
        const claims = extensionClaims.get(extension) ?? [];
        claims.push({ ids, icon: entry.icon });
        extensionClaims.set(extension, claims);
      }
      for (const name of language.knownFilenames ?? []) languageNames.set(name, entry.icon);
    }
    const populate = (value) => {
      if (entry.filename) declaredNames.set(value, entry.icon);
      else declaredExtensions.set(value.replace(/^\./, ""), entry.icon);
    };
    for (const value of entry.extensions ?? []) populate(value);
    if (entry.filenamesGlob?.length && entry.extensionsGlob?.length) {
      for (const stem of entry.filenamesGlob) for (const suffix of entry.extensionsGlob) populate(`${stem}.${suffix}`);
    }
  }

  // Where two of the pack's languages claim one extension, the language whose own id IS that
  // extension owns it. Without this the plain alphabetical last-writer rule hands `.css` to the
  // Tailwind icon, because the `tailwindcss` language also claims `css` and sorts after `css`.
  for (const [extension, claims] of extensionClaims) {
    if (claims.length < 2) continue;
    const owner = claims.find((claim) => claim.ids.includes(extension));
    if (owner) languageExtensions.set(extension, owner.icon);
  }

  return {
    names: new Map([...languageNames, ...declaredNames]),
    extensions: new Map([...languageExtensions, ...declaredExtensions]),
  };
}

/** The pack's answer for one file name: its name maps first, then its extensions, longest first. */
function resolveIcon(fileName, maps) {
  const byName = maps.names.get(fileName) ?? maps.names.get(fileName.toLowerCase());
  if (byName) return byName;
  const lower = fileName.toLowerCase();
  for (let at = lower.indexOf(".", 1); at !== -1; at = lower.indexOf(".", at + 1)) {
    const icon = maps.extensions.get(lower.slice(at + 1));
    if (icon) return icon;
  }
  return undefined;
}

/** `default_file.svg` is the pack's default; its manifest spells the icon `file`. */
const DEFAULT_ICON = "default_file";

function assetNameFor(icon) {
  return icon === DEFAULT_ICON ? "default_file" : `file_type_${icon}`;
}

/**
 * Turns one icon's SVG into a `<symbol>`: its root element's attributes are dropped except the
 * viewBox, its `<title>` goes (the row's own name carries the file's type, and the icon is
 * `aria-hidden`), and every internal id is prefixed with the icon's name so gradients and clip
 * paths from different icons cannot collide once they share one document.
 */
function toSymbol(icon, source) {
  const root = /<svg([^>]*)>([\s\S]*)<\/svg>/.exec(source);
  if (!root) throw new Error(`${icon}: not an <svg> document`);
  const viewBox = /viewBox="([^"]+)"/.exec(root[1]);
  if (!viewBox) throw new Error(`${icon}: no viewBox`);

  let body = root[2].replace(/<title>[\s\S]*?<\/title>/g, "");
  const ids = [...new Set([...body.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]))].sort(
    (a, b) => b.length - a.length,
  );
  for (const id of ids) {
    const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const renamed = `${icon}-${id}`;
    body = body
      .replace(new RegExp(`id="${escaped}"`, "g"), `id="${renamed}"`)
      .replace(new RegExp(`url\\(#${escaped}\\)`, "g"), `url(#${renamed})`)
      .replace(new RegExp(`href="#${escaped}"`, "g"), `href="#${renamed}"`);
  }
  body = body.replace(/>\s+</g, "><").trim();
  return `<symbol id="file-type-icon-${icon}" viewBox="${viewBox[1]}">${body}</symbol>`;
}

function asTypeScriptLiteral(value) {
  return JSON.stringify(value);
}

function tableEntries(map) {
  return [...map.entries()]
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([key, icon]) => `  ${asTypeScriptLiteral(key)}: ${asTypeScriptLiteral(icon)},`)
    .join("\n");
}

const GENERATED_HEADER = `// GENERATED by scripts/generate-file-type-icons.mjs from vscode-icons
// ${PACK_REPO} at ${PACK_COMMIT} (MIT, see public/vscode-icons-LICENSE.txt, shipped with the bundle).
// Do not edit by hand; run \`npm run icons\` instead.
`;

async function main() {
  const [languagesSource, extensionsSource, license] = await Promise.all([
    fetchText(`${RAW_BASE}/src/iconsManifest/languages.ts`),
    fetchText(`${RAW_BASE}/src/iconsManifest/supportedExtensions.ts`),
    fetchText(`${RAW_BASE}/LICENSE`),
  ]);
  const maps = buildPackMaps(readManifest(languagesSource, extensionsSource));

  const icons = new Set([DEFAULT_ICON]);
  const unmappedSeeds = [];
  for (const seed of ICON_SEEDS) {
    const icon = resolveIcon(seed, maps);
    if (icon === undefined) unmappedSeeds.push(seed);
    else icons.add(icon);
  }

  // Everything the pack points at an icon we ship comes along: the seeds choose the icons, the
  // pack chooses which files reach them, so `.jpeg` and `.tar.gz` need no seed of their own.
  const shippedNames = new Map();
  for (const [name, icon] of maps.names) {
    if (!icons.has(icon)) continue;
    const key = name.toLowerCase();
    const existing = shippedNames.get(key);
    if (existing !== undefined && existing !== icon) {
      throw new Error(`file name ${key} maps to both ${existing} and ${icon}`);
    }
    shippedNames.set(key, icon);
  }
  // Lower-cased the same way shippedNames is, above: `fileTypeIconID` lowercases the file name
  // before it slices out an extension, so a mixed-case manifest extension (e.g. `JSON-tmLanguage`)
  // would otherwise sit in the table under a key lookup can never produce.
  const shippedExtensions = new Map();
  for (const [extension, icon] of maps.extensions) {
    if (!icons.has(icon)) continue;
    const key = extension.toLowerCase();
    const existing = shippedExtensions.get(key);
    if (existing !== undefined && existing !== icon) {
      throw new Error(`extension ${key} maps to both ${existing} and ${icon}`);
    }
    shippedExtensions.set(key, icon);
  }

  const sorted = [...icons].sort();
  const symbols = [];
  for (const icon of sorted) {
    symbols.push(toSymbol(icon, await fetchText(`${RAW_BASE}/icons/${assetNameFor(icon)}.svg`)));
  }
  const sprite = symbols.join("");
  const duplicateIDs = [...sprite.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  if (new Set(duplicateIDs).size !== duplicateIDs.length) throw new Error("duplicate id in sprite");

  await mkdir(appDir, { recursive: true });
  await writeFile(
    path.join(appDir, "fileTypeIconSprite.ts"),
    `${GENERATED_HEADER}
/** One \`<symbol>\` per shipped icon, keyed \`file-type-icon-<pack icon name>\`; mounted once per
 *  pane by \`fileTypeIcon.ts\` and referenced by every row's \`<use>\`. */
export const FILE_TYPE_ICON_SYMBOLS = ${asTypeScriptLiteral(sprite)};
`,
  );
  await writeFile(
    path.join(appDir, "fileTypeIconTable.ts"),
    `${GENERATED_HEADER}
/** The pack's exact-file-name mappings, lower-cased, for the icons this bundle ships. */
export const FILE_TYPE_ICON_BY_NAME: Readonly<Record<string, string>> = {
${tableEntries(shippedNames)}
};

/** The pack's extension mappings (no leading dot, lower-case) for the icons this bundle ships. */
export const FILE_TYPE_ICON_BY_EXTENSION: Readonly<Record<string, string>> = {
${tableEntries(shippedExtensions)}
};

/** The pack's default file icon, for a name neither table answers. */
export const DEFAULT_FILE_TYPE_ICON = ${asTypeScriptLiteral(DEFAULT_ICON)};
`,
  );
  await writeFile(
    path.join(publicDir, "vscode-icons-LICENSE.txt"),
    `The SVG artwork in fileTypeIconSprite.ts, and the name/extension mappings in
fileTypeIconTable.ts, come from vscode-icons (${PACK_REPO})
at commit ${PACK_COMMIT}, under the license below.

${license.trim()}\n`,
  );

  console.log(`icons: ${sorted.length}`);
  console.log(`sprite bytes: ${Buffer.byteLength(sprite, "utf8")}`);
  console.log(`file names: ${shippedNames.size}, extensions: ${shippedExtensions.size}`);
  console.log(`seeds with no pack icon (they fall to ${DEFAULT_ICON}): ${unmappedSeeds.join(", ") || "none"}`);
}

await main();
