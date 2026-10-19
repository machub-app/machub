# Security

Please don't open a public issue for a security problem. Use GitHub's private reporting instead: **Security › Report a vulnerability** on this repository. We answer as fast as we can.

What MacHub protects:
- Your Steam password never reaches MacHub (Steam OpenID and Steam's own window).
- API keys are kept in the macOS Keychain only.
- Releases aren't notarized by Apple yet: each one lists the SHA-256 of its `.dmg`, and the app is built from this repository by `scripts/make-dmg.sh`.
- Engine downloads are checked against a SHA-256 published with the app.
- Mod archives are checked for paths that would write outside the game (zip-slip) and for symbolic links.
