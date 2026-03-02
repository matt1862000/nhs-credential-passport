"""
Key management and JWT signing/verification for Verifiable Credentials.
Uses RS256; public key exposed via did:web for verifier.
"""
import json
from pathlib import Path

from jose import jwk, jwt
from jose.utils import base64url_encode

KEYS_DIR = Path(__file__).resolve().parent.parent / "keys"
PRIVATE_KEY_PATH = KEYS_DIR / "private_key.json"
PUBLIC_KEY_PATH = KEYS_DIR / "public_key.json"


def get_issuer_did(base_url: str) -> str:
    """Build did:web from base URL."""
    from urllib.parse import urlparse
    p = urlparse(base_url)
    host = p.netloc or "localhost:8000"
    return f"did:web:{host.replace(':', '%3A')}"


def _int_to_b64url(n):
    """Encode integer to base64url per JWK."""
    byt = n.to_bytes((n.bit_length() + 7) // 8 or 1, "big")
    return base64url_encode(byt).decode("ascii")


def ensure_keys():
    """Generate RS256 key pair if not present; save as JWK JSON."""
    KEYS_DIR.mkdir(parents=True, exist_ok=True)
    if PRIVATE_KEY_PATH.exists():
        return
    from cryptography.hazmat.primitives.asymmetric import rsa

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv_nums = key.private_numbers()
    pub_nums = priv_nums.public_numbers

    public_jwk = {
        "kty": "RSA",
        "alg": "RS256",
        "n": _int_to_b64url(pub_nums.n),
        "e": _int_to_b64url(pub_nums.e),
    }
    private_jwk = {
        "kty": "RSA",
        "alg": "RS256",
        "n": _int_to_b64url(pub_nums.n),
        "e": _int_to_b64url(pub_nums.e),
        "d": _int_to_b64url(priv_nums.d),
        "p": _int_to_b64url(priv_nums.p),
        "q": _int_to_b64url(priv_nums.q),
        "dp": _int_to_b64url(priv_nums.dmp1),
        "dq": _int_to_b64url(priv_nums.dmq1),
        "qi": _int_to_b64url(priv_nums.iqmp),
    }
    with open(PRIVATE_KEY_PATH, "w") as f:
        json.dump(private_jwk, f, indent=2)
    with open(PUBLIC_KEY_PATH, "w") as f:
        json.dump(public_jwk, f, indent=2)


def get_private_jwk():
    ensure_keys()
    with open(PRIVATE_KEY_PATH) as f:
        return jwk.construct(json.load(f), algorithm="RS256")


def get_public_jwk():
    ensure_keys()
    with open(PUBLIC_KEY_PATH) as f:
        return jwk.construct(json.load(f), algorithm="RS256")


def get_public_jwk_dict():
    ensure_keys()
    with open(PUBLIC_KEY_PATH) as f:
        d = json.load(f)
    if "kid" not in d:
        d["kid"] = "nhs-credential-passport-1"
    return d


def sign_credential(payload: dict, credential_id: str) -> str:
    key = get_private_jwk()
    return jwt.encode(
        payload,
        key,
        algorithm="RS256",
        headers={"kid": credential_id[:32]},
    )


def verify_jwt(token: str) -> tuple:
    try:
        key = get_public_jwk()
        payload = jwt.decode(token, key, algorithms=["RS256"])
        return payload, None
    except Exception as e:
        return None, str(e)
