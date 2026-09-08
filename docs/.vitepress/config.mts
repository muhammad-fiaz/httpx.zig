import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";

// Site configuration
export const SITE_URL = "https://muhammad-fiaz.github.io/httpx.zig";
export const SITE_NAME = "httpx.zig";
export const SITE_DESCRIPTION = "A production-ready, high-performance HTTP client and server library for Zig with HTTP/1.x, HTTP/2, HTTP/3, concurrency, proxy support, and protocol primitives.";

// Google Analytics and Google Tag Manager IDs
export const GA_ID = "G-6BVYCRK57P";
export const GTM_ID = "GTM-P4M9T8ZR";

// Google AdSense Client ID
export const ADSENSE_CLIENT_ID = "ca-pub-2040560600290490";

// SEO Keywords
export const KEYWORDS = "zig, http, https, http3, quic, server, client, networking, library, async, production, connection pooling, middleware, routing, tls, ssl, performance, socks5h, proxy";

export default defineConfig({
  lang: "en-US",
  title: SITE_NAME,
  description: SITE_DESCRIPTION,
  base: "/httpx.zig/",
  lastUpdated: true,
  cleanUrls: false,

  sitemap: {
    // Per VitePress docs: when `base` is set, append it (with trailing
    // slash) to the hostname so generated loc entries keep the subpath.
    hostname: `${SITE_URL}/`,
  },

  vite: {
    plugins: [llmstxt()],
  },

  head: [
    // Primary Meta Tags
    ["meta", { name: "title", content: SITE_NAME }],
    ["meta", { name: "description", content: SITE_DESCRIPTION }],
    ["meta", { name: "keywords", content: KEYWORDS }],
    ["meta", { name: "author", content: "Muhammad Fiaz" }],
    ["meta", { name: "robots", content: "index, follow" }],
    ["meta", { name: "language", content: "English" }],
    ["meta", { name: "revisit-after", content: "7 days" }],
    ["meta", { name: "generator", content: "VitePress" }],

    // Open Graph
    ["meta", { property: "og:type", content: "website" }],
    ["meta", { property: "og:url", content: SITE_URL }],
    ["meta", { property: "og:title", content: SITE_NAME }],
    ["meta", { property: "og:description", content: SITE_DESCRIPTION }],
    ["meta", { property: "og:image", content: `${SITE_URL}/cover.png` }],
    ["meta", { property: "og:image:width", content: "1536" }],
    ["meta", { property: "og:image:height", content: "1024" }],
    ["meta", { property: "og:image:alt", content: "httpx.zig - High Performance Zig HTTP Library" }],
    ["meta", { property: "og:image:secure_url", content: `${SITE_URL}/cover.png` }],
    ["meta", { property: "og:site_name", content: SITE_NAME }],
    ["meta", { property: "og:locale", content: "en_US" }],

    // Twitter Card
    ["meta", { name: "twitter:card", content: "summary_large_image" }],
    ["meta", { name: "twitter:url", content: SITE_URL }],
    ["meta", { name: "twitter:title", content: SITE_NAME }],
    ["meta", { name: "twitter:description", content: SITE_DESCRIPTION }],
    ["meta", { name: "twitter:image", content: `${SITE_URL}/cover.png` }],
    ["meta", { name: "twitter:image:alt", content: "httpx.zig - High Performance Zig HTTP Library" }],
    ["meta", { name: "twitter:site", content: "@muhammadfiaz_" }],
    ["meta", { name: "twitter:creator", content: "@muhammadfiaz_" }],

    // Canonical URL
    ["link", { rel: "canonical", href: SITE_URL }],

    // Favicons
    ["link", { rel: "icon", href: "/httpx.zig/favicon.ico" }],
    ["link", { rel: "icon", type: "image/png", sizes: "16x16", href: "/httpx.zig/favicon-16x16.png" }],
    ["link", { rel: "icon", type: "image/png", sizes: "32x32", href: "/httpx.zig/favicon-32x32.png" }],
    ["link", { rel: "apple-touch-icon", sizes: "180x180", href: "/httpx.zig/apple-touch-icon.png" }],
    ["link", { rel: "icon", type: "image/png", sizes: "192x192", href: "/httpx.zig/android-chrome-192x192.png" }],
    ["link", { rel: "icon", type: "image/png", sizes: "512x512", href: "/httpx.zig/android-chrome-512x512.png" }],
    ["link", { rel: "manifest", href: "/httpx.zig/site.webmanifest" }],

    // Theme color
    ["meta", { name: "theme-color", content: "#f7a41d" }],
    ["meta", { name: "msapplication-TileColor", content: "#f7a41d" }],

    // Google Analytics
    [
      "script",
      { async: "", src: `https://www.googletagmanager.com/gtag/js?id=${GA_ID}` },
    ],
    [
      "script",
      {},
      `window.dataLayer = window.dataLayer || [];
function gtag(){dataLayer.push(arguments);}
gtag('js', new Date());
gtag('config', '${GA_ID}');`,
    ],

    // Google Tag Manager
    ...(GTM_ID
      ? ([
          [
            "script",
            {},
            `(function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start': new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0], j=d.createElement(s), dl=l!='dataLayer'?'&l='+l:''; j.async=true; j.src='https://www.googletagmanager.com/gtm.js?id='+i+dl; f.parentNode.insertBefore(j,f);})(window,document,'script','dataLayer','${GTM_ID}');`,
          ],
          [
            "noscript",
            {},
            `<iframe src="https://www.googletagmanager.com/ns.html?id=${GTM_ID}" height="0" width="0" style="display:none;visibility:hidden"></iframe>`,
          ],
        ] as [string, Record<string, string>, string][])
      : []),

    // Google AdSense
    [
      "script",
      {
        async: "",
        src: `https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=${ADSENSE_CLIENT_ID}`,
        crossorigin: "anonymous",
      },
    ],
  ],

  ignoreDeadLinks: [/.*\.zig$/],

  transformPageData(pageData: any) {
    // Dynamic OG image generation based on page title
    const pageTitle = pageData.title || SITE_NAME;
    const pageDescription = pageData.description || SITE_DESCRIPTION;
    const normalizedPath = pageData.relativePath
      .replace(/\.md$/, "")
      .replace(/(^|\/)index$/, "$1")
      .replace(/\/$/, "");
    const canonicalUrl = normalizedPath.length > 0 ? `${SITE_URL}/${normalizedPath}` : SITE_URL;

    pageData.frontmatter.head ??= [];
    pageData.frontmatter.head.push(
      ["link", { rel: "canonical", href: canonicalUrl }],
      ["meta", { property: "og:title", content: `${pageTitle} | ${SITE_NAME}` }],
      ["meta", { property: "og:url", content: canonicalUrl }]
    );

    if (pageData.frontmatter.description) {
      pageData.frontmatter.head.push(
        ["meta", { property: "og:description", content: pageData.frontmatter.description }],
        ["meta", { name: "description", content: pageData.frontmatter.description }]
      );
    }

    // Dynamic JSON-LD Schema
    const isHome = pageData.relativePath === 'index.md';
    const lastUpdated = pageData.lastUpdated
      ? new Date(pageData.lastUpdated).toISOString()
      : new Date().toISOString();

    // Base Graph
    const graph: any[] = [];

    // 1. WebSite Schema (Global, but usually best on Home)
    if (isHome) {
      graph.push({
        "@type": "WebSite",
        "name": SITE_NAME,
        "url": SITE_URL,
        "description": SITE_DESCRIPTION,
        "author": {
          "@type": "Person",
          "name": "Muhammad Fiaz",
          "url": "https://github.com/muhammad-fiaz"
        }
      });
    }

    // 2. Main Entity Schema (SoftwareApplication or TechArticle)
    const authorSchema = {
      "@type": "Person",
      "name": "Muhammad Fiaz",
      "url": "https://muhammadfiaz.com",
      "sameAs": [
        "https://github.com/muhammad-fiaz",
        "https://www.linkedin.com/in/muhammad-fiaz-",
        "https://x.com/muhammadfiaz_"
      ]
    };

    const primarySchema: Record<string, any> = {
      "@type": isHome ? "SoftwareApplication" : "TechArticle",
      "name": isHome ? SITE_NAME : pageTitle,
      "description": pageDescription,
      "url": canonicalUrl,
      "image": `${SITE_URL}/cover.png`,
      "author": authorSchema,
      "publisher": {
        "@type": "Organization",
        "name": "httpx.zig",
        "url": SITE_URL,
        "logo": {
          "@type": "ImageObject",
          "url": `${SITE_URL}/logo.png`
        }
      }
    };

    if (isHome) {
      Object.assign(primarySchema, {
        "applicationCategory": "DeveloperApplication",
        "operatingSystem": "Cross-platform",
        "programmingLanguage": "Zig",
        "offers": {
          "@type": "Offer",
          "price": "0",
          "priceCurrency": "USD"
        },
        "downloadUrl": "https://github.com/muhammad-fiaz/httpx.zig",
        "softwareVersion": "0.2.0",
        "license": "https://opensource.org/licenses/MIT"
      });
    } else {
      // Extract section from path (e.g. guide/getting-started -> Guide)
      const pathParts = pageData.relativePath.split('/');
      const section = pathParts.length > 1
        ? pathParts[0].charAt(0).toUpperCase() + pathParts[0].slice(1)
        : 'Documentation';

      Object.assign(primarySchema, {
        "headline": pageTitle,
        "articleSection": section,
        "mainEntityOfPage": {
          "@type": "WebPage",
          "@id": canonicalUrl
        },
        "datePublished": "2026-01-01T00:00:00Z",
        "dateModified": lastUpdated
      });
    }
    graph.push(primarySchema);

    // 3. BreadcrumbList Schema
    const breadcrumbs: any[] = [
      {
        "@type": "ListItem",
        "position": 1,
        "name": "Home",
        "item": SITE_URL
      }
    ];

    if (!isHome) {
      const pathParts = pageData.relativePath.replace(/\.md$/, '').split('/');
      let currentPath = SITE_URL;

      pathParts.forEach((part: string, index: number) => {
        currentPath += `/${part}`;
        // Best effort capitalization
        const name = part.split('-').map(s => s.charAt(0).toUpperCase() + s.slice(1)).join(' ');

        breadcrumbs.push({
          "@type": "ListItem",
          "position": index + 2,
          "name": name,
          "item": index === pathParts.length - 1 ? canonicalUrl : currentPath
        });
      });
    }

    graph.push({
      "@type": "BreadcrumbList",
      "itemListElement": breadcrumbs
    });

    pageData.frontmatter.head.push([
      "script",
      { type: "application/ld+json" },
      JSON.stringify({
        "@context": "https://schema.org",
        "@graph": graph
      })
    ]);
  },

  themeConfig: {
    logo: "/logo.png",
    siteTitle: "httpx.zig",

    nav: [
      { text: "Home", link: "/" },
      { text: "Guide", link: "/guide/getting-started" },
      { text: "API", link: "/api/" },
      { text: "Web", link: "/web/graphql" },
      { text: "Protocols", link: "/protocols/http-1.1" },
      { text: "Security", link: "/security/overview" },
      { text: "Observability", link: "/observability/logging" },
      { text: "Examples", link: "/examples/" },
      { text: "Benchmarks", link: "/reference/benchmarks" },
      { text: "Releases", link: "https://github.com/muhammad-fiaz/httpx.zig/releases" },
      {
        text: "Support",
        items: [
          { text: "💖 Sponsor", link: "https://github.com/sponsors/muhammad-fiaz" },
          { text: "☕ Donate", link: "https://pay.muhammadfiaz.com" },
        ],
      },
      { text: "GitHub", link: "https://github.com/muhammad-fiaz/httpx.zig" },
    ],

    sidebar: {
      "/guide/": [
        {
          text: "Getting Started",
          items: [
            { text: "Getting Started", link: "/guide/getting-started" },
            { text: "Installation", link: "/guide/installation" },
          ],
        },
        {
          text: "Client Guide",
          items: [
            { text: "Client Basics", link: "/guide/client-basics" },
            { text: "Requests & Options", link: "/guide/requests" },
            { text: "Responses & Parsing", link: "/guide/responses" },
            { text: "Streaming Transfers", link: "/guide/streaming" },
            { text: "Cookie Handling", link: "/guide/cookies" },
            { text: "Authentication", link: "/guide/authentication" },
            { text: "Connection Pooling", link: "/guide/pooling" },
            { text: "Concurrency", link: "/guide/concurrency" },
            { text: "Proxies & SOCKS5", link: "/guide/proxies" },
            { text: "TLS & HTTPS", link: "/guide/tls" },
            { text: "DNS Resolution", link: "/guide/dns" },
          ],
        },
        {
          text: "Server Guide",
          items: [
            { text: "Routing", link: "/guide/routing" },
            { text: "Middleware", link: "/guide/middleware" },
            { text: "Static Files & SPA", link: "/guide/static-files" },
            { text: "Multipart Uploads", link: "/guide/multipart" },
            { text: "Session Management", link: "/guide/sessions" },
            { text: "Rate Limiting", link: "/guide/rate-limiting" },
            { text: "WebSockets", link: "/guide/websockets" },
            { text: "Server-Sent Events", link: "/guide/sse" },
            { text: "Deployment & Nginx", link: "/guide/deployment" },
          ],
        },
        {
          text: "Advanced & Protocols",
          items: [
            { text: "HTTP/2", link: "/guide/http2" },
            { text: "HTTP/3", link: "/guide/http3" },
            { text: "GraphQL", link: "/guide/graphql" },
            { text: "OpenAPI", link: "/guide/openapi" },
            { text: "Caching", link: "/guide/caching" },
            { text: "Compression", link: "/guide/compression" },
            { text: "Unix Domain Sockets", link: "/guide/unix-sockets" },
            { text: "Metrics", link: "/guide/metrics" },
            { text: "Interceptors", link: "/guide/interceptors" },
            { text: "Benchmarks", link: "/reference/benchmarks" },
          ],
        },
      ],
      "/api/": [
        {
          text: "API Reference",
          items: [
            { text: "API Overview", link: "/api/" },
            { text: "Core API", link: "/api/core" },
            { text: "Client API", link: "/api/client" },
            { text: "Server API", link: "/api/server" },
            { text: "Request API", link: "/api/request" },
            { text: "Response API", link: "/api/response" },
            { text: "Headers API", link: "/api/headers" },
            { text: "Router API", link: "/api/router" },
            { text: "Middleware API", link: "/api/middleware" },
            { text: "Connection Pool", link: "/api/pool" },
            { text: "Concurrency API", link: "/api/concurrency" },
            { text: "TLS API", link: "/api/tls" },
            { text: "DNS API", link: "/api/dns" },
            { text: "Network Sockets", link: "/api/net" },
            { text: "Protocol Primitives", link: "/api/protocol" },
            { text: "IO Abstraction", link: "/api/io" },
            { text: "Compression", link: "/api/compression" },
            { text: "Cache", link: "/api/cache" },
            { text: "Data Formats", link: "/api/data" },
            { text: "Metrics Registry", link: "/api/metrics" },
            { text: "Session Store", link: "/api/session" },
            { text: "Server-Sent Events", link: "/api/sse" },
            { text: "WebSocket", link: "/api/websocket" },
            { text: "FTP API", link: "/api/ftp" },
            { text: "Proxy API", link: "/api/proxy" },
            { text: "Utilities API", link: "/api/utils" },
          ],
        },
      ],
      "/web/": [
        {
          text: "Web Framework",
          items: [
            { text: "GraphQL Engine", link: "/web/graphql" },
            { text: "OpenAPI Specification", link: "/web/openapi" },
            { text: "Documentation UIs", link: "/web/documentation-ui" },
            { text: "HTML & DOM", link: "/web/html" },
            { text: "Static Files", link: "/web/static-files" },
            { text: "Single-Page Applications", link: "/web/spa" },
            { text: "HTML Templates", link: "/web/templates" },
            { text: "Server-Sent Events", link: "/web/sse" },
            { text: "WebSocket Engine", link: "/web/websocket" },
          ],
        },
      ],
      "/protocols/": [
        {
          text: "HTTP Protocols",
          items: [
            { text: "HTTP/1.0", link: "/protocols/http-1.0" },
            { text: "HTTP/1.1", link: "/protocols/http-1.1" },
            { text: "HTTP/2", link: "/protocols/http-2" },
            { text: "HTTP/3", link: "/protocols/http-3" },
          ],
        },
        {
          text: "Transport & Security",
          items: [
            { text: "TLS 1.2", link: "/protocols/tls-1.2" },
            { text: "TLS 1.3", link: "/protocols/tls-1.3" },
            { text: "ALPN Negotiation", link: "/protocols/alpn" },
            { text: "QUIC Transport", link: "/protocols/quic" },
            { text: "TCP Sockets", link: "/protocols/tcp" },
            { text: "UDP Datagrams", link: "/protocols/udp" },
          ],
        },
        {
          text: "Networking & FTP",
          items: [
            { text: "DNS Resolution", link: "/protocols/dns" },
            { text: "Proxies", link: "/protocols/proxies" },
            { text: "SOCKS5", link: "/protocols/socks5" },
            { text: "SOCKS5H Remote DNS", link: "/protocols/socks5h" },
            { text: "FTP Protocol", link: "/protocols/ftp" },
            { text: "FTPS (TLS)", link: "/protocols/ftp-tls" },
          ],
        },
      ],
      "/security/": [
        {
          text: "Security Architecture",
          items: [
            { text: "Security Overview", link: "/security/overview" },
            { text: "TLS Security", link: "/security/tls" },
            { text: "Security Headers", link: "/security/headers" },
            { text: "Path Traversal Defenses", link: "/security/path-security" },
            { text: "Request Limits", link: "/security/request-limits" },
            { text: "Cookie Hardening", link: "/security/cookies" },
            { text: "CORS Protection", link: "/security/cors" },
            { text: "Rate Limiting", link: "/security/rate-limiting" },
          ],
        },
      ],
      "/observability/": [
        {
          text: "Observability",
          items: [
            { text: "Structured Events", link: "/observability/events" },
            { text: "Logging Callbacks", link: "/observability/logging" },
            { text: "Prometheus Metrics", link: "/observability/metrics" },
            { text: "Distributed Tracing", link: "/observability/tracing" },
          ],
        },
      ],
      "/examples/": [
        {
          text: "Runnable Examples",
          items: [
            { text: "All Examples", link: "/examples/" },
            { text: "HTTP/1.1 Client", link: "/examples/http11-client" },
            { text: "HTTP/1.1 Server", link: "/examples/http11-server" },
            { text: "Simple GET", link: "/examples/simple-get" },
            { text: "Simple GET Deserialize", link: "/examples/simple-get-deserialize" },
            { text: "POST JSON", link: "/examples/post-json" },
            { text: "Custom Headers", link: "/examples/custom-headers" },
            { text: "HTTP Auth Helpers", link: "/examples/http-auth-helpers" },
            { text: "Concurrent Requests", link: "/examples/concurrent-requests" },
            { text: "Connection Pool", link: "/examples/connection-pool" },
            { text: "Cookies Demo", link: "/examples/cookies-demo" },
            { text: "Proxy Example", link: "/examples/proxy-example" },
            { text: "SOCKS5h Proxy", link: "/examples/socks5-proxy" },
            { text: "Simple Server", link: "/examples/simple-server" },
            { text: "Async Thread Server", link: "/examples/async-server-example" },
            { text: "Router Example", link: "/examples/router-example" },
            { text: "Middleware Example", link: "/examples/middleware-example" },
            { text: "Streaming", link: "/examples/streaming" },
            { text: "Static Files", link: "/examples/static-files" },
            { text: "Multi Page Website", link: "/examples/multi-page-website" },
            { text: "HTTP/2 Example", link: "/examples/http2-example" },
            { text: "HTTP/3 Example", link: "/examples/http3-example" },
            { text: "WebSocket Example", link: "/examples/websocket-example" },
            { text: "SSE Example", link: "/examples/sse-example" },
            { text: "Multipart Form Data", link: "/examples/multipart-example" },
            { text: "Metrics & Observability", link: "/examples/metrics-example" },
            { text: "Logging Callback", link: "/examples/logging-callback" },
            { text: "TLS Server", link: "/examples/tls-server" },
            { text: "HTTPS Client", link: "/examples/https-client" },
            { text: "TLS Custom CA", link: "/examples/tls-custom-ca" },
            { text: "FTP Client", link: "/examples/ftp-client" },
            { text: "FTP Server", link: "/examples/ftp-server" },
            { text: "FTP Download", link: "/examples/ftp-download" },
          ],
        },
      ],
      "/reference/": [
        {
          text: "Reference & Benchmarks",
          items: [
            { text: "CLI", link: "/reference/cli" },
            { text: "Benchmarks", link: "/reference/benchmarks" },
          ],
        },
      ],
    },

    socialLinks: [
      { icon: "github", link: "https://github.com/muhammad-fiaz/httpx.zig" },
    ],

    footer: {
      message: "Released under the MIT License.",
      copyright: "Copyright © 2026 Muhammad Fiaz",
    },

    search: {
      provider: "local",
    },

    editLink: {
      pattern: "https://github.com/muhammad-fiaz/httpx.zig/edit/main/docs/:path",
      text: "Edit this page on GitHub",
    },

    lastUpdated: {
      text: "Last updated",
      formatOptions: {
        dateStyle: "medium",
        timeStyle: "short",
      },
    },
  },
});
