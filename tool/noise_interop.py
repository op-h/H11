"""Cross-check Midad's Dart Noise implementation against the independent
`noiseprotocol` Python library, byte for byte.

Usage: dart run tool/noise_vectors.dart > vectors.json
       python tool/noise_interop.py vectors.json
"""
import json
import sys

from noise.connection import Keypair, NoiseConnection


def fill(v):
    return bytes([v]) * 32


def run(case):
    name = case["protocol"].encode()
    psk = "psk" in case["protocol"]
    i = NoiseConnection.from_name(name)
    r = NoiseConnection.from_name(name)
    for c, s, e in ((i, 1, 3), (r, 2, 4)):
        c.set_keypair_from_private_bytes(Keypair.STATIC, fill(s))
        c.set_keypair_from_private_bytes(Keypair.EPHEMERAL, fill(e))
        c.set_prologue(b"midad/1")
        if psk:
            c.set_psks(fill(9))
    tmp = NoiseConnection.from_name(name)
    tmp.set_keypair_from_private_bytes(Keypair.STATIC, fill(2))
    rs_pub = tmp.noise_protocol.keypairs["s"].public_bytes
    i.set_keypair_from_public_bytes(Keypair.REMOTE_STATIC, rs_pub)
    i.set_as_initiator()
    r.set_as_responder()
    i.start_handshake()
    r.start_handshake()
    m1 = i.write_message(b"hello")
    assert r.read_message(m1) == b"hello"
    m2 = r.write_message(b"world")
    assert i.read_message(m2) == b"world"
    t1 = i.encrypt(b"transport-1")
    t2 = r.encrypt(b"transport-2")
    got = {"msg1": m1.hex(), "msg2": m2.hex(), "t1": t1.hex(), "t2": t2.hex(),
           "hash": i.get_handshake_hash().hex()}
    ok = all(got[k] == case[k] for k in got)
    print(f"{case['protocol']}: {'MATCH' if ok else 'MISMATCH'}")
    if not ok:
        for k in got:
            if got[k] != case[k]:
                print(f"  {k}\n   dart={case[k]}\n   py  ={got[k]}")
    return ok


cases = json.load(open(sys.argv[1]))
results = [run(c) for c in cases]
sys.exit(0 if all(results) else 1)
