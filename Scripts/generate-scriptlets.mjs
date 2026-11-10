#!/usr/bin/env node
// Extracts uBlock Origin's scriptlets into yab/Resources/Scriptlets/ubo-scriptlets.json.
//
// Usage: node Scripts/generate-scriptlets.mjs <uBlock Origin version>
// Example: node Scripts/generate-scriptlets.mjs 1.76.0
//
// uBlock Origin is GPL-3.0-or-later, like yab. The scriptlet code is copied verbatim.

import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const version = process.argv[2];
if (!version) {
    console.error('Usage: node Scripts/generate-scriptlets.mjs <uBlock Origin version>');
    process.exit(1);
}

const repository = join(dirname(fileURLToPath(import.meta.url)), '..');
const work = mkdtempSync(join(tmpdir(), 'yab-ubo-'));

try {
    const response = await fetch(`https://github.com/gorhill/uBlock/archive/refs/tags/${version}.tar.gz`);
    if (!response.ok) {
        throw new Error(`Downloading uBlock Origin ${version} failed: HTTP ${response.status}`);
    }
    const archive = join(work, 'ubo.tar.gz');
    writeFileSync(archive, Buffer.from(await response.arrayBuffer()));
    execFileSync('tar', ['-xzf', archive, '-C', work, '--strip-components=1']);

    // uBO's sources are ES modules, but nothing marks them as such for Node.
    writeFileSync(join(work, 'src', 'package.json'), '{"type":"module"}');
    const { builtinScriptlets } = await import(pathToFileURL(join(work, 'src/js/resources/scriptlets.js')));

    // Entries ending in `.js` are scriptlets usable in filters; `.fn` entries are helpers
    // they depend on. `code` is a function or class declaration named `function`.
    const scriptlets = builtinScriptlets.map(scriptlet => ({
        name: scriptlet.name,
        aliases: scriptlet.aliases ?? [],
        function: scriptlet.fn.name,
        dependencies: scriptlet.dependencies ?? [],
        world: scriptlet.world ?? 'MAIN',
        requiresTrust: scriptlet.requiresTrust === true,
        code: scriptlet.fn.toString(),
    }));

    // Redirect resources loaded as text, like `noeval.js`, can be injected with `+js()` too.
    // Wrapped into functions the way uBO's make-scriptlets.js `importScriptlet` does it.
    const { default: redirectResources } = await import(pathToFileURL(join(work, 'src/js/redirect-resources.js')));
    const injectableResources = [];
    for (const [name, details] of redirectResources) {
        if (details.data !== 'text' || !name.endsWith('.js')) { continue; }
        const source = readFileSync(join(work, 'src/web_accessible_resources', name), 'utf8');
        const body = source.replace(/\/\*.+?\*\//gs, '').trim();
        const functionName = `yabResource_${name.replace(/[^a-zA-Z0-9]/g, '_')}`;
        const code = /^function\s+[^(]+\(.*?\)\s*\{.*\}$/s.test(body)
            ? `function ${functionName}(...args) { // ${name}\n(${body})(...args)\n}`
            : `function ${functionName}() { // ${name}\n${body}\n}`;
        const aliases = [details.alias ?? []].flat();
        injectableResources.push({
            name,
            aliases,
            function: functionName,
            dependencies: [],
            world: details.world === 'ISOLATED' ? 'ISOLATED' : 'MAIN',
            requiresTrust: details.requiresTrust === true,
            code,
        });
    }

    const resources = [...scriptlets, ...injectableResources].sort((a, b) => a.name.localeCompare(b.name));

    const output = {
        source: `uBlock Origin ${version}`,
        license: 'GPL-3.0-or-later. Copyright (C) Raymond Hill and contributors. https://github.com/gorhill/uBlock',
        resources,
    };
    const destination = join(repository, 'yab/Resources/Scriptlets/ubo-scriptlets.json');
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, JSON.stringify(output, null, 1) + '\n');
    console.log(`Wrote ${resources.length} resources from uBlock Origin ${version} to ${destination}`);
} finally {
    rmSync(work, { recursive: true, force: true });
}
