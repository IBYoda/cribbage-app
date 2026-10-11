// Lets `node scripts/*.ts` import the project's modules the way the Next.js
// bundler does.
//
// Node 24 runs TypeScript directly by stripping types, which is why the test
// suite needs no framework and no build step. But Node's ESM resolver wants a
// COMPLETE specifier -- `./cards.ts`, not `./cards` -- while the app code uses
// the extensionless form the bundler understands. Rather than put `.ts` file
// extensions into lib/ (which would need allowImportingTsExtensions in
// tsconfig and would look wrong to anyone reading the app), this hook fills
// the extension back in, and only when the file really is there.
//
// Usage: node --import ./scripts/ts-resolve.mjs scripts/test-scoring.ts
//
// Expect one warning from Node about the package.json having no "type" field;
// it means the file was reparsed as ESM, costs a few milliseconds once, and
// adding "type": "module" to fix it would change how every other config file
// in the project is loaded.

import { registerHooks } from "node:module";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const EXTENSIONS = [".ts", ".tsx", ".mts"];

registerHooks({
  resolve(specifier, context, nextResolve) {
    // Only bare relative specifiers, and only when they have no extension of
    // their own. Anything else is passed straight through.
    if (specifier.startsWith(".") && !/\.[a-z0-9]+$/i.test(specifier)) {
      const base = new URL(specifier, context.parentURL);
      for (const extension of EXTENSIONS) {
        const candidate = new URL(base.href + extension);
        if (existsSync(fileURLToPath(candidate))) {
          return nextResolve(specifier + extension, context);
        }
      }
    }
    return nextResolve(specifier, context);
  },
});
