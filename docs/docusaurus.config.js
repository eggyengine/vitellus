// The docs workflow sets SITE_URL and BASE_PATH (the Pages base path plus /<branch>) from
// actions/configure-pages, so a custom domain works without editing this file. DOCS_BRANCH
// points the "Edit this page" links at the branch being published.
const baseUrl = `${process.env.BASE_PATH ?? '/vitellus'}/`.replace(/\/+$/, '/');

/** @type {import('@docusaurus/types').Config} */
export default {
  title: 'Vitellus',
  tagline: 'A native-first rendering hardware interface for Zig',
  url: process.env.SITE_URL ?? 'https://eggyengine.github.io',
  baseUrl,
  onBrokenLinks: 'throw',
  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          editUrl: `https://github.com/eggyengine/vitellus/edit/${process.env.DOCS_BRANCH ?? 'main'}/docs/`,
        },
        blog: false,
      },
    ],
  ],
  themeConfig: {
    colorMode: { respectPrefersColorScheme: true },
    navbar: {
      title: 'Vitellus',
      items: [
        { to: '/', label: 'Guide', position: 'left' },
        // Zig's generated docs are copied to build/api by the workflow.
        { to: 'pathname:///api/', label: 'API reference', position: 'left' },
        { href: 'https://github.com/eggyengine/vitellus', label: 'GitHub', position: 'right' },
      ],
    },
    prism: { additionalLanguages: ['zig', 'bash', 'hlsl'] },
  },
};
