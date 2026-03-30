#!/usr/bin/env python3
"""
Send a multiple-choice question to iPhone via the claudecode-controller socket.
Usage: python3 ask-question.py "Question?" "Option1" "Option2" ...
"""
import sys, socket, json, os

SOCKET_PATH = os.path.expanduser('~/.ask/sockets/claudecode-controller.sock')

if len(sys.argv) < 3:
    print("Usage: ask-question.py 'Question?' 'Option1' 'Option2' ...")
    sys.exit(1)

question = sys.argv[1]
options = sys.argv[2:]

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(310)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps({
        'type': 'question',
        'title': question,
        'body': '',
        'options': options,
    }, ensure_ascii=False).encode())
    sock.shutdown(socket.SHUT_WR)
    data = b''
    while True:
        chunk = sock.recv(4096)
        if not chunk: break
        data += chunk
    sock.close()
    response = json.loads(data.decode())
    print(response.get('value', ''))
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
