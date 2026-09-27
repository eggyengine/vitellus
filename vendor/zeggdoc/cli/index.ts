import { readdir, lstat, mkdir, realpath, unlink } from "node:fs/promises";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import tailwind from "bun-plugin-tailwind";
import { Language, Parser, type Node as SyntaxNode } from "web-tree-sitter";
import { readDocs, readGuides } from "../docs/server";

export type Symbol = {
  name: string;
  kind: string;
  signature: string;
  docs: string;
  line: number;
  visibility: "public" | "protected" | "private";
};

type FileEntry = { path: string; output: string; symbols: number };
const ignored = new Set(["zig-cache", ".zig-cache", "zig-out", "zig-pkg", "docs", "tests", "node_modules", ".git"]);
const containers = new Set([
  "struct_declaration",
  "enum_declaration",
  "union_declaration",
  "opaque_declaration",
  "error_set_declaration",
]);

async function parser(): Promise<Parser> {
  await Parser.init();
  const wasm = fileURLToPath(
    import.meta.resolve("@tree-sitter-grammars/tree-sitter-zig/tree-sitter-zig.wasm"),
  );
  const language = await Language.load(wasm);
  const result = new Parser();
  result.setLanguage(language);
  return result;
}

function declaration(node: SyntaxNode, prefix: string, docs: string, inherited: Symbol["visibility"]): Symbol | undefined {
  const isTest = node.type === "test_declaration";
  if (!isTest && node.type !== "function_declaration" && node.type !== "variable_declaration") return;

  let visibility: Symbol["visibility"] | undefined;
  const description: string[] = [];
  for (const line of docs.split("\n")) {
    if (line.trim().startsWith("@visibility")) {
      const value = line.trim().match(/^@visibility (public|protected|private)$/)?.[1] as Symbol["visibility"] | undefined;
      if (!value || visibility) throw new Error(`Invalid or duplicate @visibility at line ${node.startPosition.row + 1}`);
      visibility = value;
    } else {
      description.push(line);
    }
  }
  if (!isTest && !visibility && !node.children.some((child) => child.type === "pub")) return;

  const name = isTest
    ? node.namedChildren.find((child) => child.type === "string" || child.type === "identifier")?.text ?? "test"
    : node.type === "function_declaration"
      ? node.childForFieldName("name")?.text
      : node.namedChildren.find((child) => child.type === "identifier")?.text;
  if (!name) return;

  const container = node.type === "variable_declaration"
    ? node.namedChildren.find((child) => containers.has(child.type))
    : undefined;
  const keyword = node.children.find((child) => child.type === "const" || child.type === "var");
  let signature = node.text.trim();
  if (node.type === "function_declaration" || isTest) {
    const body = node.childForFieldName("body") ??
      node.namedChildren.find((child) => child.type === "block");
    if (body) signature = node.text.slice(0, body.startIndex - node.startIndex).trimEnd();
  } else if (container) {
    const open = container.children.find((child) => child.type === "{");
    const close = container.children.findLast((child) => child.type === "}");
    if (open && close) {
      signature = node.text.slice(0, open.startIndex - node.startIndex) +
        "{ ... }" + node.text.slice(close.endIndex - node.startIndex);
    }
  }

  return {
    name: prefix + name,
    kind: isTest ? "test" : node.type === "function_declaration"
      ? "fn" : container ? "type" : keyword?.type ?? "const",
    signature,
    docs: description.join("\n").trim(),
    line: node.startPosition.row + 1,
    visibility: visibility ?? inherited,
  };
}

function collect(container: SyntaxNode, prefix: string, symbols: Symbol[], inherited: Symbol["visibility"] = "public"): void {
  let comments: string[] = [];
  let lastDocRow = -2;
  for (const node of container.children) {
    if (node.type === "comment" && node.text.startsWith("///")) {
      if (node.startPosition.row !== lastDocRow + 1) comments = [];
      comments.push(node.text.slice(3).replace(/^ /, ""));
      lastDocRow = node.endPosition.row;
      continue;
    }
    const docs = node.startPosition.row === lastDocRow + 1 ? comments.join("\n") : "";
    comments = [];
    lastDocRow = -2;

    const symbol = declaration(node, prefix, docs, inherited);
    if (!symbol) continue;
    symbols.push(symbol);
    if (node.type === "variable_declaration") {
      const nested = node.namedChildren.find((child) => containers.has(child.type));
      if (nested) collect(nested, `${symbol.name}.`, symbols, symbol.visibility);
    }
  }
}

export function extractSymbols(source: string, zigParser: Parser): Symbol[] {
  const tree = zigParser.parse(source);
  if (!tree) throw new Error("Unable to parse Zig source");
  const symbols: Symbol[] = [];
  collect(tree.rootNode, "", symbols);
  tree.delete();
  return symbols;
}

async function* zigFiles(root: string, excludes: Bun.Glob[], directory = root): AsyncGenerator<string> {
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
    if (ignored.has(entry.name)) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) yield* zigFiles(root, excludes, path);
    else if (entry.isFile() && entry.name.endsWith(".zig")) {
      const sourcePath = relative(root, path).split(sep).join("/");
      if (!excludes.some(glob => glob.match(sourcePath))) yield sourcePath;
    }
  }
}

async function outputDirectory(root: string, relativeDirectory: string): Promise<void> {
  let current = root;
  for (const segment of relativeDirectory.split("/")) {
    current = join(current, segment);
    try {
      const info = await lstat(current);
      if (!info.isDirectory() || info.isSymbolicLink()) {
        throw new Error(`Refusing non-directory output path: ${current}`);
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      await mkdir(current);
    }
  }
}

async function existing(path: string): Promise<Awaited<ReturnType<typeof lstat>> | undefined> {
  try {
    return await lstat(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
    throw error;
  }
}

async function refuseSymlinks(directory: string): Promise<void> {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.isSymbolicLink()) throw new Error(`Refusing symlinked output path: ${join(directory, entry.name)}`);
    if (entry.isDirectory()) await refuseSymlinks(join(directory, entry.name));
  }
}

async function writeOutput(path: string, contents: string, ifMissing = false): Promise<void> {
  const info = await existing(path);
  if (info?.isSymbolicLink() || (info && !info.isFile())) {
    throw new Error(`Refusing non-file output path: ${path}`);
  }
  if (!ifMissing || !info) await Bun.write(path, contents);
}

function yaml(value: unknown): string {
  return Bun.YAML.stringify(value) + "\n";
}

async function removeStaleOutput(root: string, files: FileEntry[]): Promise<void> {
  const dataDir = join(root, "docs/data");
  const manifestPath = join(dataDir, "index.yaml");
  const info = await existing(manifestPath);
  if (info?.isSymbolicLink() || (info && !info.isFile())) {
    throw new Error(`Refusing non-file output path: ${manifestPath}`);
  }
  if (!info) return;
  const manifest = Bun.file(manifestPath);
  const previous = Bun.YAML.parse(await manifest.text()) as { files?: { output?: string }[] };
  if (!Array.isArray(previous?.files)) throw new Error("Invalid previous docs/data/index.yaml");
  const current = new Set(files.map(file => file.output));
  for (const entry of previous.files) {
    if (typeof entry.output !== "string") throw new Error("Invalid previous documentation output");
    const path = resolve(dataDir, entry.output);
    if (entry.output.split("/").some(segment => !segment || segment === "." || segment === "..") ||
      !path.startsWith(dataDir + sep) || !path.endsWith(".yaml") || path === join(dataDir, "index.yaml")) {
      throw new Error(`Invalid previous documentation path: ${entry.output}`);
    }
    if (current.has(entry.output)) continue;
    let parent: string;
    try {
      parent = await realpath(dirname(path));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw error;
    }
    if (parent !== dataDir && !parent.startsWith(dataDir + sep)) {
      throw new Error(`Refusing symlinked output path: ${path}`);
    }
    const info = await existing(path);
    if (info?.isSymbolicLink() || (info && !info.isFile())) {
      throw new Error(`Refusing non-file output path: ${path}`);
    }
    if (info) await unlink(path);
  }
}

async function portableSite(root: string): Promise<void> {
  const sourceRoot = resolve(import.meta.dir, "..");
  const docs = join(root, "docs");
  const site = join(docs, "site");
  await outputDirectory(root, "docs/site");
  await outputDirectory(root, "docs/guides");
  await refuseSymlinks(site);

  const server = join(sourceRoot, "docs/server.ts");
  if (!await Bun.file(server).exists()) {
    throw new Error("Portable website server is missing from docs/");
  }
  await writeOutput(join(docs, "server.ts"), await Bun.file(server).text(), true);
  await writeOutput(join(docs, "package.json"), JSON.stringify({
    private: true,
    scripts: { dev: "bun --hot server.ts" },
  }, null, 2) + "\n", true);
  await writeOutput(join(docs, "guides/01-getting-started.md"),
    "# Getting started\n\nRun the Zeggdoc generator with this project directory to refresh the API reference. From `docs/`, run `bun run dev` to browse the generated site.\n",
    true);

  const result = await Bun.build({
    entrypoints: [join(sourceRoot, "src/index.html")],
    outdir: site,
    plugins: [tailwind],
    target: "browser",
    minify: true,
    define: { "process.env.NODE_ENV": JSON.stringify("production") },
  });
  if (!result.success) throw new Error(`Website build failed:\n${result.logs.join("\n")}`);
  const outputs = new Set(result.outputs.map(output => basename(output.path)));
  for (const entry of await readdir(site, { withFileTypes: true })) {
    if (/^chunk-[a-z0-9]+\.(js|css)(\.map)?$/.test(entry.name) && !outputs.has(entry.name)) {
      if (!entry.isFile()) throw new Error(`Refusing non-file output path: ${join(site, entry.name)}`);
      await unlink(join(site, entry.name));
    }
  }
  await outputDirectory(root, "docs/site/api");
  await writeOutput(join(site, "api/docs.json"), JSON.stringify(await readDocs(docs)) + "\n");
  await writeOutput(join(site, "api/guides.json"), JSON.stringify(await readGuides(docs)) + "\n");
  await writeOutput(join(site, ".nojekyll"), "");
}

export async function generate(projectRoot = ".", exclude: string[] = []): Promise<FileEntry[]> {
  const root = await realpath(resolve(projectRoot));
  const excludes = exclude.map(pattern => {
    if (!pattern || pattern.startsWith("/") || pattern.split("/").includes("..")) {
      throw new Error(`Invalid exclude pattern: ${pattern}`);
    }
    return new Bun.Glob(pattern);
  });
  const zigParser = await parser();
  const files: FileEntry[] = [];
  try {
    for await (const path of zigFiles(root, excludes)) {
      const source = await Bun.file(join(root, path)).text();
      const symbols = extractSymbols(source, zigParser);
      const output = `${path}.yaml`;
      await outputDirectory(root, ["docs", "data", ...path.split("/").slice(0, -1)].join("/"));
      await writeOutput(join(root, "docs/data", output), yaml({ path, source, symbols }));
      files.push({ path, output, symbols: symbols.length });
    }
    await outputDirectory(root, "docs/data");
    await removeStaleOutput(root, files);
    await writeOutput(join(root, "docs/data/index.yaml"), yaml({ project: basename(root), files }));
    await portableSite(root);
    return files;
  } finally {
    zigParser.delete();
  }
}

if (import.meta.main) {
  const args = Bun.argv.slice(2);
  const exclude: string[] = [];
  let root: string | undefined;
  try {
    for (let i = 0; i < args.length; i++) {
      if (args[i] === "--exclude") {
        const pattern = args[++i];
        if (!pattern || pattern.startsWith("--")) throw new Error("--exclude requires a file path or glob");
        exclude.push(pattern);
      } else if (args[i]?.startsWith("-") || root) {
        throw new Error("Usage: bun run cli/index.ts [project-root] [--exclude <glob>]...");
      } else {
        root = args[i];
      }
    }
    await generate(root, exclude);
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  }
}
