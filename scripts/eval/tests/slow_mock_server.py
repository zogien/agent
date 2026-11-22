"""Local SSE fixture for evaluation runtime tests."""
import http.server
import json
import socketserver
import threading
import time


def slow_text_then_tooluse(n_chunks=15, delay=0.5, tool="Read", tool_input='{"file_path":"/tmp/bgtest_file.txt"}'):
    parts = [
        b'data: {"type":"message_start","message":{"id":"m1","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n',
        b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
    ]
    for i in range(n_chunks):
        parts.append((b'__DELAY__%f\n' % delay))
        parts.append(('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"tok%d "}}\n\n' % i).encode())
    parts += [
        b'data: {"type":"content_block_stop","index":0}\n\n',
        ('data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"%s","input":{}}}\n\n' % tool).encode(),
        ('data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":%s}}\n\n' % json.dumps(tool_input)).encode(),
        b'data: {"type":"content_block_stop","index":1}\n\n',
        b'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":5}}\n\n',
        b'data: {"type":"message_stop"}\n\n',
    ]
    return b''.join(parts)


def simple_text(text="SHOULD_NOT_REACH"):
    return (
        b'data: {"type":"message_start","message":{"id":"m2","role":"assistant","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}\n\n'
        b'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
        + ('data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"%s"}}\n\n' % text).encode()
        + b'data: {"type":"content_block_stop","index":0}\n\n'
        b'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n'
        b'data: {"type":"message_stop"}\n\n'
    )


class SlowMockServer:
    """Replay scripted SSE responses and record incoming request bodies."""

    def __init__(self, turns):
        self.turns = turns
        self.turn_idx = 0
        self.requests = []
        self._srv = None
        self._thr = None
        self.port = None

    def __enter__(self):
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                ln = int(self.headers.get('content-length', 0))
                outer.requests.append(self.rfile.read(ln))
                idx = min(outer.turn_idx, len(outer.turns) - 1)
                outer.turn_idx += 1
                body = outer.turns[idx]
                self.send_response(200)
                self.send_header('content-type', 'text/event-stream')
                self.end_headers()
                for chunk in _split_delays(body):
                    if isinstance(chunk, float):
                        time.sleep(chunk)
                    else:
                        try:
                            self.wfile.write(chunk)
                            self.wfile.flush()
                        except (BrokenPipeError, ConnectionResetError):
                            return

        socketserver.TCPServer.allow_reuse_address = True
        self._srv = socketserver.TCPServer(("127.0.0.1", 0), H)
        self.port = self._srv.server_address[1]
        self._thr = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thr.start()
        return self

    @property
    def url(self):
        return "http://127.0.0.1:%d/v1/messages" % self.port

    def __exit__(self, *a):
        if self._srv:
            self._srv.shutdown()
            self._srv.server_close()


def _split_delays(body):
    """Split SSE bytes at delay markers."""
    out = []
    i = 0
    marker = b'__DELAY__'
    while i < len(body):
        j = body.find(marker, i)
        if j == -1:
            out.append(body[i:])
            break
        if j > i:
            out.append(body[i:j])
        nl = body.find(b'\n', j)
        sec = float(body[j + len(marker):nl])
        out.append(sec)
        i = nl + 1
    return out
