import index from "./index.html";
import { readDocs, readGuides } from "../docs/server";

const guides = {
  async GET() {
    try {
      return Response.json(await readGuides());
    } catch (error) {
      console.error("Failed to load guides:", error);
      return Response.json({ error: "Could not load guides." }, { status: 500 });
    }
  },
};
const docs = {
  async GET() {
    try {
      return Response.json(await readDocs());
    } catch (error) {
      console.error("Failed to load documentation:", error);
      return Response.json({ error: "Could not load generated documentation." }, { status: 500 });
    }
  },
};

const server = Bun.serve({
  routes: {
    "/api/guides": guides,
    "/api/guides.json": guides,
    "/api/docs": docs,
    "/api/docs.json": docs,
    "/*": index,
  },
  development: process.env.NODE_ENV !== "production" && {
    hmr: true,
    console: true,
  },
});

console.log(`Documentation server at ${server.url}`);
