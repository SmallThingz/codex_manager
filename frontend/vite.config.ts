import { existsSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { defineConfig, type Plugin, type ResolvedConfig } from "vite";
import solidPlugin from "vite-plugin-solid";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const rootDir = dirname(fileURLToPath(import.meta.url));

function isLocalAssetRef(ref: string): boolean {
  return !(
    ref.startsWith("http://") ||
    ref.startsWith("https://") ||
    ref.startsWith("//") ||
    ref.startsWith("data:")
  );
}

function resolveAssetPath(outDir: string, ref: string): string {
  const normalizedRef = ref.startsWith("/") ? ref.slice(1) : ref;
  return resolve(outDir, normalizedRef);
}

function inlineHtmlAssetsPlugin(): Plugin {
  let config: ResolvedConfig | undefined;

  return {
    name: "inline-html-assets",
    apply: "build",
    configResolved(resolvedConfig) {
      config = resolvedConfig;
    },
    closeBundle() {
      if (!config) {
        return;
      }

      const outDir = resolve(config.root, config.build.outDir);
      const indexPath = resolve(outDir, "index.html");
      if (!existsSync(indexPath)) {
        return;
      }

      let html = readFileSync(indexPath, "utf8");
      const filesToDelete = new Set<string>();

      if (!html.includes('src="/webui.js"') && !html.includes("src='/webui.js'")) {
        html = html.replace("</head>", '  <script src="/webui.js"></script>\n</head>');
      }

      html = html.replace(/<link\b[^>]*>/g, (tag) => {
        if (!/\brel=(["'])stylesheet\1/.test(tag)) {
          return tag;
        }

        const hrefMatch = tag.match(/\bhref=(["'])([^"']+)\1/);
        if (!hrefMatch) {
          return tag;
        }

        const href = hrefMatch[2];
        if (!isLocalAssetRef(href)) {
          return tag;
        }

        const cssPath = resolveAssetPath(outDir, href);
        if (!existsSync(cssPath)) {
          return tag;
        }

        filesToDelete.add(cssPath);
        const css = readFileSync(cssPath, "utf8");
        return `<style>\n${css}\n</style>`;
      });

      html = html.replace(
        /<script\b[^>]*\bsrc=(["'])([^"']+)\1[^>]*><\/script>/g,
        (tag, _quote: string, src: string) => {
          if (!isLocalAssetRef(src)) {
            return tag;
          }

          const jsPath = resolveAssetPath(outDir, src);
          if (!existsSync(jsPath)) {
            return tag;
          }

          filesToDelete.add(jsPath);
          const js = readFileSync(jsPath, "utf8");
          return `<script type="module">\n${js}\n</script>`;
        },
      );

      writeFileSync(indexPath, html, "utf8");

      for (const filePath of filesToDelete) {
        rmSync(filePath, { force: true });
      }

      for (const filePath of filesToDelete) {
        let dir = dirname(filePath);
        while (dir.startsWith(outDir) && dir !== outDir) {
          if (!existsSync(dir) || readdirSync(dir).length > 0) {
            break;
          }
          rmSync(dir, { force: true, recursive: true });
          dir = dirname(dir);
        }
      }
    },
  };
}

export default defineConfig(async () => ({
  root: rootDir,
  plugins: [solidPlugin(), inlineHtmlAssetsPlugin()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    host: false,
  },
  build: {
    target: "esnext",
    assetsInlineLimit: Number.MAX_SAFE_INTEGER,
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        entryFileNames: "assets/app.js",
        chunkFileNames: "assets/chunk-[name].js",
        assetFileNames: (assetInfo) => {
          if (assetInfo.name?.endsWith(".css")) {
            return "assets/app.css";
          }
          return "assets/[name][extname]";
        },
        inlineDynamicImports: true,
      },
    },
  },
}));
