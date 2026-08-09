# OpenAPI specs (not vendored)

The upstream OpenAPI specs are **not committed** to this repo (they are
distributed by SUPER PDP, which owns their redistribution rights). Development
and specs do not require them — they are reference material only.

To restore them locally, download the following from the
[SUPER PDP](https://www.superpdp.tech) developer portal / API documentation
and drop them in this directory (they are gitignored):

| File | Spec | Version used during development |
| --- | --- | --- |
| `superpdp.json` | SUPER PDP API (`v1.beta`) | 1.30.0.beta |
| `xp-z12-013-flow-1.3.0.json` | AFNOR Flow Service (XP Z12-013 interop) | 1.3.0 |
| `xp-z12-013-directory-1.3.0.json` | AFNOR Directory Service (XP Z12-013 interop) | 1.3.0 |

They are served unauthenticated from `https://api.superpdp.tech/openapi/<file>` (the file
names come from the Scalar config inlined in `https://www.superpdp.tech/openapi`).
