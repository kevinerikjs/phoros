# Security

`Phoros`, `PhorosSession`, `PhorosMedia` and `PhorosInput` define message formats and logic. They do not open connections, store secrets or encrypt anything. `PhorosNetwork` opens a plain TCP connection with no transport encryption. `PhorosCore` opens a UDP peer whose media is encrypted with DTLS and SRTP, keyed by a fingerprint exchanged over whatever the base connection is, which means it inherits that connection's trust and adds no authentication of its own.

Applications that use any of them must:

- authenticate a peer before they accept control messages or media from it
- limit frame and payload sizes before they allocate (`FrameDecoder` does this)
- treat the shared secret from pairing as a credential: keep it in the Keychain, never log it, and let the person revoke it
- use TLS, or a private overlay such as Tailscale, when a connection leaves the local network. The v1 wire is not encrypted, and the v2 wire's encryption authenticates nothing on its own

## Reporting

Do not open a public issue for a security problem. Email [support@beamscreen.app](mailto:support@beamscreen.app) with the package version, a reproduction and the impact you expect. You will get a reply within seven days.
