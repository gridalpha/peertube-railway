// Public media gateway for PeerTube's Railway bucket.
//
// PeerTube hands the browser a plain object-storage URL for every public video:
// `buildObjectStoragePublicFileUrl()` in server/core/lib/object-storage/urls.ts
// builds it from the bucket endpoint, or from `base_url` when one is set, and
// only *private* videos are proxied by PeerTube itself. Railway's managed
// object storage implements neither anonymous read nor PutBucketPolicy (501),
// so a public video would 403 in the player.
//
// This service is the public half: it accepts GET/HEAD for keys under
// PeerTube's public media prefixes, signs the request to the bucket with SigV4,
// and streams the object back. It is what `base_url` points at.
//
// Nothing else reaches the bucket — no writes, no listings, no incoming query
// string forwarded, and in particular no `user-exports/` or
// `original-video-files/`, which PeerTube serves itself through its own
// presigned URLs and which are not meant to be readable by key alone.

const http = require("node:http");
const crypto = require("node:crypto");
const { Readable } = require("node:stream");

const endpoint = stripScheme(required("S3_ENDPOINT"));
const bucket = required("S3_BUCKET");
const accessKeyId = required("S3_ACCESS_KEY_ID");
const secretAccessKey = required("S3_SECRET_ACCESS_KEY");
const region = process.env.S3_REGION || "us-east-1";
const port = Number(process.env.PORT || 3000);
// The three prefixes PeerTube expects to be world readable. They match the
// `object_storage.*.prefix` values set on the PeerTube service.
const publicPrefixes = (
  process.env.PUBLIC_PREFIXES ||
  "web-videos/,streaming-playlists/,captions/"
)
  .split(",")
  .map((prefix) => prefix.trim())
  .filter(Boolean);
// Video and HLS segment filenames carry a uuid, so an object never changes
// under its key. Playlists (.m3u8) do change while a live stream is running.
const immutableCacheControl =
  process.env.CACHE_CONTROL || "public, max-age=315576000, immutable";
const playlistCacheControl =
  process.env.PLAYLIST_CACHE_CONTROL || "public, max-age=2";

function required(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`Missing required environment variable ${name}`);
    process.exit(1);
  }
  return value;
}

function stripScheme(value) {
  return value.replace(/^https?:\/\//, "").replace(/\/+$/, "");
}

const hmac = (key, data) => crypto.createHmac("sha256", key).update(data).digest();
const sha256 = (data) => crypto.createHash("sha256").update(data).digest("hex");

// Every path segment is encoded, but `/` stays a separator: S3 canonicalises
// the URI segment by segment.
const encodeKey = (key) => key.split("/").map(encodeURIComponent).join("/");

// RFC 3986 encoding for query values — S3's canonical query string wants the
// stricter form, which encodeURIComponent leaves alone for ! ' ( ) *.
const encodeQuery = (value) =>
  encodeURIComponent(value).replace(
    /[!'()*]/g,
    (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase(),
  );

function signedHeaders(method, canonicalUri, canonicalQuery) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = sha256("");
  const canonicalHeaders =
    `host:${endpoint}\n` +
    `x-amz-content-sha256:${payloadHash}\n` +
    `x-amz-date:${amzDate}\n`;
  const signed = "host;x-amz-content-sha256;x-amz-date";
  const canonicalRequest = [
    method,
    canonicalUri,
    canonicalQuery,
    canonicalHeaders,
    signed,
    payloadHash,
  ].join("\n");
  const scope = `${dateStamp}/${region}/s3/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    scope,
    sha256(canonicalRequest),
  ].join("\n");
  const signingKey = hmac(
    hmac(hmac(hmac(`AWS4${secretAccessKey}`, dateStamp), region), "s3"),
    "aws4_request",
  );
  const signature = crypto
    .createHmac("sha256", signingKey)
    .update(stringToSign)
    .digest("hex");

  return {
    host: endpoint,
    "x-amz-content-sha256": payloadHash,
    "x-amz-date": amzDate,
    authorization:
      `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, ` +
      `SignedHeaders=${signed}, Signature=${signature}`,
  };
}

// Anything that is not a plain, non-traversing key under one of the public
// prefixes is refused before a request is ever signed.
function parseKey(url) {
  let key;
  try {
    key = decodeURIComponent(url.split("?")[0].replace(/^\/+/, ""));
  } catch {
    return null;
  }
  // With `object_storage.force_path_style`, PeerTube puts the bucket name in
  // the path — both in the URLs it builds and in the presigned ones it rewrites
  // onto this host. Accept either shape.
  if (key.startsWith(`${bucket}/`)) key = key.slice(bucket.length + 1);
  if (!publicPrefixes.some((prefix) => key.startsWith(prefix))) return null;
  if (key.endsWith("/")) return null;
  if (key.split("/").some((s) => s === "" || s === "." || s === "..")) return null;
  if (/[\x00-\x1f\x7f]/.test(key)) return null;
  return key;
}

// PeerTube's own presigned download URLs are rewritten onto this host by
// `replaceByBaseUrl`, so they arrive carrying someone else's signature plus a
// `response-content-disposition`. The signature is discarded — this gateway
// re-signs — but the disposition is honoured, or the Download button would play
// the file inline instead of saving it.
function contentDisposition(url) {
  const query = url.includes("?") ? url.slice(url.indexOf("?") + 1) : "";
  const value = new URLSearchParams(query).get("response-content-disposition");
  if (!value) return null;
  if (/[\x00-\x1f\x7f]/.test(value)) return null;
  return value.slice(0, 512);
}

const passThrough = [
  "content-type",
  "content-length",
  "content-disposition",
  "content-encoding",
  "etag",
  "last-modified",
  "accept-ranges",
  "content-range",
];

const corsHeaders = {
  // The player fetches HLS playlists and segments cross-origin from PeerTube's
  // own domain, and other instances embed the files. Everything served here is
  // public by definition and no credential is ever accepted.
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, HEAD, OPTIONS",
  "access-control-allow-headers": "range, content-type",
  "access-control-expose-headers":
    "content-length, content-range, accept-ranges, etag, content-type",
  "access-control-max-age": "86400",
};

const server = http.createServer(async (req, res) => {
  const path = req.url.split("?")[0];

  if (path === "/healthz") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end('{"status":"ok"}');
    return;
  }

  if (req.method === "OPTIONS") {
    res.writeHead(204, corsHeaders).end();
    return;
  }

  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { allow: "GET, HEAD, OPTIONS" }).end();
    return;
  }

  const key = parseKey(req.url);
  if (!key) {
    res.writeHead(404).end();
    return;
  }

  const canonicalUri = `/${encodeKey(bucket)}/${encodeKey(key)}`;
  const disposition = contentDisposition(req.url);
  const canonicalQuery = disposition
    ? `response-content-disposition=${encodeQuery(disposition)}`
    : "";
  const upstream =
    `https://${endpoint}${canonicalUri}` +
    (canonicalQuery ? `?${canonicalQuery}` : "");

  try {
    const headers = signedHeaders(req.method, canonicalUri, canonicalQuery);
    if (req.headers.range) headers.range = req.headers.range;
    const response = await fetch(upstream, { method: req.method, headers });

    if (!response.ok && response.status !== 206) {
      res.writeHead(response.status === 404 ? 404 : 502, corsHeaders).end();
      return;
    }

    const out = {
      ...corsHeaders,
      "cache-control": key.endsWith(".m3u8")
        ? playlistCacheControl
        : immutableCacheControl,
      "x-content-type-options": "nosniff",
    };
    for (const name of passThrough) {
      const value = response.headers.get(name);
      if (value) out[name] = value;
    }

    res.writeHead(response.status, out);
    if (req.method === "HEAD" || !response.body) {
      res.end();
      return;
    }
    Readable.fromWeb(response.body).pipe(res);
  } catch (error) {
    console.error(`Failed to serve ${key}:`, error);
    if (!res.headersSent) res.writeHead(502);
    res.end();
  }
});

// Railway's edge pools connections; a server that closes them first turns into
// intermittent 502s on exactly the lazily fetched requests a video player makes.
server.keepAliveTimeout = 65000;
server.headersTimeout = 70000;

server.listen(port, "::", () => {
  console.log(`PeerTube media gateway listening on :${port}`);
  console.log(`Serving ${publicPrefixes.join(", ")} from ${bucket} at ${endpoint}`);
});

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
