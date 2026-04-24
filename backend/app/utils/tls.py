"""Shared TLS configuration.

Supports corporate-proxy setups (e.g. Netskope, Zscaler) that intercept outbound
TLS with their own root CA. We load certifi's Mozilla bundle as the baseline and
layer any extra CA file referenced by one of:

  - SSL_CERT_FILE          (OpenSSL convention)
  - REQUESTS_CA_BUNDLE     (requests convention, honored for convenience)
  - NODE_EXTRA_CA_CERTS    (Node convention — we piggy-back so users don't need
                            to duplicate configuration)

The httpx clients used by the Anthropic SDK and our bunq client both accept
this context via their `verify=` param. For requests-based code (the vendored
bunq toolkit), set REQUESTS_CA_BUNDLE to the same path in the shell.
"""
from __future__ import annotations

import os
import ssl
from functools import lru_cache
from pathlib import Path

import certifi


def extra_ca_path() -> Path | None:
    for env in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "NODE_EXTRA_CA_CERTS"):
        p = os.environ.get(env)
        if p and Path(p).is_file():
            return Path(p)
    return None


@lru_cache
def make_ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context(cafile=certifi.where())
    extra = extra_ca_path()
    if extra:
        ctx.load_verify_locations(cafile=str(extra))
    return ctx
