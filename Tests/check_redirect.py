import http.server, threading, subprocess, sys
class RedirectFixture(http.server.BaseHTTPRequestHandler):
    followed = False
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.path == '/initial':
            self.send_response(307)
            self.send_header('Location', 'http://127.0.0.1:%s/redirected' % self.server.server_port)
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            type(self).followed = True
            self.send_response(200); self.send_header('Content-Length','0'); self.end_headers()
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1',0),RedirectFixture)
thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
try:
    subprocess.run([sys.argv[1], 'http://127.0.0.1:%s/initial'%server.server_port],check=True,timeout=15)
    assert not RedirectFixture.followed, 'Document body followed redirect'
finally:
    server.shutdown();server.server_close();thread.join()
