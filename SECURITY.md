# Security

`Phoros`, `PhorosSession`, `PhorosMedia` and `PhorosInput` define message formats and logic. They do not open connections or store secrets. `PhorosSession` holds the encryption primitives (`SecureChannelClient`, `SecureChannelHost`, `FrameCipher`), built on CryptoKit.

`PhorosNetwork` opens a TCP connection. Since 1.7.0 it encrypts that connection when it is given `security:`. Without it, the connection is plaintext, as every version before 1.7.0 was. `PhorosCore` opens a UDP peer whose media is encrypted with DTLS and SRTP. Its fingerprint travels over the base connection, so the DTLS is authenticated when the base connection is encrypted. On a plaintext base connection it authenticates nothing.

## What an encrypted connection protects

- **Returning devices** (mode `authenticate`). Keys come from a fresh X25519 exchange and the 32-byte pairing secret. Someone on the same network sees two public keys, two nonces, a device id and sealed frames. They cannot read or change anything. A host without the secret cannot produce `proof`, so the client stops before it sends anything. A client without the secret cannot produce a frame the host can open. The exchange is fresh every time, so recorded traffic stays sealed even if the secret leaks later.
- **Pairing** (mode `pair`). There is no secret yet, so the keys come from X25519 alone. A passive listener can no longer read the secret out of `pair_success`. An active attacker who takes over the connection during the pairing attempt can still read it. That attacker has to be on the same network, impersonate the host at that moment, and finish before the code expires. Closing the gap needs a password-authenticated key exchange (PAKE) keyed by the six-digit code. CryptoKit has no PAKE, so this is tracked as follow-up work.
- **What stays visible:** frame sizes and timing, the device id in `secure_hello`, and that two devices are talking.

Applications that use Phoros must:

- authenticate a peer before they accept control messages or media from it
- limit frame and payload sizes before they allocate (`FrameDecoder` and `PhorosConnection` do this)
- treat the shared secret from pairing as a credential: keep it in the Keychain, never log it, and let the person revoke it
- encrypt every connection to a peer that supports it, remember that it does, and refuse plaintext from it afterwards, so an attacker cannot downgrade the connection by pretending to be an old build

## Reporting

Do not open a public issue for a security problem. Email [support@beamscreen.app](mailto:support@beamscreen.app) with the package version, a reproduction and the impact you expect. You will get a reply within seven days.
