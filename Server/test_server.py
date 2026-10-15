import base64
import hashlib
import http.client
import json
import os
import sqlite3
import tempfile
import threading
import time
import unittest
import uuid
from server import Server, MAX_BODY, PBKDF_ROUNDS

PDF = b'%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n%%EOF\n'


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.database = os.path.join(cls.temp.name, 'private.sqlite3')
        cls.server = Server(('127.0.0.1', 0), cls.database)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()
        cls.temp.cleanup()

    def request(self, method, path, payload=None, token=None, raw=False, headers=None):
        call = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        h = {'Content-Type': 'application/json'}
        if token:
            h['Authorization'] = 'Bearer ' + token
        if headers:
            h.update(headers)
        body = json.dumps(payload).encode() if payload is not None else None
        call.request(method, path, body, h)
        response = call.getresponse(); data = response.read(); code = response.status
        call.close()
        return code, data if raw else json.loads(data)

    def account(self):
        username = 'user_' + uuid.uuid4().hex
        code, value = self.request('POST', '/v1/register', {'username': username, 'password': 'test-password-01234'})
        self.assertEqual(code, 201)
        return username, value['token']

    def upload(self, token, doc_id=None, version=0, data=PDF, name='Synthetic'):
        doc_id = doc_id or str(uuid.uuid4()).upper()
        payload = {'record': {'id': doc_id, 'name': name, 'date': 0, 'starred': False, 'text': 'OCR <&>'}, 'pdf_base64': base64.b64encode(data).decode(), 'expected_version': version}
        return doc_id, self.request('PUT', '/v1/documents/' + doc_id, payload, token)

    def test_authentication_and_hashed_secrets(self):
        username, token = self.account()
        self.assertEqual(self.request('GET', '/v1/documents')[0], 401)
        self.assertEqual(self.request('GET', '/v1/documents', token=token[:-1] + '!')[0], 401)
        self.assertEqual(self.request('POST', '/v1/login', {'username': username, 'password': 'incorrect-password'})[0], 401)
        code, logged = self.request('POST', '/v1/login', {'username': username, 'password': 'test-password-01234'})
        self.assertEqual(code, 200); self.assertNotEqual(token, logged['token'])
        with sqlite3.connect(self.database) as db:
            stored = db.execute('SELECT token_hash FROM tokens WHERE token_hash=?', (hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
            row = db.execute('SELECT salt,password_hash FROM users WHERE username=?', (username,)).fetchone()
            self.assertIsNotNone(stored); self.assertEqual(len(row[0]), 32); self.assertEqual(len(row[1]), 32)
            self.assertNotEqual(row[1], b'test-password-01234')
            db.execute('UPDATE tokens SET expires=0 WHERE token_hash=?', (stored[0],))
        self.assertGreaterEqual(PBKDF_ROUNDS, 300000)
        self.assertEqual(self.request('GET', '/v1/documents', token=token)[0], 401)

    def test_isolation_revisions_and_preserved_versions(self):
        _, a = self.account(); _, b = self.account()
        doc, (code, first) = self.upload(a)
        self.assertEqual((code, first['version']), (200, 1))
        self.assertEqual(self.request('GET', '/v1/documents/' + doc, token=b)[0], 404)
        self.assertEqual(self.request('GET', '/v1/documents', token=b)[1]['documents'], [])
        self.assertEqual(self.request('POST', '/v1/shares', {'document_id': doc, 'expires_hours': 1}, b)[0], 404)
        _, (code, conflict) = self.upload(a, doc, 0, PDF + b'new')
        self.assertEqual(code, 409); self.assertEqual(conflict['current_version'], 1)
        _, (code, second) = self.upload(a, doc, 1, PDF + b'new')
        self.assertEqual((code, second['version']), (200, 2))
        fetched = self.request('GET', '/v1/documents/' + doc.lower(), token=a)[1]
        self.assertEqual(base64.b64decode(fetched['pdf_base64']), PDF + b'new')
        with sqlite3.connect(self.database) as db:
            versions = db.execute('SELECT version,pdf FROM versions WHERE document_id=? ORDER BY version', (doc,)).fetchall()
        self.assertEqual(versions, [(1, PDF), (2, PDF + b'new')])
        # Same UUID is isolated per user, never overwrites another account's version.
        _, (code, _) = self.upload(b, doc, 0, PDF + b'other')
        self.assertEqual(code, 200)
        self.assertEqual(base64.b64decode(self.request('GET', '/v1/documents/' + doc, token=a)[1]['pdf_base64']), PDF + b'new')

    def test_share_snapshot_expiry_and_tampering(self):
        _, token = self.account(); doc, _ = self.upload(token)
        code, share = self.request('POST', '/v1/shares', {'document_id': doc.lower(), 'expires_hours': 1}, token)
        self.assertEqual(code, 201)
        self.upload(token, doc, 1, PDF + b'new')
        self.assertEqual(self.request('GET', share['url_path'], raw=True), (200, PDF))
        self.assertEqual(self.request('GET', share['url_path'] + 'x')[0], 404)
        self.assertEqual(self.request('PUT', share['url_path'], {}, token)[0], 404)
        with sqlite3.connect(self.database) as db:
            db.execute('UPDATE shares SET expires=0 WHERE token_hash=?', (hashlib.sha256(share['url_path'][3:].encode()).hexdigest(),))
        self.assertEqual(self.request('GET', share['url_path'])[0], 404)

    def test_concurrent_revision_serialization_and_health(self):
        code, health = self.request('GET', '/health')
        self.assertEqual(code, 200); self.assertEqual(health['service'], 'ScanMacPrivate')
        _, token = self.account(); doc = str(uuid.uuid4()).upper()
        barrier = threading.Barrier(2); results = []
        def writer():
            barrier.wait()
            results.append(self.upload(token, doc, 0)[1][0])
        threads = [threading.Thread(target=writer) for _ in range(2)]
        for thread in threads: thread.start()
        for thread in threads: thread.join()
        self.assertEqual(sorted(results), [200, 409])
        self.assertEqual(self.request('GET', '/v1/documents/' + doc, token=token)[1]['version'], 1)

    def test_payload_validation_and_request_size(self):
        _, token = self.account(); doc = str(uuid.uuid4())
        self.assertEqual(self.request('PUT', '/v1/documents/' + doc, {'record': {'id': doc, 'name': 'x'}, 'pdf_base64': 'broken', 'expected_version': 0}, token)[0], 400)
        self.assertEqual(self.upload(token, data=b'not a PDF')[1][0], 400)
        self.assertEqual(self.request('POST', '/v1/shares', {'document_id': doc, 'expires_hours': -1}, token)[0], 400)
        self.assertEqual(self.request('PUT', '/v1/documents/' + doc, {}, token, headers={'Content-Length': str(MAX_BODY + 1)})[0], 413)
        self.assertEqual(self.request('POST', '/v1/register', {'username': "' OR 1=1", 'password': 'test-password-01234'})[0], 400)


if __name__ == '__main__':
    unittest.main()
