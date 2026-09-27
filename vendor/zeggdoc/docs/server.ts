import { resolve, sep } from "node:path";

type Symbol = { name: string; kind: string; signature: string; docs: string; line: number; visibility: "public" | "protected" | "private" };
type SourceFile = { path: string; source: string; symbols: Symbol[] };
const siteDir = resolve(import.meta.dir, "site");

export async function readDocs(docsDir = import.meta.dir): Promise<{ project: string; files: SourceFile[] }> {
  const dataDir = resolve(docsDir, "data");
  const manifest = Bun.file(resolve(dataDir, "index.yaml"));
  if (!(await manifest.exists())) return { project: "Zig project", files: [] };
  const index = Bun.YAML.parse(await manifest.text()) as {
    project: string;
    files: { path: string; output: string }[];
  };
  if (typeof index.project !== "string" || !Array.isArray(index.files)) {
    throw new Error("Invalid docs/data/index.yaml");
  }
  const files = await Promise.all(index.files.map(async entry => {
    if (typeof entry.path !== "string" || typeof entry.output !== "string") {
      throw new Error("Invalid documentation manifest entry");
    }
    const path = resolve(dataDir, entry.output);
    if (!path.startsWith(dataDir + sep) || !path.endsWith(".yaml")) {
      throw new Error(`Invalid documentation path: ${entry.output}`);
    }
    const file = Bun.YAML.parse(await Bun.file(path).text()) as SourceFile;
    if (file.path !== entry.path || typeof file.source !== "string" || !Array.isArray(file.symbols) ||
      file.symbols.some(symbol => !["public", "protected", "private"].includes(symbol.visibility))) {
      throw new Error(`Invalid documentation file: ${entry.output}`);
    }
    return file;
  }));
  return { project: index.project, files };
}

export async function readGuides(docsDir = import.meta.dir) {
  const guidesDir = resolve(docsDir, "guides");
  const paths = await Array.fromAsync(new Bun.Glob("**/*.md").scan({ cwd: guidesDir }));
  return Promise.all(paths.sort().map(async path => {
    const source = await Bun.file(resolve(guidesDir, path)).text();
    const heading = source.match(/^# (.+)$/m);
    const title = heading?.[1] ?? path.replace(/\.md$/, "");
    const content = heading ? source.replace(/^# .+\r?\n?/, "").trim() : source.trim();
    const summary = content.split(/\r?\n\r?\n/).find(paragraph => !paragraph.startsWith("#")) ?? "";
    return { id: path.replace(/\.md$/, ""), title, summary, content: content.replace(summary, "").trim() };
  }));
}

if (import.meta.main) {
  const server = Bun.serve({
    async fetch(request) {
      try {
        const pathname = decodeURIComponent(new URL(request.url).pathname);
        if (pathname === "/api/docs" || pathname === "/api/docs.json") return Response.json(await readDocs());
        if (pathname === "/api/guides" || pathname === "/api/guides.json") return Response.json(await readGuides());
        const file = resolve(siteDir, `.${pathname === "/" ? "/index.html" : pathname}`);
        if (!file.startsWith(siteDir + sep) || !(await Bun.file(file).exists())) {
          return new Response("Not found", { status: 404 });
        }
        return new Response(Bun.file(file));
      } catch (error) {
        console.error("Failed to serve documentation:", error);
        return Response.json({ error: "Could not serve documentation." }, { status: 500 });
      }
    },
  });
  console.log(`Documentation server at ${server.url}`);
}
