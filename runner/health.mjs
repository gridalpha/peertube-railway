// Liveness probe for the transcoding runner.
//
// `peertube-runner server` speaks only to PeerTube, over HTTP and a WebSocket
// it opens itself, so the service would otherwise have no port for Railway to
// check and a crash-looping runner would report SUCCESS forever. This answers
// 200 only while the runner process the entrypoint started is still alive.

import http from "node:http";
import { readFileSync } from "node:fs";

const port = Number(process.env.PORT || 3000);
const pidFile = process.env.RUNNER_PID_FILE || "/tmp/runner.pid";

function runnerAlive() {
  try {
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    if (!Number.isInteger(pid) || pid <= 0) return false;
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

http
  .createServer((req, res) => {
    const alive = runnerAlive();
    res.writeHead(alive ? 200 : 503, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: alive ? "ok" : "down" }));
  })
  .listen(port, "::", () => console.log(`[runner] health server on :${port}`));
