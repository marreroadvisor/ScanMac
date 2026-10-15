#!/usr/bin/env python3
"""Private ScanMac document service. Deploy behind HTTPS; stdlib only."""
from contextlib import closing
import threading
import argparse
import base64
import binascii
import hashlib
import hmac
import json
import os
import math
import re
import secrets
import sqlite3
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_PDF = 30 * 1024 * 1024
MAX_BODY = 42 * 1024 * 1024
PBKDF_ROUNDS = 600_000
TOKEN_TTL = 30 * 24 * 3600

SCHEMA = '''
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL, salt BLOB NOT NULL, password_hash BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS tokens(token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), expires REAL NOT NULL);
CREATE TABLE IF NOT EXISTS documents(user_id TEXT NOT NULL, document_id TEXT NOT NULL, record TEXT NOT NULL, version INTEGER NOT NULL, PRIMARY KEY(user_id,document_id));
CREATE TABLE IF NOT EXISTS versions(user_id TEXT NOT NULL, document_id TEXT NOT NULL, version INTEGER NOT NULL, pdf BLOB NOT NULL, record TEXT NOT NULL, created REAL NOT NULL, PRIMARY KEY(user_id,document_id,version));
CREATE TABLE IF NOT EXISTS shares(token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, document_id TEXT NOT NULL, version INTEGER NOT NULL, expires REAL NOT NULL);
'''


def digest(token):
    return hashlib.sha256(token.encode('utf-8')).hexdigest()


class APIError(Exception):
    def __init__(self, status, error, **fields):
        self.status, self.payload = status, {'error': error, **fields}


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, address, database):
        self.slots = threading.BoundedSemaphore(16)
        self.database = os.path.abspath(database)
        os.makedirs(os.path.dirname(self.database), mode=0o700, exist_ok=True)
        with closing(self.connect()) as db:
            db.executescript(SCHEMA)
        os.chmod(self.database, 0o600)
        super().__init__(address, Handler)

    def handle_error(self, request, client_address):
        # Do not emit request details or exception traces to shared logs.
        pass

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def connect(self):
        db = sqlite3.connect(self.database, timeout=10)
        db.execute('PRAGMA foreign_keys=ON')
        return db


class Handler(BaseHTTPRequestHandler):
    server_version = 'ScanMacPrivate/1'
    sys_version = ''
    protocol_version = 'HTTP/1.0'

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *_):
        # Paths may contain share credentials. Never log requests, credentials or bodies.
        pass

    def send_json(self, code, value):
        body = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        self.send_bytes(code, body, 'application/json; charset=utf-8')

    def send_bytes(self, code, body, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        if content_type == 'application/pdf':
            self.send_header('Content-Disposition', 'inline; filename="document.pdf"')
        self.end_headers()
        self.wfile.write(body)

    def body(self, limit=MAX_BODY):
        if self.headers.get('Transfer-Encoding'):
            raise APIError(400, 'Transfer encoding is not supported')
        try:
            size = int(self.headers.get('Content-Length', '-1'))
        except ValueError:
            raise APIError(400, 'Invalid content length')
        if size < 0:
            raise APIError(411, 'Content length required')
        if size > limit:
            raise APIError(413, 'Request too large')
        if self.headers.get_content_type() != 'application/json':
            raise APIError(415, 'JSON required')
        raw = self.rfile.read(size)
        if len(raw) != size:
            raise APIError(400, 'Incomplete request')
        try:
            value = json.loads(raw)
        except (ValueError, UnicodeError):
            raise APIError(400, 'Invalid JSON')
        if not isinstance(value, dict):
            raise APIError(400, 'JSON object required')
        return value

    def user(self, db):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer ') or len(auth) > 256:
            raise APIError(401, 'Authentication required')
        row = db.execute('SELECT user_id FROM tokens WHERE token_hash=? AND expires>?', (digest(auth[7:]), time.time())).fetchone()
        if not row:
            raise APIError(401, 'Invalid or expired token')
        return row[0]

    def authenticate(self, db, register):
        value = self.body(8192)
        username, password = value.get('username'), value.get('password')
        if not isinstance(username, str) or not re.fullmatch(r'[A-Za-z0-9_.-]{3,64}', username) or not isinstance(password, str) or not 10 <= len(password) <= 1024:
            raise APIError(400, 'Use a username of 3-64 letters, digits, dots, dashes or underscores and a password of 10-1024 characters')
        username = username.lower()
        row = db.execute('SELECT id,salt,password_hash FROM users WHERE username=?', (username,)).fetchone()
        if register:
            if row:
                raise APIError(409, 'Account unavailable')
            user_id, salt = str(uuid.uuid4()), secrets.token_bytes(32)
            password_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, PBKDF_ROUNDS)
            try:
                db.execute('INSERT INTO users VALUES(?,?,?,?)', (user_id, username, salt, password_hash))
            except sqlite3.IntegrityError:
                raise APIError(409, 'Account unavailable')
        else:
            salt = row[1] if row else b'\x00' * 32
            candidate = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, PBKDF_ROUNDS)
            if not row or not hmac.compare_digest(candidate, row[2]):
                raise APIError(401, 'Invalid credentials')
            user_id = row[0]
        token, expires = secrets.token_urlsafe(32), time.time() + TOKEN_TTL
        db.execute('INSERT INTO tokens VALUES(?,?,?)', (digest(token), user_id, expires))
        db.commit()
        self.send_json(201 if register else 200, {'token': token, 'expires_at': expires, 'username': username})

    def dispatch(self, method):
        path = self.path.split('?', 1)[0]
        with closing(self.server.connect()) as db:
            if method == 'GET' and path == '/health':
                return self.send_json(200, {'status': 'ok', 'service': 'ScanMacPrivate', 'api_version': 1})
            if method == 'POST' and path in ('/v1/register', '/v1/login'):
                return self.authenticate(db, path == '/v1/register')
            if method == 'GET' and path.startswith('/s/'):
                token = path[3:]
                if not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
                    raise APIError(404, 'Share unavailable')
                row = db.execute('SELECT v.pdf FROM shares s JOIN versions v ON v.user_id=s.user_id AND v.document_id=s.document_id AND v.version=s.version WHERE s.token_hash=? AND s.expires>?', (digest(token), time.time())).fetchone()
                if not row:
                    raise APIError(404, 'Share unavailable')
                return self.send_bytes(200, row[0], 'application/pdf')
            user_id = self.user(db)
            if method == 'GET' and path == '/v1/documents':
                rows = db.execute('SELECT record,version FROM documents WHERE user_id=? ORDER BY document_id', (user_id,)).fetchall()
                return self.send_json(200, {'documents': [{'record': json.loads(r), 'version': v} for r, v in rows]})
            if method == 'POST' and path == '/v1/shares':
                value = self.body(8192)
                doc_id, hours = value.get('document_id'), value.get('expires_hours', 24)
                if not isinstance(doc_id, str) or isinstance(hours, bool) or not isinstance(hours, (int, float)) or not 0 < hours <= 720:
                    raise APIError(400, 'Invalid share parameters')
                try:
                    doc_id = str(uuid.UUID(doc_id)).upper()
                except ValueError:
                    raise APIError(400, 'Invalid document identifier')
                row = db.execute('SELECT version FROM documents WHERE user_id=? AND document_id=?', (user_id, doc_id)).fetchone()
                if not row:
                    raise APIError(404, 'Document unavailable')
                token, expires = secrets.token_urlsafe(32), time.time() + hours * 3600
                db.execute('INSERT INTO shares VALUES(?,?,?,?,?)', (digest(token), user_id, doc_id, row[0], expires)); db.commit()
                return self.send_json(201, {'url_path': '/s/' + token, 'expires_at': expires})
            match = re.fullmatch(r'/v1/documents/([0-9a-fA-F-]{36})', path)
            if match:
                try:
                    doc_id = str(uuid.UUID(match[1])).upper()
                except ValueError:
                    raise APIError(400, 'Invalid document identifier')
                if method == 'GET':
                    row = db.execute('SELECT d.record,d.version,v.pdf FROM documents d JOIN versions v ON d.user_id=v.user_id AND d.document_id=v.document_id AND d.version=v.version WHERE d.user_id=? AND d.document_id=?', (user_id, doc_id)).fetchone()
                    if not row:
                        raise APIError(404, 'Document unavailable')
                    return self.send_json(200, {'record': json.loads(row[0]), 'version': row[1], 'pdf_base64': base64.b64encode(row[2]).decode('ascii')})
                if method == 'PUT':
                    value = self.body()
                    record, encoded, expected = value.get('record'), value.get('pdf_base64'), value.get('expected_version')
                    if not isinstance(record, dict) or not isinstance(encoded, str) or isinstance(expected, bool) or not isinstance(expected, int) or expected < 0:
                        raise APIError(400, 'Invalid document payload')
                    try:
                        record_id = str(uuid.UUID(record.get('id', ''))).upper()
                    except (ValueError, AttributeError, TypeError):
                        raise APIError(400, 'Invalid record identifier')
                    if record_id != doc_id or not isinstance(record.get('name'), str) or not 1 <= len(record['name']) <= 1000:
                        raise APIError(400, 'Record identifier and name required')
                    if len(encoded) > ((MAX_PDF + 2) // 3) * 4:
                        raise APIError(413, 'PDF exceeds 30 MiB')
                    try:
                        pdf = base64.b64decode(encoded, validate=True)
                    except (ValueError, binascii.Error):
                        raise APIError(400, 'Invalid PDF encoding')
                    if len(pdf) > MAX_PDF:
                        raise APIError(413, 'PDF exceeds 30 MiB')
                    if not pdf.startswith(b'%PDF-'):
                        raise APIError(400, 'PDF header required')
                    for field in ('date', 'updatedAt', 'trashedAt'):
                        number = record.get(field)
                        if (field == 'date' and number is None) or (number is not None and (isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number))):
                            raise APIError(400, 'Invalid record dates')
                    if not isinstance(record.get('starred'), bool) or not isinstance(record.get('text'), str):
                        raise APIError(400, 'Record text and starred flag required')
                    if record.get('signed') is not None and not isinstance(record['signed'], bool):
                        raise APIError(400, 'Invalid signed flag')
                    if record.get('folder') is not None and not isinstance(record['folder'], str):
                        raise APIError(400, 'Invalid folder')
                    if record.get('tags') is not None and (not isinstance(record['tags'], list) or not all(isinstance(tag, str) for tag in record['tags'])):
                        raise APIError(400, 'Invalid tags')
                    record['id'] = doc_id
                    metadata = json.dumps(record, ensure_ascii=False, allow_nan=False)
                    db.execute('BEGIN IMMEDIATE')
                    row = db.execute('SELECT version FROM documents WHERE user_id=? AND document_id=?', (user_id, doc_id)).fetchone()
                    current = row[0] if row else 0
                    if expected != current:
                        raise APIError(409, 'Revision conflict', current_version=current)
                    version = current + 1
                    db.execute('INSERT INTO versions VALUES(?,?,?,?,?,?)', (user_id, doc_id, version, pdf, metadata, time.time()))
                    db.execute('INSERT INTO documents VALUES(?,?,?,?) ON CONFLICT(user_id,document_id) DO UPDATE SET record=excluded.record,version=excluded.version', (user_id, doc_id, metadata, version))
                    db.commit()
                    return self.send_json(200, {'record': record, 'version': version})
            raise APIError(404, 'Route unavailable')

    def handle_api(self, method):
        try:
            self.dispatch(method)
        except APIError as error:
            self.send_json(error.status, error.payload)
        except (TimeoutError, ConnectionError, BrokenPipeError):
            self.close_connection = True
        except (ValueError, UnicodeError):
            self.send_json(400, {'error': 'Invalid request data'})
        except Exception:
            self.send_json(500, {'error': 'Service could not complete the request'})

    def do_GET(self):
        self.handle_api('GET')

    def do_POST(self):
        self.handle_api('POST')

    def do_PUT(self):
        self.handle_api('PUT')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--data-dir', default='./data', help='Private persistent storage directory')
    parser.add_argument('--database', help='Optional explicit SQLite filename; overrides --data-dir')
    args = parser.parse_args()
    server = Server((args.host, args.port), args.database or os.path.join(args.data_dir, 'scanmac.sqlite3'))
    print('ScanMac private service listening on %s:%s' % server.server_address)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
