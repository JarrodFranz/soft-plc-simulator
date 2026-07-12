import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_certificate.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_crypto.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_secure_channel.dart';
import 'package:soft_plc_mobile/protocols/opcua/opcua_transport.dart';

/// Asymmetric OPN loopback for Basic256Sha256.
///
/// The production [OpcSecureChannel] plays the SERVER: it verifies+decrypts a
/// client OPN and signs+encrypts the OPN response. The test provides a small,
/// INDEPENDENT client-side mirror ([_asymSignEncrypt] / [_asymDecryptVerify])
/// written from the Rust `secure_channel.rs` reference — signing with the
/// client key and encrypting to the server cert. If the padding/signed-range/
/// block-chunking match, the round-trip recovers the exact plaintext.
void main() {
  // RSA-2048 keygen is expensive; fixed Fortuna seeds keep the run
  // reproducible and let both keypairs be generated once.
  final serverKp = generateRsa2048(fortunaRandom(List<int>.filled(32, 7)));
  final clientKp = generateRsa2048(fortunaRandom(List<int>.filled(32, 11)));

  final serverCertDer = buildSelfSignedCertificate(
    keyPair: serverKp,
    applicationUri: 'urn:server',
    commonName: 'S',
    notBefore: DateTime.utc(2020),
    notAfter: DateTime.utc(2040),
  );
  final clientCertDer = buildSelfSignedCertificate(
    keyPair: clientKp,
    applicationUri: 'urn:client',
    commonName: 'C',
    notBefore: DateTime.utc(2020),
    notAfter: DateTime.utc(2040),
  );

  final clientNonce = Uint8List.fromList(
      List<int>.generate(kSecureChannelNonceLength, (i) => i + 1));
  final serverNonce = Uint8List.fromList(
      List<int>.generate(kSecureChannelNonceLength, (i) => 200 - i));

  Uint8List seqHeader(int seq, int req) {
    final b = ByteData(8)
      ..setUint32(0, seq, Endian.little)
      ..setUint32(4, req, Endian.little);
    return b.buffer.asUint8List();
  }

  test('asymmetric OPN loopback: client OPN verifies & decrypts; response '
      'round-trips', () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );

    // --- Client -> Server OPN ---
    final requestBody = Uint8List.fromList(
        List<int>.generate(137, (i) => (i * 3 + 5) & 0xff));
    final clientSeqBody =
        Uint8List.fromList(<int>[...seqHeader(1, 1), ...requestBody]);

    final clientFrame = _asymSignEncrypt(
      signKey: clientKp.privateKey,
      encKey: serverKp.publicKey,
      senderCertDer: clientCertDer,
      receiverThumbprint: sha1(serverCertDer),
      secureChannelId: 0,
      sequenceNumber: 1,
      requestId: 1,
      plainSeqBody: clientSeqBody,
    );

    final hdr = parseChunkHeader(clientFrame);
    expect(hdr.messageType, 'OPN');
    expect(hdr.securityPolicyUri, kSecurityPolicyBasic256Sha256Uri);
    final rawHeader =
        Uint8List.sublistView(clientFrame, 0, hdr.securityHeaderEnd);
    final rawAfter =
        Uint8List.sublistView(clientFrame, hdr.securityHeaderEnd, hdr.size);

    final recovered = channel.openFromClient(
      policyUri: hdr.securityPolicyUri!,
      senderCertificate: Uint8List.fromList(hdr.senderCertificate!),
      rawHeader: rawHeader,
      rawAfterSecurityHeader: rawAfter,
      serverNonce: serverNonce,
      clientNonce: clientNonce,
      receiverCertificateThumbprint: hdr.receiverCertificateThumbprint == null
          ? null
          : Uint8List.fromList(hdr.receiverCertificateThumbprint!),
    );
    expect(recovered, equals(clientSeqBody));
    expect(channel.mode, OpcSecurityMode.signAndEncrypt);
    expect(channel.clientCertificate, isNotNull);
    // Keys derived for Task 5.
    expect(channel.clientKeys!.signingKey.length, 32);
    expect(channel.clientKeys!.encryptingKey.length, 32);
    expect(channel.clientKeys!.iv.length, 16);

    // --- Server -> Client OPN response ---
    final respBody = Uint8List.fromList(
        List<int>.generate(60, (i) => (i * 7 + 1) & 0xff));
    final respSeqBody =
        Uint8List.fromList(<int>[...seqHeader(1, 1), ...respBody]);

    final respFrame = channel.buildSecuredOpnResponse(
      secureChannelId: 42,
      sequenceNumber: 1,
      requestId: 1,
      plaintextSequenceAndBody: respSeqBody,
    );

    final respHdr = parseChunkHeader(respFrame);
    expect(respHdr.secureChannelId, 42);
    expect(respFrame.length, respHdr.size); // header size == final frame size

    final recoveredResp = _asymDecryptVerify(
      decKey: clientKp.privateKey,
      verifyKey: serverKp.publicKey,
      frame: respFrame,
    );
    expect(recoveredResp, equals(respSeqBody));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('None policy passes through unchanged both ways', () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );
    final remainder = Uint8List.fromList(<int>[...seqHeader(3, 9), 1, 2, 3, 4]);
    final out = channel.openFromClient(
      policyUri: kSecurityPolicyNoneUri,
      senderCertificate: null,
      rawHeader: Uint8List(0),
      rawAfterSecurityHeader: remainder,
      serverNonce: serverNonce,
      clientNonce: clientNonce,
    );
    expect(out, equals(remainder));
    expect(channel.mode, OpcSecurityMode.none);

    final resp = channel.buildSecuredOpnResponse(
      secureChannelId: 5,
      sequenceNumber: 3,
      requestId: 9,
      plaintextSequenceAndBody: remainder,
    );
    final chunk = parseChunk(resp);
    expect(chunk.messageType, 'OPN');
    expect(chunk.securityPolicyUri, kSecurityPolicyNoneUri);
    expect(chunk.body, equals(Uint8List.fromList(<int>[1, 2, 3, 4])));
  });

  test('malformed encrypted OPN throws OpcSecurityException, never uncaught',
      () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );
    // 256 bytes of garbage that will not OAEP-decrypt cleanly.
    final garbage = Uint8List.fromList(List<int>.filled(256, 0xAB));
    expect(
      () => channel.openFromClient(
        policyUri: kSecurityPolicyBasic256Sha256Uri,
        senderCertificate: clientCertDer,
        rawHeader: Uint8List(12),
        rawAfterSecurityHeader: garbage,
        serverNonce: serverNonce,
        clientNonce: clientNonce,
      ),
      throwsA(isA<OpcSecurityException>()),
    );
  });

  test(
      'OPN with a present-but-wrong receiverCertificateThumbprint is rejected '
      'before decryption', () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );

    final requestBody = Uint8List.fromList(
        List<int>.generate(50, (i) => (i * 5 + 2) & 0xff));
    final clientSeqBody =
        Uint8List.fromList(<int>[...seqHeader(1, 1), ...requestBody]);

    // Wrong thumbprint: 20 bytes of 0xFF, guaranteed not to equal
    // sha1(serverCertDer).
    final wrongThumbprint = Uint8List.fromList(List<int>.filled(20, 0xFF));

    final clientFrame = _asymSignEncrypt(
      signKey: clientKp.privateKey,
      encKey: serverKp.publicKey,
      senderCertDer: clientCertDer,
      receiverThumbprint: wrongThumbprint,
      secureChannelId: 0,
      sequenceNumber: 1,
      requestId: 1,
      plainSeqBody: clientSeqBody,
    );

    final hdr = parseChunkHeader(clientFrame);
    final rawHeader =
        Uint8List.sublistView(clientFrame, 0, hdr.securityHeaderEnd);
    final rawAfter =
        Uint8List.sublistView(clientFrame, hdr.securityHeaderEnd, hdr.size);

    expect(
      () => channel.openFromClient(
        policyUri: hdr.securityPolicyUri!,
        senderCertificate: Uint8List.fromList(hdr.senderCertificate!),
        rawHeader: rawHeader,
        rawAfterSecurityHeader: rawAfter,
        serverNonce: serverNonce,
        clientNonce: clientNonce,
        receiverCertificateThumbprint:
            Uint8List.fromList(hdr.receiverCertificateThumbprint!),
      ),
      throwsA(isA<OpcSecurityException>()),
    );
  });

  // --- Task 5: symmetric MSG security ---------------------------------------

  test('symmetric MSG round-trips (sign+encrypt) and a tampered MAC is rejected',
      () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );
    const tokenId = 7;
    channel.deriveSymmetricKeys(
      tokenId: tokenId,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    );
    final clientKeys = channel.clientKeys!;
    final serverKeys = channel.serverKeys!;

    // Body length chosen so it is NOT already block-aligned, forcing >1 padding
    // byte (exercises the padding path).
    final body =
        Uint8List.fromList(List<int>.generate(53, (i) => (i * 9 + 4) & 0xff));

    // Inbound: the CLIENT signs+encrypts with the client key set; the server's
    // channel.openSymmetric (which uses the client keys) must recover it.
    final inFrame = _symBuild(
      keys: clientKeys,
      secureChannelId: 11,
      tokenId: tokenId,
      sequenceNumber: 2,
      requestId: 3,
      body: body,
    );
    final inHdr = parseChunkHeader(inFrame);
    final opened = channel.openSymmetric(
      tokenId: tokenId,
      rawHeader: Uint8List.sublistView(inFrame, 0, inHdr.securityHeaderEnd),
      rawAfterSecurityHeader:
          Uint8List.sublistView(inFrame, inHdr.securityHeaderEnd, inHdr.size),
    );
    // opened == sequenceHeader(8) ++ body
    expect(opened.length, 8 + body.length);
    expect(Uint8List.sublistView(opened, 8), equals(body));
    final openedSeq = ByteData.sublistView(opened, 0, 8);
    expect(openedSeq.getUint32(0, Endian.little), 2); // sequenceNumber
    expect(openedSeq.getUint32(4, Endian.little), 3); // requestId

    // Outbound: the SERVER builds with the server key set; a client mirror
    // (server keys) must recover it.
    final outFrame = channel.buildSecuredMsg(
      secureChannelId: 11,
      tokenId: tokenId,
      sequenceNumber: 5,
      requestId: 6,
      body: body,
    );
    expect(_symOpenBody(keys: serverKeys, frame: outFrame), equals(body));

    // Tamper: flip a byte inside the encrypted region -> HMAC fails -> throws.
    final tampered = Uint8List.fromList(inFrame);
    tampered[inHdr.securityHeaderEnd + 4] ^= 0xFF;
    expect(
      () => channel.openSymmetric(
        tokenId: tokenId,
        rawHeader: Uint8List.sublistView(tampered, 0, inHdr.securityHeaderEnd),
        rawAfterSecurityHeader: Uint8List.sublistView(
            tampered, inHdr.securityHeaderEnd, inHdr.size),
      ),
      throwsA(isA<OpcSecurityException>()),
    );
  });

  test(
      'symmetric MSG round-trips (sign-only, no AES) and a tampered MAC is '
      'rejected', () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );
    channel.messageSecurityMode = OpcSecurityMode.sign;
    const tokenId = 8;
    channel.deriveSymmetricKeys(
      tokenId: tokenId,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    );
    final clientKeys = channel.clientKeys!;
    final serverKeys = channel.serverKeys!;

    // Body length chosen so it is NOT already block-aligned, forcing >1
    // padding byte — Sign mode must pad exactly like SignAndEncrypt.
    final body =
        Uint8List.fromList(List<int>.generate(53, (i) => (i * 11 + 2) & 0xff));

    // Inbound: the CLIENT signs (no encrypt) with the client key set; the
    // server's channel.openSymmetric (client keys) must recover it.
    final inFrame = _symBuildSignOnly(
      keys: clientKeys,
      secureChannelId: 12,
      tokenId: tokenId,
      sequenceNumber: 2,
      requestId: 3,
      body: body,
    );
    final inHdr = parseChunkHeader(inFrame);
    final opened = channel.openSymmetric(
      tokenId: tokenId,
      rawHeader: Uint8List.sublistView(inFrame, 0, inHdr.securityHeaderEnd),
      rawAfterSecurityHeader:
          Uint8List.sublistView(inFrame, inHdr.securityHeaderEnd, inHdr.size),
    );
    expect(opened.length, 8 + body.length);
    expect(Uint8List.sublistView(opened, 8), equals(body));

    // Outbound: the SERVER builds (Sign mode) with the server key set.
    final outFrame = channel.buildSecuredMsg(
      secureChannelId: 12,
      tokenId: tokenId,
      sequenceNumber: 5,
      requestId: 6,
      body: body,
    );

    // Sanity-check the built chunk is NOT AES-encrypted: the plaintext
    // sequenceHeader++body region is present in the clear immediately after
    // the security header (before the padding + 32-byte HMAC).
    final outHdr = parseChunkHeader(outFrame);
    final plainRegion = Uint8List.sublistView(outFrame,
        outHdr.securityHeaderEnd, outHdr.securityHeaderEnd + 8 + body.length);
    expect(Uint8List.sublistView(plainRegion, 8), equals(body));

    // The chunk reflects padding + the 32-byte HMAC: the secured region is
    // longer than the unpadded seqHeader+body+HMAC (padding is present), and
    // — since Sign uses the same padding sizing as SignAndEncrypt — its
    // length is a multiple of the AES block size (16).
    final securedLen = outHdr.size - outHdr.securityHeaderEnd;
    expect(securedLen, greaterThan(8 + body.length + kSymSignatureSize));
    expect(securedLen % 16, 0);

    final openedOut = _symOpenBodySignOnly(keys: serverKeys, frame: outFrame);
    expect(openedOut, equals(body));

    // Tamper: flip a byte inside the signed region -> HMAC fails -> throws.
    final tampered = Uint8List.fromList(inFrame);
    tampered[inHdr.securityHeaderEnd + 4] ^= 0xFF;
    expect(
      () => channel.openSymmetric(
        tokenId: tokenId,
        rawHeader: Uint8List.sublistView(tampered, 0, inHdr.securityHeaderEnd),
        rawAfterSecurityHeader: Uint8List.sublistView(
            tampered, inHdr.securityHeaderEnd, inHdr.size),
      ),
      throwsA(isA<OpcSecurityException>()),
    );
  });

  test('Renew derives fresh keys while the old token still validates within '
      'lifetime', () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );

    // Issue: token 1 keyed on nonce set A.
    channel.deriveSymmetricKeys(
      tokenId: 1,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    );
    final clientKeysA = channel.clientKeys!;

    // A message secured under token 1 (before the renew).
    final body =
        Uint8List.fromList(List<int>.generate(20, (i) => (i * 3) & 0xff));
    final frameA = _symBuild(
      keys: clientKeysA,
      secureChannelId: 22,
      tokenId: 1,
      sequenceNumber: 1,
      requestId: 1,
      body: body,
    );

    // Renew: token 2 keyed on a DIFFERENT nonce set B -> fresh keys.
    final clientNonceB = Uint8List.fromList(
        List<int>.generate(kSecureChannelNonceLength, (i) => i + 50));
    final serverNonceB = Uint8List.fromList(
        List<int>.generate(kSecureChannelNonceLength, (i) => 100 + i));
    channel.deriveSymmetricKeys(
      tokenId: 2,
      clientNonce: clientNonceB,
      serverNonce: serverNonceB,
    );
    final clientKeysB = channel.clientKeys!;
    expect(clientKeysB.encryptingKey, isNot(equals(clientKeysA.encryptingKey)));

    // The OLD token (1) still validates after the renew.
    final hdrA = parseChunkHeader(frameA);
    final openedA = channel.openSymmetric(
      tokenId: 1,
      rawHeader: Uint8List.sublistView(frameA, 0, hdrA.securityHeaderEnd),
      rawAfterSecurityHeader:
          Uint8List.sublistView(frameA, hdrA.securityHeaderEnd, hdrA.size),
    );
    expect(Uint8List.sublistView(openedA, 8), equals(body));

    // The NEW token (2) validates with the fresh key set.
    final frameB = _symBuild(
      keys: clientKeysB,
      secureChannelId: 22,
      tokenId: 2,
      sequenceNumber: 2,
      requestId: 2,
      body: body,
    );
    final hdrB = parseChunkHeader(frameB);
    final openedB = channel.openSymmetric(
      tokenId: 2,
      rawHeader: Uint8List.sublistView(frameB, 0, hdrB.securityHeaderEnd),
      rawAfterSecurityHeader:
          Uint8List.sublistView(frameB, hdrB.securityHeaderEnd, hdrB.size),
    );
    expect(Uint8List.sublistView(openedB, 8), equals(body));
  });

  // --- Task 5: UserNameIdentityToken password decrypt -----------------------

  test('decryptUserPassword recovers the password and rejects a wrong nonce',
      () {
    final channel = OpcSecureChannel(
      keyPair: serverKp,
      certificateDer: serverCertDer,
    );
    // Establish a serverNonce on the channel (as a real OPN would).
    channel.deriveSymmetricKeys(
      tokenId: 1,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    );

    const password = 'sup3r-s3cret-päss'; // includes a non-ASCII char
    final encrypted = _legacyPasswordEncrypt(
      serverPub: serverKp.publicKey,
      password: password,
      serverNonce: serverNonce,
    );
    expect(channel.decryptUserPassword(encrypted), password);

    // A token encrypted against a DIFFERENT nonce is rejected (null), because
    // the trailing nonce won't match the channel's lastServerNonce.
    final wrongNonce = Uint8List.fromList(
        List<int>.generate(kSecureChannelNonceLength, (i) => i));
    final encryptedWrong = _legacyPasswordEncrypt(
      serverPub: serverKp.publicKey,
      password: password,
      serverNonce: wrongNonce,
    );
    expect(channel.decryptUserPassword(encryptedWrong), isNull);

    // Garbage that won't OAEP-decrypt is rejected (null), never throws.
    expect(
      channel.decryptUserPassword(
          Uint8List.fromList(List<int>.filled(256, 0x5A))),
      isNull,
    );
    expect(channel.lastServerNonce, equals(serverNonce));
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Client-side mirror of the server's symmetric sign+encrypt (SignAndEncrypt),
/// written independently from `secure_channel.rs symmetric_sign_and_encrypt`:
/// pad to the AES block, HMAC-SHA256 over the whole chunk except the signature,
/// then AES-256-CBC encrypt the sequence-header..signature region.
Uint8List _symBuild({
  required OpcChannelKeys keys,
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required Uint8List body,
}) {
  const headerSize = 16; // chunk header(12) + tokenId(4)
  const sig = 32;
  const block = 16;
  final plainFrame = buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
  final encryptSize = 8 + body.length + sig + 1;
  final rem = encryptSize % block;
  final inner = rem == 0 ? 0 : block - rem;
  final padTotal = 1 + inner;
  final pad = Uint8List(padTotal)..fillRange(0, padTotal, inner & 0xff);

  final tmp = Uint8List(headerSize + 8 + body.length + padTotal + sig);
  tmp.setRange(0, plainFrame.length, plainFrame);
  tmp.setRange(plainFrame.length, plainFrame.length + padTotal, pad);
  ByteData.sublistView(tmp, 4, 8).setUint32(0, tmp.length, Endian.little);

  final signedEnd = tmp.length - sig;
  final signature =
      hmacSha256(keys.signingKey, Uint8List.sublistView(tmp, 0, signedEnd));
  tmp.setRange(signedEnd, tmp.length, signature);

  final cipher = aes256CbcEncrypt(
    keys.encryptingKey,
    keys.iv,
    Uint8List.sublistView(tmp, headerSize, tmp.length),
  );
  final out = Uint8List(tmp.length);
  out.setRange(0, headerSize, tmp);
  out.setRange(headerSize, out.length, cipher);
  return out;
}

/// Client-side mirror of the server's symmetric Sign-only path: the SAME
/// padding + HMAC layout as [_symBuild]'s SignAndEncrypt, but the
/// sequenceHeader..signature region is left in the clear (no AES step).
Uint8List _symBuildSignOnly({
  required OpcChannelKeys keys,
  required int secureChannelId,
  required int tokenId,
  required int sequenceNumber,
  required int requestId,
  required Uint8List body,
}) {
  const headerSize = 16; // chunk header(12) + tokenId(4)
  const sig = 32;
  const block = 16;
  final plainFrame = buildMsgChunk(
    secureChannelId: secureChannelId,
    tokenId: tokenId,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
  final encryptSize = 8 + body.length + sig + 1;
  final rem = encryptSize % block;
  final inner = rem == 0 ? 0 : block - rem;
  final padTotal = 1 + inner;
  final pad = Uint8List(padTotal)..fillRange(0, padTotal, inner & 0xff);

  final tmp = Uint8List(headerSize + 8 + body.length + padTotal + sig);
  tmp.setRange(0, plainFrame.length, plainFrame);
  tmp.setRange(plainFrame.length, plainFrame.length + padTotal, pad);
  ByteData.sublistView(tmp, 4, 8).setUint32(0, tmp.length, Endian.little);

  final signedEnd = tmp.length - sig;
  final signature =
      hmacSha256(keys.signingKey, Uint8List.sublistView(tmp, 0, signedEnd));
  tmp.setRange(signedEnd, tmp.length, signature);
  return tmp; // no AES step
}

/// Client-side mirror of the Sign-only receive path: verify HMAC, strip
/// padding, return the body (dropping the 8-byte sequence header). No AES.
Uint8List _symOpenBodySignOnly({
  required OpcChannelKeys keys,
  required Uint8List frame,
}) {
  const sig = 32;
  final hdr = parseChunkHeader(frame);
  final rawHeader = Uint8List.sublistView(frame, 0, hdr.securityHeaderEnd);
  final rawAfter =
      Uint8List.sublistView(frame, hdr.securityHeaderEnd, hdr.size);
  final signedEnd = rawAfter.length - sig;
  final signed = Uint8List(rawHeader.length + signedEnd);
  signed.setRange(0, rawHeader.length, rawHeader);
  signed.setRange(rawHeader.length, signed.length,
      Uint8List.sublistView(rawAfter, 0, signedEnd));
  final expected = hmacSha256(keys.signingKey, signed);
  expect(Uint8List.sublistView(rawAfter, signedEnd), equals(expected));
  final padByte = rawAfter[signedEnd - 1];
  final bodyEnd = signedEnd - (padByte + 1);
  return Uint8List.fromList(Uint8List.sublistView(rawAfter, 8, bodyEnd));
}

/// Client-side mirror of the receive path: AES-decrypt, verify HMAC, strip
/// padding, return the body (dropping the 8-byte sequence header).
Uint8List _symOpenBody({
  required OpcChannelKeys keys,
  required Uint8List frame,
}) {
  const sig = 32;
  final hdr = parseChunkHeader(frame);
  final rawHeader = Uint8List.sublistView(frame, 0, hdr.securityHeaderEnd);
  final rawAfter =
      Uint8List.sublistView(frame, hdr.securityHeaderEnd, hdr.size);
  final dec = aes256CbcDecrypt(keys.encryptingKey, keys.iv, rawAfter);
  final signedEnd = dec.length - sig;
  final signed = Uint8List(rawHeader.length + signedEnd);
  signed.setRange(0, rawHeader.length, rawHeader);
  signed.setRange(rawHeader.length, signed.length,
      Uint8List.sublistView(dec, 0, signedEnd));
  final expected = hmacSha256(keys.signingKey, signed);
  expect(Uint8List.sublistView(dec, signedEnd), equals(expected));
  final padByte = dec[signedEnd - 1];
  final bodyEnd = signedEnd - (padByte + 1);
  return Uint8List.fromList(Uint8List.sublistView(dec, 8, bodyEnd));
}

/// Client-side mirror of `user_identity.rs legacy_password_encrypt`: build the
/// plaintext `UInt32-LE (len) ++ password ++ serverNonce` and RSA-OAEP-SHA1
/// encrypt it under the server public key (one 256-byte block for <=214 bytes).
Uint8List _legacyPasswordEncrypt({
  required RSAPublicKey serverPub,
  required String password,
  required Uint8List serverNonce,
}) {
  final passBytes = Uint8List.fromList(utf8.encode(password));
  final plaintextLen = 4 + passBytes.length + serverNonce.length;
  final src = Uint8List(plaintextLen);
  ByteData.sublistView(src, 0, 4)
      .setUint32(0, plaintextLen - 4, Endian.little);
  src.setRange(4, 4 + passBytes.length, passBytes);
  src.setRange(4 + passBytes.length, plaintextLen, serverNonce);
  return rsaOaepSha1Encrypt(serverPub, src);
}

/// Independent client-side mirror of the server's asymmetric sign+encrypt.
Uint8List _asymSignEncrypt({
  required RSAPrivateKey signKey,
  required RSAPublicKey encKey,
  required Uint8List senderCertDer,
  required Uint8List receiverThumbprint,
  required int secureChannelId,
  required int sequenceNumber,
  required int requestId,
  required Uint8List plainSeqBody,
}) {
  const plainBlock = 214;
  const cipherBlock = 256;
  const sigSize = 256;

  final body = Uint8List.sublistView(plainSeqBody, 8);
  final plainFrame = buildOpnChunk(
    secureChannelId: secureChannelId,
    securityPolicyUri: kSecurityPolicyBasic256Sha256Uri,
    senderCertificate: senderCertDer,
    receiverCertificateThumbprint: receiverThumbprint,
    sequenceNumber: sequenceNumber,
    requestId: requestId,
    body: body,
  );
  final headerSize = plainFrame.length - plainSeqBody.length;

  final encryptSize = 8 + body.length + sigSize + 1;
  final rem = encryptSize % plainBlock;
  final pInner = rem == 0 ? 0 : plainBlock - rem;
  final padTotal = 1 + pInner;
  final pad = Uint8List(padTotal)..fillRange(0, padTotal, pInner & 0xff);

  final encPlainLen = plainSeqBody.length + padTotal + sigSize;
  final tmp = Uint8List(headerSize + encPlainLen);
  tmp.setRange(0, plainFrame.length, plainFrame);
  tmp.setRange(plainFrame.length, plainFrame.length + padTotal, pad);

  final cipherTextSize = (encPlainLen ~/ plainBlock) * cipherBlock;
  ByteData.sublistView(tmp, 4, 8)
      .setUint32(0, headerSize + cipherTextSize, Endian.little);

  final signedEnd = tmp.length - sigSize;
  var sig = rsaPkcs1Sha256Sign(signKey, Uint8List.sublistView(tmp, 0, signedEnd));
  if (sig.length < sigSize) {
    final padded = Uint8List(sigSize);
    padded.setRange(sigSize - sig.length, sigSize, sig);
    sig = padded;
  }
  tmp.setRange(signedEnd, tmp.length, sig);

  final out = BytesBuilder(copy: true);
  out.add(Uint8List.sublistView(tmp, 0, headerSize));
  for (var i = headerSize; i < tmp.length; i += plainBlock) {
    out.add(rsaOaepSha1Encrypt(encKey, Uint8List.sublistView(tmp, i, i + plainBlock)));
  }
  return out.takeBytes();
}

/// Independent decrypt+verify of a secured OPN frame (mirrors the receive side).
Uint8List _asymDecryptVerify({
  required RSAPrivateKey decKey,
  required RSAPublicKey verifyKey,
  required Uint8List frame,
}) {
  const cipherBlock = 256;
  const sigSize = 256;

  final hdr = parseChunkHeader(frame);
  final rawHeader = Uint8List.sublistView(frame, 0, hdr.securityHeaderEnd);
  final enc = Uint8List.sublistView(frame, hdr.securityHeaderEnd, hdr.size);

  final dec = BytesBuilder(copy: true);
  for (var i = 0; i < enc.length; i += cipherBlock) {
    dec.add(rsaOaepSha1Decrypt(decKey, Uint8List.sublistView(enc, i, i + cipherBlock)));
  }
  final plain = dec.takeBytes();
  final signedEnd = plain.length - sigSize;
  final sig = Uint8List.sublistView(plain, signedEnd);
  final signed = Uint8List(rawHeader.length + signedEnd);
  signed.setRange(0, rawHeader.length, rawHeader);
  signed.setRange(rawHeader.length, signed.length, plain);
  expect(rsaPkcs1Sha256Verify(verifyKey, signed, sig), isTrue);

  final padByte = plain[signedEnd - 1];
  final bodyEnd = signedEnd - (padByte + 1);
  return Uint8List.fromList(Uint8List.sublistView(plain, 0, bodyEnd));
}
