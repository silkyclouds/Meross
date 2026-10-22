import net from 'node:net';
import type { Response } from 'node-fetch';

/**
 * Minimal fetch replacement that tolerates the malformed HTTP responses Meross
 * devices return.
 *
 * Their firmware terminates the status line with a bare line feed instead of
 * CRLF. Node's parser rejects that with "Missing expected CR after response
 * line", and `--insecure-http-parser` does not relax this particular check, so
 * every request through node-fetch fails on current Node releases. Reading the
 * socket directly is the only way to stay compatible with the devices already
 * in the field, whose firmware cannot be fixed.
 *
 * Only the subset of the Response interface used by HTTPTransport is provided.
 */

const RESPONSE_TIMEOUT_MS = 20_000;

type LenientRequestInit = {
  method?: string;
  headers?: Record<string, string>;
  body?: string;
};

function buildRequest(url: URL, init: LenientRequestInit): string {
  const body = init.body ?? '';
  const headers = Object.entries(init.headers ?? {})
    .map(([name, value]) => `${name}: ${value}`)
    .join('\r\n');

  return (
    `${init.method ?? 'GET'} ${url.pathname}${url.search} HTTP/1.1\r\n` +
    `Host: ${url.hostname}\r\n` +
    (headers ? `${headers}\r\n` : '') +
    `Content-Length: ${Buffer.byteLength(body)}\r\n` +
    `Connection: close\r\n\r\n${body}`
  );
}

function splitHeadAndBody(raw: string): { head: string; body: string } {
  const separator = raw.includes('\r\n\r\n') ? '\r\n\r\n' : '\n\n';
  const index = raw.indexOf(separator);
  if (index < 0) {
    return { head: raw, body: '' };
  }
  return { head: raw.slice(0, index), body: raw.slice(index + separator.length) };
}

function decodeChunked(body: string): string {
  let remaining = body;
  let decoded = '';

  while (remaining.length) {
    const lineEnd = remaining.search(/\r?\n/);
    if (lineEnd < 0) break;

    const size = parseInt(remaining.slice(0, lineEnd).trim(), 16);
    if (!Number.isFinite(size) || size <= 0) break;

    const start = lineEnd + (remaining[lineEnd] === '\r' ? 2 : 1);
    decoded += remaining.slice(start, start + size);
    remaining = remaining.slice(start + size).replace(/^\r?\n/, '');
  }

  return decoded;
}

function parseHeaders(head: string): Map<string, string> {
  const headers = new Map<string, string>();
  for (const line of head.split(/\r?\n/).slice(1)) {
    const separator = line.indexOf(':');
    if (separator > 0) {
      headers.set(
        line.slice(0, separator).trim().toLowerCase(),
        line.slice(separator + 1).trim(),
      );
    }
  }
  return headers;
}

function buildResponse(raw: string): Response {
  const { head, body } = splitHeadAndBody(raw);
  const headers = parseHeaders(head);
  const statusLine = head.match(/HTTP\/[\d.]+\s+(\d+)\s*(.*)/);
  const status = Number(statusLine?.[1] ?? 0);
  const statusText = statusLine?.[2]?.trim() ?? '';

  const text =
    headers.get('transfer-encoding')?.toLowerCase() === 'chunked'
      ? decodeChunked(body)
      : body;

  const make = (): Response =>
    ({
      ok: status >= 200 && status < 300,
      status,
      statusText,
      headers,
      text: async () => text,
      json: async () => JSON.parse(text),
      clone: () => make(),
    }) as unknown as Response;

  return make();
}

export function lenientFetch(
  url: string,
  init: LenientRequestInit = {},
): Promise<Response> {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const socket = net.connect(
      target.port ? Number(target.port) : 80,
      target.hostname,
    );
    const chunks: Buffer[] = [];
    let settled = false;

    const fail = (error: Error) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(error);
    };

    socket.setTimeout(RESPONSE_TIMEOUT_MS);
    socket.on('connect', () => socket.write(buildRequest(target, init)));
    socket.on('data', (chunk) => chunks.push(chunk));
    socket.on('error', fail);
    socket.on('timeout', () =>
      fail(new Error(`No response from ${target.hostname} within ${RESPONSE_TIMEOUT_MS} ms`)),
    );
    socket.on('close', () => {
      if (settled) return;
      settled = true;
      resolve(buildResponse(Buffer.concat(chunks).toString('utf-8')));
    });
  });
}
