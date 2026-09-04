// Tests for App Attest verification.
//
// Assertions can be built here from scratch: an assertion is signed by the
// device key, and a test can generate one. An attestation cannot -- its chain
// ends at Apple's root, and nothing local can mint a certificate under it. So
// `verifyAttestation` is covered by a fixture captured from a real device,
// and the test that reads it skips itself until that file exists. See
// fixtures/README.md for how to capture one.
//
// Run: deno test --allow-net --allow-env supabase/functions/tidynote_organize/

import { assert, assertEquals, assertRejects } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  APP_IDS,
  AttestError,
  base64ToBytes,
  derToRawSignature,
  parseAuthData,
  sha256,
  verifyAssertion,
  verifyAttestation,
} from './attest.ts';

const EC_P256 = { name: 'ECDSA', namedCurve: 'P-256' } as const;
const RP_ID = APP_IDS[0];

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/** The 37-byte blob an assertion carries: the App ID hash, a flags byte, and
 * the signature counter. */
async function authenticatorData(rpId: string, counter: number): Promise<Uint8Array> {
  const rpIdHash = await sha256(new TextEncoder().encode(rpId));
  const tail = new Uint8Array(5);
  new DataView(tail.buffer).setUint32(1, counter, false);
  return concat(rpIdHash, tail);
}

/** WebCrypto signs ECDSA into raw r‖s. Apple's assertions are DER, so the
 * fixture has to go the other way from `derToRawSignature`. */
function rawToDerSignature(raw: Uint8Array): Uint8Array {
  const encodeInteger = (value: Uint8Array): Uint8Array => {
    let start = 0;
    while (start < value.length - 1 && value[start] === 0) start++;
    let trimmed = value.subarray(start);
    // DER integers are signed, so a leading byte over 0x7f needs a zero in
    // front of it or it reads as negative.
    if (trimmed[0] & 0x80) trimmed = concat(new Uint8Array([0]), trimmed);
    return concat(new Uint8Array([0x02, trimmed.length]), trimmed);
  };
  const body = concat(encodeInteger(raw.subarray(0, 32)), encodeInteger(raw.subarray(32, 64)));
  return concat(new Uint8Array([0x30, body.length]), body);
}

/**
 * CBOR for `{ signature: <bytes>, authenticatorData: <bytes> }`, written by
 * hand so the tests do not depend on an encoder as well as a decoder.
 *
 * Only two shapes are needed: a definite-length map of two pairs, text keys
 * under 24 characters, and byte strings under 65536 bytes.
 */
function cborAssertion(signature: Uint8Array, authData: Uint8Array): Uint8Array {
  const textKey = (name: string): Uint8Array => {
    const bytes = new TextEncoder().encode(name);
    return concat(new Uint8Array([0x60 | bytes.length]), bytes);
  };
  const byteString = (bytes: Uint8Array): Uint8Array => {
    const header = new Uint8Array(3);
    header[0] = 0x59; // byte string, two-byte length
    new DataView(header.buffer).setUint16(1, bytes.length, false);
    return concat(header, bytes);
  };
  return concat(
    new Uint8Array([0xa2]), // map of two pairs
    textKey('signature'),
    byteString(signature),
    textKey('authenticatorData'),
    byteString(authData),
  );
}

interface Fixture {
  assertion: string;
  publicKeyJwk: JsonWebKey;
}

/** A signed assertion the verifier should accept, plus the key that signed it. */
async function makeAssertion(
  options: { rpId?: string; counter?: number; clientDataHash?: Uint8Array; corruptSignature?: boolean } = {},
): Promise<Fixture> {
  const rpId = options.rpId ?? RP_ID;
  const counter = options.counter ?? 1;
  const clientDataHash = options.clientDataHash ?? await sha256(new TextEncoder().encode('body'));

  const keys = await crypto.subtle.generateKey(EC_P256, true, ['sign', 'verify']);
  const authData = await authenticatorData(rpId, counter);
  const nonce = await sha256(authData, clientDataHash);
  const raw = new Uint8Array(
    await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, keys.privateKey, nonce),
  );
  if (options.corruptSignature) raw[0] ^= 0xff;

  return {
    assertion: bytesToBase64(cborAssertion(rawToDerSignature(raw), authData)),
    publicKeyJwk: await crypto.subtle.exportKey('jwk', keys.publicKey),
  };
}

const BODY_HASH = await sha256(new TextEncoder().encode('body'));

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Deno.test('parseAuthData reads the fixed prefix of an attestation blob', () => {
  const rpIdHash = new Uint8Array(32).fill(7);
  const counterBytes = new Uint8Array([0x00, 0x00, 0x01, 0x02]);
  const aaguid = new Uint8Array(16).fill(9);
  const credentialId = new Uint8Array(32).fill(3);
  const bytes = concat(
    rpIdHash,
    new Uint8Array([0x40]),
    counterBytes,
    aaguid,
    new Uint8Array([0x00, 0x20]),
    credentialId,
  );

  const parsed = parseAuthData(bytes);
  assertEquals(parsed.rpIdHash, rpIdHash);
  assertEquals(parsed.flags, 0x40);
  assertEquals(parsed.counter, 258);
  assertEquals(parsed.aaguid, aaguid);
  assertEquals(parsed.credentialId, credentialId);
});

Deno.test('parseAuthData stops at the counter for an assertion blob', async () => {
  const parsed = parseAuthData(await authenticatorData(RP_ID, 5));
  assertEquals(parsed.counter, 5);
  assertEquals(parsed.aaguid, null);
  assertEquals(parsed.credentialId, null);
});

Deno.test('parseAuthData rejects a blob too short to hold a counter', () => {
  const error = assertRejectsSync(() => parseAuthData(new Uint8Array(36)));
  assertEquals(error.code, 'malformed_auth_data');
});

Deno.test('derToRawSignature pads both halves to 32 bytes', () => {
  // r is one byte, s is 33 bytes because its top bit is set.
  const der = new Uint8Array([
    0x30,
    0x26,
    0x02,
    0x01,
    0x05,
    0x02,
    0x21,
    0x00,
    ...new Array(32).fill(0xff),
  ]);
  const raw = derToRawSignature(der);
  assertEquals(raw.length, 64);
  assertEquals(raw[31], 5);
  assertEquals(raw.subarray(0, 31), new Uint8Array(31));
  assertEquals(raw.subarray(32), new Uint8Array(32).fill(0xff));
});

Deno.test('derToRawSignature rejects something that is not a signature', () => {
  const error = assertRejectsSync(() => derToRawSignature(new Uint8Array([0x04, 0x02, 0x01, 0x02])));
  assertEquals(error.code, 'malformed_signature');
});

Deno.test('base64ToBytes accepts base64url as well as base64', () => {
  assertEquals(base64ToBytes('_-8='), base64ToBytes('/+8='));
});

/** `assertRejects` is for promises; these throw synchronously. */
function assertRejectsSync(body: () => unknown): AttestError {
  try {
    body();
  } catch (error) {
    assert(error instanceof AttestError, `expected AttestError, got ${error}`);
    return error;
  }
  throw new Error('expected a throw');
}

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

Deno.test('a well-formed assertion verifies and returns its counter', async () => {
  const fixture = await makeAssertion({ counter: 4 });
  const result = await verifyAssertion({
    assertion: fixture.assertion,
    clientDataHash: BODY_HASH,
    publicKeyJwk: fixture.publicKeyJwk,
    rpId: RP_ID,
    previousCounter: 3,
  });
  assertEquals(result.counter, 4);
});

Deno.test('an assertion for another App ID is rejected', async () => {
  const fixture = await makeAssertion({ rpId: 'SUFCW5V2QV.com.example.other' });
  await assertRejects(
    () =>
      verifyAssertion({
        assertion: fixture.assertion,
        clientDataHash: BODY_HASH,
        publicKeyJwk: fixture.publicKeyJwk,
        rpId: RP_ID,
        previousCounter: 0,
      }),
    AttestError,
    'rp_id_mismatch',
  );
});

Deno.test('a counter that has not moved is a replay', async () => {
  const fixture = await makeAssertion({ counter: 7 });
  await assertRejects(
    () =>
      verifyAssertion({
        assertion: fixture.assertion,
        clientDataHash: BODY_HASH,
        publicKeyJwk: fixture.publicKeyJwk,
        rpId: RP_ID,
        previousCounter: 7,
      }),
    AttestError,
    'counter_replayed',
  );
});

Deno.test('a corrupted signature is rejected', async () => {
  const fixture = await makeAssertion({ corruptSignature: true });
  await assertRejects(
    () =>
      verifyAssertion({
        assertion: fixture.assertion,
        clientDataHash: BODY_HASH,
        publicKeyJwk: fixture.publicKeyJwk,
        rpId: RP_ID,
        previousCounter: 0,
      }),
    AttestError,
    'bad_signature',
  );
});

Deno.test('an assertion signed over one body does not verify against another', async () => {
  const fixture = await makeAssertion();
  const otherHash = await sha256(new TextEncoder().encode('a different body'));
  await assertRejects(
    () =>
      verifyAssertion({
        assertion: fixture.assertion,
        clientDataHash: otherHash,
        publicKeyJwk: fixture.publicKeyJwk,
        rpId: RP_ID,
        previousCounter: 0,
      }),
    AttestError,
    'bad_signature',
  );
});

Deno.test('a signature from a different key is rejected', async () => {
  const fixture = await makeAssertion();
  const other = await crypto.subtle.generateKey(EC_P256, true, ['sign', 'verify']);
  const otherJwk = await crypto.subtle.exportKey('jwk', other.publicKey);
  await assertRejects(
    () =>
      verifyAssertion({
        assertion: fixture.assertion,
        clientDataHash: BODY_HASH,
        publicKeyJwk: otherJwk,
        rpId: RP_ID,
        previousCounter: 0,
      }),
    AttestError,
    'bad_signature',
  );
});

Deno.test('a body that is not CBOR is rejected', async () => {
  const fixture = await makeAssertion();
  await assertRejects(
    () =>
      verifyAssertion({
        assertion: bytesToBase64(new TextEncoder().encode('not cbor at all, really not')),
        clientDataHash: BODY_HASH,
        publicKeyJwk: fixture.publicKeyJwk,
        rpId: RP_ID,
        previousCounter: 0,
      }),
    AttestError,
  );
});

// ---------------------------------------------------------------------------
// Attestation
// ---------------------------------------------------------------------------

const FIXTURE_PATH = new URL('./fixtures/attestation.json', import.meta.url);

/** False when the fixture is absent and also when the suite was run without
 * `--allow-read`, which is how CI runs it. The permission is checked rather
 * than tripped over so the run never stops on a prompt. */
function fixtureExists(): boolean {
  try {
    if (Deno.permissions.querySync({ name: 'read', path: FIXTURE_PATH }).state !== 'granted') return false;
    Deno.statSync(FIXTURE_PATH);
    return true;
  } catch {
    return false;
  }
}

Deno.test({
  name: 'a real attestation from a device verifies',
  ignore: !fixtureExists(),
  fn: async () => {
    const fixture = JSON.parse(await Deno.readTextFile(FIXTURE_PATH)) as {
      keyId: string;
      attestation: string;
      appUserId: string;
      timestamp: number;
      capturedAt?: string;
    };

    const result = await verifyAttestation({
      keyId: fixture.keyId,
      attestation: fixture.attestation,
      clientDataHash: await sha256(new TextEncoder().encode(`${fixture.appUserId}|${fixture.timestamp}`)),
      // The leaf certificate is only valid for a few days, so the fixture is
      // judged at the moment it was captured rather than at the moment the
      // test runs. Nothing else in the check depends on the clock.
      now: new Date(fixture.capturedAt ?? fixture.timestamp * 1000),
    });

    assert(APP_IDS.includes(result.rpId as typeof APP_IDS[number]));
    assertEquals(result.publicKeyJwk.crv, 'P-256');
  },
});

Deno.test({
  name: 'an attestation with a tampered key ID is rejected',
  ignore: !fixtureExists(),
  fn: async () => {
    const fixture = JSON.parse(await Deno.readTextFile(FIXTURE_PATH)) as {
      keyId: string;
      attestation: string;
      appUserId: string;
      timestamp: number;
      capturedAt?: string;
    };
    const tampered = base64ToBytes(fixture.keyId);
    tampered[0] ^= 0xff;
    const clientDataHash = await sha256(new TextEncoder().encode(`${fixture.appUserId}|${fixture.timestamp}`));

    await assertRejects(
      () =>
        verifyAttestation({
          keyId: bytesToBase64(tampered),
          attestation: fixture.attestation,
          clientDataHash,
          now: new Date(fixture.capturedAt ?? fixture.timestamp * 1000),
        }),
      AttestError,
    );
  },
});

Deno.test('an attestation that is not CBOR is rejected before any crypto runs', async () => {
  await assertRejects(
    () =>
      verifyAttestation({
        keyId: bytesToBase64(new Uint8Array(32).fill(1)),
        attestation: bytesToBase64(new TextEncoder().encode('nowhere near an attestation object')),
        clientDataHash: BODY_HASH,
        now: new Date('2026-09-03T00:00:00Z'),
      }),
    AttestError,
  );
});

Deno.test('a key ID that is not 32 bytes is rejected', async () => {
  await assertRejects(
    () =>
      verifyAttestation({
        keyId: bytesToBase64(new Uint8Array(16)),
        attestation: bytesToBase64(new Uint8Array(8)),
        clientDataHash: BODY_HASH,
        now: new Date('2026-09-03T00:00:00Z'),
      }),
    AttestError,
    'bad_key_id',
  );
});
