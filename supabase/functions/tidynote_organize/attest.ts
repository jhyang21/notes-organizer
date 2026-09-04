// Apple App Attest verification.
//
// The organize endpoint identifies an install by a string the client chose. On
// its own that proves nothing, so App Attest binds the string to a key the
// Secure Enclave generated and Apple vouched for. This file does the vouching
// half: it checks Apple's attestation over a new key, and later checks each
// assertion that key signs.
//
// Import-safe by rule, the same as organize.ts: no env reads, no top-level work
// beyond building constants, so the tests and anything else can import it
// without a platform underneath.
//
// The steps below follow Apple's "Validating apps that connect to your server".
// Where a step is skipped it says so and why.

import { decode as decodeCbor } from 'npm:cbor-x@1.6.0';
import { X509Certificate } from 'npm:@peculiar/x509@1.12.3';

/**
 * The App IDs -- team prefix plus bundle identifier -- allowed to attest. Two,
 * because the share extension is a separate process with its own bundle ID and
 * its own App Attest keys.
 */
export const APP_IDS = [
  'SUFCW5V2QV.com.immform.notesorganizer',
  'SUFCW5V2QV.com.immform.notesorganizer.share',
] as const;

/**
 * The nonce Apple puts in the leaf certificate, as an extension.
 * https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
 */
const NONCE_OID = '1.2.840.113635.100.8.2';

/** "appattest" in ASCII, then seven zero bytes. The development environment
 * uses "appattestdevelop" instead, which this file rejects: a development key
 * is minted by a build that is not the App Store build, so honouring it would
 * hand the whole control back to anyone with a developer account. */
const PRODUCTION_AAGUID = new Uint8Array([
  0x61, 0x70, 0x70, 0x61, 0x74, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]);

/**
 * Apple's App Attest root, from
 * https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
 *
 * Embedded rather than fetched. A root fetched at request time is a root an
 * outage can take away and a proxy can replace, and this one is valid until
 * 2045.
 *
 * SHA-256 fingerprint of the DER:
 * 1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
 * Subject and issuer: CN=Apple App Attestation Root CA, O=Apple Inc., ST=California
 */
const APPLE_ROOT_CA_PEM = `-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----`;

/** The Secure Enclave signs with P-256, so every key here is one. */
const EC_P256 = { name: 'ECDSA', namedCurve: 'P-256' } as const;

/** WebCrypto and the X.509 parser both insist on bytes that own a plain
 * ArrayBuffer rather than the wider `ArrayBufferLike`, so every helper below
 * hands back exactly that. */
type Bytes = Uint8Array<ArrayBuffer>;

/**
 * Every way verification can end badly. One class, with a machine-readable
 * `code`, because the caller turns all of them into the same 401 -- telling a
 * caller which step failed only helps someone building a forgery.
 */
export class AttestError extends Error {
  readonly code: string;

  constructor(code: string) {
    super(code);
    this.name = 'AttestError';
    this.code = code;
  }
}

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

/** Accepts base64 and base64url, since Apple's key IDs are standard base64 but
 * a client that URL-encodes one is easier to accept than to debug. */
export function base64ToBytes(value: string): Bytes {
  const normalized = value.replaceAll('-', '+').replaceAll('_', '/');
  const padded = normalized + '='.repeat((4 - (normalized.length % 4)) % 4);
  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    throw new AttestError('malformed_base64');
  }
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function sha256(...parts: Uint8Array[]): Promise<Bytes> {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    joined.set(part, offset);
    offset += part.length;
  }
  const digest = await crypto.subtle.digest('SHA-256', joined);
  return new Uint8Array(digest);
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** cbor-x hands byte strings back as a Uint8Array on Deno and a Buffer on
 * Node. A Buffer is a Uint8Array subclass, so it passes the check below, but
 * it can be a view into a larger pooled buffer -- copying is the only way to
 * be sure the bytes stand alone. */
function asBytes(value: unknown): Bytes {
  if (!(value instanceof Uint8Array)) throw new AttestError('malformed_attestation');
  const copy = new Uint8Array(value.byteLength);
  copy.set(value);
  return copy;
}

// ---------------------------------------------------------------------------
// DER
// ---------------------------------------------------------------------------

interface DerValue {
  tag: number;
  contentStart: number;
  contentLength: number;
  end: number;
}

/** One tag-length-value at `offset`. Long-form lengths are read; the
 * indefinite-length form is not, because DER forbids it. */
function readDer(bytes: Uint8Array, offset: number): DerValue {
  if (offset + 2 > bytes.length) throw new AttestError('malformed_der');
  const tag = bytes[offset];
  const first = bytes[offset + 1];
  let contentStart = offset + 2;
  let contentLength: number;

  if (first < 0x80) {
    contentLength = first;
  } else {
    const lengthBytes = first & 0x7f;
    if (lengthBytes === 0 || lengthBytes > 4) throw new AttestError('malformed_der');
    if (contentStart + lengthBytes > bytes.length) throw new AttestError('malformed_der');
    contentLength = 0;
    // Multiplied rather than shifted: `<<` works on 32-bit signed values, so
    // four length bytes with the top bit set would wrap to a negative length
    // and slip past the bounds check below.
    for (let i = 0; i < lengthBytes; i++) contentLength = contentLength * 256 + bytes[contentStart + i];
    contentStart += lengthBytes;
  }

  const end = contentStart + contentLength;
  if (end > bytes.length) throw new AttestError('malformed_der');
  return { tag, contentStart, contentLength, end };
}

/**
 * The 64 raw bytes WebCrypto wants, from the DER SEQUENCE of two INTEGERs that
 * Apple signs with.
 *
 * DER integers are signed and minimally encoded, so `r` and `s` arrive with a
 * leading zero when their top bit is set and without leading zeros otherwise.
 * Both halves have to end up exactly 32 bytes, right-aligned.
 */
export function derToRawSignature(der: Uint8Array): Bytes {
  const sequence = readDer(der, 0);
  if (sequence.tag !== 0x30) throw new AttestError('malformed_signature');

  const first = readDer(der, sequence.contentStart);
  if (first.tag !== 0x02) throw new AttestError('malformed_signature');
  const second = readDer(der, first.end);
  if (second.tag !== 0x02) throw new AttestError('malformed_signature');
  if (second.end !== sequence.end) throw new AttestError('malformed_signature');

  const raw = new Uint8Array(64);
  raw.set(fixedWidthInteger(der.subarray(first.contentStart, first.end)), 0);
  raw.set(fixedWidthInteger(der.subarray(second.contentStart, second.end)), 32);
  return raw;
}

function fixedWidthInteger(value: Uint8Array): Bytes {
  let start = 0;
  while (start < value.length - 1 && value[start] === 0) start++;
  const trimmed = value.subarray(start);
  if (trimmed.length > 32) throw new AttestError('malformed_signature');
  const out = new Uint8Array(32);
  out.set(trimmed, 32 - trimmed.length);
  return out;
}

/** The nonce Apple stamped into the leaf certificate. The extension value is a
 * DER SEQUENCE holding a context-specific [1] that wraps the OCTET STRING. */
function nonceFromExtension(extensionValue: Bytes): Bytes {
  const sequence = readDer(extensionValue, 0);
  if (sequence.tag !== 0x30) throw new AttestError('malformed_nonce_extension');
  const wrapper = readDer(extensionValue, sequence.contentStart);
  if (wrapper.tag !== 0xa1) throw new AttestError('malformed_nonce_extension');
  const octets = readDer(extensionValue, wrapper.contentStart);
  if (octets.tag !== 0x04) throw new AttestError('malformed_nonce_extension');
  return extensionValue.slice(octets.contentStart, octets.end);
}

// ---------------------------------------------------------------------------
// Authenticator data
// ---------------------------------------------------------------------------

export interface AuthData {
  /** SHA-256 of the App ID this key belongs to. */
  rpIdHash: Uint8Array;
  flags: number;
  /** How many assertions this key has signed. Zero in an attestation. */
  counter: number;
  /** Present only in an attestation, where the attested credential data
   * follows the counter. Assertions stop after the counter. */
  aaguid: Uint8Array | null;
  credentialId: Uint8Array | null;
}

/**
 * The fixed prefix of an authenticator data blob.
 *
 * Layout, from Apple's page: rpIdHash 0..32, flags at 32, counter 33..37 big
 * endian, then -- in an attestation only -- aaguid 37..53, a two-byte
 * credential ID length at 53..55, and the credential ID itself. An assertion's
 * blob is 37 bytes and stops there.
 */
export function parseAuthData(bytes: Uint8Array): AuthData {
  if (bytes.length < 37) throw new AttestError('malformed_auth_data');

  const rpIdHash = bytes.slice(0, 32);
  const flags = bytes[32];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const counter = view.getUint32(33, false);

  if (bytes.length < 55) return { rpIdHash, flags, counter, aaguid: null, credentialId: null };

  const aaguid = bytes.slice(37, 53);
  const credentialIdLength = view.getUint16(53, false);
  if (55 + credentialIdLength > bytes.length) throw new AttestError('malformed_auth_data');
  const credentialId = bytes.slice(55, 55 + credentialIdLength);
  return { rpIdHash, flags, counter, aaguid, credentialId };
}

// ---------------------------------------------------------------------------
// Attestation
// ---------------------------------------------------------------------------

export interface AttestationInput {
  /** The key ID the app reported, base64 as `DCAppAttestService` gives it. */
  keyId: string;
  /** The attestation object, base64. */
  attestation: string;
  /** SHA-256 of whatever the app and this server agreed the challenge is. */
  clientDataHash: Uint8Array;
  /** Certificate validity is judged against this, so a test can pin it. */
  now: Date;
}

export interface AttestationResult {
  /** The leaf's public key, ready to store and to verify assertions with. */
  publicKeyJwk: JsonWebKey;
  /** The App ID whose hash matched, which later assertions must also match. */
  rpId: string;
}

/** Parsed once, on first use, and kept. Parsing costs nothing but doing it per
 * request costs it per request. */
let cachedRoot: X509Certificate | null = null;

function rootCertificate(): X509Certificate {
  if (!cachedRoot) cachedRoot = new X509Certificate(APPLE_ROOT_CA_PEM);
  return cachedRoot;
}

/**
 * Checks Apple's attestation over a newly generated key and returns the key.
 *
 * Throws `AttestError` at the first step that fails. Nothing partial is
 * returned: a caller either gets a key it may store or gets nothing.
 */
export async function verifyAttestation(input: AttestationInput): Promise<AttestationResult> {
  const { keyId, attestation, clientDataHash, now } = input;
  const keyIdBytes = base64ToBytes(keyId);
  if (keyIdBytes.length !== 32) throw new AttestError('bad_key_id');

  // --- 0. shape ----------------------------------------------------------
  let object: { fmt?: unknown; attStmt?: { x5c?: unknown }; authData?: unknown };
  try {
    object = decodeCbor(base64ToBytes(attestation)) as typeof object;
  } catch {
    throw new AttestError('malformed_attestation');
  }
  if (object?.fmt !== 'apple-appattest') throw new AttestError('bad_format');

  const x5c = object.attStmt?.x5c;
  if (!Array.isArray(x5c) || x5c.length < 2) throw new AttestError('bad_certificate_chain');
  const authData = asBytes(object.authData);

  // --- 1. chain ----------------------------------------------------------
  // Leaf signed by intermediate, intermediate signed by the embedded root, and
  // both in date at `now`. `verify` is given the issuer certificate rather than
  // a bare key so it also checks that the issuer name matches the subject.
  let leaf: X509Certificate;
  let intermediate: X509Certificate;
  try {
    leaf = new X509Certificate(asBytes(x5c[0]));
    intermediate = new X509Certificate(asBytes(x5c[1]));
  } catch {
    throw new AttestError('bad_certificate_chain');
  }

  const root = rootCertificate();
  if (!(await verifyAgainstIssuer(intermediate, root, now))) throw new AttestError('bad_certificate_chain');
  if (!(await verifyAgainstIssuer(leaf, intermediate, now))) throw new AttestError('bad_certificate_chain');

  // --- 2/3. nonce --------------------------------------------------------
  const nonce = await sha256(authData, clientDataHash);

  // --- 4. the nonce Apple stamped into the leaf --------------------------
  const extension = leaf.getExtension(NONCE_OID);
  if (!extension) throw new AttestError('missing_nonce_extension');
  if (!bytesEqual(nonceFromExtension(new Uint8Array(extension.value)), nonce)) {
    throw new AttestError('nonce_mismatch');
  }

  // Step 5 in Apple's list is the macOS aclBlob extension. This app is iOS
  // only, so there is nothing to check.

  // --- 6. the key ID is the hash of the key ------------------------------
  const spki = new Uint8Array(leaf.publicKey.rawData);
  let publicKey: CryptoKey;
  try {
    publicKey = await crypto.subtle.importKey('spki', spki, EC_P256, true, ['verify']);
  } catch {
    throw new AttestError('bad_public_key');
  }
  // X9.62 uncompressed: 0x04 then X then Y, which is what `raw` exports.
  const uncompressed = new Uint8Array(await crypto.subtle.exportKey('raw', publicKey));
  if (!bytesEqual(await sha256(uncompressed), keyIdBytes)) throw new AttestError('key_id_mismatch');

  // --- 7. the App ID -----------------------------------------------------
  const parsed = parseAuthData(authData);
  let rpId: string | null = null;
  for (const appId of APP_IDS) {
    if (bytesEqual(parsed.rpIdHash, await sha256(new TextEncoder().encode(appId)))) {
      rpId = appId;
      break;
    }
  }
  if (!rpId) throw new AttestError('rp_id_mismatch');

  // --- 8. a fresh key has signed nothing ---------------------------------
  if (parsed.counter !== 0) throw new AttestError('bad_counter');

  // --- 9. production keys only -------------------------------------------
  if (!parsed.aaguid || !bytesEqual(parsed.aaguid, PRODUCTION_AAGUID)) throw new AttestError('bad_aaguid');

  // --- 10. the credential is the key we were told about ------------------
  if (!parsed.credentialId || !bytesEqual(parsed.credentialId, keyIdBytes)) throw new AttestError('credential_id_mismatch');

  // Steps 11 and 12 read the validation-category and bundle-version
  // extensions. Neither is a security check on its own -- the chain and the
  // production aaguid already say this is an App Store build of one of two
  // App IDs -- and reading them would pin the server to a version list it
  // would then have to be redeployed to update.

  const publicKeyJwk = await crypto.subtle.exportKey('jwk', publicKey);
  return { publicKeyJwk, rpId };
}

async function verifyAgainstIssuer(cert: X509Certificate, issuer: X509Certificate, now: Date): Promise<boolean> {
  try {
    return await cert.verify({ publicKey: issuer, date: now });
  } catch {
    // An unsupported algorithm or a malformed signature lands here. Either way
    // the certificate is not one we trust.
    return false;
  }
}

// ---------------------------------------------------------------------------
// Assertion
// ---------------------------------------------------------------------------

export interface AssertionInput {
  /** The assertion object, base64. */
  assertion: string;
  /** SHA-256 of the bytes the app signed over -- here, the request body. */
  clientDataHash: Uint8Array;
  /** The key stored when this key ID was attested. */
  publicKeyJwk: JsonWebKey;
  rpId: string;
  /** The highest counter already seen for this key. */
  previousCounter: number;
}

/**
 * Checks one assertion and returns the counter to store.
 *
 * The counter is what stops a replay: the Secure Enclave increments it on every
 * signature, so a captured request replayed later carries a counter that is no
 * longer ahead of the stored one.
 */
export async function verifyAssertion(input: AssertionInput): Promise<{ counter: number }> {
  const { assertion, clientDataHash, publicKeyJwk, rpId, previousCounter } = input;

  let object: { signature?: unknown; authenticatorData?: unknown };
  try {
    object = decodeCbor(base64ToBytes(assertion)) as typeof object;
  } catch {
    throw new AttestError('malformed_assertion');
  }
  const signature = asBytes(object?.signature);
  const authenticatorData = asBytes(object?.authenticatorData);

  const parsed = parseAuthData(authenticatorData);
  if (!bytesEqual(parsed.rpIdHash, await sha256(new TextEncoder().encode(rpId)))) {
    throw new AttestError('rp_id_mismatch');
  }

  // Apple signs SHA-256 of the nonce. WebCrypto hashes whatever data it is
  // given, so the nonce goes in whole -- hashing it here would sign the digest
  // of a digest and never verify.
  const nonce = await sha256(authenticatorData, clientDataHash);

  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey('jwk', publicKeyJwk, EC_P256, false, ['verify']);
  } catch {
    throw new AttestError('bad_public_key');
  }

  const raw = derToRawSignature(signature);
  const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, raw, nonce);
  if (!valid) throw new AttestError('bad_signature');

  if (parsed.counter <= previousCounter) throw new AttestError('counter_replayed');

  // Apple's step 6 asks that the challenge inside the client data match the
  // one the server issued. Here the client data is the request body itself and
  // `clientDataHash` is the hash of the bytes that arrived, so the two are the
  // same thing and there is nothing left to compare. Steps 7 and 8 are the
  // validation-category and bundle-version extensions, skipped for the reason
  // given in `verifyAttestation`.
  return { counter: parsed.counter };
}
