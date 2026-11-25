#!/usr/bin/env node
// HTTP proxy -> SOCKS5 shim. No dependencies.
//
// npm (and curl, pip, git over https, ...) speak "HTTP proxy": plain requests
// with an absolute URL, and CONNECT for https. The reverse tunnel the client
// opens only offers SOCKS5 (ssh -R <port>). This process listens as an HTTP
// proxy on 127.0.0.1:PROXY_PORT and re-dials every request through the SOCKS5
// port, so the traffic leaves the network from the client machine.
//
// Host names are passed to SOCKS unresolved, so DNS also happens on the client.
'use strict';

const http = require('node:http');
const net = require('node:net');

const PROXY_PORT = Number(process.env.PROXY_PORT || 3128);
const SOCKS_PORT = Number(process.env.SOCKS_PORT || 1080);
const SOCKS_HOST = '127.0.0.1';
const HANDSHAKE_TIMEOUT_MS = 15000;

const TUNNEL_DOWN =
  'git-tunnel: the client tunnel is not connected. ' +
  'Run scripts/connect.sh on the client machine.\n';

function log(msg) {
  process.stderr.write(`http-to-socks: ${msg}\n`);
}

// Opens a SOCKS5 connection to host:port. cb(err, socket); the socket is paused.
function socksConnect(host, port, cb) {
  const sock = net.connect(SOCKS_PORT, SOCKS_HOST);
  let buf = Buffer.alloc(0);
  let stage = 'greeting';
  let done = false;

  const timer = setTimeout(
    () => finish(new Error('SOCKS handshake timed out')),
    HANDSHAKE_TIMEOUT_MS,
  );

  function finish(err) {
    if (done) return;
    done = true;
    clearTimeout(timer);
    sock.removeListener('data', onData);
    sock.removeListener('error', finish);
    sock.removeListener('close', onClose);
    if (err) {
      sock.on('error', () => {});
      sock.destroy();
      cb(err);
      return;
    }
    sock.pause();
    if (buf.length) sock.unshift(buf);
    cb(null, sock);
  }

  function onClose() {
    finish(
      new Error(
        `${host}:${port} was refused by the client tunnel. ` +
          'It only allows the destinations given to connect.sh with --allow (default *:443)',
      ),
    );
  }

  function request() {
    let addr;
    if (net.isIPv4(host)) {
      addr = Buffer.from([1, ...host.split('.').map(Number)]);
    } else if (net.isIPv6(host)) {
      // Let the SOCKS server parse it: send as a name. OpenSSH accepts this.
      addr = Buffer.concat([Buffer.from([3, Buffer.byteLength(host)]), Buffer.from(host)]);
    } else {
      const name = Buffer.from(host);
      if (name.length === 0 || name.length > 255) {
        finish(new Error(`invalid host name: ${host}`));
        return;
      }
      addr = Buffer.concat([Buffer.from([3, name.length]), name]);
    }
    const p = Buffer.alloc(2);
    p.writeUInt16BE(port);
    sock.write(Buffer.concat([Buffer.from([5, 1, 0]), addr, p]));
  }

  function onData(chunk) {
    buf = Buffer.concat([buf, chunk]);
    if (stage === 'greeting') {
      if (buf.length < 2) return;
      if (buf[0] !== 5 || buf[1] !== 0) {
        finish(new Error('SOCKS server refused the no-auth method'));
        return;
      }
      buf = buf.subarray(2);
      stage = 'reply';
      request();
    }
    if (stage === 'reply') {
      if (buf.length < 5) return;
      let len;
      if (buf[3] === 1) len = 10;
      else if (buf[3] === 4) len = 22;
      else if (buf[3] === 3) len = 7 + buf[4];
      else {
        finish(new Error('malformed SOCKS reply'));
        return;
      }
      if (buf.length < len) return;
      if (buf[1] !== 0) {
        finish(new Error(`SOCKS connect to ${host}:${port} failed (code ${buf[1]})`));
        return;
      }
      buf = buf.subarray(len);
      finish(null);
    }
  }

  sock.on('data', onData);
  sock.once('error', finish);
  sock.once('close', onClose);
  sock.once('connect', () => sock.write(Buffer.from([5, 1, 0])));
}

function describe(err) {
  if (err && err.code === 'ECONNREFUSED') return TUNNEL_DOWN;
  return `git-tunnel proxy error: ${err ? err.message : 'unknown'}\n`;
}

// "host:port" or "[v6]:port"
function parseAuthority(authority) {
  const m = /^(?:\[([^\]]+)\]|([^:]+)):(\d+)$/.exec(authority || '');
  if (!m) return null;
  const port = Number(m[3]);
  if (port < 1 || port > 65535) return null;
  return { host: m[1] || m[2], port };
}

// Outgoing plain-http requests get their socket from the SOCKS tunnel.
class SocksAgent extends http.Agent {
  createConnection(options, cb) {
    socksConnect(options.host, Number(options.port), (err, sock) => {
      cb(err, sock);
      // socksConnect hands the socket over paused. The http client has
      // attached its listeners by now, so let the data flow.
      if (sock) sock.resume();
    });
  }
}
const socksAgent = new SocksAgent({ keepAlive: false });

const HOP_BY_HOP = [
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'proxy-connection',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
];

const server = http.createServer((req, res) => {
  // Plain http:// request with an absolute URL.
  let url;
  try {
    url = new URL(req.url);
  } catch {
    url = null;
  }
  if (!url || url.protocol !== 'http:') {
    res.writeHead(400, { 'content-type': 'text/plain' });
    res.end('git-tunnel: this is a forward proxy. Use it through HTTP_PROXY / HTTPS_PROXY.\n');
    return;
  }
  const host = url.hostname.replace(/^\[|\]$/g, '');
  const port = Number(url.port || 80);

  const headers = { ...req.headers };
  const chunked = /chunked/i.test(headers['transfer-encoding'] || '');
  for (const h of HOP_BY_HOP) delete headers[h];
  if (chunked) headers['transfer-encoding'] = 'chunked';
  headers.connection = 'close';

  const out = http.request(
    {
      agent: socksAgent,
      host,
      port,
      method: req.method,
      path: url.pathname + url.search,
      headers,
      setHost: false,
    },
    (upRes) => {
      res.writeHead(upRes.statusCode, upRes.statusMessage, upRes.headers);
      upRes.pipe(res);
    },
  );
  out.on('error', (e) => {
    log(`${req.method} ${url.host}: ${e.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'text/plain' });
      res.end(describe(e));
    } else {
      res.destroy();
    }
  });
  req.pipe(out);
});

// https and everything else: CONNECT host:port
server.on('connect', (req, client, head) => {
  client.on('error', () => {});
  const target = parseAuthority(req.url);
  if (!target) {
    client.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    return;
  }
  socksConnect(target.host, target.port, (err, upstream) => {
    if (err) {
      log(`CONNECT ${req.url}: ${err.message}`);
      const body = describe(err);
      client.end(
        'HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\n' +
          `Content-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
      );
      return;
    }
    if (client.destroyed) {
      upstream.destroy();
      return;
    }
    upstream.on('error', () => client.destroy());
    client.on('error', () => upstream.destroy());
    upstream.on('close', () => client.destroy());
    client.on('close', () => upstream.destroy());
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) upstream.write(head);
    upstream.pipe(client);
    client.pipe(upstream);
  });
});

server.on('clientError', (err, socket) => {
  if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
});

server.listen(PROXY_PORT, '127.0.0.1', () => {
  log(`HTTP proxy on 127.0.0.1:${PROXY_PORT} -> SOCKS5 127.0.0.1:${SOCKS_PORT}`);
});
