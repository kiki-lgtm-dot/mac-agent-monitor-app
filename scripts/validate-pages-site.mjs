#!/usr/bin/env node

import { existsSync, readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = relativePath => readFileSync(path.join(root, relativePath), "utf8");
const pages = {
  home: read("docs/site/index.html"),
  privacy: read("docs/site/privacy/index.html"),
  support: read("docs/site/support/index.html"),
  styles: read("docs/site/styles.css")
};
const deploymentOrigin = "https://kiki-lgtm-dot.github.io";
const deploymentRoot = "/mac-agent-monitor-app/";
const documentByPath = new Map([
  [`${deploymentRoot}`, "home"],
  [`${deploymentRoot}index.html`, "home"],
  [`${deploymentRoot}privacy/`, "privacy"],
  [`${deploymentRoot}privacy/index.html`, "privacy"],
  [`${deploymentRoot}support/`, "support"],
  [`${deploymentRoot}support/index.html`, "support"]
]);
const outputAssetSources = new Map([
  [`${deploymentRoot}styles.css`, "docs/site/styles.css"],
  [`${deploymentRoot}media/mac-agent-monitor-overview-zh.png`, "docs/media/mac-agent-monitor-overview-zh.png"],
  [`${deploymentRoot}media/mac-agent-monitor-overview-en.png`, "docs/media/mac-agent-monitor-overview-en.png"]
]);
const fail = message => {
  console.error(`Public-site validation failed: ${message}`);
  process.exit(1);
};
const requireText = (source, values, label) => {
  for (const value of values) if (!source.includes(value)) fail(`${label} is missing ${JSON.stringify(value)}`);
};

for (const [name, source] of Object.entries(pages)) {
  if (!source.trim()) fail(`${name} is empty`);
  if (/\[(?:Effective Date|Support Email|Support URL|Developer Legal Name|[^\]]*YYYY-MM-DD)[^\]]*\]/i.test(source)) {
    fail(`${name} contains a release placeholder`);
  }
}

requireText(pages.home, [
  "MAC版灵动岛--Agent运行监测",
  "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/",
  "media/mac-agent-monitor-overview-zh.png",
  "media/mac-agent-monitor-overview-en.png",
  "privacy/",
  "support/"
], "home page");
requireText(pages.privacy, [
  "lang=\"zh-CN\"",
  "id=\"en\" lang=\"en\"",
  "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/",
  "App Sandbox",
  "security-scoped bookmark",
  "CloudKit",
  "off by default",
  "OpenAI-compatible API",
  "GitHub Issues",
  "September 3, 2026"
], "privacy page");
requireText(pages.support, [
  "lang=\"zh-CN\"",
  "id=\"en\" lang=\"en\"",
  "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/",
  "Agent is not detected",
  "token usage is unavailable",
  "Translation returns 401",
  "GitHub Issue"
], "support page");

const pageURL = name => new URL(name === "home" ? deploymentRoot : `${deploymentRoot}${name}/`, deploymentOrigin);
const voidElements = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);
const parsedPages = new Map();

for (const [name, source] of Object.entries({ home: pages.home, privacy: pages.privacy, support: pages.support })) {
  if (/<script\b|<form\b|google-analytics|googletagmanager|segment\.com|mixpanel|posthog/i.test(source)) {
    fail(`${name} unexpectedly contains executable, form, or analytics markup`);
  }
  const ids = new Set();
  const references = [];
  const stack = [];
  const markup = source.replace(/<!--[\s\S]*?-->/g, "");
  const tagPattern = /<!doctype\s+html\s*>|<\/?([a-z][a-z0-9:-]*)(\s[^<>]*?)?\s*\/?>/gi;
  let match;
  while ((match = tagPattern.exec(markup))) {
    if (!match[1]) continue;
    const tag = match[1].toLowerCase();
    const token = match[0];
    const closing = token.startsWith("</");
    if (closing) {
      const opened = stack.pop();
      if (opened !== tag) fail(`${name} closes <${tag}> while <${opened || "nothing"}> is open`);
      continue;
    }
    const attributes = new Map();
    const attributeSource = match[2] || "";
    const attributePattern = /([a-zA-Z_:][-a-zA-Z0-9_:.]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
    let attributeMatch;
    while ((attributeMatch = attributePattern.exec(attributeSource))) {
      const key = attributeMatch[1].toLowerCase();
      if (attributes.has(key)) fail(`${name} <${tag}> repeats attribute ${key}`);
      attributes.set(key, attributeMatch[2] ?? attributeMatch[3] ?? attributeMatch[4] ?? "");
    }
    if (attributes.has("id")) {
      const id = attributes.get("id");
      if (!id) fail(`${name} contains an empty id`);
      if (ids.has(id)) fail(`${name} repeats id #${id}`);
      ids.add(id);
    }
    if (tag === "img" && (!attributes.has("alt") || !attributes.get("alt").trim())) {
      fail(`${name} has an image without non-empty alt text`);
    }
    for (const key of ["href", "src"]) {
      if (attributes.has(key)) references.push({ tag, key, value: attributes.get(key) });
    }
    if (!voidElements.has(tag) && !token.endsWith("/>")) stack.push(tag);
  }
  if (stack.length) fail(`${name} leaves <${stack.at(-1)}> unclosed`);
  parsedPages.set(name, { ids, references });
}

for (const [name, parsed] of parsedPages) {
  for (const { tag, key, value } of parsed.references) {
    if (!value || /^(?:mailto:|tel:|data:)/i.test(value)) continue;
    let target;
    try {
      target = new URL(value, pageURL(name));
    } catch {
      fail(`${name} <${tag}> has an invalid ${key}: ${JSON.stringify(value)}`);
    }
    if (target.protocol !== "https:") fail(`${name} <${tag}> uses a non-HTTPS ${key}: ${value}`);
    if (target.origin !== deploymentOrigin || !target.pathname.startsWith(deploymentRoot)) continue;
    const targetDocument = documentByPath.get(target.pathname);
    const targetAsset = outputAssetSources.get(target.pathname);
    if (!targetDocument && !targetAsset) fail(`${name} links to missing published path ${target.pathname}`);
    if (targetAsset && !existsSync(path.join(root, targetAsset))) fail(`${name} links to missing asset ${targetAsset}`);
    if (target.hash) {
      if (!targetDocument) fail(`${name} uses a fragment on non-document ${target.pathname}`);
      const fragment = decodeURIComponent(target.hash.slice(1));
      if (!parsedPages.get(targetDocument).ids.has(fragment)) {
        fail(`${name} links to missing fragment ${target.pathname}#${fragment}`);
      }
    }
  }
}

for (const image of [
  "docs/media/mac-agent-monitor-overview-zh.png",
  "docs/media/mac-agent-monitor-overview-en.png"
]) {
  if (statSync(path.join(root, image)).size < 100_000) fail(`${image} is missing or unexpectedly small`);
}

console.log(JSON.stringify({
  ok: true,
  productName: "MAC版灵动岛--Agent运行监测",
  privacyURL: "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/privacy/",
  supportURL: "https://kiki-lgtm-dot.github.io/mac-agent-monitor-app/support/",
  languages: ["zh-CN", "en"]
}, null, 2));
