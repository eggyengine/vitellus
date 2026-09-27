import { useEffect, useMemo, useRef, useState } from "react";
import Markdown from "react-markdown";
import {
  ArrowRight, BookOpen, Braces, Check, ChevronRight, Command, Copy, FileCode2, Hash,
  Menu, Moon, Search, Sun, Terminal, X,
} from "lucide-react";
import { Button } from "./components/ui/button";
import { Card } from "./components/ui/card";
import { Input } from "./components/ui/input";
import "./index.css";

type DocSymbol = {
  name: string;
  kind: string;
  signature: string;
  docs: string;
  line: number;
  visibility: "public" | "protected" | "private";
};
type SourceFile = { path: string; source: string; symbols: DocSymbol[] };
type Documentation = { project: string; files: SourceFile[] };
type Guide = { id: string; title: string; summary: string; content: string };
type GuideNode = { id: string; title: string; guide?: Guide; children: GuideNode[] };

function guideTree(guides: Guide[]): GuideNode[] {
  const roots: GuideNode[] = [];
  for (const guide of guides) {
    const parts = guide.id.split("/");
    let siblings = roots;
    let parent: GuideNode | undefined;
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i]!;
      if (i === parts.length - 1 && part === "index" && parent) {
        parent.guide = guide;
        parent.title = guide.title;
      } else {
        const id = parts.slice(0, i + 1).join("/");
        let node = siblings.find(item => item.id === id);
        if (!node) {
          node = { id, title: i === parts.length - 1 ? guide.title : part.replace(/^\d+-/, "").replaceAll("-", " "), children: [] };
          siblings.push(node);
        }
        if (i === parts.length - 1) node.guide = guide;
        parent = node;
        siblings = node.children;
      }
    }
  }
  return roots;
}

function GuideNav({ nodes, depth, selected, open, toggle, select }: {
  nodes: GuideNode[]; depth: number; selected?: string; open: Record<string, boolean>;
  toggle: (id: string) => void; select: (id: string) => void;
}) {
  return nodes.map(node => {
    const expanded = open[node.id] ?? true;
    return <div key={node.id}>
      <div className={`guide-nav-row ${node.guide?.id === selected ? "selected" : ""}`} style={{ paddingLeft: 10 + depth * 15 }}>
        <button className="guide-nav-label" onClick={() => node.guide ? select(node.guide.id) : toggle(node.id)}>
          <BookOpen size={15} /><span>{node.title}</span>
        </button>
        {node.children.length > 0 && <button className={`guide-nav-toggle ${expanded ? "expanded" : ""}`} onClick={() => toggle(node.id)} aria-label={`${expanded ? "Collapse" : "Expand"} ${node.title}`} aria-expanded={expanded}><ChevronRight size={14} /></button>}
      </div>
      {expanded && node.children.length > 0 && <GuideNav nodes={node.children} depth={depth + 1} selected={selected} open={open} toggle={toggle} select={select} />}
    </div>;
  });
}

async function getJson<T>(path: string): Promise<T> {
  const response = await fetch(path);
  if (!response.ok) throw new Error((await response.json()).error || "Could not load documentation.");
  return response.json() as Promise<T>;
}

function route() {
  const params = new URLSearchParams(location.hash.slice(1));
  return {
    section: params.has("file") ? "api" : "guides",
    file: params.get("file"),
    symbol: params.get("symbol"),
    guide: params.get("guide"),
    view: params.get("view") === "source" ? "source" : "api",
    line: params.get("line"),
  };
}

function navigate(file: string, symbol?: string) {
  const params = new URLSearchParams({ file });
  if (symbol) params.set("symbol", symbol);
  location.hash = params.toString();
  if (!symbol) window.scrollTo({ top: 0, behavior: "smooth" });
}

function sourceHash(file: string, line?: number) {
  const params = new URLSearchParams({ file, view: "source" });
  if (line) params.set("line", String(line));
  return `#${params}`;
}

function navigateSource(file: string, line?: number) {
  location.hash = sourceHash(file, line);
  if (!line) window.scrollTo({ top: 0, behavior: "smooth" });
}

function navigateGuide(guide: string) {
  location.hash = new URLSearchParams({ guide }).toString();
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function kindLabel(kind: string) {
  return kind === "fn" ? "Function" : kind === "const" ? "Constant" :
    kind === "var" ? "Variable" : kind === "test" ? "Test" : kind === "type" ? "Type" : kind;
}

function SymbolIcon({ kind }: { kind: string }) {
  return kind === "fn" || kind === "type" ? <Braces size={16} /> : kind === "test" ? <Terminal size={16} /> : <Hash size={16} />;
}

export function App() {
  const [data, setData] = useState<Documentation | null>(null);
  const [guides, setGuides] = useState<Guide[]>([]);
  const [error, setError] = useState("");
  const [current, setCurrent] = useState(route);
  const [query, setQuery] = useState("");
  const [mobileMenu, setMobileMenu] = useState(false);
  const [copyStatus, setCopyStatus] = useState("");
  const [openFolders, setOpenFolders] = useState<Record<string, boolean>>({});
  const [visibilityFilter, setVisibilityFilter] = useState<"all" | DocSymbol["visibility"]>("all");
  const [dark, setDark] = useState(() => localStorage.getItem("zeggdoc-theme") !== "light");
  const dialog = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    document.documentElement.classList.toggle("dark", dark);
    localStorage.setItem("zeggdoc-theme", dark ? "dark" : "light");
  }, [dark]);

  useEffect(() => {
    Promise.all([getJson<Documentation>("./api/docs.json"), getJson<Guide[]>("./api/guides.json")])
      .then(([docs, pages]) => { setData(docs); setGuides(pages); })
      .catch(err => setError(err instanceof Error ? err.message : "Could not load documentation."));
    const onHash = () => { setCurrent(route()); setCopyStatus(""); };
    addEventListener("hashchange", onHash);
    return () => removeEventListener("hashchange", onHash);
  }, []);

  useEffect(() => {
    const target = current.view === "source" && current.line && /^\d+$/.test(current.line)
      ? `L${current.line}` : current.view === "api" && current.symbol ? `symbol-${current.symbol}` : null;
    if (target) requestAnimationFrame(() => document.getElementById(target)?.scrollIntoView({ behavior: "smooth" }));
  }, [current, data]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        dialog.current?.showModal();
      }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);

  const files = data?.files ?? [];
  const selected = current.file ? files.find(file => file.path === current.file) :
    files.find(file => file.path === "src/root.zig") ??
    files.find(file => file.path.startsWith("src/")) ?? files[0];
  const selectedGuide = current.guide ? guides.find(guide => guide.id === current.guide) : guides[0];
  const guideNodes = useMemo(() => guideTree(guides), [guides]);
  const visibleSymbols = selected?.symbols.filter(symbol => visibilityFilter === "all" || symbol.visibility === visibilityFilter) ?? [];
  const sourceLines = selected?.source.replace(/\r?\n$/, "").split(/\r?\n/) ?? [];
  const lineNumber = current.line && /^\d+$/.test(current.line) ? Number(current.line) : null;
  const invalidLine = current.view === "source" && current.line !== null &&
    (lineNumber === null || lineNumber < 1 || lineNumber > sourceLines.length);
  const invalidSymbol = current.view === "api" && current.symbol !== null &&
    !selected?.symbols.some(symbol => symbol.name === current.symbol);
  const totalSymbols = files.reduce((count, file) => count + file.symbols.length, 0);
  const results = useMemo(() => files.flatMap(file =>
    file.symbols.map(symbol => ({ file, symbol }))
  ).filter(({ file, symbol }) =>
    `${file.path} ${symbol.name} ${symbol.kind} ${symbol.docs}`.toLowerCase().includes(query.toLowerCase())
  ).slice(0, 50), [files, query]);
  const matchingGuides = guides.filter(guide =>
    `${guide.title} ${guide.summary} ${guide.content}`.toLowerCase().includes(query.toLowerCase())
  );

  const select = (file: string, symbol?: string) => {
    setVisibilityFilter("all");
    navigate(file, symbol);
    setMobileMenu(false);
    dialog.current?.close();
    setQuery("");
  };
  const selectSource = (file: string, line?: number) => {
    navigateSource(file, line);
    setMobileMenu(false);
    setCopyStatus("");
  };
  const copyLink = async () => {
    try {
      await navigator.clipboard.writeText(location.href);
      setCopyStatus("Link copied");
    } catch {
      setCopyStatus("Could not copy link");
    }
  };
  const selectGuide = (id: string) => {
    const parts = id.split("/");
    setOpenFolders(previous => {
      const next = { ...previous };
      for (let i = 1; i < parts.length; i++) next[parts.slice(0, i).join("/")] = true;
      return next;
    });
    navigateGuide(id);
    setMobileMenu(false);
    dialog.current?.close();
    setQuery("");
  };

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark"><Braces size={21} strokeWidth={2.5} /></span>
          <span className="brand-name">zeggdoc<span className="brand-dot">.</span></span>
          <span className="brand-divider" />
          <span className="brand-project">{data?.project ?? "Documentation"}</span>
        </div>
        <nav className="topnav" aria-label="Main navigation">
          <button className={current.section === "guides" ? "topnav-current" : ""} onClick={() => selectedGuide && selectGuide(selectedGuide.id)}>Guides</button>
          <button className={current.section === "api" ? "topnav-current" : ""} onClick={() => selected && select(selected.path)}>API Reference</button>
        </nav>
        <div className="top-actions">
          <button className="search-trigger" onClick={() => dialog.current?.showModal()} aria-label="Search documentation">
            <Search size={16} /><span>Search documentation...</span><kbd>⌘ K</kbd>
          </button>
          <Button variant="ghost" size="icon" className="theme-button" onClick={() => setDark(!dark)} aria-label={`Switch to ${dark ? "light" : "dark"} theme`}>
            {dark ? <Sun size={18} /> : <Moon size={18} />}
          </Button>
          <Button variant="ghost" size="icon" className="menu-button" onClick={() => setMobileMenu(!mobileMenu)} aria-label="Toggle navigation">
            {mobileMenu ? <X size={20} /> : <Menu size={20} />}
          </Button>
        </div>
      </header>

      <div className="workspace">
        <aside className={`sidebar ${mobileMenu ? "sidebar-open" : ""}`}>
          <div className="sidebar-inner">
            <div className="sidebar-label">LEARN</div>
            <button className={`sidebar-overview ${current.section === "guides" ? "selected" : ""}`} onClick={() => selectedGuide && selectGuide(selectedGuide.id)}>
              <BookOpen size={17} /><span>Guides & tutorials</span><ChevronRight size={15} />
            </button>
            <div className="sidebar-section-head"><span>Guides</span><span className="count-pill">{guides.length}</span></div>
            <GuideNav nodes={guideNodes} depth={0} selected={current.section === "guides" ? selectedGuide?.id : undefined}
              open={openFolders} toggle={id => setOpenFolders(previous => ({ ...previous, [id]: !(previous[id] ?? true) }))} select={selectGuide} />
            <div className="sidebar-section-head"><span>API REFERENCE</span><span className="count-pill">{files.length}</span></div>
            {files.map(file => (
              <div key={file.path} className="sidebar-file-group">
                <button
                  className={`sidebar-file ${current.section === "api" && selected?.path === file.path ? "selected" : ""}`}
                  onClick={() => select(file.path)}
                  title={file.path}
                >
                  <FileCode2 size={16} /><span>{file.path}</span>
                </button>
                {current.section === "api" && selected?.path === file.path && (
                  <div className="sidebar-symbols">
                    {visibleSymbols.map(symbol => (
                      <button key={`${symbol.name}:${symbol.line}`} onClick={() => select(file.path, symbol.name)}
                        className={current.symbol === symbol.name ? "active" : ""}>
                        <span className={`symbol-dot dot-${symbol.kind}`} />
                        <span>{symbol.name}</span>
                      </button>
                    ))}
                  </div>
                )}
              </div>
            ))}
            {files.length === 0 && <p className="sidebar-hint">Generate YAML to populate the reference.</p>}
          </div>
          <div className="sidebar-footer"><span className="status-indicator" /> Generated from Zig source <span className="footer-version">v0.1</span></div>
        </aside>

        <main className="content">
          {error ? (
            <div className="empty-state">
              <span className="empty-icon"><X size={24} /></span>
              <h1>Unable to load documentation</h1>
              <p>{error}</p>
              <code>Run the generator again, then reload this page.</code>
            </div>
          ) : !data ? (
            <div className="empty-state"><span className="loading-dot" /> Loading documentation...</div>
          ) : (current.guide && !selectedGuide) || (current.file && !selected) ? (
            <div className="empty-state"><span className="empty-icon"><X size={24} /></span><h1>Reference not found</h1>
              <p>No {current.guide ? "guide" : "source file"} matches <code>{current.guide ?? current.file}</code>.</p></div>
          ) : current.section === "guides" && selectedGuide ? (
            <div className="page-layout">
              <article className="document">
                <div className="breadcrumbs"><span>{data.project}</span><ChevronRight size={14} /><span>Guides</span><ChevronRight size={14} /><strong>{selectedGuide.title}</strong></div>
                <div className="page-head guide-head">
                  <div className="page-kicker"><span className="kicker-line" /> TUTORIALS & GUIDES</div>
                  <h1>{selectedGuide.title}</h1>
                  <p>{selectedGuide.summary}</p>
                </div>
                <div className="guide-copy"><Markdown>{selectedGuide.content}</Markdown></div>
                <div className="guide-next">
                  {guides[guides.indexOf(selectedGuide) + 1] && <button onClick={() => selectGuide(guides[guides.indexOf(selectedGuide) + 1]!.id)}>
                    <span>UP NEXT</span><strong>{guides[guides.indexOf(selectedGuide) + 1]!.title}</strong><ArrowRight size={18} />
                  </button>}
                </div>
              </article>
              <aside className="toc" aria-label="Guides">
                <div className="toc-sticky">
                  <div className="toc-title">IN THIS SECTION</div>
                  {guides.map(guide => <button key={guide.id} className={guide.id === selectedGuide.id ? "toc-active" : ""} onClick={() => selectGuide(guide.id)}>{guide.title}</button>)}
                  <div className="toc-help"><div className="toc-help-icon"><FileCode2 size={18} /></div><strong>Looking for a symbol?</strong><p>Browse the generated functions, types, and constants.</p><button onClick={() => selected && select(selected.path)}>Explore API <ArrowRight size={14} /></button></div>
                </div>
              </aside>
            </div>
          ) : !selected ? (
            <div className="empty-state">
              <span className="empty-icon"><Terminal size={25} /></span>
              <div className="eyebrow">GET STARTED</div>
              <h1>Your docs start here.</h1>
              <p>Generate structured documentation from your Zig source, then browse every public declaration in one place.</p>
              <div className="setup-code"><span>$</span> zig build doc</div>
              <p className="empty-note">From your project root, then run <code>cd docs && bun run dev</code>.</p>
            </div>
          ) : (
            <div className="page-layout">
              <article className="document">
                <div className="breadcrumbs"><span>{data.project}</span><ChevronRight size={14} /><span>API Reference</span><ChevronRight size={14} /><strong>{selected.path}</strong></div>
                <div className="page-head">
                  <div className="page-kicker"><span className="kicker-line" /> SOURCE REFERENCE</div>
                  <h1>{selected.path.split("/").at(-1)}</h1>
                  <p>{current.view === "source" ? "Read the complete Zig source and link directly to any line in" : "Explore the public declarations, signatures, and documentation in"} <code>{selected.path}</code>.</p>
                  <div className="meta-row">
                    <span><FileCode2 size={15} /> {selected.path}</span>
                    <span><Braces size={15} /> {selected.symbols.length} {selected.symbols.length === 1 ? "symbol" : "symbols"}</span>
                  </div>
                </div>
                <div className="file-tabs" role="tablist" aria-label="File view">
                  <button role="tab" aria-selected={current.view === "api"} className={current.view === "api" ? "file-tab-active" : ""} onClick={() => select(selected.path)}>
                    <Braces size={16} /> API Reference
                  </button>
                  <button role="tab" aria-selected={current.view === "source"} className={current.view === "source" ? "file-tab-active" : ""} onClick={() => selectSource(selected.path)}>
                    <FileCode2 size={16} /> Source code
                  </button>
                </div>
                {invalidSymbol && <p className="line-error" role="alert">Symbol {current.symbol} does not exist in this file.</p>}
                {current.view === "source" ? (
                  <section className="source-section" aria-label={`Source code for ${selected.path}`}>
                    <div className="source-toolbar">
                      <div><span className="section-overline">FULL SOURCE</span><h2>{selected.path} <span>{sourceLines.length} lines</span></h2></div>
                      <div className="source-actions">
                        {copyStatus && <span role="status">{copyStatus}</span>}
                        <Button variant="outline" size="sm" onClick={copyLink}>{copyStatus === "Link copied" ? <Check size={14} /> : <Copy size={14} />} Copy {lineNumber && !invalidLine ? "line" : "file"} link</Button>
                      </div>
                    </div>
                    {invalidLine && <p className="line-error" role="alert">Line {current.line} does not exist in this file.</p>}
                    <div className="source-code" role="region" aria-label="Full file source">
                      <div className="source-lines">
                        {sourceLines.map((text, index) => {
                          const line = index + 1;
                          return <div id={`L${line}`} className={`source-row ${lineNumber === line && !invalidLine ? "source-row-selected" : ""}`} key={line}>
                            <a href={sourceHash(selected.path, line)} onClick={event => { event.preventDefault(); selectSource(selected.path, line); }} aria-label={`Reference line ${line}`} title={`Link to line ${line}`}>{line}</a>
                            <code>{text || "\u00a0"}</code>
                          </div>;
                        })}
                      </div>
                    </div>
                    <p className="source-hint">Select a line number, then copy its link to reference it directly.</p>
                  </section>
                ) : <>
                  <div className="section-title-row">
                    <div><span className="section-overline">CONTENTS</span><h2>Declarations <span>{visibleSymbols.length}</span></h2></div>
                    <div className="visibility-filters" aria-label="Filter by documented visibility">
                      {(["all", "public", "protected", "private"] as const).map(value => <button key={value} className={visibilityFilter === value ? "active" : ""} onClick={() => setVisibilityFilter(value)} aria-pressed={visibilityFilter === value}>{value}</button>)}
                    </div>
                  </div>
                  {visibleSymbols.length === 0 ? <p className="no-symbols">No declarations match this visibility filter.</p> :
                    <div className="symbol-list">
                      {visibleSymbols.map(symbol => (
                        <Card className="symbol-card" id={`symbol-${symbol.name}`} key={`${symbol.name}:${symbol.line}`}>
                          <div className="symbol-top">
                            <span className={`symbol-icon icon-${symbol.kind}`}><SymbolIcon kind={symbol.kind} /></span>
                            <div className="symbol-heading">
                              <div className="symbol-name-line"><h3>{symbol.name}</h3><span className={`kind-badge badge-${symbol.kind}`}>{kindLabel(symbol.kind)}</span><span className={`visibility-badge visibility-${symbol.visibility}`}>{symbol.visibility}</span></div>
                              <button className="source-line source-line-link" onClick={() => selectSource(selected.path, symbol.line)}>View source · line {symbol.line} <ArrowRight size={12} /></button>
                            </div>
                            <button className="anchor-button" onClick={() => select(selected.path, symbol.name)} aria-label={`Link to ${symbol.name}`}><Hash size={17} /></button>
                          </div>
                          <div className="signature"><div className="signature-bar"><span className="code-language">ZIG</span><button onClick={() => selectSource(selected.path, symbol.line)}>{selected.path}:{symbol.line}</button></div><pre><code>{symbol.signature}</code></pre></div>
                          {symbol.docs ? <div className="doc-copy"><Markdown>{symbol.docs}</Markdown></div> :
                            <div className="undocumented">No documentation comment provided.</div>}
                        </Card>
                      ))}
                    </div>
                  }
                </>}
                <div className="page-end"><span className="end-mark"><Braces size={16} /></span><span>End of {selected.path}</span></div>
              </article>
              <aside className="toc" aria-label="On this page">
                <div className="toc-sticky">
                  <div className="toc-title">{current.view === "source" ? "IN THIS FILE" : "ON THIS PAGE"}</div>
                  <button onClick={() => window.scrollTo({ top: 0, behavior: "smooth" })} className="toc-overview">Overview</button>
                  <div className="toc-group">Declarations</div>
                  {(current.view === "source" ? selected.symbols : visibleSymbols).map(symbol => <button key={`${symbol.name}:${symbol.line}`} onClick={() => current.view === "source" ? selectSource(selected.path, symbol.line) : select(selected.path, symbol.name)} className={current.view === "source" ? lineNumber === symbol.line ? "toc-active" : "" : current.symbol === symbol.name ? "toc-active" : ""}>{symbol.name}</button>)}
                  <div className="toc-help"><div className="toc-help-icon"><Command size={18} /></div><strong>Quick navigation</strong><p>{current.view === "source" ? "Click a line number to create a shareable reference." : "Find any symbol instantly with search."}</p><button onClick={() => current.view === "source" ? select(selected.path) : dialog.current?.showModal()}>{current.view === "source" ? "View API" : "Open search"} <ArrowRight size={14} /></button></div>
                </div>
              </aside>
            </div>
          )}
        </main>
      </div>

      <dialog className="search-dialog" ref={dialog} onClose={() => setQuery("")} aria-label="Search documentation">
        <div className="dialog-search"><Search size={19} /><Input autoFocus placeholder="Search guides or API symbols..." value={query} onChange={event => setQuery(event.target.value)}
          onKeyDown={event => {
            if (event.key !== "Enter") return;
            if (matchingGuides[0]) selectGuide(matchingGuides[0].id);
            else if (results[0]) select(results[0].file.path, results[0].symbol.name);
          }} /><button onClick={() => dialog.current?.close()} aria-label="Close search">ESC</button></div>
        <div className="dialog-results">
          <div className="dialog-label">GUIDES · {guides.length}</div>
          {matchingGuides.map(guide =>
            <button key={guide.id} onClick={() => selectGuide(guide.id)}><span className="symbol-icon icon-guide"><BookOpen size={16} /></span><span><strong>{guide.title}</strong><small>Guide</small></span><ArrowRight size={16} /></button>
          )}
          <div className="dialog-label dialog-label-spaced">{query ? `${results.length} API RESULTS` : `API SYMBOLS · ${totalSymbols}`}</div>
          {results.map(({ file, symbol }) => <button key={`${file.path}:${symbol.name}:${symbol.line}`} onClick={() => select(file.path, symbol.name)}>
            <span className={`symbol-icon icon-${symbol.kind}`}><SymbolIcon kind={symbol.kind} /></span>
            <span><strong>{symbol.name}</strong><small>{file.path} · {kindLabel(symbol.kind)}</small></span>
            <ArrowRight size={16} />
          </button>)}
          {results.length === 0 && <p className="search-empty">No matching symbols found.</p>}
        </div>
        <div className="dialog-footer"><span><kbd>↵</kbd> to open</span><span><kbd>esc</kbd> to close</span></div>
      </dialog>
    </div>
  );
}

export default App;
