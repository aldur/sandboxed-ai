"""Exercise the actual sandboxed TensorFold server over TCP or a UNIX socket."""
import http.client
import json
import os
import socket
import stat
import sys
import time

transport, address, pid = sys.argv[1], sys.argv[2], int(sys.argv[3])


class UnixConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(address)


def request(path, body=None, stream=False):
    conn = (UnixConnection('localhost', timeout=180) if transport == 'unix'
            else http.client.HTTPConnection('127.0.0.1', int(address), timeout=180))
    try:
        conn.request('GET' if body is None else 'POST', path,
                     body=None if body is None else json.dumps(body),
                     headers={'Content-Type': 'application/json'})
        response = conn.getresponse()
        assert response.status == 200, (response.status, response.read().decode())
        if stream:
            events = []
            while line := response.readline():
                if not line.startswith(b'data: '):
                    continue
                data = line[6:].strip()
                if data == b'[DONE]':
                    return events
                events.append(json.loads(data))
            raise AssertionError('SSE stream ended without [DONE]')
        return json.load(response)
    finally:
        conn.close()


for _ in range(300):
    os.kill(pid, 0)
    try:
        health = request('/health')
        assert health['status'] == 'ok'
        break
    except (OSError, http.client.HTTPException):
        time.sleep(2)
else:
    raise AssertionError('server did not become healthy in 600s')
print(f'ok   - TensorFold ({transport}) healthy', flush=True)
if transport == 'unix':
    assert stat.S_IMODE(os.stat(address).st_mode) == 0o600
models = request('/v1/models')['data']
assert models and models[0]['meta']['n_ctx'] == 2048
model = models[0]['id']
assert request('/props')['default_generation_settings']['n_ctx'] == 2048
body = {'model': model, 'messages': [{'role': 'user', 'content': 'Say hello.'}],
        'max_tokens': 16, 'temperature': 0, 'seed': 42}
reply = request('/v1/chat/completions', body)
text = reply['choices'][0]['message']['content']
assert text.strip(), reply
assert reply['usage']['completion_tokens'] > 0, reply
serial = request('/v1/chat/completions', {**body, 'draft': False})
assert serial['choices'][0]['message']['content'] == text, (reply, serial)
events = request('/v1/chat/completions', {**body, 'stream': True}, stream=True)
stream_text = ''.join(e['choices'][0]['delta'].get('content', '')
                      for e in events if e.get('choices'))
assert stream_text == text, (stream_text, text)
assert any(e.get('choices') and e['choices'][0].get('finish_reason') for e in events)
followup = request('/v1/chat/completions', {
    **body, 'messages': body['messages'] + [{'role': 'assistant', 'content': text},
                                          {'role': 'user', 'content': 'Say goodbye.'}]})
assert followup['choices'][0]['message']['content'].strip(), followup
response = request('/v1/responses', {'model': model, 'input': 'Say hello.',
                                    'max_output_tokens': 16, 'temperature': 0})
assert response['object'] == 'response' and response['output'], response
completion = request('/v1/completions', {'model': model, 'prompt': 'Hello',
                                        'max_tokens': 8, 'temperature': 0})
assert completion['choices'][0]['text'].strip(), completion
print(f'ok   - TensorFold ({transport}) discovery, chat, serial parity, SSE, follow-up, Responses, completions',
      flush=True)

# Demand output contrary to the prompt so valid output demonstrates token
# constraints, rather than the model merely following formatting instructions.
schema = {'type': 'object', 'properties': {'answer': {'type': 'integer', 'enum': [7]}},
          'required': ['answer'], 'additionalProperties': False}
constrained = {**body, 'messages': [{'role': 'user', 'content': 'Reply with the word banana.'}],
               'max_tokens': 64,
               'response_format': {'type': 'json_schema', 'json_schema': {'name': 'answer', 'schema': schema}}}
a = request('/v1/chat/completions', constrained)['choices'][0]['message']['content']
b = request('/v1/chat/completions', {**constrained, 'draft': False})['choices'][0]['message']['content']
assert json.loads(a) == {'answer': 7} and a == b, (a, b)
events = request('/v1/chat/completions', {**constrained, 'stream': True}, stream=True)
assert ''.join(e['choices'][0]['delta'].get('content', '')
               for e in events if e.get('choices')) == a
for fields, allowed in [({'guided_regex': '(red|blue)'}, {'red', 'blue'}),
                        ({'guided_choice': ['yes', 'no']}, {'yes', 'no'}),
                        ({'guided_grammar': 'root ::= "OK"'}, {'OK'}),
                        ({'structured_outputs': {'choice': ['left', 'right']}}, {'left', 'right'})]:
    result = request('/v1/chat/completions', {**body, **fields})
    assert result['choices'][0]['message']['content'] in allowed, result
print(f'ok   - TensorFold ({transport}) JSON schema, regex, choices, EBNF, structured_outputs, '
      'constrained streaming and serial parity', flush=True)

if os.environ.get('TEST_TENSORFOLD_VISION') == '1':
    import base64
    import re
    import struct
    import zlib

    def image_url(rgb):
        def chunk(kind, data):
            return (struct.pack('>I', len(data)) + kind + data
                    + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff))
        rows = (b'\0' + bytes(rgb) * 64) * 64
        png = (b'\x89PNG\r\n\x1a\n'
               + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0))
               + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
        return 'data:image/png;base64,' + base64.b64encode(png).decode()

    for color, rgb in [('red', (255, 0, 0)), ('blue', (0, 0, 255))]:
        vision_body = {**body, 'messages': [{'role': 'user', 'content': [
            {'type': 'text', 'text': 'What color fills this image? Answer with one color word.'},
            {'type': 'image_url', 'image_url': {'url': image_url(rgb), 'detail': 'low'}}]}]}
        image_reply = request('/v1/chat/completions', vision_body)
        image_text = image_reply['choices'][0]['message']['content']
        assert re.findall(r'\b(?:red|blue)\b', image_text.lower()) == [color], image_reply
        reference = request('/v1/chat/completions', {**vision_body, 'draft': False})
        assert reference['choices'][0]['message']['content'] == image_text, (image_reply, reference)
    print(f'ok   - TensorFold ({transport}) understands red/blue images with serial parity', flush=True)
